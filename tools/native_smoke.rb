# frozen_string_literal: true

require 'json'
require 'open3'
require 'set'

# Direct bundle-executable launch is deliberate for diagnostics: it gives this
# runner a waitable process, even when the app crashes or never writes a report.
class NativeSmokeProcess
  def initialize(command)
    @pid = Process.spawn(*command)
    @owned = {}
    @status = nil
  end

  def wait(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      observe
      result = Process.waitpid2(@pid, Process::WNOHANG) unless @status
      @status = result[1] if result
      return @status if @status
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def cleanup
    observe
    live = survivors
    return [] if live.empty?

    # First allow normal PTY HUP/close handling; force only this test's survivors.
    signal(live, 'TERM')
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
    until survivors.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      wait(0.05)
      sleep 0.05 if @status
    end
    signal(survivors, 'KILL')
    Process.wait(@pid) unless @status
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.05 until survivors.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    survivors
  rescue Errno::ECHILD
    survivors
  end

  def live_pids
    survivors
  end

  private

  def processes
    output, status = Open3.capture2('/bin/ps', '-axo', 'pid=,ppid=,lstart=')
    raise 'Cannot inspect smoke process ownership' unless status.success?

    output.lines.to_h do |line|
      pid, parent, started = line.strip.split(/\s+/, 3)
      [Integer(pid), [Integer(parent), started]]
    end
  end

  def observe
    table = processes
    parents = Set.new(@owned.keys.select { |pid| table[pid] && table[pid][1] == @owned[pid] })
    parents.add(@pid) unless @status
    loop do
      added = table.keys.select { |pid| parents.include?(table[pid][0]) && !parents.include?(pid) }
      break if added.empty?

      parents.merge(added)
    end
    parents.each { |pid| @owned[pid] ||= table[pid][1] if table[pid] }
  end

  def survivors
    table = processes
    @owned.keys.select { |pid| table[pid] && table[pid][1] == @owned[pid] }
  end

  def signal(pids, name)
    pids.each do |pid|
      # Recheck identity immediately before signalling, including after app exit.
      Process.kill(name, pid) if survivors.include?(pid)
    rescue Errno::ESRCH
      next
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Signal.trap('TERM') { raise Interrupt, 'Smoke runner terminated' }
  Signal.trap('INT') { raise Interrupt, 'Smoke runner interrupted' }
  mode = ARGV.fetch(0)
  root = File.expand_path('..', __dir__)
  report_name, flag, seconds, extra = case mode
  when 'normal' then ['native-smoke', '--self-test', 20, []]
  when 'editing' then ['editing-smoke', '--editing-smoke', 20, []]
  when 'glyph' then ['glyph-smoke', '--glyph-smoke', 55, ['--columns', '100', '--rows', '36', '--font-size', '14']]
  when 'idle' then ['native-idle', '--self-test', 90, ['--idle-test']]
  else abort "Unknown smoke mode: #{mode}"
  end
  path = File.join(root, 'reports', "#{report_name}.json")
  File.delete(path) if File.exist?(path)
  process = NativeSmokeProcess.new([File.join(root, 'dist/Terminal.app/Contents/MacOS/Terminal'), flag, path, *extra])
  begin
    status = process.wait(seconds)
    raise "#{mode} smoke timed out" unless status
    raise "#{mode} smoke exited with #{status}" unless status.success?
    raise "Smoke app exited leaving children: #{process.live_pids.join(', ')}" unless process.live_pids.empty?

    report = JSON.parse(File.read(path))
    raise "Native smoke failed: #{report.fetch('checks', report['failures'])}" unless report.fetch('passed')
  ensure
    remaining = process.cleanup
    raise "Smoke processes survived cleanup: #{remaining.join(', ')}" unless remaining.empty?
  end
  puts "PASS #{mode} smoke and app termination"
end

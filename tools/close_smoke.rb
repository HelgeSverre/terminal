#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'native_smoke'

# Launch the selected bundle directly so shutdown is waitable for development
# and hardened release builds alike. Cleanup owns only the spawned process tree.
if $PROGRAM_NAME == __FILE__
  Signal.trap('TERM') { raise Interrupt, 'Closure smoke interrupted' }
  Signal.trap('INT') { raise Interrupt, 'Closure smoke interrupted' }
  abort 'Usage: ruby tools/close_smoke.rb [app-bundle]' if ARGV.length > 1

  root = File.expand_path('..', __dir__)
  bundle = File.expand_path(ARGV.fetch(0, 'dist/Terminal.app'), root)
  app = File.join(bundle, 'Contents/MacOS/Terminal')
  abort "Missing executable: #{app}" unless File.executable?(app)

  %w[window shortcut].each do |mode|
    path = File.join(root, 'reports', "close-#{mode}-smoke.json")
    File.delete(path) if File.exist?(path)
    flags = mode == 'shortcut' ? ['--quit-shortcut'] : []
    process = NativeSmokeProcess.new([
      app, '--close-smoke', path, *flags, '--execute', '/bin/sh', '-c',
      "trap '' HUP; printf CLOSE_SMOKE_READY; exec /bin/sleep 30",
      out: File::NULL, err: File::NULL
    ])
    report = nil
    begin
      status = process.wait(10)
      raise "#{mode}: app did not exit successfully" unless status&.success?

      report = JSON.parse(File.read(path))
      trigger = mode == 'shortcut' ? 'cmd+q' : 'last-window-close'
      raise "#{mode}: incorrect shutdown trigger" unless report.fetch('trigger') == trigger

      child = report.fetch('child_pid')
      raise "#{mode}: invalid child PID" unless child.is_a?(Integer) && child > 0

      begin
        Process.kill(0, child)
        raise "#{mode}: PTY child survived app shutdown"
      rescue Errno::ESRCH
        # The native fixture must reap this child itself, before cleanup runs.
      end
      raise "#{mode}: descendants survived app shutdown" unless process.live_pids.empty?

      report.merge!('passed' => true, 'app_exited' => true, 'child_exited' => true, 'bundle_path' => bundle)
    rescue Exception => error # Interrupts must also invalidate a partial report.
      report ||= {}
      report.merge!('passed' => false, 'runner_error' => error.message)
      raise
    ensure
      begin
        remaining = process.cleanup
        raise "#{mode}: processes survived cleanup: #{remaining.join(', ')}" unless remaining.empty?
      rescue Exception => error
        report ||= {}
        report.merge!('passed' => false, 'cleanup_error' => error.message)
        raise
      ensure
        File.write(path, JSON.pretty_generate(report) + "\n") if report
      end
    end
    puts "PASS #{mode}: application exited and PTY descendants reaped"
  end
end

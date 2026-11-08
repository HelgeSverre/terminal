# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'native_smoke'

motion = ARGV.length == 4 && ARGV.last == 'motion'
ARGV.pop if motion
abort "Usage: #{$PROGRAM_NAME} APP SOURCE_FILE NEW_OUTPUT_DIRECTORY [motion]" unless ARGV.length == 3
Signal.trap('TERM') { raise Interrupt, 'Cat stress terminated' }
Signal.trap('INT') { raise Interrupt, 'Cat stress interrupted' }
app, source = ARGV[0, 2].map { |path| File.realpath(path) }
output = File.expand_path(ARGV[2])
abort 'Choose a new output directory' if File.exist?(output)
executable = File.join(app, 'Contents/MacOS/Terminal')
abort 'Missing app executable' unless File.executable?(executable)
initial = File.stat(source)
abort 'Source must be a nonempty regular file' unless initial.file? && initial.size.positive?
identity = ->(stat) { [stat.dev, stat.ino, stat.size, stat.mtime.to_i, stat.mtime.nsec] }
FileUtils.mkdir_p(output)
report = File.join(output, 'cat.json')
result = { 'passed' => false, 'app' => app, 'source_name' => File.basename(source),
           'window_motion_requested' => motion,
           'source_bytes' => initial.size, 'source_identity' => identity.call(initial),
           'executable_sha256' => Digest::SHA256.file(executable).hexdigest,
           'runner_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
           'scope' => 'Full local file through /bin/cat, primary history and scheduled live resize probes; no file contents recorded.' }
process = nil
begin
  command = [
    executable, '--columns', '100', '--rows', '30', '--font-size', '14', '--history-limit', '10000',
    '--cat-smoke', report, initial.size.to_s
  ]
  command << '--cat-motion-stress' if motion
  command.concat(['--execute', '/bin/cat', '--', source])
  process = NativeSmokeProcess.new(command, log: File.join(output, 'app-launch.log'))
  result['pid'] = process.pid
  status = process.wait(630)
  raise 'Cat stress timed out' unless status
  result['exit_status'] = status.exitstatus
  raise 'App exited unsuccessfully' unless status.success?
  raise 'App left owned children' unless process.live_pids.empty?
  data = JSON.parse(File.read(report))
  raise 'Cat stress checks failed' unless data.fetch('passed') && data.fetch('final')
  raise 'Wrong source extent' unless data.fetch('source_file_bytes') == initial.size
  raise 'Metal command errors' unless data.fetch('renderer').fetch('command_errors').zero?
  if motion
    movement = data.fetch('window_motion')
    raise 'Window motion did not finish' unless movement.fetch('stopped_reason') == 'cat_finished'
    raise 'Window motion did not cover a complete cycle' unless movement.fetch('duration_seconds') >= 7 && movement.fetch('tick_count') > 1
    bounds = movement.fetch('applied_frame_bounds')
    %w[x y width height].each do |axis|
      raise "Window #{axis} did not vary" unless bounds.fetch("max_#{axis}") > bounds.fetch("min_#{axis}") + 1
    end
  end
  session = data.fetch('session')
  raise 'Session did not drain and reap' unless session.values_at('child_reaped', 'read_ended', 'parser_ended').all?
  raise 'Source changed during the run' unless identity.call(File.stat(source)) == identity.call(initial)
  result['natural_exit'] = true
  result['passed'] = true
rescue StandardError, Interrupt => error
  result['failure'] = "#{error.class}: #{error.message}"
  raise
ensure
  begin
    result['cleanup_survivors'] = process ? process.cleanup : []
    result['passed'] = false unless result['cleanup_survivors'].empty?
  rescue StandardError => error
    result['passed'] = false
    result['cleanup_failure'] = "#{error.class}: #{error.message}"
  ensure
    File.write(File.join(output, 'provenance.json'), JSON.pretty_generate(result) + "\n")
  end
end
abort 'Cat stress cleanup failed' unless result.fetch('passed')
puts 'PASS full-file cat stress; app and children exited cleanly'

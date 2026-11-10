# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'native_smoke'

Signal.trap('TERM') { raise Interrupt, 'Diagnostic terminated' }
Signal.trap('INT') { raise Interrupt, 'Diagnostic interrupted' }

abort "Usage: #{$PROGRAM_NAME} APP NEW_OUTPUT_DIRECTORY BYTES_PER_RUN" unless ARGV.length == 3
app = File.realpath(ARGV[0])
output = File.expand_path(ARGV[1])
bytes = Integer(ARGV[2], 10)
abort 'Bytes must be between 1 and 1 GiB' unless (1..1_073_741_824).cover?(bytes)
abort 'Choose a new output directory' if File.exist?(output)
executable = File.join(app, 'Contents/MacOS/Terminal')
abort 'Missing app executable' unless File.executable?(executable)
FileUtils.mkdir_p(output)
source = File.expand_path('../Benchmarks/TerminalBench/terminal-bench.c', __dir__)
driver = File.join(output, 'terminal-bench')
statistics = File.join(output, 'session.json')
report = File.join(output, 'driver.json')
result = { 'passed' => false, 'scope' => 'Instrumented short-ASCII diagnosis; not performance acceptance.',
           'app' => app, 'executable_sha256' => Digest::SHA256.file(executable).hexdigest,
           'driver_source_sha256' => Digest::SHA256.file(source).hexdigest,
           'runner_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
           'requested_bytes_per_run' => bytes, 'runs' => 10 }
process = nil
begin
  diagnostics, status = Open3.capture2e('xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-O2', source, '-o', driver)
  File.write(File.join(output, 'driver-build.log'), diagnostics)
  raise 'Driver compilation failed' unless status.success?
  result['driver_sha256'] = Digest::SHA256.file(driver).hexdigest
  process = NativeSmokeProcess.new([
    executable, *(ENV['BENCH_BACKGROUND'] == '1' ? ['--background'] : []),
    '--columns', '100', '--rows', '30', '--font-size', '14',
    '--session-statistics-file', statistics, '--exit-after-command', '--execute', driver,
    '--output', report, '--terminal', 'session-diagnostic', '--bytes', bytes.to_s,
    '--runs', '10', '--columns', '100', '--rows', '30', '--workload', 'ascii_short_lines'
  ])
  result['pid'] = process.pid
  status = process.wait(180)
  raise File.read("#{report}.failed") if File.file?("#{report}.failed")
  raise 'Diagnostic timed out' unless status
  result['exit_status'] = status.exitstatus
  raise 'App did not exit successfully' unless status.success?
  raise 'Owned children survived app exit' unless process.live_pids.empty?
  data = JSON.parse(File.read(report))
  raise 'Unexpected driver schema or process' unless data.fetch('schema') == 2 && data.fetch('terminal_pid') == process.pid
  raise 'Unexpected terminal label' unless data.fetch('terminal') == 'session-diagnostic'
  raise 'Unexpected terminal geometry' unless data.values_at('columns', 'rows') == [100, 30]
  workloads = data.fetch('workloads')
  raise 'Unexpected workload' unless workloads.length == 1 && workloads[0].fetch('name') == 'ascii_short_lines'
  workload = workloads[0]
  raise 'Incomplete workload' unless workload.fetch('source_bytes_per_run') == bytes && workload.dig('mib_per_second', 'samples') == 10
  observations = workload.fetch('run_samples')
  raise 'Missing ordered observations' unless observations.length == 10 && observations.map { |run| run.fetch('run') } == (1..10).to_a
  observations.each do |run|
    %w[mib_per_second elapsed_seconds].each do |key|
      value = run.fetch(key)
      raise "Invalid #{key}" unless value.is_a?(Numeric) && value.finite? && value.positive?
    end
  end
  raise 'Raw rate median differs' unless observations.map { |run| run.fetch('mib_per_second') }.sort[4] == workload.dig('mib_per_second', 'p50')
  result['diagnostic_mib_per_second'] = workload.fetch('mib_per_second')
  session = JSON.parse(File.read(statistics))
  raise 'Session did not drain and reap' unless session.values_at('child_reaped', 'read_ended', 'parser_ended').all?
  raise 'Output was not fully parsed' unless session.fetch('bytes_read') == session.fetch('bytes_parsed') && session.fetch('queued_output_bytes').zero?
  raise 'Session parsed less than the requested source' unless session.fetch('bytes_parsed') >= bytes * 10
  counters = session.fetch('stream_diagnostic')
  raise 'Counter byte accounting differs' unless counters.fetch('feed_bytes') == session.fetch('bytes_parsed')
  raise 'No output events recorded' unless counters.fetch('output_events').positive?
  source_mib = bytes * 10 / 1_048_576.0
  result['per_source_mib'] = counters.transform_values { |value| value / source_mib }
  result['per_source_mib'].delete('event_queue_high_water')
  result['per_source_mib'].delete('queued_output_bytes_high_water')
  result['mean_output_event_bytes'] = session.fetch('bytes_read').fdiv(counters.fetch('output_events'))
  result['natural_exit'] = true
  result['passed'] = true
rescue StandardError, Interrupt => error
  result['failure'] = "#{error.class}: #{error.message}"
  raise
ensure
  if process
    result['cleanup_survivors'] = process.cleanup
    result['passed'] = false unless result['cleanup_survivors'].empty?
  end
  File.write(File.join(output, 'diagnostic.json'), JSON.pretty_generate(result) + "\n")
end
abort 'Owned process cleanup failed' unless result.fetch('passed')
puts 'PASS session stream diagnostic; app and children exited cleanly'

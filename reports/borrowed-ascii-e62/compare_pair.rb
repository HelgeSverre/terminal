require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require '/Users/helge/code/terminal/tools/native_smoke'
require '/Users/helge/code/terminal/tools/compare_terminal_apps'

Signal.trap('TERM') { raise Interrupt, 'Pair runner terminated' }
Signal.trap('INT') { raise Interrupt, 'Pair runner interrupted' }
abort 'Usage: compare_pair.rb NEW_OUTPUT BASELINE_APP CANDIDATE_APP' unless ARGV.length == 3
output, baseline, candidate = ARGV.map { |path| File.expand_path(path) }
abort 'Choose a new report directory' if File.exist?(output)
apps = { 'baseline' => baseline, 'candidate' => candidate }
bytes = 16 * 1024 * 1024
runs = 10
result = { 'passed' => false, 'scope' => 'Two Swift WMO app builds; sequential B-C-C-B, same PTY driver and geometry. Not display FPS.',
           'bytes_per_run' => bytes, 'runs' => runs, 'trials' => [],
           'runner_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
           'validator_sha256' => Digest::SHA256.file('/Users/helge/code/terminal/tools/compare_terminal_apps.rb').hexdigest,
           'load_before' => `sysctl -n vm.loadavg`.strip,
           'apps' => apps.transform_values { |app| { 'bundle' => app,
             'executable_sha256' => Digest::SHA256.file(File.join(app, 'Contents/MacOS/Terminal')).hexdigest } } }
FileUtils.mkdir_p(output)
validator = TerminalAppComparison.allocate
validator.instance_variable_set(:@bytes, bytes)
validator.instance_variable_set(:@runs, runs)
begin
  source = '/Users/helge/code/terminal/Benchmarks/TerminalBench/terminal-bench.c'
  driver = File.join(output, 'terminal-bench')
  diagnostics, status = Open3.capture2e('xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-O2', source, '-o', driver)
  File.write(File.join(output, 'driver-build.log'), diagnostics)
  raise 'Driver compilation failed' unless status.success?
  result['driver_source_sha256'] = Digest::SHA256.file(source).hexdigest
  result['driver_sha256'] = Digest::SHA256.file(driver).hexdigest
  [%w[baseline candidate], %w[candidate baseline]].each_with_index do |order, index|
    trial = { 'order' => order, 'apps' => {} }
    result['trials'] << trial
    order.each do |name|
      executable = File.join(apps.fetch(name), 'Contents/MacOS/Terminal')
      raise 'App changed after freezing' unless Digest::SHA256.file(executable).hexdigest == result['apps'][name]['executable_sha256']
      report = File.join(output, "#{index + 1}-#{name}.json")
      record = { 'natural_exit' => false }
      trial['apps'][name] = record
      process = nil
      begin
        command = [executable, '--columns', '100', '--rows', '30', '--font-size', '14',
          '--history-limit', '10000', '--exit-after-command', '--execute', driver,
          '--output', report, '--terminal', name, '--bytes', bytes.to_s, '--runs', runs.to_s,
          '--columns', '100', '--rows', '30']
        record['command'] = command
        process = NativeSmokeProcess.new(command, log: File.join(output, "#{index + 1}-#{name}.log"))
        record['pid'] = process.pid
        puts "Trial #{index + 1}: #{name}, PID #{process.pid}"
        STDOUT.flush
        status = process.wait(300)
        raise File.read("#{report}.failed") if File.file?("#{report}.failed")
        raise 'App failed or timed out' unless status&.success?
        raise 'Owned child survived natural exit' unless process.live_pids.empty?
        data = JSON.parse(File.read(report))
        raise 'Wrong report owner, terminal or schema' unless data['schema'] == 2 && data['terminal_pid'] == process.pid && data['terminal'] == name
        raise 'Wrong grid' unless data.values_at('columns', 'rows') == [100, 30]
        raise 'Missing PTY modes' unless [true, false].include?(data['output_post_processing'])
        raise 'Missing pixel geometry' unless data.values_at('pixel_width', 'pixel_height').all? { |value| value.is_a?(Integer) && value.positive? }
        raise 'Wrong workloads' unless data.fetch('workloads').map { |w| w['name'] } == %w[ascii_short_lines ascii_long_lines ansi_truecolor unicode]
        data.fetch('workloads').each { |workload| validator.send(:validate_workload, workload, name) }
        record['report'] = data
        record['natural_exit'] = true
      ensure
        record['cleanup_survivors'] = process ? process.cleanup : []
        raise 'Owned cleanup survivors' unless record['cleanup_survivors'].empty?
      end
    end
    layouts = trial['apps'].values.map { |app| app['report'].values_at('columns', 'rows', 'pixel_width', 'pixel_height', 'output_post_processing') }
    raise 'PTY layouts differ' unless layouts.uniq.length == 1
    trial['ratios'] = trial['apps']['candidate']['report']['workloads'].each_with_index.to_h do |workload, i|
      [workload['name'], workload.dig('mib_per_second', 'p50') / trial['apps']['baseline']['report']['workloads'][i].dig('mib_per_second', 'p50')]
    end
  end
  result['passed'] = true
rescue StandardError, Interrupt => error
  result['failure'] = "#{error.class}: #{error.message}"
  raise
ensure
  result['load_after'] = `sysctl -n vm.loadavg`.strip
  File.write(File.join(output, 'comparison.json'), JSON.pretty_generate(result) + "\n")
end
puts 'PASS paired Swift app comparison; all owned processes exited'

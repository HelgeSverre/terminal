# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'native_smoke'

# Both bundles are launched directly into independent, owned processes. Each
# runs the same PTY driver and must exit naturally with all children reaped.
class TerminalAppComparison
  MINIMUM_SWIFT_TO_RUST_RATIO = 0.7

  def initialize(output, rust_app, swift_app)
    @output = File.expand_path(output)
    @apps = { 'rust' => File.realpath(rust_app), 'swift' => File.realpath(swift_app) }
    first = ENV.fetch('BENCH_FIRST', 'rust')
    raise 'BENCH_FIRST must be rust or swift' unless @apps.key?(first)
    @apps = @apps.sort_by { |label, _| label == first ? 0 : 1 }.to_h
    @bytes = Integer(ENV.fetch('BENCH_BYTES', '2097152'), 10)
    @runs = Integer(ENV.fetch('BENCH_RUNS', '3'), 10)
    raise 'BENCH_BYTES must be between 1 and 1 GiB' unless (1..1_073_741_824).cover?(@bytes)
    raise 'BENCH_RUNS must be between 1 and 100' unless (1..100).cover?(@runs)
    raise 'Choose a new, empty report directory' if File.exist?(@output) && !Dir.empty?(@output)
    @apps.each_value do |app|
      raise "Missing executable in #{app}" unless File.executable?(File.join(app, 'Contents/MacOS/Terminal'))
    end
    @result = { 'passed' => false, 'requested_bytes' => @bytes, 'runs_per_workload' => @runs,
                'geometry' => [100, 30], 'font' => 'Obel Mono', 'font_size' => 14,
                'runner_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
                'order' => @apps.keys, 'apps' => {},
                'scope' => 'Sequential visible-app PTY pilot; parser barriers are not display latency. History is excluded by the driver alternate screen.' }
    @reports = {}
  end

  def run
    FileUtils.mkdir_p(@output)
    @driver = File.join(@output, 'terminal-bench')
    source = File.expand_path('../Benchmarks/TerminalBench/terminal-bench.c', __dir__)
    diagnostics, status = Open3.capture2e('xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-O2', source, '-o', @driver)
    File.write(File.join(@output, 'driver-build.log'), diagnostics)
    raise "Driver build failed: #{status}" unless status.success?
    @result['driver_sha256'] = Digest::SHA256.file(@driver).hexdigest
    @result['driver_source_sha256'] = Digest::SHA256.file(source).hexdigest
    @apps.each { |label, app| measure(label, app) }
    layout_fields = %w[columns rows pixel_width pixel_height output_post_processing]
    raise 'App PTY layouts differ' unless @reports.fetch('rust').values_at(*layout_fields) == @reports.fetch('swift').values_at(*layout_fields)
    rust_rates = @reports.fetch('rust').fetch('workloads').to_h { |item| [item.fetch('name'), item.dig('mib_per_second', 'p50')] }
    ratios = @reports.fetch('swift').fetch('workloads').to_h do |item|
      [item.fetch('name'), item.dig('mib_per_second', 'p50') / rust_rates.fetch(item.fetch('name'))]
    end
    @result['performance_gate'] = {
      'minimum_swift_to_rust_ratio' => MINIMUM_SWIFT_TO_RUST_RATIO, 'observed_ratios' => ratios,
      'passed' => ratios.values.all? { |ratio| ratio >= MINIMUM_SWIFT_TO_RUST_RATIO }
    }
    @result['passed'] = true
  rescue StandardError, Interrupt => error
    @result['failure'] = "#{error.class}: #{error.message}"
    raise
  ensure
    File.write(File.join(@output, 'comparison.json'), JSON.pretty_generate(@result) + "\n") if Dir.exist?(@output)
  end

  private

  def measure(label, app)
    executable = File.join(app, 'Contents/MacOS/Terminal')
    report = File.join(@output, "#{label}.json")
    log = File.join(@output, "#{label}-launch.log")
    bundle_bytes = Dir.glob(File.join(app, '**/*'), File::FNM_DOTMATCH).sum do |path|
      File.file?(path) && !File.symlink?(path) ? File.size(path) : 0
    end
    record = { 'bundle' => app, 'executable_sha256' => Digest::SHA256.file(executable).hexdigest,
               'executable_bytes' => File.size(executable), 'bundle_regular_file_bytes' => bundle_bytes,
               'natural_exit' => false, 'cleanup_survivors' => [] }
    @result['apps'][label] = record
    process = nil
    begin
      process = NativeSmokeProcess.new([
          executable, '--columns', '100', '--rows', '30', '--font-size', '14',
          '--history-limit', '10000', '--exit-after-command', '--execute', @driver,
          '--output', report, '--terminal', label, '--bytes', @bytes.to_s,
          '--runs', @runs.to_s, '--columns', '100', '--rows', '30'
        ], log: log)
      record['pid'] = process.pid
      puts "Measuring #{label} app (PID #{process.pid})"
      STDOUT.flush
      status = process.wait(300)
      raise File.read("#{report}.failed") if File.file?("#{report}.failed")
      raise "#{label} benchmark timed out" unless status
      record['exit_status'] = status.exitstatus
      raise "#{label} app exited with #{status}" unless status.success?
      raise "#{label} app left children: #{process.live_pids.join(', ')}" unless process.live_pids.empty?
      record['natural_exit'] = true
      data = JSON.parse(File.read(report))
      raise "#{label} driver schema mismatch" unless data.fetch('schema') == 2
      raise "#{label} report belongs to another process" unless data.fetch('terminal_pid') == process.pid
      raise "#{label} report label mismatch" unless data.fetch('terminal') == label
      raise "#{label} geometry mismatch" unless [data.fetch('columns'), data.fetch('rows')] == [100, 30]
      workloads = data.fetch('workloads')
      expected = %w[ascii_short_lines ascii_long_lines ansi_truecolor unicode]
      raise "#{label} workload mismatch" unless workloads.map { |item| item.fetch('name') } == expected
      workloads.each do |item|
        validate_workload(item, label)
      end
      record['report'] = File.basename(report)
      @reports[label] = data
    ensure
      if process
        record['cleanup_survivors'] = process.cleanup
        raise "#{label} cleanup left processes: #{record['cleanup_survivors'].join(', ')}" unless record['cleanup_survivors'].empty?
      end
    end
  end

  # The aggregate count alone cannot prove that all requested runs happened.
  # Keep observations paired and verify the distributions used by the gate.
  def validate_workload(item, label)
    samples = item.fetch('run_samples')
    unless item.fetch('source_bytes_per_run') == @bytes && samples.is_a?(Array) &&
        samples.length == @runs && samples.map { |sample| sample.fetch('run') } == (1..@runs).to_a
      raise "#{label} incomplete or unordered workload observations"
    end
    %w[mib_per_second elapsed_seconds terminal_cpu_seconds].each do |metric|
      values = samples.map { |sample| sample.fetch(metric) }
      summary = item.fetch(metric)
      next if metric == 'terminal_cpu_seconds' && summary.nil? && values.all?(&:nil?)
      unless values.all? { |value| value.is_a?(Numeric) && value.finite? &&
          (metric == 'terminal_cpu_seconds' ? value >= 0 : value.positive?) }
        raise "#{label} invalid #{metric} observations"
      end
      sorted = values.sort
      expected = { 'p50' => sorted[(@runs - 1) / 2], 'p95' => sorted[(@runs - 1) * 95 / 100],
                   'p99' => sorted[(@runs - 1) * 99 / 100], 'max' => sorted.last }
      unless summary.is_a?(Hash) && summary.fetch('samples') == @runs &&
          expected.all? { |key, value| summary.fetch(key) == value }
        raise "#{label} #{metric} distribution does not match observations"
      end
    end
    samples.each do |sample|
      rate = sample.fetch('mib_per_second')
      elapsed = sample.fetch('elapsed_seconds')
      # Both fields are printed to six decimal places by the C driver. Their
      # rounding intervals must overlap for the exact requested byte count.
      seconds_from_rate = @bytes / 1_048_576.0 / rate
      tolerance = 0.500001e-6 + seconds_from_rate * 0.500001e-6 / (rate - 0.5e-6)
      raise "#{label} unpaired throughput/time observations" unless
        (elapsed - seconds_from_rate).abs <= tolerance
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby #{$PROGRAM_NAME} REPORT_DIRECTORY RUST_APP SWIFT_APP" unless ARGV.length == 3
  Signal.trap('TERM') { raise Interrupt, 'Comparison terminated' }
  Signal.trap('INT') { raise Interrupt, 'Comparison interrupted' }
  TerminalAppComparison.new(*ARGV).run
  puts 'Completed both app benchmarks; all owned processes exited cleanly'
end

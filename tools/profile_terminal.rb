# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require_relative 'native_smoke'

# Profiles one explicitly supplied, directly launched bundle. The runner owns
# only the app and sampler it starts, so cleanup never targets a user instance.
class TerminalAppProfile
  DRIVER_BYTES = 64 * 1024 * 1024
  DRIVER_RUNS = 1
  DRIVER_IDLE_SECONDS = 3
  COLUMNS = 100
  ROWS = 30
  FONT = 'Obel Mono'
  FONT_SIZE = 14
  SAMPLE_SECONDS = 5
  SAMPLE_INTERVAL_MS = 1

  class CleanupFailure < RuntimeError; end

  def initialize(app, output)
    @app = File.realpath(app)
    @output = File.expand_path(output)
    @executable = File.join(@app, 'Contents/MacOS/Terminal')
    raise "Missing executable in #{@app}" unless File.executable?(@executable)
    raise "Refusing to clobber existing report path #{@output}" if File.exist?(@output)

    @result = {
      'schema' => 1,
      'passed' => false,
      'contract' => {
        'columns' => COLUMNS, 'rows' => ROWS, 'font' => FONT, 'font_size' => FONT_SIZE,
        'bytes_per_workload' => DRIVER_BYTES, 'runs_per_workload' => DRIVER_RUNS,
        'idle_seconds' => DRIVER_IDLE_SECONDS, 'sample_seconds' => SAMPLE_SECONDS,
        'sample_interval_ms' => SAMPLE_INTERVAL_MS
      },
      'provenance' => {
        'runner_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
        'app_bundle' => @app,
        'app_executable_sha256' => Digest::SHA256.file(@executable).hexdigest
      },
      'lifecycle' => {},
      'interpretation' =>
        'The benchmark driver wall and CPU fields are diagnostic-only here: the concurrent sampler perturbs them and they are not comparison timing.'
    }
  end

  def run
    original_failure = nil
    Dir.mkdir(@output)
    build_driver
    run_profile
    @result['passed'] = true
  rescue StandardError, Interrupt => error
    original_failure = error
    @result['failure'] = "#{error.class}: #{error.message}"
    raise
  ensure
    cleanup_issues = cleanup_owned_processes
    cleanup_error = nil
    unless cleanup_issues.empty?
      cleanup_error = CleanupFailure.new("Owned process cleanup failed: #{cleanup_issues.join('; ')}")
      @result['passed'] = false
      @result['cleanup_failure'] = cleanup_error.message
      @result['failure'] = [@result['failure'], cleanup_error.message].compact.join("\n")
    end
    write_result if Dir.exist?(@output)
    # If benchmark work already failed, let that original exception remain the
    # process failure while retaining the cleanup failure in profile.json.
    raise cleanup_error if cleanup_error && original_failure.nil?
  end

  private

  def build_driver
    source = File.expand_path('../native/benchmarks/terminal-bench.c', __dir__)
    @driver = File.join(@output, 'terminal-bench')
    build_log = File.join(@output, 'driver-build.log')
    output, status = Open3.capture2e(
      'xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-O2', source, '-o', @driver)
    File.write(build_log, output)
    raise "Driver build failed: #{status}" unless status.success?

    @result['provenance']['driver_source'] = source
    @result['provenance']['driver_source_sha256'] = Digest::SHA256.file(source).hexdigest
    @result['provenance']['driver_sha256'] = Digest::SHA256.file(@driver).hexdigest
    @result['provenance']['driver_build_command'] =
      ['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-O2', source, '-o', @driver]
  end

  def run_profile
    report = File.join(@output, 'driver.json')
    app_log = File.join(@output, 'app-launch.log')
    app_args = [
      @executable, '--columns', COLUMNS.to_s, '--rows', ROWS.to_s,
      '--font-size', FONT_SIZE.to_s, '--exit-after-command', '--execute', @driver,
      '--output', report, '--terminal', 'profiled-app', '--bytes', DRIVER_BYTES.to_s,
      '--runs', DRIVER_RUNS.to_s, '--columns', COLUMNS.to_s, '--rows', ROWS.to_s,
      '--idle-seconds', DRIVER_IDLE_SECONDS.to_s
    ]
    @result['provenance']['app_command'] = app_args
    @app_process = NativeSmokeProcess.new(app_args, log: app_log)
    @result['lifecycle']['app'] = { 'pid' => @app_process.pid, 'natural_exit' => false }

    early_exit = @app_process.wait(3.5)
    raise "App exited before profiling: #{early_exit}" if early_exit

    raw_sample = File.join(@output, 'sample.txt')
    sample_log = File.join(@output, 'sample-launch.log')
    sample_args = [
      '/usr/bin/sample', @app_process.pid.to_s, SAMPLE_SECONDS.to_s,
      SAMPLE_INTERVAL_MS.to_s, '-file', raw_sample
    ]
    @result['provenance']['sample_command'] = sample_args
    @sample_process = NativeSmokeProcess.new(sample_args, log: sample_log)
    @result['lifecycle']['sample'] = { 'pid' => @sample_process.pid, 'natural_exit' => false }
    sample_status = @sample_process.wait(SAMPLE_SECONDS + 20)
    raise 'sample timed out' unless sample_status
    raise "sample exited with #{sample_status}" unless sample_status.success?
    raise "sample left children: #{@sample_process.live_pids.join(', ')}" unless @sample_process.live_pids.empty?
    raise 'sample did not produce raw text' unless File.file?(raw_sample) && File.size?(raw_sample)
    @result['provenance']['sample_sha256'] = Digest::SHA256.file(raw_sample).hexdigest
    @result['provenance']['sample_bytes'] = File.size(raw_sample)
    @result['lifecycle']['sample'].merge!(status_record(sample_status), 'natural_exit' => true)

    app_status = @app_process.wait(180)
    raise 'App benchmark timed out' unless app_status
    raise "App exited with #{app_status}" unless app_status.success?
    raise "App left children: #{@app_process.live_pids.join(', ')}" unless @app_process.live_pids.empty?
    raise File.read("#{report}.failed") if File.file?("#{report}.failed")
    driver_report = JSON.parse(File.read(report))
    raise 'Driver report schema mismatch' unless driver_report.fetch('schema') == 2
    raise 'Driver report belongs to another process' unless driver_report.fetch('terminal_pid') == @app_process.pid
    raise 'Driver report geometry mismatch' unless [driver_report.fetch('columns'), driver_report.fetch('rows')] == [COLUMNS, ROWS]
    @result['lifecycle']['app'].merge!(status_record(app_status), 'natural_exit' => true)
    @result['driver_report_sha256'] = Digest::SHA256.file(report).hexdigest
    @result['driver_report_summary'] = {
      'idle_cpu_percent_one_core' => driver_report['idle_cpu_percent_one_core'],
      'workload_terminal_cpu_seconds' => driver_report.fetch('workloads').to_h {
        |workload| [workload.fetch('name'), workload['terminal_cpu_seconds']]
      }
    }
  end

  def status_record(status)
    { 'exitstatus' => status.exitstatus, 'termsig' => status.termsig, 'success' => status.success? }
  end

  def cleanup_owned_processes
    issues = []
    [[:sample, @sample_process], [:app, @app_process]].each do |name, process|
      next unless process

      lifecycle = @result['lifecycle'].fetch(name.to_s)
      lifecycle['forced_cleanup'] = process.status.nil? && !process.live_pids.empty?
      survivors = process.cleanup
      lifecycle['cleanup_survivors'] = survivors
      lifecycle['final_status'] = status_record(process.status) if process.status
      issues << "#{name} survivors: #{survivors.join(', ')}" unless survivors.empty?
    rescue StandardError => error
      lifecycle['cleanup_error'] = "#{error.class}: #{error.message}"
      issues << "#{name} cleanup error: #{error.class}: #{error.message}"
    end
    issues
  end

  def write_result
    File.write(File.join(@output, 'profile.json'), JSON.pretty_generate(@result) + "\n")
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby #{$PROGRAM_NAME} APP_BUNDLE NEW_REPORT_DIRECTORY" unless ARGV.length == 2
  Signal.trap('TERM') { raise Interrupt, 'Profile runner terminated' }
  Signal.trap('INT') { raise Interrupt, 'Profile runner interrupted' }
  TerminalAppProfile.new(*ARGV).run
  puts 'Profile complete; all owned app, sampler, and PTY descendants exited cleanly'
end

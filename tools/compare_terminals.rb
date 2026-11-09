# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'native_smoke'

# A fixed comparison contract: optimized local app, installed references, two
# opposite orders, one driver, isolated bundles, and owned-process cleanup.
class TerminalComparison
  def initialize(output)
    @root = File.expand_path('..', __dir__)
    @output = File.expand_path(output)
    @bytes = Integer(ENV.fetch('BENCH_BYTES', '16777216'))
    @runs = Integer(ENV.fetch('BENCH_RUNS', '10'))
    raise 'Invalid payload/sample count' unless (1..1_073_741_824).cover?(@bytes) && (1..100).cover?(@runs)
    raise 'Output already contains a result' if File.exist?(File.join(@output, 'comparison.json'))
    @result = { 'passed' => false, 'source_sha' => capture('git', 'rev-parse', 'HEAD').strip,
      'bytes_per_run' => @bytes, 'runs_per_workload' => @runs, 'geometry' => [100, 30],
      'font' => 'Obel Mono 14', 'os' => capture('sw_vers'), 'hardware' => capture('sysctl', '-n', 'machdep.cpu.brand_string'),
      'power' => capture('pmset', '-g', 'batt'), 'load_before' => capture('sysctl', '-n', 'vm.loadavg'),
      'scope' => 'Sequential visible-app PTY throughput and ordered parser replies; alternate screen excludes history. Same cell grid/configured font; native cell-pixel metrics are recorded, not normalized. Not display FPS, presentation/input latency, peak memory, or a SQL benchmark.',
      'trials' => [] }
  end

  def run
    FileUtils.mkdir_p(@output)
    @result['stage'] = 'compile_driver'
    source = File.join(@root, 'Benchmarks/TerminalBench/terminal-bench.c')
    driver = File.join(@output, 'terminal-bench')
    capture('xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-O2', source, '-o', driver)
    @result['driver_source_sha256'] = Digest::SHA256.file(source).hexdigest
    @result['driver_sha256'] = Digest::SHA256.file(driver).hexdigest
    @result['runner_sha256'] = Digest::SHA256.file(__FILE__).hexdigest
    Dir.mktmpdir('terminal-ghostty-comparison-') do |temporary|
      @result['stage'] = 'freeze_apps'
      apps = { 'terminal' => File.join(@root, 'dist/Terminal.app'), 'ghostty' => '/Applications/Ghostty.app',
               'kitty' => '/Applications/kitty.app' }
      @result['apps'] = {}
      apps.transform_values!.with_index do |app, index|
        name = apps.keys[index]
        executable = name == 'terminal' ? 'Terminal' : name
        source_executable = File.join(app, 'Contents/MacOS', executable)
        raise "Missing #{source_executable}" unless File.executable?(source_executable)
        @result['apps'][name] = { 'executable_sha256' => Digest::SHA256.file(source_executable).hexdigest,
          'executable_bytes' => File.size(source_executable), 'bundle_bytes' => Dir.glob(File.join(app, '**/*')).sum { |p| File.file?(p) && !File.symlink?(p) ? File.size(p) : 0 } }
        destination = File.join(temporary, "#{name}.app")
        capture('ditto', app, destination)
        frozen_executable = File.join(destination, 'Contents/MacOS', executable)
        frozen_hash = Digest::SHA256.file(frozen_executable).hexdigest
        @result['apps'][name]['frozen_executable_sha256'] = frozen_hash
        raise "#{name} executable changed while freezing" unless frozen_hash == @result['apps'][name]['executable_sha256']
        frozen_executable
      end
      @result['ghostty_version'] = capture(apps.fetch('ghostty'), '+version')
      @result['kitty_version'] = capture(apps.fetch('kitty'), '--version')
      config = File.join(@output, 'ghostty.conf')
      File.write(config, <<~CONFIG)
        config-default-files = false
        font-family = Obel Mono
        font-size = 14
        cursor-style-blink = false
        background-opacity = 1
        window-width = 100
        window-height = 30
        window-padding-x = 8
        window-padding-y = 8
        scrollback-limit-lines = 10000
        scrollback-limit-bytes = 67108864
        shell-integration = none
        confirm-close-surface = false
        quit-after-last-window-closed = true
        window-save-state = never
      CONFIG
      [%w[terminal ghostty kitty], %w[kitty ghostty terminal]].each_with_index do |order, index|
        trial = { 'order' => order, 'apps' => {} }
        @result['trials'] << trial
        order.each do |name|
          @result['stage'] = "trial_#{index + 1}_#{name}"
          measure(name, apps.fetch(name), driver, config, index + 1, trial)
        end
        @result['stage'] = "validate_trial_#{index + 1}"
        fields = %w[columns rows output_post_processing]
        raise 'PTY geometry/modes differ' unless trial['apps'].values.map { |x| x.fetch('report').values_at(*fields) }.uniq.length == 1
      end
    end
    @result['passed'] = true
    @result['stage'] = 'finished'
  rescue StandardError, Interrupt => error
    @result['failure'] = "#{error.class}: #{error.message}"
    raise
  ensure
    @result['load_after'] = capture('sysctl', '-n', 'vm.loadavg')
    File.write(File.join(@output, 'comparison.json'), JSON.pretty_generate(@result) + "\n")
  end

  private

  def measure(name, executable, driver, config, index, trial)
    report = File.join(@output, "#{index}-#{name}.json")
    raise "Refusing to overwrite #{report}" if File.exist?(report)
    args = ['--output', report, '--terminal', name, '--bytes', @bytes.to_s, '--runs', @runs.to_s, '--columns', '100', '--rows', '30']
    command = case name
    when 'terminal'
      [executable, '--columns', '100', '--rows', '30', '--font-size', '14', '--history-limit', '10000', '--exit-after-command', '--execute', driver, *args]
    when 'ghostty'
      [executable, '--config-default-files=false', "--config-file=#{config}", '-e', driver, *args]
    when 'kitty'
      settings = {
        'font_family' => 'Obel Mono', 'font_size' => '14',
        'initial_window_width' => '100c', 'initial_window_height' => '30c',
        'remember_window_size' => 'no', 'cursor_blink_interval' => '0',
        'scrollback_lines' => '10000', 'background_opacity' => '1',
        'shell_integration' => 'disabled', 'window_padding_width' => '8',
        'macos_quit_when_last_window_closed' => 'yes', 'confirm_os_window_close' => '0'
      }
      [executable, '--config', 'NONE', '--session', 'none',
       *settings.flat_map { |key, value| ['--override', "#{key}=#{value}"] }, driver, *args]
    else
      raise "Unknown terminal #{name}"
    end
    process = nil
    record = { 'natural_exit' => false }
    trial['apps'][name] = record
    begin
      process = NativeSmokeProcess.new(command, log: File.join(@output, "#{index}-#{name}.log"))
      record['pid'] = process.pid
      puts "Measuring trial #{index}: #{name}, owned PID #{process.pid}"
      STDOUT.flush
      status = process.wait(300)
      raise File.read("#{report}.failed") if File.file?("#{report}.failed")
      raise "#{name} timed out" unless status
      raise "#{name} failed: #{status}" unless status.success?
      raise 'Children survived natural app exit' unless process.live_pids.empty?
      record['natural_exit'] = true
      data = JSON.parse(File.read(report))
      record['report_pid'] = data['terminal_pid']
      raise 'Wrong report owner/schema/grid' unless data['schema'] == 2 && process.observed_owned?(data['terminal_pid']) && data.values_at('columns', 'rows') == [100, 30]
      raise 'Wrong report terminal label' unless data['terminal'] == name
      raise 'Missing output-processing mode' unless [true, false].include?(data['output_post_processing'])
      raise 'Missing cell-pixel geometry' unless data.values_at('pixel_width', 'pixel_height').all? { |value| value.is_a?(Integer) && value.positive? }
      raise 'Wrong corpus' unless data.fetch('workloads').map { |x| x['name'] } == %w[ascii_short_lines ascii_long_lines ansi_truecolor unicode]
      data.fetch('workloads').each do |workload|
        samples = workload.fetch('run_samples')
        raise 'Incomplete samples' unless workload['source_bytes_per_run'] == @bytes && samples.map { |x| x['run'] } == (1..@runs).to_a
        rates = samples.map { |x| x.fetch('mib_per_second') }.sort
        raise 'Invalid median' unless rates.all? { |x| x.finite? && x.positive? } && workload.dig('mib_per_second', 'p50') == rates[(@runs - 1) / 2]
      end
      record['report'] = data
    ensure
      record['cleanup_survivors'] = process ? process.cleanup : []
      raise 'Owned processes survived cleanup' unless record['cleanup_survivors'].empty?
    end
  end

  def capture(*command)
    output, error, status = Open3.capture3(*command, chdir: @root)
    raise "#{command.first} failed: #{error}" unless status.success?
    output
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby tools/compare_terminals.rb NEW_REPORT_DIRECTORY' unless ARGV.length == 1
  Signal.trap('TERM') { raise Interrupt, 'Comparison terminated' }
  Signal.trap('INT') { raise Interrupt, 'Comparison interrupted' }
  TerminalComparison.new(ARGV.first).run
  puts 'PASS terminal comparison; both orders completed with no surviving owned processes'
end

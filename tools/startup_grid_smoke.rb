# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'native_smoke'

abort 'Usage: ruby tools/startup_grid_smoke.rb APP REPORT.json' unless ARGV.length == 2
Signal.trap('TERM') { raise Interrupt, 'Grid smoke terminated' }
Signal.trap('INT') { raise Interrupt, 'Grid smoke interrupted' }
app, report_path = ARGV.map { |path| File.expand_path(path) }
root = File.expand_path('..', __dir__)
report = { 'passed' => false, 'executable_sha256' => Digest::SHA256.file(File.join(app, 'Contents/MacOS/Terminal')).hexdigest, 'cases' => [] }
begin
  Dir.mktmpdir('terminal-startup-grid-') do |directory|
    frozen = File.join(directory, 'Terminal.app')
    raise 'Bundle copy failed' unless system('ditto', app, frozen)
    driver = File.join(directory, 'grid-driver')
    raise 'Driver build failed' unless system('xcrun', 'clang', '-O2', File.join(root, 'native/benchmarks/terminal-bench.c'), '-o', driver)
    [[80, 24, 8], [100, 30, 14], [60, 14, 20]].each_with_index do |(columns, rows, font), index|
      path = File.join(directory, "#{index}.json")
      entry = { 'requested' => [columns, rows], 'font_size' => font }
      report['cases'] << entry
      process = NativeSmokeProcess.new([File.join(frozen, 'Contents/MacOS/Terminal'),
        '--columns', columns.to_s, '--rows', rows.to_s, '--font-size', font.to_s,
        '--exit-after-command', '--execute', driver, '--output', path,
        '--terminal', 'grid-smoke', '--bytes', '1', '--runs', '1', '--idle-seconds', '1',
        '--workload', 'ascii_short_lines', '--columns', columns.to_s, '--rows', rows.to_s],
        log: File.join(directory, "#{index}.log"))
      begin
        raise 'App timeout/failure' unless process.wait(15)&.success?
        raise File.read("#{path}.failed") if File.file?("#{path}.failed")
        data = JSON.parse(File.read(path))
        raise 'Wrong owner/grid' unless process.observed_owned?(data['terminal_pid']) && data.values_at('columns', 'rows') == [columns, rows]
        raise 'Children survived natural exit' unless process.live_pids.empty?
        entry['observed'] = data.values_at('columns', 'rows', 'pixel_width', 'pixel_height')
        entry['natural_exit'] = true
      ensure
        entry['cleanup_survivors'] = process.cleanup
        raise 'Processes survived cleanup' unless entry['cleanup_survivors'].empty?
      end
    end
  end
  report['passed'] = true
rescue StandardError, Interrupt => error
  report['failure'] = "#{error.class}: #{error.message}"
  raise
ensure
  FileUtils.mkdir_p(File.dirname(report_path))
  File.write(report_path, JSON.pretty_generate(report) + "\n")
end
puts 'PASS startup grid: explicit cells at 8/14/20pt, natural exit, owned children reaped'

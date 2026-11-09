#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs one disposable, real interactive workload against a copied Terminal.app.
# GUI input is deliberately unavailable during --prepare; the caller must opt
# in with a frozen app, provenance, and an empty report directory.
require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'rbconfig'
require 'tmpdir'
require_relative '../native_smoke'

ROOT = File.expand_path('../..', __dir__)
FIXTURE = File.join(__dir__, 'fixture.rb')
PROVIDER = File.join(__dir__, 'provider.rb')
DRIVER_SOURCE = File.join(__dir__, 'Driver.swift')
CAPTURE_SOURCE = File.join(ROOT, 'tools/rendering_proof/Capture.swift')

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def bundle_manifest(directory)
  Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).sort.filter_map do |path|
    stat = File.lstat(path)
    next if stat.directory?

    relative = path.delete_prefix(directory + '/')
    value = stat.symlink? ? { 'symlink' => File.readlink(path) } : { 'sha256' => sha256(path), 'bytes' => stat.size }
    [relative, value]
  end.to_h
end

def compile_helper(name, source, helpers)
  binary = File.join(helpers, name)
  stamp = File.join(helpers, "#{name}.build.json")
  source_hash = sha256(source)
  previous = File.file?(stamp) ? JSON.parse(File.read(stamp)) : {}
  return binary if File.file?(binary) && previous['source_sha256'] == source_hash && previous['binary_sha256'] == sha256(binary)

  command = ['xcrun', 'swiftc', '-parse-as-library', '-O', '-target', 'arm64-apple-macosx15.0', source, '-o', binary]
  raise "#{name} compilation failed" unless system(*command)
  raise "#{name} source changed while compiling" unless sha256(source) == source_hash

  File.write(stamp, JSON.pretty_generate(source_sha256: source_hash, binary_sha256: sha256(binary)) + "\n")
  binary
end

def wait_until(seconds, message)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    value = yield
    return value if value
    raise message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.05
  end
end

def wait_for_capture(process, launched_at:, duration: 30, grace: 5, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
  deadline = launched_at + duration + grace
  loop do
    remaining = deadline - clock.call
    raise 'capture did not finish within its launch-relative deadline' if remaining <= 0

    status = process.wait([remaining, 0.05].min)
    return status if status
  end
end

def self_test_capture_wait
  clock = Struct.new(:now) { def advance(seconds) = self.now += seconds }.new(6.0)
  completed = Struct.new(:success?).new(true)
  process = Object.new
  process.define_singleton_method(:wait) do |seconds|
    clock.advance(seconds)
    clock.now >= 30 ? completed : nil
  end
  status = wait_for_capture(process, launched_at: 0, duration: 30, grace: 5, clock: -> { clock.now })
  raise 'capture that finished after the driver was rejected' unless status.success?
  raise 'capture wait exceeded its launch-relative deadline' unless clock.now.between?(30, 35)
  puts 'PASS tui-stress capture deadline: a 30-second capture may finish after a short driver exercise'
end

def matching_installation_receipt(receipts, executable_sha256)
  matches = receipts.select do |receipt|
    source = receipt['source_commit']
    receipt['executable_sha256'] == executable_sha256 && source.is_a?(String) && source.match?(/\A[0-9a-f]{40}\z/)
  end
  raise "no distribution installation receipt matches executable #{executable_sha256}" if matches.empty?
  raise "multiple distribution installation receipts match executable #{executable_sha256}" unless matches.length == 1

  matches.fetch(0)
end

def installed_provenance(root, app)
  executable = File.join(app, 'Contents/MacOS/Terminal')
  raise "installed app executable is missing: #{executable}" unless File.executable?(executable)

  receipt_paths = Dir.glob(File.join(root, 'reports/distribution-*-evidence/installation.json')).sort
  receipts = receipt_paths.map { |path| JSON.parse(File.read(path)).merge('_receipt_path' => path) }
  receipt = matching_installation_receipt(receipts, sha256(executable))
  { app: app, source_sha: receipt.fetch('source_commit'), executable_sha: receipt.fetch('executable_sha256'), receipt: receipt.fetch('_receipt_path') }
end

def event_files(directory)
  Dir.glob(File.join(directory, 'pane-*-events.jsonl')).sort
end

def events_for(path)
  File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
end

def workload_output_ready?(events, workload)
  expected = workload == 'codex' ? 'codex_response' : 'files_listing'
  events.any? { |event| event['event'] == 'workload_output_canary' && event['kind'] == expected }
end

def workload_started?(events, workload)
  expected = workload == 'codex' ? 'codex_banner' : 'files_listing'
  events.any? { |event| event['event'] == 'workload_output_canary' && event['kind'] == expected }
end

def final_receipts(directory, workload)
  panes = Dir.glob(File.join(directory, 'pane-*.json')).reject { |path| path.end_with?('-final.json') }.map do |path|
    JSON.parse(File.read(path)).fetch('pane')
  end.sort
  raise 'no workload pane metadata was recorded' if panes.empty?

  receipts = panes.to_h do |pane|
    path = File.join(directory, "pane-#{pane}-final.json")
    raise "missing final receipt for pane #{pane}" unless File.file?(path)
    receipt = JSON.parse(File.read(path))
    raise "receipt pane mismatch for pane #{pane}" unless receipt['pane'] == pane && receipt['workload'] == workload
    raise "pane #{pane} retained a child after cleanup" unless receipt['child_alive'] == false
    raise "pane #{pane} wrapper reported failure: #{receipt['failure']}" unless receipt.fetch('failure', nil).nil?
    [pane, receipt]
  end
  raise 'final receipt count does not match pane metadata' unless receipts.length == panes.length

  receipts
end

def workload_binary(workload, explicit)
  return File.realpath(explicit) if explicit

  candidates = workload == 'codex' ? [
    File.expand_path('~/.bun/install/global/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex')
  ] : [File.expand_path('~/.local/bin/files')]
  candidate = candidates.find { |path| File.executable?(path) }
  raise "Pass --#{workload} with the actual #{workload} executable" unless candidate

  candidate
end

options = { prepare: false, self_test: false, installed: false, workload: nil }
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/tui_stress/run.rb --prepare | --workload files|codex --app APP ...'
  parser.on('--prepare') { options[:prepare] = true }
  parser.on('--self-test') { options[:self_test] = true }
  parser.on('--installed') { options[:installed] = true }
  parser.on('--workload NAME', %w[files codex]) { |value| options[:workload] = value }
  parser.on('--app PATH') { |value| options[:app] = File.expand_path(value) }
  parser.on('--output PATH') { |value| options[:output] = File.expand_path(value) }
  parser.on('--source-sha SHA') { |value| options[:source_sha] = value }
  parser.on('--executable-sha256 SHA') { |value| options[:expected_sha] = value }
  parser.on('--files PATH') { |value| options[:files] = value }
  parser.on('--codex PATH') { |value| options[:codex] = value }
end.parse!

if options[:self_test]
  raise '--self-test cannot launch a workload' if options[:workload] || options[:prepare]
  self_test_capture_wait
  known = matching_installation_receipt([{ 'source_commit' => 'a' * 40, 'executable_sha256' => 'fixture' }], 'fixture')
  raise 'matching receipt self-test selected wrong record' unless known.fetch('source_commit') == 'a' * 40
  begin
    matching_installation_receipt([], 'missing')
    raise 'missing receipt self-test unexpectedly succeeded'
  rescue RuntimeError
    nil
  end
  puts 'PASS tui-stress installed provenance: one matching receipt required'
  exit
end

if options[:installed]
  raise '--installed cannot be combined with explicit app provenance' if %i[app source_sha expected_sha].any? { |key| options[key] }
  raise '--installed requires --workload' unless options[:workload]
  provenance = installed_provenance(ROOT, File.expand_path('~/Applications/Helge Terminal.app'))
  options[:app] = provenance.fetch(:app)
  options[:source_sha] = provenance.fetch(:source_sha)
  options[:expected_sha] = provenance.fetch(:executable_sha)
  options[:installed_receipt] = provenance.fetch(:receipt)
  options[:output] ||= File.join(Dir.tmpdir, "terminal-tui-#{options[:workload]}-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}")
end

helpers = File.expand_path(ENV.fetch('TERMINAL_TUI_STRESS_HELPERS', '~/.codex/artifacts/tui-stress/helpers'))
FileUtils.mkdir_p(helpers)
raise 'TUI stress runner self-test failed' unless system(RbConfig.ruby, __FILE__, '--self-test')
driver = compile_helper('TUIStressDriver', DRIVER_SOURCE, helpers)
capture = compile_helper('TUIStressCapture', CAPTURE_SOURCE, helpers)
raise 'TUI stress driver self-test failed' unless system(driver, '--self-test')
raise 'Capture self-test failed' unless system(capture, '--self-test')
raise 'Fixture self-test failed' unless system({ 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin' }, RbConfig.ruby, FIXTURE, '--self-test')
raise 'Fixture PTY self-test failed' unless system(RbConfig.ruby, File.join(__dir__, 'FixtureTests.rb'))
raise 'Local Codex provider self-test failed' unless system(RbConfig.ruby, PROVIDER, '--self-test')

if options[:prepare]
  raise '--prepare cannot launch a workload' if options[:workload]
  puts 'PASS tui-stress preparation: helpers and isolated-PTY checks passed; no app, workload, capture, or GUI input launched'
  exit
end

%i[workload app output source_sha expected_sha].each { |key| raise "Missing --#{key.to_s.tr('_', '-')}" unless options[key] }
raise 'Invalid source SHA' unless options[:source_sha].match?(/\A[0-9a-f]{40}\z/)
raise 'Use a fresh --output directory' if File.exist?(options[:output])
raise 'App must be a Terminal.app bundle' unless File.directory?(options[:app])
raise 'Output cannot be inside the input app' if options[:output].start_with?(options[:app] + '/')
input_executable = File.join(options[:app], 'Contents/MacOS/Terminal')
raise 'Missing app executable' unless File.executable?(input_executable)
raise 'Executable SHA does not match supplied frozen provenance' unless sha256(input_executable) == options[:expected_sha]

workload = options[:workload]
binary = workload_binary(workload, options[workload.to_sym])
FileUtils.mkdir_p(options[:output], mode: 0o700)
fixture_cwd = File.join(options[:output], 'fixture-cwd')
FileUtils.mkdir_p(fixture_cwd, mode: 0o700)
File.write(File.join(fixture_cwd, 'README.md'), "# TUI stress fixture\n\n猫\n")
File.write(File.join(fixture_cwd, 'example.swift'), "print(\"TUI_STRESS_SOURCE\")\n")
File.write(File.join(fixture_cwd, 'TUI_STRESS_FILES_LISTING_READY'), "stable real-files readiness entry\n")
FileUtils.mkdir_p(File.join(fixture_cwd, 'nested'), mode: 0o700)
File.write(File.join(fixture_cwd, 'nested', 'unicode-猫.txt'), "fixture\n")

frozen = File.join(options[:output], 'Frozen Terminal.app')
before_bundle = bundle_manifest(options[:app])
FileUtils.cp_r(options[:app], frozen)
executable = File.join(frozen, 'Contents/MacOS/Terminal')
raise 'Bundle changed while being copied' unless before_bundle == bundle_manifest(options[:app]) && before_bundle == bundle_manifest(frozen)
raise 'Frozen executable provenance mismatch' unless sha256(executable) == options[:expected_sha]

environment = {
  'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
  'SHELL' => FIXTURE,
  'TERM' => 'xterm-256color',
  'COLORTERM' => 'truecolor',
  'LANG' => nil, 'LC_ALL' => nil, 'LC_CTYPE' => nil,
  'NO_COLOR' => nil, 'CLICOLOR' => nil, 'CLICOLOR_FORCE' => nil, 'FORCE_COLOR' => nil,
  'TERMINAL_TUI_STRESS_DIRECTORY' => options[:output],
  'TERMINAL_TUI_STRESS_WORKLOAD' => workload,
  'TERMINAL_TUI_STRESS_CWD' => fixture_cwd,
  'TERMINAL_TUI_STRESS_EXECUTABLE' => executable,
  "TERMINAL_TUI_STRESS_#{workload.upcase}" => binary,
}
if workload == 'codex'
  codex_directory = File.join(options[:output], 'codex-private-state')
  FileUtils.mkdir_p(codex_directory, mode: 0o700)
  environment['TERMINAL_TUI_STRESS_CODEX_DIRECTORY'] = codex_directory
end

processes = []
report = {
  source_sha: options[:source_sha], workload: workload, workload_executable: binary, workload_sha256: sha256(binary),
  input_app: options[:app], frozen_app: frozen, executable_sha256: options[:expected_sha],
  helper_sha256: { 'Driver.swift' => sha256(DRIVER_SOURCE), 'TUIStressDriver' => sha256(driver),
    'Capture.swift' => sha256(CAPTURE_SOURCE), 'TUIStressCapture' => sha256(capture), 'fixture.rb' => sha256(FIXTURE),
    'provider.rb' => sha256(PROVIDER) },
  capture_marker_interpretation: 'inconclusive for real Codex/Files workloads; video and PNGs are retained only for visual inspection',
  verified_bundle_manifest: before_bundle,
}
report[:installed_receipt] = options[:installed_receipt] if options[:installed_receipt]
Signal.trap('INT') { raise Interrupt, 'TUI stress interrupted' }
Signal.trap('TERM') { raise Interrupt, 'TUI stress terminated' }
begin
  if workload == 'codex'
    provider_environment = {
      'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
      'TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE' => File.join(options[:output], 'provider.json'),
      'TERMINAL_TUI_STRESS_PROVIDER_SLOW_MS' => '150', 'TERMINAL_TUI_STRESS_PROVIDER_MAX_REQUESTS' => '8',
      'TERMINAL_TUI_STRESS_PROVIDER_LIFETIME_SECONDS' => '90'
    }
    provider = NativeSmokeProcess.new([provider_environment, RbConfig.ruby, PROVIDER,
      out: File.open(File.join(options[:output], 'provider.stdout'), 'wx'), err: File.open(File.join(options[:output], 'provider.stderr'), 'wx')])
    processes << provider
    provider_info = wait_until(10, 'loopback Codex provider did not become ready') do
      raise 'loopback Codex provider exited before readiness' if provider.wait(0.01)
      path = File.join(options[:output], 'provider.json')
      next unless File.file?(path)
      candidate = JSON.parse(File.read(path)) rescue nil
      candidate if candidate && candidate['status'] == 'listening'
    end
    environment['TERMINAL_TUI_STRESS_CODEX_BASE_URL'] = "http://127.0.0.1:#{provider_info.fetch('port')}/v1"
    report[:provider_initial] = provider_info
  end
  app = NativeSmokeProcess.new([environment, executable, '--working-directory', fixture_cwd, '--font-size', '14',
    out: File.open(File.join(options[:output], 'app.log'), 'wx'), err: File.open(File.join(options[:output], 'app.log'), 'a')])
  processes << app
  wait_until(15, 'app exited before first fixture pane started') do
    raise 'app exited before fixture startup' if app.wait(0.01)
    File.file?(File.join(options[:output], 'pane-0.json'))
  end
  wait_until(12, 'real workload did not reach its initial visible UI state') do
    first = event_files(options[:output]).first
    first && workload_started?(events_for(first), workload)
  end

  prepare = NativeSmokeProcess.new([environment, driver, 'prepare', app.pid.to_s, options[:output],
    out: File.open(File.join(options[:output], 'driver-prepare.log'), 'wx'), err: File.open(File.join(options[:output], 'driver-prepare.log'), 'a')])
  processes << prepare
  raise 'owned-window preparation failed' unless prepare.wait(15)&.success?
  identity = JSON.parse(File.read(File.join(options[:output], 'identity.json')))
  raise 'driver prepared the wrong app' unless identity.fetch('pid') == app.pid && identity.fetch('executable') == executable

  capture_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  capture_process = NativeSmokeProcess.new([capture, identity.fetch('window').to_s, options[:output], app.pid.to_s, '30',
    out: File.open(File.join(options[:output], 'capture.log'), 'wx'), err: File.open(File.join(options[:output], 'capture.log'), 'a')])
  processes << capture_process
  wait_until(10, 'capture failed to become ready') do
    raise 'capture exited before readiness' if capture_process.wait(0.01)
    File.file?(File.join(options[:output], 'ready'))
  end

  exercise = NativeSmokeProcess.new([environment, driver, 'exercise', app.pid.to_s, options[:output],
    out: File.open(File.join(options[:output], 'driver-exercise.log'), 'wx'), err: File.open(File.join(options[:output], 'driver-exercise.log'), 'a')])
  processes << exercise
  raise 'native driver exercise timed out or failed' unless exercise.wait(28)&.success?
  raise 'app exited during stress exercise' if app.wait(0.01)
  raise 'capture did not finish cleanly' unless wait_for_capture(capture_process, launched_at: capture_started_at)&.success?

  final_screen = JSON.parse(File.read(File.join(options[:output], 'final-screen.json')))
  raise 'final screen invariant was not recorded' unless final_screen.fetch('panes').all? { |pane| pane.fetch('actual_workload_marker_visible') }
  pane_records = event_files(options[:output]).to_h { |path| [File.basename(path), events_for(path)] }
  raise 'missing fixture event transcripts' if pane_records.empty?
  metadata_panes = Dir.glob(File.join(options[:output], 'pane-*.json')).reject { |path| path.end_with?('-final.json') }
    .map { |path| JSON.parse(File.read(path)).fetch('pane') }.sort
  event_panes = pane_records.values.map { |events| events.first&.fetch('pane') }.sort
  raise "expected exactly four pane metadata records, found #{metadata_panes.length}" unless metadata_panes.length == 4
  raise 'pane metadata and event transcripts do not have matching four-pane identities' unless metadata_panes == event_panes && event_panes.uniq.length == 4
  pane_checks = pane_records.transform_values do |events|
    sizes = events.select { |event| event['event'] == 'winsize' }.map { |event| [event['rows'], event['columns']] }.uniq
    pane = events.first&.fetch('pane')
    { child_started: events.any? { |event| event['event'] == 'child_started' }, real_workload_started: workload_started?(events, workload),
      pty_sizes: sizes, pty_size_changed: sizes.length >= 2,
      files_refresh_complete: workload != 'files' || events.any? { |event| event['event'] == 'files_refresh_complete' },
      real_workload_output_visible: workload_output_ready?(events, workload),
      final_receipt_before_runner_cleanup: pane && File.file?(File.join(options[:output], "pane-#{pane}-final.json")) }
  end
  if workload == 'codex'
    closed, live = pane_checks.values.partition { |check| check[:final_receipt_before_runner_cleanup] }
    raise "expected exactly one deliberately closed Codex pane, found #{closed.length}" unless closed.length == 1
    raise "expected three live Codex panes, found #{live.length}" unless live.length == 3
    raise 'closed Codex pane lacked child/banner/WINCH evidence' unless closed.all? { |check| check[:child_started] && check[:real_workload_started] && !check[:pty_sizes].empty? }
    raise 'live Codex pane lacked child/banner/WINCH/response evidence' unless live.all? do |check|
      check[:child_started] && check[:real_workload_started] && check[:pty_size_changed] && check[:real_workload_output_visible]
    end
  else
    raise 'one or more real workload panes lacked child/readiness/WINCH evidence' unless pane_checks.values.all? do |check|
      check[:child_started] && check[:real_workload_started] && check[:pty_size_changed] && check[:files_refresh_complete]
    end
    raise 'one or more panes lacked real workload output after the stress run' unless pane_checks.values.all? { |check| check[:real_workload_output_visible] }
  end
  capture_summary = JSON.parse(File.read(File.join(options[:output], 'summary.json')))
  raise 'capture did not preserve a nonempty video' unless capture_summary.fetch('recording_valid')
  report[:identity] = identity
  report[:final_screen] = final_screen
  report[:pane_checks] = pane_checks
  report[:capture_summary] = capture_summary
  if workload == 'codex'
    provider_info = JSON.parse(File.read(File.join(options[:output], 'provider.json')))
    responses = provider_info.fetch('requests').count { |request| request['method'] == 'POST' && request['path'] == '/v1/responses' && request['status'] == 200 }
    raise "expected a local provider response for each of four created Codex panes, got #{responses}" unless responses >= 4
    report[:provider_requests_before_cleanup] = provider_info
  end
  report[:passed] = true
rescue Exception => error
  report[:passed] = false
  report[:error] = "#{error.class}: #{error.message}"
  raise
ensure
  report[:cleanup] = processes.reverse.map { |process| { pid: process.pid, survivors: process.cleanup } }
  receipt_error = nil
  begin
    report[:final_receipts] = final_receipts(options[:output], workload)
  rescue StandardError => error
    report[:passed] = false
    report[:cleanup_receipt_error] = "#{error.class}: #{error.message}"
    receipt_error = error
  end
  report[:artefact_sha256] = %w[identity.json input-events.json final-screen.json frames.jsonl capture.mp4 summary.json].filter_map do |name|
    path = File.join(options[:output], name)
    [name, sha256(path)] if File.file?(path)
  end.to_h
  File.write(File.join(options[:output], 'analysis.json'), JSON.pretty_generate(report) + "\n") if File.directory?(options[:output])
  raise receipt_error if receipt_error
  raise 'owned diagnostic processes survived cleanup' unless report[:cleanup].all? { |item| item[:survivors].empty? }
end

puts "PASS real #{workload} pane stress; inspect capture.mp4 and sampled PNGs visually (marker classifications are intentionally inconclusive)"

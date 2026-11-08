#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative '../native_smoke'
require_relative 'recording_evidence'

def bundle_manifest(directory)
  Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).sort.filter_map do |path|
    stat = File.lstat(path)
    next if stat.directory?
    relative = path.delete_prefix(directory + '/')
    record = stat.symlink? ? { 'symlink' => File.readlink(path) } : { 'sha256' => Digest::SHA256.file(path).hexdigest, 'bytes' => stat.size }
    [relative, record]
  end.to_h
end

options = { prepare: false, negative: false }
OptionParser.new do |parser|
  parser.on('--prepare') { options[:prepare] = true }
  parser.on('--app PATH') { |v| options[:app] = File.expand_path(v) }
  parser.on('--output PATH') { |v| options[:output] = File.expand_path(v) }
  parser.on('--source-sha SHA') { |v| options[:source_sha] = v }
  parser.on('--executable-sha256 SHA') { |v| options[:expected_sha] = v }
  parser.on('--negative-control') { options[:negative] = true }
end.parse!
helpers = File.expand_path(ENV.fetch('TERMINAL_RENDER_PROOF_HELPERS', '~/.codex/artifacts/rendering-final-preflight/helpers'))
FileUtils.mkdir_p(helpers)
%w[Capture Driver].each do |name|
  source = File.join(__dir__, "#{name}.swift")
  binary = File.join(helpers, name)
  stamp = File.join(helpers, "#{name}.build.json")
  source_sha = Digest::SHA256.file(source).hexdigest
  previous = File.file?(stamp) ? JSON.parse(File.read(stamp)) : {}
  unless File.file?(binary) && previous['source_sha256'] == source_sha && previous['binary_sha256'] == Digest::SHA256.file(binary).hexdigest
    raise "Compile #{name} failed" unless system('xcrun', 'swiftc', '-parse-as-library', '-O', '-target',
      'arm64-apple-macosx15.0', source, '-o', binary)
    raise 'Helper source changed while compiling' unless Digest::SHA256.file(source).hexdigest == source_sha
    File.write(stamp, JSON.pretty_generate(source_sha256: source_sha, binary_sha256: Digest::SHA256.file(binary).hexdigest) + "\n")
  end
  raise "#{name} self-test failed" unless system(binary, '--self-test')
end
raise 'Fixture self-test failed' unless system({ 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin' }, '/usr/bin/ruby', File.join(__dir__, 'fixture.rb'), '--self-test')
raise 'PTY fixture test failed' unless system(RbConfig.ruby, File.join(__dir__, 'FixtureTests.rb'))
raise 'Recording evidence test failed' unless system(RbConfig.ruby, File.join(__dir__, 'RecordingEvidenceTests.rb'))
clock_start = Process.clock_gettime(Process::CLOCK_UPTIME_RAW)
native_clock = IO.popen([File.join(helpers, 'Driver'), '--clock'], &:read).to_f
clock_end = Process.clock_gettime(Process::CLOCK_UPTIME_RAW)
raise 'Ruby fixture and native helper clock domains differ' unless native_clock.between?(clock_start - 0.01, clock_end + 0.01)
puts 'PASS fixture/native host clock compatibility'
if options[:prepare]
  puts 'PASS preparation only: helpers compiled and headless self-tests passed; no GUI launched'
  exit
end

%i[app output source_sha expected_sha].each { |key| raise "Missing --#{key.to_s.tr('_', '-')}" unless options[key] }
raise 'Invalid source SHA' unless options[:source_sha].match?(/\A[0-9a-f]{40}\z/)
raise 'Use a fresh output directory' if File.exist?(options[:output])
raise 'Output cannot be inside the input app' if options[:output].start_with?(options[:app] + '/')
input_executable = File.join(options[:app], 'Contents/MacOS/Terminal')
raise 'Executable SHA does not match supplied frozen provenance' unless Digest::SHA256.file(input_executable).hexdigest == options[:expected_sha]
FileUtils.mkdir_p(options[:output])
frozen = File.join(options[:output], 'Frozen Terminal.app')
before_bundle = bundle_manifest(options[:app])
FileUtils.cp_r(options[:app], frozen)
executable = File.join(frozen, 'Contents/MacOS/Terminal')
raise 'App resources changed while freezing' unless before_bundle == bundle_manifest(frozen) && before_bundle == bundle_manifest(options[:app])
raise 'App changed while freezing' unless Digest::SHA256.file(executable).hexdigest == options[:expected_sha] &&
  Digest::SHA256.file(input_executable).hexdigest == options[:expected_sha]
environment = {
  'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
  'SHELL' => File.join(__dir__, 'fixture.rb'),
  'TERMINAL_RENDER_PROOF_DIRECTORY' => options[:output],
  'TERMINAL_RENDER_PROOF_EXECUTABLE' => executable,
  'TERMINAL_RENDER_PROOF_NEGATIVE' => options[:negative] ? '1' : '0'
}
processes = []
report = { source_sha: options[:source_sha], executable_sha256: options[:expected_sha], input_app: options[:app],
  host_clock: 'ProcessInfo.systemUptime / CLOCK_UPTIME_RAW, cross-checked by prepare',
  verified_bundle_manifest: before_bundle,
  frozen_app: frozen, negative_control: options[:negative],
  negative_control_kind: 'fixture rectangle doubled in width; not a compositor-gravity toggle',
  prior_evidence_reused: false, helper_sha256: %w[Capture Driver].to_h { |n| [n, Digest::SHA256.file(File.join(helpers, n)).hexdigest] },
  source_sha256: Dir[File.join(__dir__, '*')].select { |p| File.file?(p) }.to_h { |p| [File.basename(p), Digest::SHA256.file(p).hexdigest] } }
Signal.trap('INT') { raise Interrupt }
Signal.trap('TERM') { raise Interrupt }
begin
  log = File.open(File.join(options[:output], 'app.log'), 'w')
  app = NativeSmokeProcess.new([environment, executable, '--working-directory', '/tmp', '--font-size', '14', out: log, err: log])
  processes << app
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  until File.exist?(File.join(options[:output], 'pane-0.json'))
    raise 'App exited before fixture startup' if app.wait(0.05)
    raise 'Fixture startup timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  end
  driver_log = File.open(File.join(options[:output], 'driver.log'), 'w')
  prepare = NativeSmokeProcess.new([environment, File.join(helpers, 'Driver'), 'prepare', app.pid.to_s, options[:output], out: driver_log, err: driver_log])
  processes << prepare
  raise 'Owned-window preparation failed' unless prepare.wait(15)&.success?
  identity = JSON.parse(File.read(File.join(options[:output], 'identity.json')))
  raise 'Owned window identity mismatch' unless identity.fetch('pid') == app.pid && identity.fetch('executable') == executable
  report[:identity] = identity
  capture_log = File.open(File.join(options[:output], 'capture.log'), 'w')
  capture = NativeSmokeProcess.new([File.join(helpers, 'Capture'), identity.fetch('window').to_s,
    options[:output], app.pid.to_s, '22', out: capture_log, err: capture_log])
  processes << capture
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until File.exist?(File.join(options[:output], 'ready'))
    raise 'Capture exited before readiness' if capture.wait(0.05)
    raise 'Capture startup timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise 'App exited during capture startup' if app.wait(0.01)
  end
  driver = NativeSmokeProcess.new([environment, File.join(helpers, 'Driver'), 'exercise', app.pid.to_s, options[:output], out: driver_log, err: driver_log])
  processes << driver
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  loop do
    raise 'App exited during proof' if app.wait(0.01)
    state = capture.wait(0.05)
    if state
      raise 'Capture failed' unless state.success?
      break
    end
    raise 'Capture deadline expired' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  end
  raise 'Native input exercise failed' unless driver.wait(2)&.success?
  report[:recording_evidence] = RecordingEvidence.validate!(options[:output])
  samples = File.readlines(File.join(options[:output], 'frames.jsonl')).map { |line| JSON.parse(line) }
  events = JSON.parse(File.read(File.join(options[:output], 'input-events.json'))).fetch('events')
  pane_events = (0..2).flat_map { |id| File.readlines(File.join(options[:output], "pane-#{id}-events.jsonl")).map { |line| JSON.parse(line) } }
  errors = samples.select { |s| %w[stream_error recording_error stop_error].any? { |key| s.key?(key) } }
  final = events.find { |event| event['phase'] == 'final_static_output' }
  expected_final = (0..2).to_h { |id| [id, pane_events.reverse.find { |event| event['pane'] == id && event['final'] }] }
  report[:expected_final_panes] = expected_final
  report[:final_visible_generation_gate] = final && samples.any? do |sample|
    sample['host_time'].to_f >= final.fetch('host_time') && (0..2).all? do |id|
      expected_final[id] && (sample['panes'] || []).any? { |p| p['pane'] == id && p['result'] == 'correct' && p['visible_final_flag'] && p['validated_visible_generation'] == expected_final[id]['generation'] && p['visible_rows'] == expected_final[id]['rows'] && p['visible_columns'] == expected_final[id]['columns'] }
    end
  end
  report[:native_phases] = %w[native_outer_divider native_inner_divider native_window_resize].to_h do |phase|
    phase_events = events.select { |event| event['phase'] == phase }
    range = phase_events.empty? ? nil : (phase_events.first['host_time']..phase_events.last['host_time'])
    changes = range ? pane_events.select { |event| range.cover?(event['host_time']) } : []
    captured = range ? samples.count { |sample| range.cover?(sample['host_time'].to_f) && sample['status'] == 0 } : 0
    changing = changes.group_by { |e| e['pane'] }.values.any? { |rows| rows.map { |e| [e['rows'], e['columns']] }.uniq.length > 1 }
    [phase, { complete: phase_events.any? { |e| e['gesture_complete'] }, geometry_changed_within_pane: changing,
      geometry_states: changes.map { |e| [e['pane'], e['rows'], e['columns']] }.uniq.length,
      complete_capture_callbacks: captured, appkit_live_resize_callbacks_available: false }]
  end
  report[:classifications] = samples.group_by { |s| s['classification'] || 'capture_error' }.transform_values(&:length)
  report[:capture_errors] = errors
  report[:scope] = 'Absolute per-pane marker dimensions + checksum-validated visible final PTY geometry; no same-frame native offset references or actual drawable presentation callbacks. Native phase geometry comes from PTY WINCH, not injection success alone. Frame phase attribution uses callback receipt host_time, not SCK presentation timestamps; queued callbacks may lag their image acquisition.'
  geometry_ok = report[:native_phases].values.all? { |p| p[:complete] && p[:geometry_changed_within_pane] && p[:complete_capture_callbacks] > 0 }
  failure_count = report[:classifications].fetch('failure', 0)
  expected_delta = [6 * identity.fetch('cell_width_pixels'), 0]
  report[:negative_control_expected_delta_wh] = expected_delta
  report[:negative_control_gate] = samples.any? do |sample|
    (0..2).all? do |id|
      (sample['panes'] || []).any? do |pane|
        delta = pane['delta_wh']
        pane['pane'] == id && pane['reason'] == 'absolute_dimensions' && delta &&
          (delta[0] - expected_delta[0]).abs <= 1 && delta[1].abs <= 1
      end
    end
  end
  report[:passed] = errors.empty? && geometry_ok && (options[:negative] ? report[:negative_control_gate] : failure_count.zero? && report[:final_visible_generation_gate])
  raise 'Proof gates did not pass; inspect preserved pixels and analysis' unless report[:passed]
rescue Exception => error
  report[:error] = "#{error.class}: #{error.message}"
  raise
ensure
  report[:cleanup] = processes.reverse.map { |process| { pid: process.pid, survivors: process.cleanup } }
  report[:sha256] = %w[frames.jsonl capture.mp4 summary.json input-events.json identity.json ax-window-queries.jsonl].filter_map do |name|
    path = File.join(options[:output], name)
    [name, Digest::SHA256.file(path).hexdigest] if File.file?(path)
  end.to_h
  File.write(File.join(options[:output], 'analysis.json'), JSON.pretty_generate(report) + "\n")
  raise 'Owned processes survived cleanup' unless report[:cleanup].all? { |entry| entry[:survivors].empty? }
end
puts "PASS #{options[:negative] ? 'fixture-width negative control detected' : 'production dimensions/final-visible-generation gates'}; inspect video for glyph quality and inconclusive frames"

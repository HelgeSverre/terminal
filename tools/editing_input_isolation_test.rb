# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

root = ENV.fetch('TERMINAL_PROJECT_ROOT', File.expand_path('..', __dir__))
require File.join(root, 'tools/native_smoke')
abort 'Usage: ruby tools/editing_input_isolation_test.rb APP NEW_REPORTDIR' unless ARGV.length == 2
app, output = ARGV.map { |path| File.expand_path(path) }
abort 'Missing app bundle' unless File.executable?(File.join(app, 'Contents/MacOS/Terminal'))
abort 'Report directory must not already exist' if File.exist?(output)
FileUtils.mkdir_p(File.dirname(output))
Dir.mkdir(output)
Signal.trap('INT') { raise Interrupt, 'Isolation test interrupted' }
Signal.trap('TERM') { raise Interrupt, 'Isolation test terminated' }
report = { 'passed' => false, 'variants' => {} }
run = lambda do |name, *command|
  text, status = Open3.capture2e(*command, chdir: root)
  File.write(File.join(output, "#{name}.log"), text)
  raise "#{name} failed (see retained log)" unless status.success?
end
replace_once = lambda do |text, needle, replacement|
  raise 'Fixture source contract changed; review the injection' unless text.scan(needle).length == 1
  text.sub(needle, replacement)
end
begin
  graph_path = File.join(root, 'tools/swift-sources.json')
  graph = JSON.parse(File.read(graph_path)).fetch('app')
  fixture = 'Sources/Terminal/EditingSmoke.swift'
  raise 'Fixture must occur exactly once in app graph' unless graph.count(fixture) == 1
  source = File.read(File.join(root, fixture))
  marker = '    window.panes.first?.onObservedSnapshot'
  injection = <<~'SWIFT'
      // Controlled, unowned input exists only in this temporary test source.
      if let nativeWindow = window.window {
        for index in 0..<2 {
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime.rounded(.down) + 3600 + Double(index), windowNumber: nativeWindow.windowNumber,
            context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
          test.isolationProbes.append(event)
          NSApp.postEvent(event, atStart: false)
        }
      }
  SWIFT
  monitor = <<~'SWIFT'.lines.map { |line| '    ' + line }.join
    test.keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak test] event in
      guard let test, event.window === test.controller.window else { return event }
      guard event === test.syntheticEvent else {
        test.suppressedExternalKeys += 1
        return nil
      }
      return event
    }
  SWIFT
  outer_guard = <<~'SWIFT'
      test.isolationGuard = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak test] event in
        guard let test, event.window === test.controller.window else { return event }
        if event === test.syntheticEvent { return event }
        if test.isIsolationProbe(event) {
          test.observedIsolationProbes += 1
          return event
        }
        return nil
      }
  SWIFT
  source = replace_once.call(source, '  private var keyboardMonitor: Any?', <<~'SWIFT')
    private var isolationGuard: Any?
    private var isolationProbes: [NSEvent] = []
    private func isIsolationProbe(_ event: NSEvent) -> Bool {
      isolationProbes.contains { probe in
        probe.timestamp == event.timestamp && probe.keyCode == event.keyCode
          && probe.type == event.type && probe.windowNumber == event.windowNumber
      }
    }
    private var observedIsolationProbes = 0
    private var rejectedIsolationProbes = 0
    private var keyboardMonitor: Any?
  SWIFT
  source = replace_once.call(source, "    active = test\n", "    active = test\n" + outer_guard)
  source = replace_once.call(source, "    Self.active = nil\n", <<~'SWIFT')
      Self.active = nil
      if let isolationGuard { NSEvent.removeMonitor(isolationGuard) }
      measurements["controlled_probes_observed"] = observedIsolationProbes
      measurements["controlled_probes_rejected"] = rejectedIsolationProbes
  SWIFT
  # Remove injected input only after strict fresh-prompt assertions; setup must
  # still execute its HISTFILE=/dev/null assignment with an empty input buffer.
  source = replace_once.call(source, "  private func setupProbe() {\n", "  private func setupProbe() {\n      key(32, \"u\", flags: .control)\n")
  candidate = replace_once.call(source, "        test.suppressedExternalKeys += 1\n", <<~'SWIFT')
          test.suppressedExternalKeys += 1
          if test.isIsolationProbe(event) { test.rejectedIsolationProbes += 1 }
  SWIFT
  variants = {
    'baseline' => replace_once.call(source, monitor, ''),
    'candidate' => candidate
  }.transform_values { |text| replace_once.call(text, marker, injection + marker) }
  inputs = graph + ['tools/swift-sources.json', 'Sources/Terminal/Interop/Bridge.h', 'Sources/Terminal/Interop/Spawn.c']
  hashes = inputs.to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
  report['source_sha256'] = hashes
  Dir.mktmpdir('terminal-editing-input-') do |temporary|
    bundle = File.join(temporary, 'Terminal.app')
    FileUtils.cp_r(app, bundle)
    spawn = File.join(temporary, 'Spawn.o')
    run.call('spawn-build', 'xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=15.0',
      '-c', File.join(root, 'Sources/Terminal/Interop/Spawn.c'), '-o', spawn)
    variants.each do |name, text|
      edited = File.join(temporary, 'EditingSmoke.swift')
      File.write(edited, text)
      executable = File.join(bundle, 'Contents/MacOS/Terminal')
      sources = graph.map { |path| path == fixture ? edited : File.join(root, path) }
      run.call("#{name}-build", 'xcrun', 'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macosx15.0',
        '-module-cache-path', File.join(temporary, 'module-cache'), '-import-objc-header',
        File.join(root, 'Sources/Terminal/Interop/Bridge.h'), *sources, spawn,
        *%w[AppKit QuartzCore Metal CoreText ImageIO].flat_map { |framework| ['-framework', framework] }, '-o', executable)
      record = report['variants'][name] = { 'fixture_sha256' => Digest::SHA256.hexdigest(text),
        'executable_sha256' => Digest::SHA256.file(executable).hexdigest }
      path = File.join(output, "#{name}.json")
      process = NativeSmokeProcess.new([executable, '--editing-smoke', path], log: File.join(output, "#{name}-app.log"))
      begin
        status = process.wait(20)
        raise "#{name} failed to exit successfully" unless status&.success?
        raise "#{name} left children running" unless process.live_pids.empty?
        record['smoke'] = JSON.parse(File.read(path))
      ensure
        record['cleanup_survivors'] = process.cleanup
        raise "#{name} cleanup failed" unless record['cleanup_survivors'].empty?
      end
      smoke = record.fetch('smoke'); measurements = smoke.fetch('measurements')
      columns = %w[fresh_initial_col fresh_typed_col fresh_erased_col].map { |key| measurements.fetch(key) }
      if name == 'baseline'
        raise 'Baseline did not reproduce controlled contamination' unless !smoke.fetch('passed') && columns == [4, 6, 4] && measurements.fetch('controlled_probes_observed') == 2
        raise 'Baseline failed another check' unless smoke.fetch('checks').reject { |key, _| key == 'fresh_starship_cursor_alignment' }.values.all?
      else
        raise 'Candidate did not isolate the injected input' unless smoke.fetch('passed') && columns == [2, 4, 2] && measurements.fetch('controlled_probes_rejected') == 2 && measurements.fetch('suppressed_external_key_events') >= 2
      end
    end
  end
  raise 'Sources changed during verification' unless hashes.all? { |path, hash| Digest::SHA256.file(File.join(root, path)).hexdigest == hash }
  report['passed'] = true
rescue Exception => error
  report['failure'] = error.message
  raise
ensure
  File.write(File.join(output, 'isolation.json'), JSON.pretty_generate(report) + "\n")
end
puts 'PASS controlled editing input isolation (baseline red, candidate green, no survivors)'

import Foundation

/// Proves that the editing smoke rejects keys it did not send.
///
/// Two temporary variants of `EditingSmoke.swift` post two stray key events
/// into the smoke's window. The baseline has the smoke's keyboard monitor
/// removed and must fail in exactly the way stray input causes; the candidate
/// keeps the monitor and must pass, having rejected both events. Each variant
/// is built into a private copy of the bundle.
enum EditingInputIsolation {
  static let command = Command(
    name: "editing-input-isolation", usage: "APP NEW_REPORT_DIRECTORY",
    summary: "Build the editing smoke with and without its keyboard monitor and require only the first to pass.",
    run: run)

  static let fixture = "Sources/Terminal/EditingSmoke.swift"

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 2 else { throw Failure.usage(command) }
    let root = ProcessInfo.processInfo.environment["TERMINAL_PROJECT_ROOT"] ?? Repository.root
    let here = FileManager.default.currentDirectoryPath
    let app = absolutePath(arguments[0], relativeTo: here)
    guard FileManager.default.isExecutableFile(atPath: app + "/Contents/MacOS/Terminal") else {
      throw Failure("missing app bundle")
    }
    let output = try OutputDirectory(creating: arguments[1])
    var report: [String: Any] = ["passed": false, "variants": [String: Any]()]
    var failure: Failure?
    do {
      try verify(root: root, app: app, output: output, report: &report)
      report["passed"] = true
    } catch {
      failure = Failure(wrapping: error)
      report["failure"] = failure?.message
    }
    try output.write(json: report, to: "isolation.json")
    if let failure { throw failure }
    print("PASS controlled editing input isolation (baseline red, candidate green, no survivors)")
  }

  private static func verify(root: String, app: String, output: OutputDirectory, report: inout [String: Any]) throws {
    let graph = try appSources(root: root)
    let edits = try variants(of: try String(contentsOfFile: "\(root)/\(fixture)", encoding: .utf8))
    let inputs = graph + ["tools/swift-sources.json", "Sources/Terminal/Interop/Bridge.h", "Sources/Terminal/Interop/Spawn.c"]
    let hashes = try sourceHashes(inputs, root: root)
    report["source_sha256"] = hashes
    var records: [String: Any] = [:]
    try withTemporaryDirectory("terminal-editing-input-") { temporary in
      let bundle = temporary + "/Terminal.app"
      try FileManager.default.copyItem(atPath: app, toPath: bundle)
      let executable = bundle + "/Contents/MacOS/Terminal"
      let spawn = temporary + "/Spawn.o"
      try build("spawn-build", ["/usr/bin/xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0",
        "-c", "\(root)/Sources/Terminal/Interop/Spawn.c", "-o", spawn], root: root, output: output)
      for variant in edits {
        let edited = temporary + "/EditingSmoke.swift"
        try variant.text.write(toFile: edited, atomically: true, encoding: .utf8)
        let sources = graph.map { $0 == fixture ? edited : "\(root)/\($0)" }
        let frameworks = ["AppKit", "QuartzCore", "Metal", "CoreText", "ImageIO"].flatMap { ["-framework", $0] }
        try build("\(variant.name)-build", ["/usr/bin/xcrun", "swiftc", "-swift-version", "5",
          "-target", "arm64-apple-macosx15.0", "-module-cache-path", temporary + "/module-cache",
          "-import-objc-header", "\(root)/Sources/Terminal/Interop/Bridge.h"]
          + sources + [spawn] + frameworks + ["-o", executable], root: root, output: output)
        var record: [String: Any] = ["fixture_sha256": try sha256(ofFile: edited),
                                     "executable_sha256": try sha256(ofFile: executable)]
        let result = Result { try smoke(variant.name, executable: executable, output: output, record: &record) }
        records[variant.name] = record
        report["variants"] = records
        try result.get()
      }
    }
    guard try sourceHashes(inputs, root: root) == hashes else { throw Failure("sources changed during verification") }
  }

  /// The app's source files, of which the fixture must be exactly one.
  private static func appSources(root: String) throws -> [String] {
    guard let graph = try readJSONObject(root + "/tools/swift-sources.json")["app"] as? [String] else {
      throw Failure("tools/swift-sources.json has no app sources")
    }
    guard graph.filter({ $0 == fixture }).count == 1 else {
      throw Failure("fixture must occur exactly once in app graph")
    }
    return graph
  }

  private static func sourceHashes(_ paths: [String], root: String) throws -> [String: String] {
    try Dictionary(paths.map { ($0, try sha256(ofFile: "\(root)/\($0)")) }) { first, _ in first }
  }

  /// Runs a build step from the repository root and keeps its output as
  /// `NAME.log` in the report directory.
  private static func build(_ name: String, _ command: [String], root: String, output: OutputDirectory) throws {
    let result = try capture(command, adding: [:], directory: root)
    try result.output.write(toFile: output.file(name + ".log"), atomically: true, encoding: .utf8)
    guard result.succeeded else { throw Failure("\(name) failed (see retained log)") }
  }

  /// Runs one variant's editing smoke, records its report and cleanup in
  /// `record`, and judges the report.
  private static func smoke(_ name: String, executable: String, output: OutputDirectory,
                            record: inout [String: Any]) throws {
    let path = output.file(name + ".json")
    let app = try ProcessTree([executable, "--editing-smoke", path], output: .log(output.file(name + "-app.log")))
    var failure: Failure?
    var report: [String: Any] = [:]
    do {
      guard app.wait(seconds: 20)?.succeeded == true else { throw Failure("\(name) failed to exit successfully") }
      guard app.livePIDs.isEmpty else { throw Failure("\(name) left children running") }
      report = try readJSONObject(path)
      record["smoke"] = report
    } catch {
      failure = Failure(wrapping: error)
    }
    let survivors = app.cleanup()
    record["cleanup_survivors"] = survivors.map { Int($0) }
    guard survivors.isEmpty else { throw Failure("\(name) cleanup failed") }
    if let failure { throw failure }
    try judge(name, report)
  }

  /// The baseline must fail only the cursor alignment check, with the prompt
  /// columns two stray characters produce. The candidate must pass with clean
  /// columns, having rejected both events.
  static func judge(_ name: String, _ smoke: [String: Any]) throws {
    let measurements = smoke["measurements"] as? [String: Any] ?? [:]
    let columns = ["fresh_initial_col", "fresh_typed_col", "fresh_erased_col"].map { measurements[$0] as? Int }
    let passed = truthy(smoke["passed"])
    if name == "baseline" {
      guard !passed, columns == [4, 6, 4], measurements["controlled_probes_observed"] as? Int == 2 else {
        throw Failure("baseline did not reproduce controlled contamination")
      }
      let others = (smoke["checks"] as? [String: Any] ?? [:]).filter { $0.key != "fresh_starship_cursor_alignment" }
      guard others.values.allSatisfy({ truthy($0) }) else { throw Failure("baseline failed another check") }
    } else {
      guard passed, columns == [2, 4, 2], measurements["controlled_probes_rejected"] as? Int == 2,
            (measurements["suppressed_external_key_events"] as? Int ?? 0) >= 2 else {
        throw Failure("candidate did not isolate the injected input")
      }
    }
  }

  /// Replaces the single occurrence of `needle`. Any other count means the
  /// fixture source has changed under the edits made here.
  static func replaceOnce(_ text: String, _ needle: String, _ replacement: String) throws -> String {
    let parts = text.components(separatedBy: needle)
    guard parts.count == 2 else { throw Failure("fixture source contract changed; review the injection") }
    return parts[0] + replacement + parts[1]
  }

  /// The two sources to build, from the fixture's source: `baseline`, then `candidate`.
  static func variants(of original: String) throws -> [(name: String, text: String)] {
    var source = try replaceOnce(original, "  private var keyboardMonitor: Any?", state)
    source = try replaceOnce(source, "    active = test\n", "    active = test\n" + outerGuard)
    source = try replaceOnce(source, "    Self.active = nil\n", teardown)
    // The injected input is erased only after the strict fresh-prompt
    // assertions; setup must still run its HISTFILE=/dev/null assignment with
    // an empty input buffer.
    source = try replaceOnce(source, "  private func setupProbe() {\n",
                             "  private func setupProbe() {\n      key(32, \"u\", flags: .control)\n")
    let candidate = try replaceOnce(source, "        test.suppressedExternalKeys += 1\n", countRejected)
    let baseline = try replaceOnce(source, monitor, "")
    return try [("baseline", baseline), ("candidate", candidate)].map { name, text in
      (name, try replaceOnce(text, marker, injection + marker))
    }
  }

  /// The line of the fixture before which the stray events are posted.
  private static let marker = "    window.panes.first?.onObservedSnapshot"

  private static let injection = """
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

    """

  /// The smoke's own keyboard monitor, as it stands in the fixture. The baseline lacks it.
  private static let monitor = """
        test.keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak test] event in
          guard let test, event.window === test.controller.window else { return event }
          guard event === test.syntheticEvent else {
            test.suppressedExternalKeys += 1
            return nil
          }
          return event
        }

    """

  /// A monitor installed before the smoke's own. It lets the stray events
  /// through and counts them, and still keeps every other key out.
  private static let outerGuard = """
    test.isolationGuard = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak test] event in
      guard let test, event.window === test.controller.window else { return event }
      if event === test.syntheticEvent { return event }
      if test.isIsolationProbe(event) {
        test.observedIsolationProbes += 1
        return event
      }
      return nil
    }

    """

  private static let state = """
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

    """

  private static let teardown = """
    Self.active = nil
    if let isolationGuard { NSEvent.removeMonitor(isolationGuard) }
    measurements["controlled_probes_observed"] = observedIsolationProbes
    measurements["controlled_probes_rejected"] = rejectedIsolationProbes

    """

  private static let countRejected = """
    test.suppressedExternalKeys += 1
    if test.isIsolationProbe(event) { test.rejectedIsolationProbes += 1 }

    """

  static let tests = [
    SelfTest.Case(name: "editing input isolation: the edits still fit the fixture source") {
      let source = try String(contentsOfFile: Repository.path(fixture), encoding: .utf8)
      let edits = try variants(of: source)
      try expect(edits.map(\.name) == ["baseline", "candidate"], "baseline is built first")
      for variant in edits {
        try expect(variant.text.contains(injection + marker), "\(variant.name) posts the stray events")
        try expect(variant.text.contains("test.observedIsolationProbes += 1"), "\(variant.name) counts them")
      }
      try expect(!edits[0].text.contains(monitor), "the baseline has no keyboard monitor")
      try expect(edits[1].text.contains(monitor.replacingOccurrences(
        of: "        test.suppressedExternalKeys += 1\n", with: countRejected)), "the candidate's monitor counts rejections")
    },
    SelfTest.Case(name: "editing input isolation: a source that changed under the edits is refused") {
      let failure = try expectFailure("a changed source") { _ = try variants(of: "struct EditingSmoke {}\n") }
      try expect(failure.message.contains("fixture source contract changed"), "got: \(failure.message)")
      try expect(try replaceOnce("a b a", "b", "c") == "a c a", "one occurrence is replaced")
      _ = try expectFailure("two occurrences") { _ = try replaceOnce("a b a", "a", "c") }
    },
    SelfTest.Case(name: "editing input isolation: the baseline must fail only on alignment, the candidate must pass") {
      func smoke(passed: Bool, columns: [Int], _ counter: String, checks: [String: Bool]) -> [String: Any] {
        ["passed": passed, "checks": checks, "measurements": [
          "fresh_initial_col": columns[0], "fresh_typed_col": columns[1], "fresh_erased_col": columns[2],
          counter: 2, "suppressed_external_key_events": 2]]
      }
      let aligned = "fresh_starship_cursor_alignment"
      try judge("baseline", smoke(passed: false, columns: [4, 6, 4], "controlled_probes_observed",
                                  checks: [aligned: false, "other": true]))
      try judge("candidate", smoke(passed: true, columns: [2, 4, 2], "controlled_probes_rejected", checks: [aligned: true]))
      var failure = try expectFailure("a passing baseline") {
        try judge("baseline", smoke(passed: true, columns: [2, 4, 2], "controlled_probes_observed", checks: [aligned: true]))
      }
      try expect(failure.message == "baseline did not reproduce controlled contamination", "got: \(failure.message)")
      failure = try expectFailure("a baseline failing elsewhere") {
        try judge("baseline", smoke(passed: false, columns: [4, 6, 4], "controlled_probes_observed",
                                    checks: [aligned: false, "other": false]))
      }
      try expect(failure.message == "baseline failed another check", "got: \(failure.message)")
      failure = try expectFailure("a contaminated candidate") {
        try judge("candidate", smoke(passed: true, columns: [4, 6, 4], "controlled_probes_rejected", checks: [aligned: true]))
      }
      try expect(failure.message == "candidate did not isolate the injected input", "got: \(failure.message)")
    },
  ]
}

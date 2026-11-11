import Foundation

/// Records how a frozen copy of the app draws while its panes change size.
///
/// The app copy starts with a synthetic fixture as its shell, which draws a
/// coloured rectangle and a barcode of its PTY geometry in each pane. A native
/// driver splits the window, drags both dividers and resizes the window while
/// it is recorded, and the run is judged from the captured frames against
/// what the fixtures recorded. `--prepare` checks the helpers and sends no
/// GUI input; a run needs a frozen app, its provenance and a new report directory.
enum RenderingProof {
  static let command = Command(
    name: "rendering-proof",
    usage: "--prepare | --app APP --output DIR --source-sha SHA --executable-sha256 SHA [--negative-control]",
    summary: "Capture a frozen copy of the app drawing synthetic panes through native splits, drags and resizes.",
    run: run)

  private static let sources = Repository.path("tools/rendering_proof")
  private static let panes = 0...2

  /// What a run is given: the app to copy and the proof of which build it is.
  struct Plan {
    var app: String
    var output: String
    var sourceSHA: String
    var executableSHA: String
    var negative: Bool

    /// The options a run must be given, each with a value.
    static let valueOptions: Set = ["--app", "--output", "--source-sha", "--executable-sha256"]

    init(_ options: Options) throws {
      func required(_ name: String) throws -> String {
        guard let value = options.values[name] else { throw Failure("Missing \(name)") }
        return value
      }
      app = absolutePath(try required("--app"))
      output = absolutePath(try required("--output"))
      sourceSHA = try required("--source-sha")
      executableSHA = try required("--executable-sha256")
      negative = options.flags.contains("--negative-control")
    }
  }

  static func run(_ arguments: [String]) throws {
    // The app starts the fixture as a program of its own.
    if arguments.first == "fixture" { return try RenderingProofFixture.main(Array(arguments.dropFirst())) }

    let options = try Options(arguments, flags: ["--prepare", "--negative-control"], values: Plan.valueOptions, command: command)
    guard options.positionals.isEmpty else { throw Failure.usage(command) }
    let helpers = try prepareHelpers()
    if options.flags.contains("--prepare") {
      print("PASS preparation only: helpers compiled and headless self-tests passed; no GUI launched")
      return
    }
    let plan = try Plan(options)
    try Session(plan, helpers: helpers).run()
    print("PASS \(plan.negative ? "fixture-width negative control detected" : "production dimensions/final-visible-generation gates")"
      + "; inspect video for glyph quality and inconclusive frames")
  }

  /// Runs tests and prints a PASS line for each. The first failure ends the run under `message`.
  private static func pass(_ cases: [SelfTest.Case], otherwise message: String) throws {
    for test in cases {
      do { try test.run() } catch { throw Failure("\(message): \(test.name): \(Failure(wrapping: error).message)") }
      print("PASS \(test.name)")
    }
  }

  /// The compiled capture and driver programs.
  struct Helpers {
    let capture: String
    let driver: String
  }

  /// Compiles the two native helpers and runs every check that needs no app:
  /// the helpers' own, the fixture's, the recording gate's and the clock comparison.
  private static func prepareHelpers() throws -> Helpers {
    let directory = absolutePath(ProcessInfo.processInfo.environment["TERMINAL_RENDER_PROOF_HELPERS"]
      ?? "~/.codex/artifacts/rendering-final-preflight/helpers")
    do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
    catch { throw Failure("cannot create \(directory): \(error.localizedDescription)") }
    func helper(_ name: String) throws -> String {
      let binary = try TUIStress.compileHelper(name, source: sources + "/\(name).swift", into: directory)
      guard try runInherited([binary, "--self-test"]) else { throw Failure("\(name) self-test failed") }
      return binary
    }
    let helpers = Helpers(capture: try helper("Capture"), driver: try helper("Driver"))
    try pass(RenderingProofFixture.imageTests, otherwise: "Fixture self-test failed")
    try pass(RenderingProofFixture.terminalTests, otherwise: "PTY fixture test failed")
    try pass(evidenceTests, otherwise: "Recording evidence test failed")
    try checkClock(driver: helpers.driver)
    return helpers
  }

  /// Fails unless the driver reads the clock the fixture stamps its events
  /// with. Phases are matched to PTY geometry and frames by time, and the
  /// system's other monotonic clock differs from this one by the time slept.
  static func checkClock(driver: String) throws {
    let start = RenderingProofFixture.hostTime()
    let output = try runCommand([driver, "--clock"], errors: .separate).output
    let end = RenderingProofFixture.hostTime()
    let native = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    guard native >= start - 0.01, native <= end + 0.01 else {
      throw Failure("Fixture and native helper clock domains differ")
    }
    print("PASS fixture/native host clock compatibility")
  }

  /// What a finished recording left, for the report. A capture counts only
  /// when its completion delegate reported success, no error was recorded and
  /// the video file has content.
  static func recordingEvidence(_ directory: String) throws -> [String: Any] {
    let summary = try readJSONObject(directory + "/summary.json")
    let finished = summary["recording_finished"]
    guard ReportValue.isBoolean(finished), finished as? Bool == true else {
      throw Failure("Recording completion delegate did not report success")
    }
    guard !ReportValue.isTruthy(summary["recording_error"]), !ReportValue.isTruthy(summary["recording_validation_error"]) else {
      throw Failure("Recording reported an error")
    }
    let video = directory + "/capture.mp4"
    guard !isDirectory(video), let bytes = try? fileBytes(video), bytes > 0 else {
      throw Failure("Finalized recording has no nonempty MP4")
    }
    return ["summary": summary, "video_bytes": bytes, "finalized_nonempty_video": true]
  }

  /// The hash of every file beside the helper sources, by name.
  static func sourceHashes(_ directory: String) throws -> [String: String] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
      .filter { !$0.hasPrefix(".") && !isDirectory(directory + "/" + $0) }
    return try Dictionary(uniqueKeysWithValues: names.map { ($0, try sha256(ofFile: directory + "/" + $0)) })
  }

  /// What the capture, the driver and the fixtures recorded during one run.
  struct Records {
    /// One record per capture callback, from `frames.jsonl`.
    var samples: [[String: Any]]
    /// The driver's input phases, from `input-events.json`.
    var inputEvents: [[String: Any]]
    /// Every image the three fixtures drew, from their `pane-N-events.jsonl`.
    var paneEvents: [[String: Any]]
  }

  /// The gates of a run as `analysis.json` records them.
  struct Verdict {
    var report: [String: Any]
    var passed: Bool
  }

  /// Judges the records of a run.
  ///
  /// Input that was posted proves nothing by itself: every native phase must
  /// have changed PTY geometry within a pane and been captured. A production
  /// run then needs no failed frame and one frame showing all three panes'
  /// latest final geometry. A negative control instead needs one frame in
  /// which all three rectangles are six cells too wide and nothing else.
  static func judge(_ records: Records, identity: [String: Any], negative: Bool) throws -> Verdict {
    let samples = records.samples
    func time(_ record: [String: Any]) -> Double? { ReportValue.number(record["host_time"]) }
    func visiblePanes(_ sample: [String: Any]) -> [[String: Any]] { sample["panes"] as? [[String: Any]] ?? [] }

    let errors = samples.filter { sample in
      ["stream_error", "recording_error", "stop_error"].contains { sample[$0] != nil }
    }
    var expected: [Int: [String: Any]] = [:]
    for pane in panes {
      expected[pane] = records.paneEvents.last { ReportValue.equals($0["pane"], pane) && ReportValue.isTruthy($0["final"]) }
    }
    // A driver that never announced its final output leaves the final gate failed.
    var finalGate = false
    if let final = records.inputEvents.first(where: { $0["phase"] as? String == "final_static_output" }) {
      let announced = try final.number("host_time")
      finalGate = samples.contains { sample in
        (time(sample) ?? 0) >= announced && panes.allSatisfy { id in
          guard let last = expected[id] else { return false }
          return visiblePanes(sample).contains { pane in
            ReportValue.equals(pane["pane"], id) && pane["result"] as? String == "correct"
              && ReportValue.isTruthy(pane["visible_final_flag"])
              && ReportValue.same(pane["validated_visible_generation"], last["generation"])
              && ReportValue.same(pane["visible_rows"], last["rows"])
              && ReportValue.same(pane["visible_columns"], last["columns"])
          }
        }
      }
    }

    var phases: [String: Any] = [:]
    var geometryChanged = true
    for phase in ["native_outer_divider", "native_inner_divider", "native_window_resize"] {
      let steps = records.inputEvents.filter { $0["phase"] as? String == phase }
      var changes: [[String: Any]] = []
      var captured = 0
      if let first = steps.first, let last = steps.last {
        let interval = (try first.number("host_time"), try last.number("host_time"))
        func within(_ record: [String: Any]) -> Bool { time(record).map { interval.0 <= $0 && $0 <= interval.1 } ?? false }
        changes = records.paneEvents.filter(within)
        // Frames are attributed by when their callback arrived, not by presentation time.
        captured = samples.filter { within($0) && ReportValue.equals($0["status"], 0) }.count
      }
      func geometry(_ event: [String: Any]) -> [Double?] {
        [ReportValue.number(event["rows"]), ReportValue.number(event["columns"])]
      }
      let complete = steps.contains { ReportValue.isTruthy($0["gesture_complete"]) }
      let changing = Dictionary(grouping: changes) { ReportValue.number($0["pane"]) }.values
        .contains { Set($0.map(geometry)).count > 1 }
      phases[phase] = [
        "complete": complete, "geometry_changed_within_pane": changing,
        "geometry_states": Set(changes.map { [ReportValue.number($0["pane"])] + geometry($0) }).count,
        "complete_capture_callbacks": captured, "appkit_live_resize_callbacks_available": false,
      ] as [String: Any]
      geometryChanged = geometryChanged && complete && changing && captured > 0
    }

    let classifications = Dictionary(grouping: samples) { $0["classification"] as? String ?? "capture_error" }
      .mapValues(\.count)
    let cellWidth = try identity.number("cell_width_pixels")
    let negativeGate = samples.contains { sample in
      panes.allSatisfy { id in
        visiblePanes(sample).contains { pane in
          guard ReportValue.equals(pane["pane"], id), pane["reason"] as? String == "absolute_dimensions",
                let delta = pane["delta_wh"] as? [Any], delta.count >= 2,
                let width = ReportValue.number(delta[0]), let height = ReportValue.number(delta[1]) else { return false }
          return abs(width - 6 * cellWidth) <= 1 && abs(height) <= 1
        }
      }
    }
    let passed: Bool
    if !errors.isEmpty || !geometryChanged {
      passed = false
    } else if negative {
      passed = negativeGate
    } else {
      passed = classifications["failure"] ?? 0 == 0 ? finalGate : false
    }

    func nullable(_ value: Any?) -> Any { value ?? NSNull() }
    let expectedWidth: Any = ReportValue.integer(identity["cell_width_pixels"]).map { 6 * $0 } ?? 6 * cellWidth
    return Verdict(report: [
      "expected_final_panes": Dictionary(uniqueKeysWithValues: panes.map { (String($0), nullable(expected[$0])) }),
      "final_visible_generation_gate": finalGate,
      "native_phases": phases,
      "classifications": classifications,
      "capture_errors": errors,
      "scope": "Absolute per-pane marker dimensions + checksum-validated visible final PTY geometry; no same-frame native"
        + " offset references or actual drawable presentation callbacks. Native phase geometry comes from PTY WINCH, not"
        + " injection success alone. Frame phase attribution uses callback receipt host_time, not SCK presentation"
        + " timestamps; queued callbacks may lag their image acquisition.",
      "negative_control_expected_delta_wh": [expectedWidth, 0],
      "negative_control_gate": negativeGate,
      "passed": passed,
    ], passed: passed)
  }

  /// One run: the frozen app copy, everything launched around it, and the report.
  final class Session {
    private let plan: Plan
    private let helpers: Helpers
    private let executable: String
    private let environment: [String: String?]
    private var processes: [ProcessTree] = []
    private var report: [String: Any]
    private var output: String { plan.output }

    /// Checks the provenance, creates the report directory and freezes the
    /// app into it. Nothing has been launched when this fails, and no report is written.
    init(_ plan: Plan, helpers: Helpers) throws {
      self.plan = plan
      self.helpers = helpers
      guard plan.sourceSHA.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
        throw Failure("Invalid source SHA")
      }
      guard !FileManager.default.fileExists(atPath: plan.output) else { throw Failure("Use a fresh output directory") }
      guard !plan.output.hasPrefix(plan.app + "/") else { throw Failure("Output cannot be inside the input app") }
      let input = plan.app + "/Contents/MacOS/Terminal"
      guard try sha256(ofFile: input) == plan.executableSHA else {
        throw Failure("Executable SHA does not match supplied frozen provenance")
      }
      let frozen = plan.output + "/Frozen Terminal.app"
      executable = frozen + "/Contents/MacOS/Terminal"
      let shell = plan.output + "/fixture-shell"
      let manifest: [String: TUIStress.BundleEntry]
      do {
        try FileManager.default.createDirectory(atPath: plan.output, withIntermediateDirectories: true)
        manifest = try TUIStress.bundleManifest(plan.app)
        try FileManager.default.copyItem(atPath: plan.app, toPath: frozen)
        guard try manifest == TUIStress.bundleManifest(frozen), try manifest == TUIStress.bundleManifest(plan.app) else {
          throw Failure("App resources changed while freezing")
        }
        try Tool.writeLauncher(at: shell, subcommand: ["rendering-proof", "fixture"])
      } catch { throw Failure(wrapping: error) }
      guard try sha256(ofFile: executable) == plan.executableSHA, try sha256(ofFile: input) == plan.executableSHA else {
        throw Failure("App changed while freezing")
      }

      environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell,
        "TERMINAL_RENDER_PROOF_DIRECTORY": plan.output, "TERMINAL_RENDER_PROOF_EXECUTABLE": executable,
        "TERMINAL_RENDER_PROOF_NEGATIVE": plan.negative ? "1" : "0",
      ]
      report = [
        "source_sha": plan.sourceSHA, "executable_sha256": plan.executableSHA, "input_app": plan.app,
        "host_clock": "ProcessInfo.systemUptime / CLOCK_UPTIME_RAW, cross-checked by prepare",
        "verified_bundle_manifest": manifest.mapValues(\.json),
        "frozen_app": frozen, "negative_control": plan.negative,
        "negative_control_kind": "fixture rectangle doubled in width; not a compositor-gravity toggle",
        "prior_evidence_reused": false,
        "helper_sha256": [
          "Capture": try sha256(ofFile: helpers.capture), "Driver": try sha256(ofFile: helpers.driver),
          // The fixture and this runner are this tool.
          "dev": try sha256(ofFile: Tool.executable),
        ],
        "source_sha256": try sourceHashes(sources),
      ]
    }

    /// Runs the proof and writes `analysis.json` whatever happens, also when
    /// the run is interrupted. A failed cleanup fails a run that otherwise passed.
    func run() throws {
      Interruption.observe()
      var failure: Failure?
      do {
        try exercise()
      } catch {
        failure = Failure(wrapping: error)
        report["error"] = "Failure: \(failure?.message ?? "")"
      }
      try finish()
      if let failure { throw failure }
    }

    private func launch(_ command: [String], environment: [String: String?] = [:], log: String) throws -> ProcessTree {
      let process = try ProcessTree(command, environment: environment, output: .log(output + "/" + log))
      processes.append(process)
      return process
    }

    /// Waits for a file a launched process writes into the report directory.
    /// `running` fails the wait when a process the file depends on has ended.
    private func waitForFile(_ name: String, seconds: Double, otherwise message: String,
                             running: () throws -> Void) throws {
      try TUIStress.waitUntil(seconds, message) { () -> Bool? in
        if FileManager.default.fileExists(atPath: output + "/" + name) { return true }
        try running()
        try Interruption.check()
        return nil
      }
    }

    private func exercise() throws {
      let app = try launch([executable, "--working-directory", "/tmp", "--font-size", "14"],
                           environment: environment, log: "app.log")
      try waitForFile("pane-0.json", seconds: 15, otherwise: "Fixture startup timed out") {
        guard app.wait(seconds: 0.05) == nil else { throw Failure("App exited before fixture startup") }
      }

      let pid = String(app.pid)
      let prepare = try launch([helpers.driver, "prepare", pid, output], environment: environment, log: "driver-prepare.log")
      guard try prepare.waitInterruptibly(seconds: 15)?.succeeded == true else {
        throw Failure("Owned-window preparation failed")
      }
      let identity = try readJSONObject(output + "/identity.json")
      guard ReportValue.equals(identity["pid"], Int(app.pid)), identity["executable"] as? String == executable,
            let window = ReportValue.integer(identity["window"]) else { throw Failure("Owned window identity mismatch") }
      report["identity"] = identity

      let capture = try launch([helpers.capture, String(window), output, pid, "22"], log: "capture.log")
      try waitForFile("ready", seconds: 10, otherwise: "Capture startup timed out") {
        guard capture.wait(seconds: 0.05) == nil else { throw Failure("Capture exited before readiness") }
        guard app.wait(seconds: 0.01) == nil else { throw Failure("App exited during capture startup") }
      }
      let driver = try launch([helpers.driver, "exercise", pid, output], environment: environment, log: "driver-exercise.log")
      let captured = try TUIStress.waitUntil(30, "Capture deadline expired") { () -> ProcessTree.Exit? in
        guard app.wait(seconds: 0.01) == nil else { throw Failure("App exited during proof") }
        try Interruption.check()
        return capture.wait(seconds: 0.05)
      }
      guard captured.succeeded else { throw Failure("Capture failed") }
      guard try driver.waitInterruptibly(seconds: 2)?.succeeded == true else {
        throw Failure("Native input exercise failed")
      }

      report["recording_evidence"] = try recordingEvidence(output)
      let records = Records(
        samples: try TUIStress.events(output + "/frames.jsonl"),
        inputEvents: try readJSONObject(output + "/input-events.json").objects("events"),
        paneEvents: try panes.flatMap { try TUIStress.events(output + "/pane-\($0)-events.jsonl") })
      let verdict = try judge(records, identity: identity, negative: plan.negative)
      report.merge(verdict.report) { _, new in new }
      guard verdict.passed else {
        throw Failure("Proof gates did not pass; inspect preserved pixels and analysis")
      }
    }

    /// Ends everything this run launched, newest first, then completes and writes the report.
    private func finish() throws {
      let cleanup = processes.reversed().map { (pid: Int($0.pid), survivors: $0.cleanup().map { Int($0) }) }
      report["cleanup"] = cleanup.map { ["pid": $0.pid, "survivors": $0.survivors] as [String: Any] }
      var hashes: [String: String] = [:]
      for name in ["frames.jsonl", "capture.mp4", "summary.json", "input-events.json", "identity.json",
                   "ax-window-queries.jsonl"] {
        if let hash = try? sha256(ofFile: output + "/" + name) { hashes[name] = hash }
      }
      report["sha256"] = hashes
      try JSONValue(sortingKeysOf: report).write(to: output + "/analysis.json")
      guard cleanup.allSatisfy(\.survivors.isEmpty) else { throw Failure("Owned processes survived cleanup") }
    }
  }

  static let tests = evidenceTests + verdictTests

  static let evidenceTests = [
    SelfTest.Case(name: "rendering-proof recording evidence: absent/unfinished/error/empty rejected; finalized nonempty accepted") {
      try withTemporaryDirectory("dev-rendering-recording-gate-") { directory in
        let summary = directory + "/summary.json", video = directory + "/capture.mp4"
        func write(_ object: [String: Any], _ videoText: String?) throws {
          try writeJSON(object, to: summary)
          try? FileManager.default.removeItem(atPath: video)
          if let videoText { FileManager.default.createFile(atPath: video, contents: Data(videoText.utf8)) }
        }
        func rejected(_ label: String, _ reason: String) throws {
          let failure = try expectFailure(label) { _ = try recordingEvidence(directory) }
          try expect(failure.message.contains(reason), "\(label): got \(failure.message)")
        }
        try rejected("missing summary", "cannot read")
        // The video only has to exist and hold bytes; decoding it is not what these gates check.
        let payload = "synthetic nonempty test payload"
        for finished in [false, NSNull(), "true", 1] as [Any] {
          try write(["recording_finished": finished], payload)
          try rejected("unfinished recording \(finished)", "did not report success")
        }
        try write(["recording_finished": true, "recording_error": "delegate failure"], payload)
        try rejected("delegate failure with finish callback", "reported an error")
        try write(["recording_finished": true, "recording_validation_error": "no video track"], payload)
        try rejected("validation failure with finish callback", "reported an error")
        try write(["recording_finished": true], nil)
        try rejected("missing MP4", "no nonempty MP4")
        try write(["recording_finished": true], "")
        try rejected("empty MP4", "no nonempty MP4")
        try write(["recording_finished": true], payload)
        let evidence = try recordingEvidence(directory)
        try expect(evidence["finalized_nonempty_video"] as? Bool == true && evidence["video_bytes"] as? Int == payload.utf8.count,
                   "a finalized nonempty recording is accepted: \(evidence)")
        try expect((evidence["summary"] as? [String: Any])?["recording_finished"] as? Bool == true, "the summary is kept")
      }
    },
  ]

  static let verdictTests = [
    SelfTest.Case(name: "rendering-proof plan: a missing option is named as it is written") {
      for missing in Plan.valueOptions.sorted() {
        let given = Plan.valueOptions.sorted().filter { $0 != missing }.flatMap { [$0, "value"] }
        let options = try Options(given, flags: [], values: Plan.valueOptions, command: command)
        let message = try expectFailure("a run without \(missing)") { _ = try Plan(options) }.message
        try expect(message == "Missing \(missing)", "got: \(message)")
      }
    },
    SelfTest.Case(name: "rendering-proof verdict: phases need changed geometry and frames, then the final or the negative gate") {
      let phases = ["native_outer_divider", "native_inner_divider", "native_window_resize"]
      let generation = RenderingProofFixture.finalGeneration(rows: 30, columns: 100)
      var records = Records(samples: [], inputEvents: [], paneEvents: [])
      for (index, phase) in phases.enumerated() {
        let start = Double(10 * index + 10)
        records.inputEvents += [["phase": phase, "host_time": start],
                                ["phase": phase, "host_time": start + 2, "gesture_complete": true]]
        records.paneEvents += [["pane": index, "generation": 2 * index + 1, "final": false, "rows": 24, "columns": 80, "host_time": start + 0.5],
                               ["pane": index, "generation": 2 * index + 2, "final": false, "rows": 24, "columns": 70, "host_time": start + 1]]
        records.samples.append(["host_time": start + 1.5, "status": 0, "classification": "correct"])
      }
      records.inputEvents.append(["phase": "final_static_output", "host_time": 50.0])
      records.paneEvents += panes.map {
        ["pane": $0, "generation": generation, "final": true, "rows": 30, "columns": 100, "host_time": 50.5]
      }
      func frame(_ time: Double, _ classification: String, _ pane: [String: Any]) -> [String: Any] {
        ["host_time": time, "status": 0, "classification": classification,
         "panes": panes.map { pane.merging(["pane": $0]) { _, new in new } }]
      }
      let shown: [String: Any] = ["result": "correct", "visible_final_flag": true, "validated_visible_generation": generation,
                                  "visible_rows": 30, "visible_columns": 100]
      let widened: [String: Any] = ["result": "failure", "reason": "absolute_dimensions", "delta_wh": [84.5, -0.5]]
      let identity: [String: Any] = ["cell_width_pixels": 14]
      func verdict(_ records: Records, negative: Bool = false) throws -> Verdict {
        try judge(records, identity: identity, negative: negative)
      }

      var production = records
      production.samples.append(frame(51, "correct", shown))
      let passed = try verdict(production)
      try expect(passed.passed == true && passed.report["passed"] as? Bool == true, "a complete production run passes")
      try expect(passed.report["final_visible_generation_gate"] as? Bool == true, "the final gate is recorded")
      try expect(passed.report["classifications"] as? [String: Int] == ["correct": 4], "frames are counted by classification")
      let phase = (passed.report["native_phases"] as? [String: Any])?["native_inner_divider"] as? [String: Any]
      try expect(phase?["geometry_states"] as? Int == 2 && phase?["complete_capture_callbacks"] as? Int == 1
                   && phase?["geometry_changed_within_pane"] as? Bool == true, "a phase records what it changed: \(phase ?? [:])")
      try expect((passed.report["expected_final_panes"] as? [String: Any])?.keys.sorted() == ["0", "1", "2"],
                 "the expected final panes are recorded by number")
      try expect((passed.report["negative_control_expected_delta_wh"] as? [Any])?.first as? Int == 84,
                 "the expected control error is six cells")
      try expect(try verdict(production, negative: true).passed == false, "a production run is not a detected control")

      var early = records
      early.samples.append(frame(49, "correct", shown))
      try expect(try verdict(early).passed == false, "a frame from before the final output does not count")
      var stale = records
      stale.samples.append(frame(51, "correct", shown.merging(["visible_columns": 99]) { _, new in new }))
      try expect(try verdict(stale).passed == false, "a frame showing other geometry does not count")
      var failed = production
      failed.samples.append(["host_time": 52.0, "status": 0, "classification": "failure"])
      try expect(try verdict(failed).passed == false, "a failed frame fails a production run")
      var broken = production
      broken.samples.append(["host_time": 52.0, "stream_error": "stopped"])
      let stopped = try verdict(broken)
      try expect(stopped.passed == false && (stopped.report["capture_errors"] as? [[String: Any]])?.count == 1
                   && (stopped.report["classifications"] as? [String: Int])?["capture_error"] == 1, "a capture error fails the run")
      var still = production
      still.paneEvents[3]["columns"] = 80
      try expect(try verdict(still).passed == false, "a drag that changed no geometry fails the run")
      var unannounced = production
      unannounced.inputEvents.removeLast()
      let open = try verdict(unannounced)
      try expect(open.passed == false && open.report["passed"] as? Bool == false
                   && open.report["final_visible_generation_gate"] as? Bool == false,
                 "a run without a final announcement records false for the final gate and for the run")

      var control = records
      control.samples.append(frame(30, "failure", widened))
      try expect(try verdict(control, negative: true).passed == true, "a control with all three rectangles six cells wider passes")
      try expect(try verdict(control).passed == false, "the same frames fail a production run")
      var partial = records
      partial.samples.append(["host_time": 30.0, "status": 0, "classification": "failure",
                              "panes": [widened.merging(["pane": 0]) { _, new in new }]])
      try expect(try verdict(partial, negative: true).passed == false, "a control seen in one pane only fails")
      var unrelated = records
      unrelated.samples.append(frame(30, "failure", widened.merging(["delta_wh": [0, 28]]) { _, new in new }))
      try expect(try verdict(unrelated, negative: true).passed == false, "an unrelated dimension error does not pass the control")
    },
  ]
}

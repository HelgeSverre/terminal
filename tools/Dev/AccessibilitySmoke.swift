import Foundation

/// Reads a styled pane through the accessibility API from another process.
///
/// The runner owns the whole disposable process tree. It copies and ad-hoc
/// signs the built bundle before launch, so that a build in progress cannot
/// replace the executable being proved. The shell command is fixed and
/// non-login: it reads neither the user's startup files nor their history.
/// `tools/AccessibilityProbe.swift` does the reading and writes the verdict.
enum AccessibilitySmoke {
  static let command = Command(
    name: "accessibility-smoke", usage: "[APP_BUNDLE]",
    summary: "Read a styled pane of a private copy of the app through the accessibility API.",
    run: run)

  static let paneIdentifierPrefix = "no.helgesverre.terminal.pane."
  static let probeSource = Repository.path("tools/AccessibilityProbe.swift")

  static func run(_ arguments: [String]) throws {
    guard arguments.count <= 1 else { throw Failure.usage(command) }
    let bundle = absolutePath(arguments.first ?? "dist/Terminal.app", relativeTo: Repository.root)
    let executable = bundle + "/Contents/MacOS/Terminal"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw Failure("missing executable: \(executable)")
    }
    let directory = ProcessInfo.processInfo.environment["TERMINAL_ACCESSIBILITY_REPORT_DIRECTORY"]
      ?? Repository.path("reports/accessibility-attributed")
    try run(bundle: bundle, reportDirectory: directory, buildProbe: buildProbe)
    print("PASS external accessibility attributed-text fixture, read-only AXValue, styles, link, and cleanup")
  }

  /// Runs the fixture and the probe, writes `provenance.json` beside the
  /// probe's `external-ax.json`, and fails unless the probe passed.
  /// `buildProbe` puts the probe executable at the path it is given.
  static func run(bundle: String, reportDirectory: String, buildProbe: (String) throws -> Void) throws {
    let reportPath = reportDirectory + "/external-ax.json"
    var provenance: [String: Any] = [
      "runner": (#filePath as NSString).lastPathComponent,
      "source_bundle": bundle,
      "source_file_sha256": try sha256(ofFile: probeSource),
      "permission_prompt_requested": false,
    ]
    try FileManager.default.createDirectory(atPath: reportDirectory, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: reportPath)
    try withTemporaryDirectory("terminal-accessibility-attributed-") { temporary in
      let probe = temporary + "/AccessibilityProbe"
      try buildProbe(probe)
      let (fixture, identifier) = try privateCopy(of: bundle, in: temporary)
      let executable = fixture + "/Contents/MacOS/Terminal"
      let childFile = temporary + "/controlled-child.pid"
      let launch = [executable, "--columns", "80", "--rows", "24", "--font-size", "14",
                    "--working-directory", "/tmp", "--execute", "/bin/sh", "-c", fixtureCommand(childFile: childFile)]
      provenance.merge([
        "private_fixture_bundle": fixture,
        "fixture_bundle_id": identifier,
        "source_executable_sha256": try sha256(ofFile: bundle + "/Contents/MacOS/Terminal"),
        "fixture_executable_sha256": try sha256(ofFile: executable),
        "probe_binary_sha256": try sha256(ofFile: probe),
        "command": launch,
        "controlled_child_pid_file": (childFile as NSString).lastPathComponent,
      ]) { $1 }
      let app = try ProcessTree(launch, output: .discarded)
      provenance["owned_app_pid"] = Int(app.pid)
      var failure: Failure?
      do {
        try waitForProbe(probe, app: app, report: reportPath)
        recordChild(childFile, in: &provenance)
      } catch {
        failure = Failure(wrapping: error)
        provenance["runner_error"] = failure?.message
      }
      try cleanup(app, recordingIn: &provenance)
      try writeJSON(provenance, to: reportDirectory + "/provenance.json")
      if let failure { throw failure }
    }
    let result = try readJSONObject(reportPath)
    guard truthy(result["passed"]) else {
      let detail = [result["error"], result["assertions"]].first(where: truthy) ?? nil
      throw Failure("accessibility probe failed: \(detail ?? "no detail")")
    }
  }

  static func buildProbe(_ path: String) throws {
    guard try runHelper("/usr/bin/xcrun", "swiftc", "-framework", "AppKit", "-framework", "ApplicationServices",
                        probeSource, "-o", path) else { throw Failure("accessibility probe build failed") }
  }

  /// Copies the bundle, gives the copy a bundle identifier of its own, and
  /// signs it ad hoc. Returns the copy and its identifier.
  private static func privateCopy(of bundle: String, in directory: String) throws -> (String, String) {
    let fixture = directory + "/Terminal.app"
    try FileManager.default.copyItem(atPath: bundle, toPath: fixture)
    let suffix = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    let identifier = "no.helgesverre.terminal.accessibility-fixture." + suffix
    guard try runHelper("/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier \(identifier)",
                        fixture + "/Contents/Info.plist") else { throw Failure("cannot set the fixture's bundle identifier") }
    guard try runHelper("/usr/bin/codesign", "--force", "--sign", "-", fixture) else {
      throw Failure("cannot sign the fixture bundle")
    }
    return (fixture, identifier)
  }

  /// What the pane's shell runs. SGR makes bold, underline, foreground and
  /// background runs; OSC 8 makes an AXLink. é and 🐈 make the first styled
  /// run exactly five UTF-16 units. The shell then records its PID and
  /// becomes a sleep, so the PTY child is a known process.
  static func fixtureCommand(childFile: String) -> String {
    #"printf '\033[31;44;1;4mAXé🐈\033[0m \033]8;;https://example.test/ax\033\\link\033]8;;\033\\\n'; "#
      + #"printf '%s\n' "$$" > "# + shellEscaped(childFile) + "; exec /bin/sleep 30"
  }

  /// `text` as one shell word, every character outside a safe set escaped with a backslash.
  static func shellEscaped(_ text: String) -> String {
    guard !text.isEmpty else { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.,:+/@")
    return text.unicodeScalars.map { scalar in
      if scalar == "\n" { return "'\n'" }
      return safe.contains(scalar) ? String(scalar) : "\\" + String(scalar)
    }.joined()
  }

  /// Runs the probe against the app until its report settles the question,
  /// for up to twelve seconds: the app needs time to show its pane.
  private static func waitForProbe(_ probe: String, app: ProcessTree, report: String) throws {
    let deadline = Clock.now + 12_000_000_000
    while true {
      try query(probe, pid: app.pid, report: report)
      let result = try FileManager.default.fileExists(atPath: report) ? readJSONObject(report) : [:]
      if truthy(result["passed"]) { return }
      // Without the accessibility permission no retry can succeed.
      if (result["error"] as? String)?.contains("AXIsProcessTrustedWithOptions") == true { return }
      // A report with a pane means the accessibility server has answered. Its
      // evidence is kept; a real style or link failure is not retried away.
      if truthy(result["pane"]) { return }
      if app.wait(seconds: 0) != nil { throw Failure("accessibility fixture exited before its pane became readable") }
      if Clock.now >= deadline {
        throw Failure("accessibility pane was not readable: \(result["error"] as? String ?? "")")
      }
      usleep(200_000)
    }
  }

  /// One run of the probe, limited to six seconds.
  private static func query(_ probe: String, pid: pid_t, report: String) throws {
    let tree = try ProcessTree([probe, "--pid", String(pid), "--identifier", paneIdentifierPrefix, "--report", report])
    let finished = tree.wait(seconds: 6) != nil
    let survivors = tree.cleanup()
    guard survivors.isEmpty else {
      throw Failure("accessibility probe survivors: \(survivors.map(String.init).joined(separator: ", "))")
    }
    guard finished else { throw Failure("external accessibility query timed out") }
  }

  private static func recordChild(_ file: String, in provenance: inout [String: Any]) {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
    if let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
      provenance["controlled_child_pid"] = pid
    } else {
      provenance["controlled_child_pid_error"] = "fixture wrote a non-integer child PID"
    }
  }

  /// Ends the fixture and records what it owned before and after.
  private static func cleanup(_ app: ProcessTree, recordingIn provenance: inout [String: Any]) throws {
    // One more look at the tree, so that the PTY child is among the owned processes recorded.
    app.wait(seconds: 0)
    provenance["owned_pids_before_cleanup"] = app.livePIDs.map { Int($0) }
    let survivors = app.cleanup()
    provenance["owned_pids_after_cleanup"] = app.livePIDs.map { Int($0) }
    provenance["cleanup_survivors"] = survivors.map { Int($0) }
    provenance["app_exit_status"] = describe(app.exit)
    if let child = provenance["controlled_child_pid"] as? Int {
      provenance["controlled_child_exited"] = try !processExists(child)
    }
    guard survivors.isEmpty else {
      throw Failure("accessibility fixture survivors: \(survivors.map(String.init).joined(separator: ", "))")
    }
  }

  private static func describe(_ exit: ProcessTree.Exit?) -> [String: Any] {
    guard let exit else { return ["observed": false] }
    return [
      "observed": true,
      "exited": !exit.signalled,
      "exit_status": exit.signalled ? NSNull() : Int(exit.code) as Any,
      "signaled": exit.signalled,
      "signal": exit.signalled ? Int(exit.code) as Any : NSNull(),
    ]
  }

  static let tests = [
    SelfTest.Case(name: "accessibility smoke: a passing probe passes and the fixture's tree is ended and recorded") {
      try withFakeApp { bundle, directory in
        // The probe answers after the fixture has had time to record its PID.
        try run(bundle: bundle, reportDirectory: directory + "/reports") { probe in
          try writeScript(#"sleep 0.4; printf '{"passed": true}' > "$6""#, to: probe)
        }
        let provenance = try readJSONObject(directory + "/reports/provenance.json")
        let status = provenance["app_exit_status"] as? [String: Any]
        try expect(provenance["runner"] as? String == "AccessibilitySmoke.swift", "runner named")
        try expect((provenance["fixture_bundle_id"] as? String)?.count == "no.helgesverre.terminal.accessibility-fixture.".count + 12,
                   "got: \(provenance["fixture_bundle_id"] ?? "nothing")")
        try expect(provenance["controlled_child_pid"] as? Int != nil, "child PID recorded")
        try expect(provenance["controlled_child_exited"] as? Bool == true, "child ended")
        try expect(provenance["cleanup_survivors"] as? [Int] == [], "no survivors")
        try expect((provenance["owned_pids_before_cleanup"] as? [Int])?.isEmpty == false, "owned processes recorded")
        try expect(status?["signaled"] as? Bool == true && status?["signal"] as? Int == 15, "got: \(status ?? [:])")
        try expect(provenance["runner_error"] == nil, "no runner error")
      }
    },
    SelfTest.Case(name: "accessibility smoke: a probe that saw the pane and failed is not retried") {
      try withFakeApp { bundle, directory in
        let failure = try expectFailure("a failed probe") {
          try run(bundle: bundle, reportDirectory: directory + "/reports") { probe in
            try writeScript(#"echo run >> "$6.runs"; printf '{"passed": false, "pane": {}, "error": "no link"}' > "$6""#,
                            to: probe)
          }
        }
        try expect(failure.message == "accessibility probe failed: no link", "got: \(failure.message)")
        let runs = try String(contentsOfFile: directory + "/reports/external-ax.json.runs", encoding: .utf8)
        try expect(runs == "run\n", "the probe ran once")
      }
    },
    SelfTest.Case(name: "accessibility smoke: the child PID file is one shell word") {
      try expect(shellEscaped("/var/T/a-b_c.pid") == "/var/T/a-b_c.pid", "safe characters are kept")
      try expect(shellEscaped("/tmp/it's here") == #"/tmp/it\'s\ here"#, "others are escaped")
      try expect(shellEscaped("") == "''", "an empty word is quoted")
    },
  ]

  /// Runs `body` with a signable stand-in bundle whose executable runs the
  /// fixture command, as the app's pane would.
  private static func withFakeApp(_ body: (String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-accessibility-smoke-") { directory in
      let bundle = try fakeBundle(in: directory, script: #"for last; do :; done; exec /bin/sh -c "$last""#)
      let information = ["CFBundleIdentifier": "test.fixture", "CFBundleExecutable": "Terminal", "CFBundlePackageType": "APPL"]
      try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
        .write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
      try body(bundle, directory)
    }
  }
}

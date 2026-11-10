import Foundation

/// Checks that closing the last window, and Command-Q, end the app and the
/// child on its PTY.
///
/// The bundle executable is launched directly so that shutdown is waitable for
/// development and hardened release builds alike. Cleanup owns only the
/// launched process tree.
enum CloseSmoke {
  static let command = Command(
    name: "close-smoke", usage: "[APP_BUNDLE]",
    summary: "Close the last window, then quit with Command-Q, and require the app and its PTY child to end.",
    run: run)

  struct Mode {
    let name: String
    let trigger: String
    var flags: [String] = []
  }

  static let modes = [
    Mode(name: "window", trigger: "last-window-close"),
    Mode(name: "shortcut", trigger: "cmd+q", flags: ["--quit-shortcut"]),
  ]

  /// The PTY child ignores hang-up, so it ends only if the app ends it.
  static let child = "trap '' HUP; printf CLOSE_SMOKE_READY; exec /bin/sleep 30"

  static func run(_ arguments: [String]) throws {
    guard arguments.count <= 1 else { throw Failure.usage(command) }
    let bundle = absolutePath(arguments.first ?? "dist/Terminal.app", relativeTo: Repository.root)
    for mode in modes {
      try run(mode, bundle: bundle, reportDirectory: Repository.path("reports"))
      print("PASS \(mode.name): application exited and PTY descendants reaped")
    }
  }

  /// Runs one mode and rewrites the app's report with the runner's verdict.
  static func run(_ mode: Mode, bundle: String, reportDirectory: String) throws {
    let app = bundle + "/Contents/MacOS/Terminal"
    guard FileManager.default.isExecutableFile(atPath: app) else { throw Failure("missing executable: \(app)") }
    let path = "\(reportDirectory)/close-\(mode.name)-smoke.json"
    try? FileManager.default.removeItem(atPath: path)
    let process = try ProcessTree(
      [app, "--close-smoke", path] + mode.flags + ["--execute", "/bin/sh", "-c", child], output: .discarded)
    var report: [String: Any] = [:]
    var failure: Failure?
    do {
      try judge(mode, process, path, &report)
      report.merge(["passed": true, "app_exited": true, "child_exited": true, "bundle_path": bundle]) { $1 }
    } catch {
      // The app's own report must not read as a pass after the runner rejected it.
      let caught = Failure(wrapping: error)
      report.merge(["passed": false, "runner_error": caught.message]) { $1 }
      failure = caught
    }
    let survivors = process.cleanup()
    if !survivors.isEmpty {
      let caught = Failure("\(mode.name): processes survived cleanup: \(survivors.map(String.init).joined(separator: ", "))")
      report.merge(["passed": false, "cleanup_error": caught.message]) { $1 }
      failure = caught
    }
    try writeJSON(report, to: path)
    if let failure { throw failure }
  }

  /// Requires a clean exit, the expected trigger, and nothing left running.
  /// `report` holds the app's report from the moment it has been read.
  private static func judge(_ mode: Mode, _ process: ProcessTree, _ path: String,
                            _ report: inout [String: Any]) throws {
    guard process.wait(seconds: 10)?.succeeded == true else {
      throw Failure("\(mode.name): app did not exit successfully")
    }
    report = try readJSONObject(path)
    guard report["trigger"] as? String == mode.trigger else {
      throw Failure("\(mode.name): incorrect shutdown trigger")
    }
    guard let child = report["child_pid"] as? Int, child > 0 else { throw Failure("\(mode.name): invalid child PID") }
    // The app must reap this child itself, before cleanup runs.
    guard try !processExists(child) else { throw Failure("\(mode.name): PTY child survived app shutdown") }
    guard process.livePIDs.isEmpty else { throw Failure("\(mode.name): descendants survived app shutdown") }
  }

  static let tests = [
    SelfTest.Case(name: "close smoke: a successful app exit does not hide a surviving child") {
      let sentinel = try ProcessTree(["/bin/sleep", "30"])
      defer { sentinel.cleanup() }
      // The app outlives the first look at its tree, so the child is known to be its own.
      let script = """
        sleep 30 &
        printf '{"passed": true, "trigger": "last-window-close", "child_pid": %d}' $! > "$2"
        sleep 0.4
        """
      try withFakeApp(script) { bundle, reports in
        let failure = try expectFailure("a surviving child") { try run(modes[0], bundle: bundle, reportDirectory: reports) }
        try expect(failure.message.contains("PTY child survived"), "got: \(failure.message)")
        let report = try readJSONObject(reports + "/close-window-smoke.json")
        try expect(report["passed"] as? Bool == false, "report failed")
        try expect(try !processExists(report["child_pid"] as? Int ?? 0), "cleanup ended the child")
        try expect(kill(sentinel.pid, 0) == 0, "a bystander still runs")
      }
    },
    SelfTest.Case(name: "close smoke: a report for the wrong trigger cannot pass") {
      try withFakeApp(#"printf '{"passed": true, "trigger": "cmd+q", "child_pid": 1}' > "$2""#) { bundle, reports in
        let failure = try expectFailure("a wrong trigger") { try run(modes[0], bundle: bundle, reportDirectory: reports) }
        try expect(failure.message.contains("incorrect shutdown trigger"), "got: \(failure.message)")
        let report = try readJSONObject(reports + "/close-window-smoke.json")
        try expect(report["passed"] as? Bool == false, "report failed")
      }
    },
    SelfTest.Case(name: "close smoke: native reports gain a pass only after both shutdown checks") {
      let script = """
        /usr/bin/true & child=$!
        wait $child
        trigger=last-window-close
        case " $* " in *" --quit-shortcut "*) trigger=cmd+q ;; esac
        printf '{"trigger": "%s", "child_pid": %d}' $trigger $child > "$2"
        """
      try withFakeApp(script) { bundle, reports in
        for mode in modes {
          try run(mode, bundle: bundle, reportDirectory: reports)
          let report = try readJSONObject("\(reports)/close-\(mode.name)-smoke.json")
          for key in ["passed", "app_exited", "child_exited"] {
            try expect(report[key] as? Bool == true, "\(mode.name): \(key)")
          }
          try expect(report["bundle_path"] as? String == bundle, "\(mode.name): bundle path")
        }
      }
    },
  ]

  /// Runs `body` with a stand-in bundle and an empty report directory.
  private static func withFakeApp(_ script: String, _ body: (String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-close-smoke-") { directory in
      let reports = directory + "/reports"
      try FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
      try body(try fakeBundle(in: directory, script: script), reports)
    }
  }
}

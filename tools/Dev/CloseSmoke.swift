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
    let exit = process.wait(seconds: 10)
    // What the app wrote is kept also when it did not exit cleanly.
    let written = Result { try readJSONObject(path) }
    if case .success(let object) = written { report = object }
    guard exit?.succeeded == true else { throw Failure("\(mode.name): app did not exit successfully") }
    _ = try written.get()
    guard report["trigger"] as? String == mode.trigger else {
      throw Failure("\(mode.name): incorrect shutdown trigger")
    }
    guard let child = report["child_pid"] as? Int, child > 0 else { throw Failure("\(mode.name): invalid child PID") }
    // The app must reap this child itself, before cleanup runs.
    guard try !processExists(child) else { throw Failure("\(mode.name): PTY child survived app shutdown") }
    guard process.livePIDs.isEmpty else { throw Failure("\(mode.name): descendants survived app shutdown") }
  }
}

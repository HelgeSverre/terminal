import Foundation

/// Runs the app's selection smoke and judges its report.
///
/// One owned app is launched with a fixed raw-PTY child. The child reads no
/// shell startup files and keeps no terminal or clipboard contents.
enum SelectionSmoke {
  static let command = Command(
    name: "selection-smoke", usage: "[APP_BUNDLE]",
    summary: "Drive mouse selection gestures and private-pasteboard copy in the app, and judge its report.",
    run: run)

  static let checks = [
    "fixture_ready", "wide_drag", "ordinary_forward_copy", "ordinary_reverse_copy", "word_double_click",
    "private_copy", "output_preserves_selection", "reflow_retains_selection", "line_triple_click",
    "rectangular_option_drag", "rectangular_ax_multirange_has_no_union_holes",
    "plain_click_publishes_caret_without_selection", "application_mouse_does_not_select",
    "original_pane_close_cancels_pending", "private_board_unchanged_after_close", "completed_without_timeout",
  ]
  static let expectedText = ["WORD_TOKEN", "猫", "SEL_WIDE_猫_TOKEN", "LINE_TOKEN", "abcde", "ABCDE", "CLICK_TAIL", "CLOSE_TOKEN"]

  /// The child's script. Each `dd` waits for an exact raw control message from
  /// the app's smoke, so everything on screen is printed by this child and
  /// none of it is user content.
  static let fixture = [
    "stty raw -echo",
    "dd bs=1 count=1 of=/dev/null 2>/dev/null",
    #"printf 'SELECTION_FIXTURE_READY SEL_WIDE_猫_TOKEN\r\n'"#,
    "dd bs=1 count=5 of=/dev/null 2>/dev/null",
    #"printf 'WORD_TOKEN\r\n'"#,
    "dd bs=1 count=7 of=/dev/null 2>/dev/null",
    #"printf 'SELECTION_OUTPUT_AFTER_GESTURE\r\n'"#,
    "dd bs=1 count=5 of=/dev/null 2>/dev/null",
    #"printf 'LINE_TOKEN\r\n'"#,
    "dd bs=1 count=5 of=/dev/null 2>/dev/null",
    #"printf 'abcde\r\nABCDE\r\n'"#,
    "dd bs=1 count=5 of=/dev/null 2>/dev/null",
    #"printf 'CLICK_TAIL\r\n'"#,
    "dd bs=1 count=6 of=/dev/null 2>/dev/null",
    #"printf '\033[?1000hMOUSE_MODE_READY\r\n'"#,
    "dd bs=1 count=6 of=/dev/null 2>/dev/null",
    #"printf 'MOUSE_ROUTE_ACK\r\nCLOSE_TOKEN\r\n\033[?1000lMOUSE_DISABLED\r\n'"#,
    "exec /bin/sleep 30",
  ].joined(separator: "; ")

  static func run(_ arguments: [String]) throws {
    guard arguments.count <= 1 else { throw Failure.usage(command) }
    let bundle = absolutePath(arguments.first ?? "dist/Terminal.app", relativeTo: Repository.root)
    let directory = ProcessInfo.processInfo.environment["TERMINAL_SELECTION_SMOKE_REPORT_DIRECTORY"]
      ?? Repository.path("reports")
    try run(bundle: bundle, reportDirectory: directory)
    print("PASS selection smoke: owned AppKit gestures, private copy, reflow, mouse routing and close cleanup")
  }

  /// Runs the smoke and rewrites the app's report with the runner's verdict.
  static func run(bundle: String, reportDirectory: String) throws {
    let app = bundle + "/Contents/MacOS/Terminal"
    guard FileManager.default.isExecutableFile(atPath: app) else { throw Failure("missing executable: \(app)") }
    let path = reportDirectory + "/selection-smoke.json"
    try FileManager.default.createDirectory(atPath: reportDirectory, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: path)
    let process = try ProcessTree([
      app, "--selection-smoke", path, "--columns", "48", "--rows", "14", "--font-size", "14",
      "--working-directory", "/tmp", "--execute", "/bin/sh", "-c", fixture,
    ], output: .discarded)
    var report: [String: Any] = [:]
    var failure: Failure?
    do {
      try judge(process, path, &report)
      report["runner"] = ["app_exited": true, "cleanup_survivors": [Int]()]
    } catch {
      // A failed run keeps what the app reported, marked as failed.
      let caught = Failure(wrapping: error)
      report["passed"] = false
      report["runner_error"] = caught.message
      failure = caught
    }
    let survivors = process.cleanup()
    var runner = report["runner"] as? [String: Any] ?? [:]
    runner["cleanup_survivors"] = survivors.map { Int($0) }
    report["runner"] = runner
    if !survivors.isEmpty {
      let caught = Failure("selection smoke cleanup survivors: \(survivors.map(String.init).joined(separator: ", "))")
      report["passed"] = false
      report["cleanup_error"] = caught.message
      failure = caught
    }
    try writeJSON(report, to: path)
    if let failure { throw failure }
  }

  /// Requires a clean exit with no children and a report in which every known
  /// check passed. `report` holds the app's report from the moment it has been read.
  private static func judge(_ process: ProcessTree, _ path: String, _ report: inout [String: Any]) throws {
    guard let exit = process.wait(seconds: 45) else { throw Failure("selection smoke timed out") }
    guard exit.succeeded else {
      throw Failure("selection smoke exited with \(exit.signalled ? "signal" : "status") \(exit.code)")
    }
    let children = process.livePIDs
    guard children.isEmpty else {
      throw Failure("selection smoke left children: \(children.map(String.init).joined(separator: ", "))")
    }
    report = try readJSONObject(path)
    guard let reported = report["checks"] as? [String: Any] else { throw Failure("selection report has no checks") }
    let missing = checks.filter { !ReportValue.isTruthy(reported[$0]) }
    guard missing.isEmpty else { throw Failure("selection checks failed: \(missing.joined(separator: ", "))") }
    // The app's own count guards against this list and the app's drifting apart.
    let counts = report["counts"] as? [String: Any]
    guard counts?["required_checks"] as? Int == checks.count, counts?["passed_checks"] as? Int == checks.count else {
      throw Failure("selection smoke reported inconsistent check counts")
    }
    guard report["expected_known_text"] as? [String] == expectedText else {
      throw Failure("selection smoke omitted its fixed expected text")
    }
    guard ReportValue.isTruthy(report["passed"]) else { throw Failure("selection smoke did not mark report passed") }
  }
}

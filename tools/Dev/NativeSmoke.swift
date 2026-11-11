import Foundation

/// Runs one of the app's built-in smoke modes and judges its report.
///
/// The app tests itself and writes a JSON report; this command launches it,
/// enforces the time limit, requires a clean exit with no children left, and
/// fails unless the report says it passed.
enum NativeSmoke {
  static let command = Command(
    name: "native-smoke", usage: "MODE",
    summary: "Run an app smoke mode: " + modes.map(\.name).joined(separator: ", ") + ".",
    run: run)

  struct Mode {
    let name: String
    let report: String
    let flag: String
    let seconds: Double
    var extra: [String] = []
    /// The app's own output is dropped, and the report printed on success.
    var printsReport = false
  }

  private static let glyphGrid = ["--columns", "100", "--rows", "36", "--font-size", "14"]
  static let modes = [
    Mode(name: "normal", report: "native-smoke", flag: "--self-test", seconds: 20),
    Mode(name: "editing", report: "editing-smoke", flag: "--editing-smoke", seconds: 20),
    Mode(name: "pane-lifecycle", report: "pane-lifecycle-smoke", flag: "--pane-lifecycle-smoke", seconds: 20),
    Mode(name: "glyph", report: "glyph-smoke", flag: "--glyph-smoke", seconds: 55, extra: glyphGrid),
    Mode(name: "atlas", report: "atlas-smoke", flag: "--glyph-smoke", seconds: 30,
         extra: ["--atlas-pressure-smoke"] + glyphGrid),
    Mode(name: "atlas-budget", report: "atlas-budget-smoke", flag: "--glyph-smoke", seconds: 30,
         extra: ["--atlas-pressure-smoke", "--atlas-fallback-budget-smoke"] + glyphGrid),
    Mode(name: "idle", report: "native-idle", flag: "--self-test", seconds: 90, extra: ["--idle-test"]),
    Mode(name: "resize", report: "resize-smoke", flag: "--resize-smoke", seconds: 90, printsReport: true),
    Mode(name: "intense-resize", report: "intense-resize-smoke", flag: "--intense-resize-smoke", seconds: 75,
         printsReport: true),
  ]

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 1 else { throw Failure.usage(command) }
    guard let mode = modes.first(where: { $0.name == arguments[0] }) else {
      throw Failure("unknown smoke mode: \(arguments[0])")
    }
    let environment = ProcessInfo.processInfo.environment
    let directory = environment["TERMINAL_NATIVE_SMOKE_REPORT_DIRECTORY"] ?? Repository.path("reports")
    let executable = environment["TERMINAL_NATIVE_SMOKE_EXECUTABLE"]
      ?? Repository.path("dist/Terminal.app/Contents/MacOS/Terminal")
    try run(mode, executable: executable, reportDirectory: directory)
    print("PASS \(mode.name) smoke and app termination")
  }

  static func run(_ mode: Mode, executable: String, reportDirectory: String) throws {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw Failure("missing app executable: \(executable)")
    }
    let report = reportDirectory + "/" + mode.report + ".json"
    try FileManager.default.createDirectory(atPath: reportDirectory, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: report)

    // Behind whatever is on screen and without taking the keyboard: the
    // smokes drive their own window and do not need the app to be active.
    let app = try ProcessTree([executable, "--background", mode.flag, report] + mode.extra,
                              output: mode.printsReport ? .discarded : .inherited)
    var failure: Failure?
    do {
      guard let exit = app.wait(seconds: mode.seconds) else { throw Failure("\(mode.name) smoke timed out") }
      guard exit.succeeded else {
        throw Failure("\(mode.name) smoke exited with \(exit.signalled ? "signal" : "status") \(exit.code)")
      }
      let children = app.livePIDs
      guard children.isEmpty else {
        throw Failure("smoke app exited leaving children: \(children.map(String.init).joined(separator: ", "))")
      }
      let result = try readJSONObject(report)
      guard result["passed"] as? Bool == true else {
        throw Failure("native smoke failed: \(describe(result["checks"] ?? result["failures"] ?? "no detail"))")
      }
      if mode.printsReport { print(try JSONValue(sortingKeysOf: result).pretty) }
    } catch let caught as Failure {
      failure = caught
    }
    // Whatever happened, nothing this run launched may outlive it.
    let survivors = app.cleanup()
    if !survivors.isEmpty {
      throw Failure("smoke processes survived cleanup: \(survivors.map(String.init).joined(separator: ", "))")
    }
    if let failure { throw failure }
  }

  /// The checks that did not pass, or the whole value when it is not a table of checks.
  private static func describe(_ value: Any) -> String {
    if let checks = value as? [String: Bool] {
      let failed = checks.filter { !$0.value }.keys.sorted()
      return "\(failed.count) of \(checks.count) checks failed: " + failed.joined(separator: ", ")
    }
    return String(describing: value)
  }
}

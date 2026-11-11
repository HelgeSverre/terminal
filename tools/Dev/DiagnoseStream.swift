import Foundation

/// Runs the short-ASCII workload in an app built with session counters and
/// relates the counters to the amount of source text.
///
/// This is a diagnosis of where PTY output goes, not a performance
/// acceptance run. With `BENCH_BACKGROUND=1` the app is started with
/// `--background`, so it does not take focus.
enum DiagnoseStream {
  static let command = Command(
    name: "diagnose-stream", usage: "APP NEW_OUTPUT_DIRECTORY BYTES_PER_RUN",
    summary: "Run ten short-ASCII passes in APP and report its session counters per MiB (BENCH_BACKGROUND=1).",
    run: run)

  static let runs = 10

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 3 else { throw Failure.usage(command) }
    guard let bytes = Int(arguments[2]) else { throw Failure("invalid value for BYTES_PER_RUN: \(arguments[2])") }
    try diagnose(app: arguments[0], output: arguments[1], bytes: bytes,
                 background: ProcessInfo.processInfo.environment["BENCH_BACKGROUND"] == "1")
    print("PASS session stream diagnostic; app and children exited cleanly")
  }

  /// Runs the diagnosis and writes diagnostic.json, which records the
  /// failure and the cleanup when the run fails.
  static func diagnose(app: String, output: String, bytes: Int, background: Bool) throws {
    let app = try realPath(app)
    let output = absolutePath(output)
    guard (1...1_073_741_824).contains(bytes) else { throw Failure("Bytes must be between 1 and 1 GiB") }
    guard !FileManager.default.fileExists(atPath: output) else { throw Failure("Choose a new output directory") }
    let executable = app + "/Contents/MacOS/Terminal"
    guard FileManager.default.isExecutableFile(atPath: executable) else { throw Failure("Missing app executable") }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    var result: [String: Any] = [
      "passed": false, "scope": "Instrumented short-ASCII diagnosis; not performance acceptance.",
      "app": app, "executable_sha256": try sha256(ofFile: executable),
      "driver_source_sha256": try sha256(ofFile: BenchDriver.source),
      "runner_sha256": try sha256(ofFile: #filePath),
      "requested_bytes_per_run": bytes, "runs": runs,
    ]
    var process: ProcessTree?
    var failure: Failure?
    do {
      try measure(executable: executable, output: output, bytes: bytes, background: background,
                  process: &process, result: &result)
    } catch {
      failure = Failure(wrapping: error)
      result["failure"] = failure?.message
    }
    if let process {
      let survivors = process.cleanup().map { Int($0) }
      result["cleanup_survivors"] = survivors
      if !survivors.isEmpty { result["passed"] = false }
    }
    try JSONValue(sortingKeysOf: result).write(to: output + "/diagnostic.json")
    if let failure { throw failure }
    guard result["passed"] as? Bool == true else { throw Failure("Owned process cleanup failed") }
  }

  private static func measure(executable: String, output: String, bytes: Int, background: Bool,
                              process: inout ProcessTree?, result: inout [String: Any]) throws {
    let driver = output + "/terminal-bench"
    let statistics = output + "/session.json"
    let report = output + "/driver.json"
    guard try BenchDriver.build(to: driver, log: output + "/driver-build.log") else {
      throw Failure("Driver compilation failed")
    }
    result["driver_sha256"] = try sha256(ofFile: driver)
    let app = try ProcessTree([executable] + (background ? ["--background"] : []) + [
      "--columns", "100", "--rows", "30", "--font-size", "14",
      "--session-statistics-file", statistics, "--exit-after-command", "--execute", driver,
      "--output", report, "--terminal", "session-diagnostic", "--bytes", String(bytes),
      "--runs", String(runs), "--columns", "100", "--rows", "30", "--workload", "ascii_short_lines",
    ])
    process = app
    result["pid"] = Int(app.pid)
    let exit = app.wait(seconds: 180)
    try BenchDriver.checkFailure(beside: report)
    guard let exit else { throw Failure("Diagnostic timed out") }
    result["exit_status"] = exit.exitStatus
    guard exit.succeeded else { throw Failure("App did not exit successfully") }
    guard app.livePIDs.isEmpty else { throw Failure("Owned children survived app exit") }

    let workload = try acceptedWorkload(try readJSONObject(report), pid: Int(app.pid), bytes: bytes)
    result["diagnostic_mib_per_second"] = try workload.fetch("mib_per_second")
    let session = try readJSONObject(statistics)
    let counters = try acceptedCounters(session, bytes: bytes)
    let sourceMiB = Double(bytes * runs) / 1_048_576.0
    var perSourceMiB: [String: Any] = [:]
    for key in counters.keys { perSourceMiB[key] = try counters.number(key) / sourceMiB }
    // High-water marks are levels, not amounts, and do not scale with the source.
    perSourceMiB["event_queue_high_water"] = nil
    perSourceMiB["queued_output_bytes_high_water"] = nil
    result["per_source_mib"] = perSourceMiB
    result["mean_output_event_bytes"] = try session.number("bytes_read") / (try counters.number("output_events"))
    result["natural_exit"] = true
    result["passed"] = true
  }

  /// The single workload of the driver's report, once the report is known to
  /// be this run's and complete.
  private static func acceptedWorkload(_ data: [String: Any], pid: Int, bytes: Int) throws -> [String: Any] {
    guard ReportValue.equals(try data.fetch("schema"), 2), ReportValue.equals(try data.fetch("terminal_pid"), pid) else {
      throw Failure("Unexpected driver schema or process")
    }
    guard try data.fetch("terminal") as? String == "session-diagnostic" else { throw Failure("Unexpected terminal label") }
    guard ReportValue.equals(data["columns"], 100), ReportValue.equals(data["rows"], 30) else {
      throw Failure("Unexpected terminal geometry")
    }
    let workloads = try data.objects("workloads")
    guard workloads.count == 1, try workloads[0].fetch("name") as? String == "ascii_short_lines" else {
      throw Failure("Unexpected workload")
    }
    let workload = workloads[0]
    let summary = workload["mib_per_second"] as? [String: Any]
    guard ReportValue.equals(try workload.fetch("source_bytes_per_run"), bytes), ReportValue.equals(summary?["samples"], runs) else {
      throw Failure("Incomplete workload")
    }
    let observations = try workload.objects("run_samples")
    guard observations.count == runs,
          try observations.enumerated().allSatisfy({ ReportValue.equals(try $1.fetch("run"), $0 + 1) }) else {
      throw Failure("Missing ordered observations")
    }
    for observation in observations {
      for key in ["mib_per_second", "elapsed_seconds"] {
        guard let value = ReportValue.number(try observation.fetch(key)), value.isFinite, value > 0 else {
          throw Failure("Invalid \(key)")
        }
      }
    }
    let rates = try observations.map { try $0.number("mib_per_second") }.sorted()
    guard rates[4] == ReportValue.number(summary?["p50"]) else { throw Failure("Raw rate median differs") }
    return workload
  }

  /// The session's stream counters, once the session is known to have read,
  /// parsed and accounted for everything the driver wrote.
  private static func acceptedCounters(_ session: [String: Any], bytes: Int) throws -> [String: Any] {
    guard ["child_reaped", "read_ended", "parser_ended"].allSatisfy({ ReportValue.isTruthy(session[$0]) }) else {
      throw Failure("Session did not drain and reap")
    }
    let parsed = try session.number("bytes_parsed")
    guard try session.number("bytes_read") == parsed, try session.number("queued_output_bytes") == 0 else {
      throw Failure("Output was not fully parsed")
    }
    guard parsed >= Double(bytes * runs) else { throw Failure("Session parsed less than the requested source") }
    let counters = try session.object("stream_diagnostic")
    guard try counters.number("feed_bytes") == parsed else { throw Failure("Counter byte accounting differs") }
    guard try counters.number("output_events") > 0 else { throw Failure("No output events recorded") }
    return counters
  }
}

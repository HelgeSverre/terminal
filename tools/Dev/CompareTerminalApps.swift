import Foundation

/// Compares PTY throughput of two builds of the app: the Rust reference and
/// the Swift app.
///
/// Both bundles are launched from their executables into independent, owned
/// processes. Each runs the same PTY driver and must exit by itself with all
/// its children reaped.
enum CompareTerminalApps {
  static let command = Command(
    name: "compare-terminal-apps", usage: "REPORT_DIRECTORY RUST_APP SWIFT_APP",
    summary: "Measure PTY throughput of two app bundles with one driver (BENCH_FIRST, BENCH_BYTES, BENCH_RUNS).",
    run: run)

  static let minimumSwiftToRustRatio = 0.7

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 3 else { throw Failure.usage(command) }
    var comparison = try Comparison(output: arguments[0], rustApp: arguments[1], swiftApp: arguments[2],
                                    environment: ProcessInfo.processInfo.environment)
    try comparison.run()
    print("Completed both app benchmarks; all owned processes exited cleanly")
  }

  struct Comparison {
    let output: String
    /// The bundles by label, in the order they are measured.
    var apps: [(label: String, bundle: String)] = []
    let bytes: Int
    let runs: Int
    var driver = ""
    var result: [String: Any] = [:]
    var records: [String: [String: Any]] = [:]
    /// The driver's report for each label, once accepted.
    var reports: [String: [String: Any]] = [:]

    init(output: String, bytes: Int, runs: Int) {
      self.output = output
      self.bytes = bytes
      self.runs = runs
    }

    /// Checks the arguments and settings before anything is launched or written.
    init(output: String, rustApp: String, swiftApp: String, environment: [String: String]) throws {
      let first = environment["BENCH_FIRST"] ?? "rust"
      guard ["rust", "swift"].contains(first) else { throw Failure("BENCH_FIRST must be rust or swift") }
      guard let bytes = Int(environment["BENCH_BYTES"] ?? "2097152"), (1...1_073_741_824).contains(bytes) else {
        throw Failure("BENCH_BYTES must be between 1 and 1 GiB")
      }
      guard let runs = Int(environment["BENCH_RUNS"] ?? "3"), (1...100).contains(runs) else {
        throw Failure("BENCH_RUNS must be between 1 and 100")
      }
      self.init(output: absolutePath(output), bytes: bytes, runs: runs)
      let bundles = [("rust", try realPath(rustApp)), ("swift", try realPath(swiftApp))]
      apps = bundles.filter { $0.0 == first } + bundles.filter { $0.0 != first }
      let contents = try? FileManager.default.contentsOfDirectory(atPath: self.output)
      if FileManager.default.fileExists(atPath: self.output), contents?.isEmpty != true {
        throw Failure("Choose a new, empty report directory")
      }
      for (_, bundle) in apps where !FileManager.default.isExecutableFile(atPath: bundle + "/Contents/MacOS/Terminal") {
        throw Failure("Missing executable in \(bundle)")
      }
      result = [
        "passed": false, "requested_bytes": bytes, "runs_per_workload": runs,
        "geometry": [100, 30], "font": "Obel Mono", "font_size": 14,
        "runner_sha256": try sha256(ofFile: #filePath), "order": apps.map(\.label),
        "scope": "Sequential visible-app PTY pilot; parser barriers are not display latency. History is excluded by the driver alternate screen.",
      ]
    }

    /// Measures both apps and writes comparison.json, which records how far
    /// the run came when it fails.
    mutating func run() throws {
      var failure: Failure?
      do { try compare() } catch {
        failure = asFailure(error)
        result["failure"] = failure?.message
      }
      if isDirectory(output) {
        result["apps"] = records
        try ReportJSON.write(result, to: output + "/comparison.json")
      }
      if let failure { throw failure }
    }

    private mutating func compare() throws {
      try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
      driver = output + "/terminal-bench"
      guard try BenchDriver.build(to: driver, log: output + "/driver-build.log") else {
        throw Failure("Driver build failed")
      }
      result["driver_sha256"] = try sha256(ofFile: driver)
      result["driver_source_sha256"] = try sha256(ofFile: BenchDriver.source)
      for (label, bundle) in apps { try measure(label, bundle) }
      guard let rust = reports["rust"], let swift = reports["swift"] else { throw Failure("key not found: \"rust\"") }
      let layout = ["columns", "rows", "pixel_width", "pixel_height", "output_post_processing"]
      guard layout.allSatisfy({ JSONValue.same(rust[$0], swift[$0]) }) else { throw Failure("App PTY layouts differ") }
      let ratios = try Self.ratios(swift: swift, rust: rust)
      // The gate is recorded for the reader; a ratio below it does not fail the run.
      result["performance_gate"] = [
        "minimum_swift_to_rust_ratio": minimumSwiftToRustRatio, "observed_ratios": ratios,
        "passed": ratios.values.allSatisfy { $0 >= minimumSwiftToRustRatio },
      ] as [String: Any]
      result["passed"] = true
    }

    /// Each workload's median Swift throughput as a fraction of the Rust one.
    private static func ratios(swift: [String: Any], rust: [String: Any]) throws -> [String: Double] {
      func medians(_ report: [String: Any]) throws -> [(String, Double)] {
        try report.objects("workloads").map { item in
          guard let name = try item.fetch("name") as? String else { throw Failure("\"name\" is not a string") }
          return (name, try item.object("mib_per_second").number("p50"))
        }
      }
      let rustMedians = Dictionary(try medians(rust)) { _, last in last }
      var ratios: [String: Double] = [:]
      for (name, median) in try medians(swift) {
        guard let reference = rustMedians[name] else { throw Failure("key not found: \"\(name)\"") }
        ratios[name] = median / reference
      }
      return ratios
    }

    /// Runs the driver once inside the bundle and keeps its record, whether
    /// or not the run is accepted.
    mutating func measure(_ label: String, _ bundle: String) throws {
      let executable = bundle + "/Contents/MacOS/Terminal"
      let report = output + "/\(label).json"
      var record: [String: Any] = [
        "bundle": bundle, "executable_sha256": try sha256(ofFile: executable),
        "executable_bytes": try fileBytes(executable),
        "bundle_regular_file_bytes": bundleBytes(bundle, includingHidden: true),
        "natural_exit": false, "cleanup_survivors": [Int](),
      ]
      defer { records[label] = record }
      let process = try ProcessTree([
        executable, "--columns", "100", "--rows", "30", "--font-size", "14",
        "--history-limit", "10000", "--exit-after-command", "--execute", driver,
        "--output", report, "--terminal", label, "--bytes", String(bytes),
        "--runs", String(runs), "--columns", "100", "--rows", "30",
      ], log: output + "/\(label)-launch.log")
      var failure: Error?
      do { reports[label] = try judge(process, label: label, report: report, record: &record) } catch { failure = error }
      // Whatever happened, nothing this run launched may outlive it.
      let survivors = process.cleanup().map { Int($0) }
      record["cleanup_survivors"] = survivors
      guard survivors.isEmpty else {
        throw Failure("\(label) cleanup left processes: \(survivors.map(String.init).joined(separator: ", "))")
      }
      if let failure { throw failure }
    }

    private func judge(_ process: ProcessTree, label: String, report: String,
                       record: inout [String: Any]) throws -> [String: Any] {
      record["pid"] = Int(process.pid)
      print("Measuring \(label) app (PID \(process.pid))")
      fflush(stdout)
      let exit = process.wait(seconds: 300)
      try BenchDriver.checkFailure(beside: report)
      guard let exit else { throw Failure("\(label) benchmark timed out") }
      record["exit_status"] = exit.exitStatus
      guard exit.succeeded else { throw Failure("\(label) app exited with \(exit.summary)") }
      let children = process.livePIDs
      guard children.isEmpty else {
        throw Failure("\(label) app left children: \(children.map(String.init).joined(separator: ", "))")
      }
      record["natural_exit"] = true
      let data = try readJSONObject(report)
      guard JSONValue.equals(try data.fetch("schema"), 2) else { throw Failure("\(label) driver schema mismatch") }
      guard JSONValue.equals(try data.fetch("terminal_pid"), Int(process.pid)) else {
        throw Failure("\(label) report belongs to another process")
      }
      guard try data.fetch("terminal") as? String == label else { throw Failure("\(label) report label mismatch") }
      guard JSONValue.equals(try data.fetch("columns"), 100), JSONValue.equals(try data.fetch("rows"), 30) else {
        throw Failure("\(label) geometry mismatch")
      }
      let workloads = try data.objects("workloads")
      guard try workloads.map({ try $0.fetch("name") as? String ?? "" }) == BenchDriver.workloads else {
        throw Failure("\(label) workload mismatch")
      }
      for item in workloads { try validateWorkload(item, label) }
      record["report"] = "\(label).json"
      return data
    }

    /// The summary's sample count alone cannot prove that all requested runs
    /// happened. Observations must be present, in order and paired, and the
    /// distributions the gate uses must follow from them.
    func validateWorkload(_ item: [String: Any], _ label: String) throws {
      guard let samples = try item.fetch("run_samples") as? [[String: Any]],
            JSONValue.equals(try item.fetch("source_bytes_per_run"), bytes), samples.count == runs,
            try samples.enumerated().allSatisfy({ JSONValue.equals(try $1.fetch("run"), $0 + 1) }) else {
        throw Failure("\(label) incomplete or unordered workload observations")
      }
      for metric in ["mib_per_second", "elapsed_seconds", "terminal_cpu_seconds"] {
        let values = try samples.map { try $0.fetch(metric) }
        let summary = try item.fetch(metric)
        let isCPU = metric == "terminal_cpu_seconds"
        // CPU time is unavailable for some terminals; then every observation must say so.
        if isCPU, summary is NSNull, values.allSatisfy({ $0 is NSNull }) { continue }
        let numbers = values.compactMap { JSONValue.number($0) }
        guard numbers.count == values.count, numbers.allSatisfy({ $0.isFinite && (isCPU ? $0 >= 0 : $0 > 0) }) else {
          throw Failure("\(label) invalid \(metric) observations")
        }
        let sorted = numbers.sorted()
        let expected = ["p50": sorted[(runs - 1) / 2], "p95": sorted[(runs - 1) * 95 / 100],
                        "p99": sorted[(runs - 1) * 99 / 100], "max": sorted[runs - 1]]
        guard let summary = summary as? [String: Any], JSONValue.equals(try summary.fetch("samples"), runs),
              try expected.allSatisfy({ JSONValue.number(try summary.fetch($0.key)) == $0.value }) else {
          throw Failure("\(label) \(metric) distribution does not match observations")
        }
      }
      for sample in samples {
        let rate = try sample.number("mib_per_second")
        let elapsed = try sample.number("elapsed_seconds")
        // The C driver prints both fields to six decimal places. Their
        // rounding intervals must overlap for the exact requested byte count.
        let secondsFromRate = Double(bytes) / 1_048_576.0 / rate
        let tolerance = 0.500001e-6 + secondsFromRate * 0.500001e-6 / (rate - 0.5e-6)
        guard abs(elapsed - secondsFromRate) <= tolerance else {
          throw Failure("\(label) unpaired throughput/time observations")
        }
      }
    }
  }

  static let tests = [
    SelfTest.Case(name: "compare terminal apps: observations in execution order are accepted") {
      try validate(observations())
    },
    SelfTest.Case(name: "compare terminal apps: the driver's failure precedes a non-zero exit and the app is reaped") {
      try withFixtureApp(failingDriverScript("fixture driver failed")) { app, root in
        var comparison = Comparison(output: root, bytes: 2 * 1_048_576, runs: 3)
        comparison.driver = "/unused-driver"
        let message = try failureMessage("driver failure") { try comparison.measure("swift", app) }
        try expect(message == "fixture driver failed", "got: \(message)")
        let record = comparison.records["swift"] ?? [:]
        try expect(record["natural_exit"] as? Bool == false, "exit is not natural")
        try expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
      }
    },
    SelfTest.Case(name: "compare terminal apps: a sample count without all observations is rejected") {
      try rejects("a missing observation") { try validate(Array(observations().dropLast())) }
    },
    SelfTest.Case(name: "compare terminal apps: duplicate and reordered run numbers are rejected") {
      var samples = observations()
      samples[2]["run"] = 2
      try rejects("a duplicate run") { try validate(samples) }
      try rejects("reversed runs") { try validate(observations().reversed()) }
    },
    SelfTest.Case(name: "compare terminal apps: a forged gate median is rejected") {
      var rate = summary(4.0, 8.0)
      rate["p50"] = 100.0
      try rejects("a forged median") { try validate(observations(), rate: rate) }
    },
    SelfTest.Case(name: "compare terminal apps: independently sorted paired values are rejected") {
      var samples = observations()
      for (index, time) in [0.25, 0.5, 1.0].enumerated() { samples[index]["elapsed_seconds"] = time }
      try rejects("unpaired values") { try validate(samples) }
    },
    SelfTest.Case(name: "compare terminal apps: unavailable CPU time is accepted only when all observations agree") {
      var samples = observations()
      for index in samples.indices { samples[index]["terminal_cpu_seconds"] = NSNull() }
      try validate(samples, cpu: NSNull())
      samples[0]["terminal_cpu_seconds"] = 0.1
      try rejects("a partly available CPU time") { try validate(samples, cpu: NSNull()) }
    },
    SelfTest.Case(name: "compare terminal apps: non-finite observations are rejected") {
      var samples = observations()
      samples[0]["mib_per_second"] = Double.infinity
      try rejects("an infinite rate") { try validate(samples) }
    },
    SelfTest.Case(name: "compare terminal apps: two accepted apps give a report with the order and the gate") {
      try withFixtureApp(reportingScript) { app, root in
        let summary: [String: Any] = ["samples": 1, "p50": 2.0, "p95": 2.0, "p99": 2.0, "max": 2.0]
        let time = summary.mapValues { $0 as? Double == 2.0 ? 0.5 : $0 }
        try ReportJSON.write([
          "schema": 2, "terminal": "LABEL", "terminal_pid": fixturePlaceholderPID, "columns": 100, "rows": 30,
          "pixel_width": 800, "pixel_height": 540, "output_post_processing": true,
          "workloads": BenchDriver.workloads.map { name -> [String: Any] in
            ["name": name, "source_bytes_per_run": 1_048_576, "mib_per_second": summary, "elapsed_seconds": time,
             "terminal_cpu_seconds": NSNull(),
             "run_samples": [["run": 1, "mib_per_second": 2.0, "elapsed_seconds": 0.5,
                              "terminal_cpu_seconds": NSNull()] as [String: Any]]]
          },
        ] as [String: Any], to: app + "/Contents/MacOS/Terminal.report")
        var comparison = try Comparison(output: root + "/report", rustApp: app, swiftApp: app, environment: [
          "BENCH_FIRST": "swift", "BENCH_BYTES": "1048576", "BENCH_RUNS": "1"])
        try comparison.run()
        let report = try readJSONObject(root + "/report/comparison.json")
        try expect(report["passed"] as? Bool == true, "comparison passed")
        try expect(report["order"] as? [String] == ["swift", "rust"], "order follows BENCH_FIRST")
        let gate = try report.object("performance_gate")
        try expect(gate["passed"] as? Bool == true, "gate passed")
        try expect(try gate.object("observed_ratios").number("unicode") == 1, "ratio is one")
        let rust = try report.object("apps").object("rust")
        try expect(rust["report"] as? String == "rust.json" && rust["natural_exit"] as? Bool == true, "rust is recorded")
        let text = try String(contentsOfFile: root + "/report/comparison.json", encoding: .utf8)
        try expect(text.contains("\"unicode\": 1.0"), "a ratio is written as floating point")
      }
    },
  ]

  /// A fixture app that writes the report beside its executable where the
  /// driver would, under the label and with the PID it was launched with.
  private static let reportingScript = """
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --output ]; then output=$2; fi
      if [ "$1" = --terminal ]; then label=$2; fi
      shift
    done
    sed -e "s/\(fixturePlaceholderPID)/$$/" -e "s/LABEL/$label/" "$0.report" > "$output"
    """

  private static func observations() -> [[String: Any]] {
    [["run": 1, "mib_per_second": 2.0, "elapsed_seconds": 1.0, "terminal_cpu_seconds": 0.1],
     ["run": 2, "mib_per_second": 8.0, "elapsed_seconds": 0.25, "terminal_cpu_seconds": 0.3],
     ["run": 3, "mib_per_second": 4.0, "elapsed_seconds": 0.5, "terminal_cpu_seconds": 0.2]]
  }

  private static func summary(_ median: Double, _ maximum: Double) -> [String: Any] {
    ["samples": 3, "p50": median, "p95": median, "p99": median, "max": maximum]
  }

  /// Validates a 2 MiB, three-run workload made of `samples` and summaries.
  private static func validate(_ samples: [[String: Any]], rate: [String: Any] = summary(4.0, 8.0),
                               cpu: Any = summary(0.2, 0.3)) throws {
    let workload: [String: Any] = [
      "source_bytes_per_run": 2 * 1_048_576, "run_samples": samples,
      "mib_per_second": rate, "elapsed_seconds": summary(0.5, 1.0), "terminal_cpu_seconds": cpu,
    ]
    try Comparison(output: "", bytes: 2 * 1_048_576, runs: 3).validateWorkload(workload, "fixture")
  }

  private static func rejects(_ what: String, _ body: () throws -> Void) throws {
    _ = try failureMessage(what, body)
  }
}

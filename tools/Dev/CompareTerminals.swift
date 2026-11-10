import Foundation

/// Compares PTY throughput of the optimized local app with Ghostty and Kitty.
///
/// The contract is fixed: the installed reference terminals, two opposite
/// orders, one driver, bundles copied aside before the first launch so that
/// nothing can rebuild them mid-run, and every launched process accounted for.
enum CompareTerminals {
  static let command = Command(
    name: "compare-terminals", usage: "NEW_REPORT_DIRECTORY",
    summary: "Measure PTY throughput of dist/Terminal.app, Ghostty and Kitty in both orders (BENCH_BYTES, BENCH_RUNS).",
    run: run)

  static let orders = [["terminal", "ghostty", "kitty"], ["kitty", "ghostty", "terminal"]]

  /// Ghostty's launch settings: the same font and cell grid as the other two.
  static let ghosttyConfiguration = """
    config-default-files = false
    font-family = Obel Mono
    font-size = 14
    cursor-style-blink = false
    background-opacity = 1
    window-width = 100
    window-height = 30
    # Eight points produced 101 columns on the Retina benchmark screen.
    window-padding-x = 0
    window-padding-y = 8
    scrollback-limit-lines = 10000
    scrollback-limit-bytes = 67108864
    shell-integration = none
    confirm-close-surface = false
    quit-after-last-window-closed = true
    window-save-state = never

    """

  /// Kitty's launch settings, in the order they are passed.
  static let kittySettings = [
    ("font_family", "Obel Mono"), ("font_size", "14"),
    ("initial_window_width", "100c"), ("initial_window_height", "30c"),
    ("remember_window_size", "no"), ("cursor_blink_interval", "0"),
    ("scrollback_lines", "10000"), ("background_opacity", "1"),
    ("shell_integration", "disabled"), ("window_padding_width", "0"),
    ("macos_quit_when_last_window_closed", "yes"), ("confirm_os_window_close", "0"),
  ]

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 1 else { throw Failure.usage(command) }
    let environment = ProcessInfo.processInfo.environment
    guard let bytes = Int(environment["BENCH_BYTES"] ?? "16777216"), let runs = Int(environment["BENCH_RUNS"] ?? "10"),
          (1...1_073_741_824).contains(bytes), (1...100).contains(runs) else {
      throw Failure("Invalid payload/sample count")
    }
    var comparison = Comparison(output: absolutePath(arguments[0]), bytes: bytes, runs: runs)
    try comparison.run()
    print("PASS terminal comparison; both orders completed with no surviving owned processes")
  }

  /// One pass over the terminals in a given order, with a record per terminal.
  struct Trial {
    let order: [String]
    var apps: [String: [String: Any]] = [:]
    var json: [String: Any] { ["order": order, "apps": apps] }
  }

  struct Comparison {
    let output: String
    let bytes: Int
    let runs: Int
    /// Seconds a terminal has to finish every workload and exit.
    var limit = 300.0
    var result: [String: Any] = [:]
    var apps: [String: [String: Any]]?
    var trials: [Trial] = []

    init(output: String, bytes: Int, runs: Int) {
      self.output = output
      self.bytes = bytes
      self.runs = runs
    }

    /// Measures both orders and writes comparison.json, which records how
    /// far the run came when it fails.
    mutating func run() throws {
      let report = output + "/comparison.json"
      guard !FileManager.default.fileExists(atPath: report) else { throw Failure("Output already contains a result") }
      result = [
        "passed": false, "source_sha": try host("git", "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines),
        "bytes_per_run": bytes, "runs_per_workload": runs, "geometry": [100, 30],
        "font": "Obel Mono 14", "os": try host("sw_vers"),
        "hardware": try host("sysctl", "-n", "machdep.cpu.brand_string"),
        "power": try host("pmset", "-g", "batt"), "load_before": try host("sysctl", "-n", "vm.loadavg"),
        "scope": "Sequential visible-app PTY throughput and ordered parser replies; alternate screen excludes history. Same cell grid/configured font; native cell-pixel metrics are recorded, not normalized. Not display FPS, presentation/input latency, peak memory, or a SQL benchmark.",
      ]
      var failure: Failure?
      do {
        try measureBothOrders()
        result["passed"] = true
        result["stage"] = "finished"
      } catch {
        failure = asFailure(error)
        result["failure"] = failure?.message
      }
      result["load_after"] = try host("sysctl", "-n", "vm.loadavg")
      result["trials"] = trials.map(\.json)
      if let apps { result["apps"] = apps }
      try ReportJSON.write(result, to: report)
      if let failure { throw failure }
    }

    private func host(_ command: String...) throws -> String {
      try standardOutput(of: command, in: Repository.root)
    }

    private mutating func measureBothOrders() throws {
      try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
      result["stage"] = "compile_driver"
      let driver = output + "/terminal-bench"
      _ = try standardOutput(of: BenchDriver.buildCommand(to: driver), in: Repository.root)
      result["driver_source_sha256"] = try sha256(ofFile: BenchDriver.source)
      result["driver_sha256"] = try sha256(ofFile: driver)
      result["runner_sha256"] = try sha256(ofFile: #filePath)
      try withTemporaryDirectory("terminal-ghostty-comparison-") { temporary in
        result["stage"] = "freeze_apps"
        let executables = try freezeApps(into: temporary)
        result["ghostty_version"] = try host(executables["ghostty"]!, "+version")
        result["kitty_version"] = try host(executables["kitty"]!, "--version")
        let configuration = output + "/ghostty.conf"
        try CompareTerminals.ghosttyConfiguration.write(toFile: configuration, atomically: true, encoding: .utf8)
        for (index, order) in CompareTerminals.orders.enumerated() {
          try measure(order, trial: index + 1, executables: executables, driver: driver, configuration: configuration)
        }
      }
    }

    /// Copies each bundle aside and returns the copies' executables. The
    /// hash is taken before and after the copy: an app rebuilt in between is
    /// not a measurement target.
    private mutating func freezeApps(into temporary: String) throws -> [String: String] {
      let bundles = [("terminal", Repository.path("dist/Terminal.app")), ("ghostty", "/Applications/Ghostty.app"),
                     ("kitty", "/Applications/kitty.app")]
      var executables: [String: String] = [:]
      apps = [:]
      for (name, bundle) in bundles {
        let binary = "/Contents/MacOS/" + (name == "terminal" ? "Terminal" : name)
        guard FileManager.default.isExecutableFile(atPath: bundle + binary) else { throw Failure("Missing \(bundle + binary)") }
        let hash = try sha256(ofFile: bundle + binary)
        apps?[name] = ["executable_sha256": hash, "executable_bytes": try fileBytes(bundle + binary),
                       "bundle_bytes": bundleBytes(bundle, includingHidden: false)]
        let copy = temporary + "/\(name).app"
        _ = try host("ditto", bundle, copy)
        let frozenHash = try sha256(ofFile: copy + binary)
        apps?[name]?["frozen_executable_sha256"] = frozenHash
        guard frozenHash == hash else { throw Failure("\(name) executable changed while freezing") }
        executables[name] = copy + binary
      }
      return executables
    }

    private mutating func measure(_ order: [String], trial index: Int, executables: [String: String],
                                  driver: String, configuration: String) throws {
      var trial = Trial(order: order)
      defer { trials.append(trial) }
      for name in order {
        result["stage"] = "trial_\(index)_\(name)"
        try measure(name, executable: executables[name]!, driver: driver, configuration: configuration,
                    index: index, trial: &trial)
      }
      result["stage"] = "validate_trial_\(index)"
      let reports = trial.apps.values.map { $0["report"] as? [String: Any] ?? [:] }
      let sameLayout = ["columns", "rows", "output_post_processing"].allSatisfy { field in
        reports.allSatisfy { JSONValue.same($0[field], reports[0][field]) }
      }
      guard sameLayout else { throw Failure("PTY geometry/modes differ") }
    }

    /// Runs the driver once inside `name` and adds its record to `trial`,
    /// whether or not the run is accepted.
    func measure(_ name: String, executable: String, driver: String, configuration: String,
                 index: Int, trial: inout Trial) throws {
      let report = output + "/\(index)-\(name).json"
      guard !FileManager.default.fileExists(atPath: report) else { throw Failure("Refusing to overwrite \(report)") }
      let driverArguments = ["--output", report, "--terminal", name, "--bytes", String(bytes), "--runs", String(runs),
                             "--columns", "100", "--rows", "30"]
      let command = try CompareTerminals.launchCommand(name, executable: executable, configuration: configuration,
                                                       driver: [driver] + driverArguments)
      var record: [String: Any] = ["natural_exit": false]
      defer { trial.apps[name] = record }
      let process: ProcessTree
      do { process = try ProcessTree(command, log: output + "/\(index)-\(name).log") } catch {
        record["cleanup_survivors"] = [Int]()
        throw error
      }
      var failure: Error?
      do { try judge(process, name: name, report: report, index: index, record: &record) } catch { failure = error }
      // Whatever happened, nothing this run launched may outlive it.
      let survivors = process.cleanup().map { Int($0) }
      record["cleanup_survivors"] = survivors
      guard survivors.isEmpty else { throw Failure("Owned processes survived cleanup") }
      if let failure { throw failure }
    }

    private func judge(_ process: ProcessTree, name: String, report: String, index: Int,
                       record: inout [String: Any]) throws {
      record["pid"] = Int(process.pid)
      print("Measuring trial \(index): \(name), owned PID \(process.pid)")
      fflush(stdout)
      let exit = process.wait(seconds: limit)
      try BenchDriver.checkFailure(beside: report)
      guard let exit else { throw Failure("\(name) timed out") }
      guard exit.succeeded else { throw Failure("\(name) failed: \(exit.summary)") }
      guard process.livePIDs.isEmpty else { throw Failure("Children survived natural app exit") }
      record["natural_exit"] = true
      let data = try readJSONObject(report)
      record["report_pid"] = data["terminal_pid"] ?? NSNull()
      // The report may come from a child of the app that serves the terminal,
      // so ownership is judged against everything seen in the tree.
      try validate(data, name: name, owned: process.observedOwned(JSONValue.integer(data["terminal_pid"])))
      record["report"] = data
    }

    private func validate(_ data: [String: Any], name: String, owned: Bool) throws {
      guard JSONValue.equals(data["schema"], 2), owned,
            JSONValue.equals(data["columns"], 100), JSONValue.equals(data["rows"], 30) else {
        throw Failure("Wrong report owner/schema/grid")
      }
      guard data["terminal"] as? String == name else { throw Failure("Wrong report terminal label") }
      guard JSONValue.isBoolean(data["output_post_processing"]) else { throw Failure("Missing output-processing mode") }
      guard ["pixel_width", "pixel_height"].allSatisfy({ (JSONValue.integer(data[$0]) ?? 0) > 0 }) else {
        throw Failure("Missing cell-pixel geometry")
      }
      let workloads = try data.objects("workloads")
      guard workloads.map({ $0["name"] as? String ?? "" }) == BenchDriver.workloads else { throw Failure("Wrong corpus") }
      for workload in workloads {
        let samples = try workload.objects("run_samples")
        guard JSONValue.equals(workload["source_bytes_per_run"], bytes), samples.count == runs,
              samples.enumerated().allSatisfy({ JSONValue.equals($1["run"], $0 + 1) }) else {
          throw Failure("Incomplete samples")
        }
        let rates = try samples.map { try $0.number("mib_per_second") }.sorted()
        let median = JSONValue.number((workload["mib_per_second"] as? [String: Any])?["p50"])
        guard rates.allSatisfy({ $0.isFinite && $0 > 0 }), median == rates[(runs - 1) / 2] else {
          throw Failure("Invalid median")
        }
      }
    }
  }

  /// How each terminal is started with the driver as its only command.
  static func launchCommand(_ name: String, executable: String, configuration: String, driver: [String]) throws -> [String] {
    switch name {
    case "terminal":
      return [executable, "--columns", "100", "--rows", "30", "--font-size", "14", "--history-limit", "10000",
              "--exit-after-command", "--execute"] + driver
    case "ghostty":
      return [executable, "--config-default-files=false", "--config-file=\(configuration)", "-e"] + driver
    case "kitty":
      return [executable, "--config", "NONE", "--session", "none"]
        + kittySettings.flatMap { ["--override", "\($0)=\($1)"] } + driver
    default:
      throw Failure("Unknown terminal \(name)")
    }
  }

  static let tests = [
    SelfTest.Case(name: "compare terminals: a valid owned report is accepted and the app reaped") {
      let (record, failure) = try trial(report: report())
      try expect(failure == nil, "got: \(failure ?? "")")
      try expect(record["natural_exit"] as? Bool == true, "exit is natural")
      try expect((record["report"] as? [String: Any])?["terminal"] as? String == "ghostty", "report is kept")
      try expect(JSONValue.same(record["report_pid"], record["pid"]), "report names the launched process")
      try expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
    },
    SelfTest.Case(name: "compare terminals: the driver's failure is kept when the app exits non-zero") {
      let (record, failure) = try trial(failed: "geometry is 100x27; expected 100x30", status: 7)
      try expect(failure == "geometry is 100x27; expected 100x30", "got: \(failure ?? "no failure")")
      try expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
    },
    SelfTest.Case(name: "compare terminals: a wrong label and a missing mode are rejected") {
      for change in [["terminal": "another-app"], ["output_post_processing": NSNull()]] as [[String: Any]] {
        let (record, failure) = try trial(report: report().merging(change) { _, new in new })
        try expect(failure != nil, "\(change.keys) is rejected")
        try expect(record["report"] == nil, "report is not kept")
        try expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
      }
    },
    SelfTest.Case(name: "compare terminals: kitty gets an isolated grid and quits with its window") {
      let command = try launchCommand("kitty", executable: "/fixture/kitty", configuration: "/fixture/config",
                                      driver: ["/fixture/driver"])
      try expect(Array(command.prefix(5)) == ["/fixture/kitty", "--config", "NONE", "--session", "none"], "isolated")
      for option in ["initial_window_width=100c", "initial_window_height=30c", "shell_integration=disabled",
                     "macos_quit_when_last_window_closed=yes"] {
        try expect(command.contains(option), "passes \(option)")
      }
      let (record, failure) = try trial(name: "kitty", report: report().merging(["terminal": "kitty"]) { _, new in new })
      try expect(failure == nil, "got: \(failure ?? "")")
      try expect(record["natural_exit"] as? Bool == true, "kitty's report is accepted")
    },
    SelfTest.Case(name: "compare terminals: an app that outlives the limit is ended and recorded") {
      let (record, failure) = try trial(linger: true)
      try expect(failure == "ghostty timed out", "got: \(failure ?? "no failure")")
      try expect(record["natural_exit"] as? Bool == false, "exit is not natural")
      try expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
      try expect(kill(pid_t(record["pid"] as? Int ?? 0), 0) != 0, "the app is gone")
    },
  ]

  private static func report() -> [String: Any] {
    ["schema": 2, "terminal": "ghostty", "terminal_pid": fixturePlaceholderPID, "columns": 100, "rows": 30,
     "pixel_width": 800, "pixel_height": 540, "output_post_processing": true,
     "workloads": BenchDriver.workloads.map { name -> [String: Any] in
       ["name": name, "source_bytes_per_run": 1, "run_samples": [["run": 1, "mib_per_second": 1.0] as [String: Any]],
        "mib_per_second": ["p50": 1.0]]
     }]
  }

  /// Measures a fixture terminal once and returns its record with the
  /// failure the measurement ended in, if any. The fixture writes `report` or
  /// the `failed` reason where the driver would, then exits with `status`, or
  /// stays when `linger`.
  private static func trial(name: String = "ghostty", report: [String: Any]? = nil, failed: String? = nil,
                            status: Int = 0, linger: Bool = false) throws -> (record: [String: Any], failure: String?) {
    try withTemporaryDirectory("dev-compare-terminals-") { directory in
      let executable = directory + "/fixture"
      if let report { try ReportJSON.write(report, to: executable + ".report") }
      if let failed { try failed.write(toFile: executable + ".failed", atomically: true, encoding: .utf8) }
      // The fixture must live long enough to be seen, or its PID is not known as owned.
      try writeExecutable("""
        #!/bin/sh
        sleep \(linger ? "30" : "0.3")
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --output ]; then
            if [ -f "$0.report" ]; then sed "s/\(fixturePlaceholderPID)/$$/" "$0.report" > "$2"; fi
            if [ -f "$0.failed" ]; then cp "$0.failed" "$2.failed"; fi
          fi
          shift
        done
        exit \(status)

        """, to: executable)
      var comparison = Comparison(output: directory, bytes: 1, runs: 1)
      if linger { comparison.limit = 0.3 }
      var trial = Trial(order: [name])
      var failure: String?
      do {
        try comparison.measure(name, executable: executable, driver: "/fixture/driver",
                               configuration: "/fixture/config", index: 1, trial: &trial)
      } catch { failure = asFailure(error).message }
      return (trial.apps[name] ?? [:], failure)
    }
  }
}

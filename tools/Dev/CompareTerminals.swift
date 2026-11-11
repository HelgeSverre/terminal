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
        failure = Failure(wrapping: error)
        result["failure"] = failure?.message
      }
      result["load_after"] = try host("sysctl", "-n", "vm.loadavg")
      result["trials"] = trials.map(\.json)
      if let apps { result["apps"] = apps }
      try JSONValue(sortingKeysOf: result).write(to: report)
      if let failure { throw failure }
    }

    private func host(_ command: String...) throws -> String { try host(command) }

    /// What a command run in the repository wrote to standard output. Error
    /// output is kept apart, so it cannot end up in the report, and becomes
    /// the failure message when the command fails.
    @discardableResult
    private func host(_ command: [String]) throws -> String {
      let result = try runCommand(command, directory: Repository.root, errors: .separate)
      guard result.succeeded else { throw Failure("\(command[0]) failed: \(result.error)") }
      return result.output
    }

    private mutating func measureBothOrders() throws {
      try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
      result["stage"] = "compile_driver"
      let driver = output + "/terminal-bench"
      try host(BenchDriver.buildCommand(to: driver))
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
        reports.allSatisfy { ReportValue.same($0[field], reports[0][field]) }
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
      do { process = try ProcessTree(command, output: .log(output + "/\(index)-\(name).log")) } catch {
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
      try validate(data, name: name, owned: process.observedOwned(ReportValue.integer(data["terminal_pid"])))
      record["report"] = data
    }

    private func validate(_ data: [String: Any], name: String, owned: Bool) throws {
      guard ReportValue.equals(data["schema"], 2), owned,
            ReportValue.equals(data["columns"], 100), ReportValue.equals(data["rows"], 30) else {
        throw Failure("Wrong report owner/schema/grid")
      }
      guard data["terminal"] as? String == name else { throw Failure("Wrong report terminal label") }
      guard ReportValue.isBoolean(data["output_post_processing"]) else { throw Failure("Missing output-processing mode") }
      guard ["pixel_width", "pixel_height"].allSatisfy({ (ReportValue.integer(data[$0]) ?? 0) > 0 }) else {
        throw Failure("Missing cell-pixel geometry")
      }
      let workloads = try data.objects("workloads")
      guard workloads.map({ $0["name"] as? String ?? "" }) == BenchDriver.workloads else { throw Failure("Wrong corpus") }
      for workload in workloads {
        let samples = try workload.objects("run_samples")
        guard ReportValue.equals(workload["source_bytes_per_run"], bytes), samples.count == runs,
              samples.enumerated().allSatisfy({ ReportValue.equals($1["run"], $0 + 1) }) else {
          throw Failure("Incomplete samples")
        }
        let rates = try samples.map { try $0.number("mib_per_second") }.sorted()
        let median = ReportValue.number((workload["mib_per_second"] as? [String: Any])?["p50"])
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
}

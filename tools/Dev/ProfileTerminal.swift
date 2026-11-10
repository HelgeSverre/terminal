import Foundation

/// Samples the call stacks of one app bundle while it runs the PTY driver.
///
/// The bundle is given explicitly and launched from its executable. The
/// runner owns only the app and the sampler it starts, so cleanup never
/// targets an instance the user has open.
enum ProfileTerminal {
  static let command = Command(
    name: "profile-terminal", usage: "APP_BUNDLE NEW_REPORT_DIRECTORY [WORKLOAD]",
    summary: "Sample APP_BUNDLE for five seconds while it runs the PTY driver, on all workloads or one.",
    run: run)

  static let driverBytes = 64 * 1024 * 1024
  static let driverRuns = 1
  static let driverIdleSeconds = 3
  static let columns = 100
  static let rows = 30
  static let font = "Obel Mono"
  static let fontSize = 14
  static let sampleSeconds = 5
  static let sampleIntervalMilliseconds = 1

  static func run(_ arguments: [String]) throws {
    guard (2...3).contains(arguments.count) else { throw Failure.usage(command) }
    var profile = try Profile(app: arguments[0], output: arguments[1],
                              workload: arguments.count == 3 ? arguments[2] : "all")
    try profile.run()
    print("Profile complete; all owned app, sampler, and PTY descendants exited cleanly")
  }

  /// A launched process as cleanup sees it. Tests substitute one that
  /// reports survivors, which a real process cannot be made to do.
  struct Owned {
    let pid: Int
    let exit: () -> ProcessTree.Exit?
    let livePIDs: () -> [pid_t]
    let cleanup: () -> [pid_t]

    init(pid: Int, exit: @escaping () -> ProcessTree.Exit?, livePIDs: @escaping () -> [pid_t],
         cleanup: @escaping () -> [pid_t]) {
      self.pid = pid
      self.exit = exit
      self.livePIDs = livePIDs
      self.cleanup = cleanup
    }
    init(_ tree: ProcessTree) {
      self.init(pid: Int(tree.pid), exit: { tree.exit }, livePIDs: { tree.livePIDs }, cleanup: { tree.cleanup() })
    }
  }

  struct Profile {
    let output: String
    var app = ""
    var executable = ""
    /// The one workload to run, or nil for all of them.
    var workload: String?
    var driverBytes = ProfileTerminal.driverBytes
    var driver = ""
    var result: [String: Any] = ["passed": false]
    var provenance: [String: Any] = [:]
    /// What became of each launched process, by "app" and "sample".
    var lifecycle: [String: [String: Any]] = [:]
    var appProcess: Owned?
    var sampleProcess: Owned?

    init(output: String) { self.output = output }

    /// Checks the bundle and the report path before anything is launched or written.
    init(app: String, output: String, workload: String) throws {
      self.init(output: absolutePath(output))
      self.app = try realPath(app)
      self.workload = workload == "all" ? nil : workload
      // A selected workload must keep running for the whole five-second
      // sample, also when ASCII throughput approaches the Rust reference.
      driverBytes = self.workload == nil ? ProfileTerminal.driverBytes : 512 * 1024 * 1024
      executable = self.app + "/Contents/MacOS/Terminal"
      guard FileManager.default.isExecutableFile(atPath: executable) else { throw Failure("Missing executable in \(self.app)") }
      guard !FileManager.default.fileExists(atPath: self.output) else {
        throw Failure("Refusing to clobber existing report path \(self.output)")
      }
      result = [
        "schema": 1, "passed": false,
        "contract": [
          "columns": columns, "rows": rows, "font": font, "font_size": fontSize,
          "bytes_per_workload": driverBytes, "runs_per_workload": driverRuns, "workload": workload,
          "idle_seconds": driverIdleSeconds, "sample_seconds": sampleSeconds,
          "sample_interval_ms": sampleIntervalMilliseconds,
        ] as [String: Any],
        "interpretation": "The benchmark driver wall and CPU fields are diagnostic-only here: the concurrent sampler perturbs them and they are not comparison timing.",
      ]
      provenance = ["runner_sha256": try sha256(ofFile: #filePath), "app_bundle": self.app,
                    "app_executable_sha256": try sha256(ofFile: executable)]
    }

    mutating func run() throws {
      var failure: Failure?
      do {
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: false)
        try buildDriver()
        try sampleApp()
        result["passed"] = true
      } catch {
        failure = asFailure(error)
        result["failure"] = failure?.message
      }
      try finish(after: failure)
    }

    /// Ends the launched processes and writes profile.json. Survivors fail a
    /// profile that otherwise completed. When the profile had already failed,
    /// that failure stays the reported one and the report keeps both.
    mutating func finish(after failure: Failure?) throws {
      let issues = cleanupOwnedProcesses()
      var cleanupFailure: Failure?
      if !issues.isEmpty {
        let cleanup = Failure("Owned process cleanup failed: " + issues.joined(separator: "; "))
        result["passed"] = false
        result["cleanup_failure"] = cleanup.message
        result["failure"] = [result["failure"] as? String, cleanup.message].compactMap { $0 }.joined(separator: "\n")
        cleanupFailure = cleanup
      }
      if isDirectory(output) {
        result["provenance"] = provenance
        result["lifecycle"] = lifecycle
        try ReportJSON.write(result, to: output + "/profile.json")
      }
      if let failure = failure ?? cleanupFailure { throw failure }
    }

    private mutating func buildDriver() throws {
      driver = output + "/terminal-bench"
      guard try BenchDriver.build(to: driver, log: output + "/driver-build.log") else {
        throw Failure("Driver build failed")
      }
      provenance["driver_source"] = BenchDriver.source
      provenance["driver_source_sha256"] = try sha256(ofFile: BenchDriver.source)
      provenance["driver_sha256"] = try sha256(ofFile: driver)
      provenance["driver_build_command"] = BenchDriver.buildCommand(to: driver)
    }

    private mutating func sampleApp() throws {
      let report = output + "/driver.json"
      var appArguments = [
        executable, "--columns", String(columns), "--rows", String(rows),
        "--font-size", String(fontSize), "--exit-after-command", "--execute", driver,
        "--output", report, "--terminal", "profiled-app", "--bytes", String(driverBytes),
        "--runs", String(driverRuns), "--columns", String(columns), "--rows", String(rows),
        "--idle-seconds", String(driverIdleSeconds),
      ]
      if let workload { appArguments += ["--workload", workload] }
      provenance["app_command"] = appArguments
      let app = try ProcessTree(appArguments, log: output + "/app-launch.log")
      appProcess = Owned(app)
      lifecycle["app"] = ["pid": Int(app.pid), "natural_exit": false]

      // The driver idles first; sampling starts once its workloads are under way.
      let earlyExit = app.wait(seconds: 3.5)
      try BenchDriver.checkFailure(beside: report)
      if let earlyExit { throw Failure("App exited before profiling: \(earlyExit.summary)") }

      try sample(app)

      let finished = app.wait(seconds: 180)
      try BenchDriver.checkFailure(beside: report)
      guard let exit = finished else { throw Failure("App benchmark timed out") }
      guard exit.succeeded else { throw Failure("App exited with \(exit.summary)") }
      let children = app.livePIDs
      guard children.isEmpty else {
        throw Failure("App left children: \(children.map(String.init).joined(separator: ", "))")
      }
      let driverReport = try readJSONObject(report)
      try validate(driverReport, pid: Int(app.pid))
      lifecycle["app"]?.merge(exit.record) { _, new in new }
      lifecycle["app"]?["natural_exit"] = true
      result["driver_report_sha256"] = try sha256(ofFile: report)
      var cpuSeconds: [String: Any] = [:]
      for workload in try driverReport.objects("workloads") {
        guard let name = try workload.fetch("name") as? String else { throw Failure("\"name\" is not a string") }
        cpuSeconds[name] = workload["terminal_cpu_seconds"] ?? NSNull()
      }
      result["driver_report_summary"] = [
        "idle_cpu_percent_one_core": driverReport["idle_cpu_percent_one_core"] ?? NSNull(),
        "workload_terminal_cpu_seconds": cpuSeconds,
      ] as [String: Any]
    }

    /// Runs `sample` on the app and requires it to leave its raw text.
    private mutating func sample(_ app: ProcessTree) throws {
      let rawSample = output + "/sample.txt"
      let arguments = ["/usr/bin/sample", String(app.pid), String(sampleSeconds),
                       String(sampleIntervalMilliseconds), "-file", rawSample]
      provenance["sample_command"] = arguments
      let sampler = try ProcessTree(arguments, log: output + "/sample-launch.log")
      sampleProcess = Owned(sampler)
      lifecycle["sample"] = ["pid": Int(sampler.pid), "natural_exit": false]
      guard let exit = sampler.wait(seconds: Double(sampleSeconds + 20)) else { throw Failure("sample timed out") }
      guard exit.succeeded else { throw Failure("sample exited with \(exit.summary)") }
      let children = sampler.livePIDs
      guard children.isEmpty else {
        throw Failure("sample left children: \(children.map(String.init).joined(separator: ", "))")
      }
      guard !isDirectory(rawSample), let bytes = try? fileBytes(rawSample), bytes > 0 else {
        throw Failure("sample did not produce raw text")
      }
      provenance["sample_sha256"] = try sha256(ofFile: rawSample)
      provenance["sample_bytes"] = bytes
      lifecycle["sample"]?.merge(exit.record) { _, new in new }
      lifecycle["sample"]?["natural_exit"] = true
    }

    private func validate(_ driverReport: [String: Any], pid: Int) throws {
      guard JSONValue.equals(try driverReport.fetch("schema"), 2) else { throw Failure("Driver report schema mismatch") }
      guard JSONValue.equals(try driverReport.fetch("terminal_pid"), pid) else {
        throw Failure("Driver report belongs to another process")
      }
      guard JSONValue.equals(try driverReport.fetch("columns"), columns),
            JSONValue.equals(try driverReport.fetch("rows"), rows) else {
        throw Failure("Driver report geometry mismatch")
      }
      guard let workload else { return }
      let names = try driverReport.objects("workloads").map { try $0.fetch("name") as? String }
      guard names == [workload] else { throw Failure("Driver reported a different workload than the selected profile") }
    }

    /// Ends the sampler, then the app, and records what it took. Returns a
    /// description of every process tree that could not be ended.
    private mutating func cleanupOwnedProcesses() -> [String] {
      var issues: [String] = []
      for (name, process) in [("sample", sampleProcess), ("app", appProcess)] {
        guard let process else { continue }
        var record = lifecycle[name] ?? [:]
        record["forced_cleanup"] = process.exit() == nil && !process.livePIDs().isEmpty
        let survivors = process.cleanup().map { Int($0) }
        record["cleanup_survivors"] = survivors
        if let exit = process.exit() { record["final_status"] = exit.record }
        lifecycle[name] = record
        if !survivors.isEmpty {
          issues.append("\(name) survivors: \(survivors.map(String.init).joined(separator: ", "))")
        }
      }
      return issues
    }
  }

  static let tests = [
    SelfTest.Case(name: "profile terminal: an early driver failure precedes a non-zero exit and cleanup is recorded") {
      try withFixtureApp(failingDriverScript("fixture profile driver failed")) { app, root in
        var profile = try Profile(app: app, output: root + "/profile", workload: "all")
        let message = try failureMessage("driver failure") { try profile.run() }
        try expect(message == "fixture profile driver failed", "got: \(message)")
        let report = try readJSONObject(root + "/profile/profile.json")
        try expect(report["passed"] as? Bool == false, "profile did not pass")
        try expect((report["failure"] as? String)?.contains("fixture profile driver failed") == true, "failure is recorded")
        let survivors = try report.object("lifecycle").object("app").fetch("cleanup_survivors") as? [Any]
        try expect(survivors?.isEmpty == true, "nothing survives")
      }
    },
    SelfTest.Case(name: "profile terminal: a cleanup survivor fails a completed profile, and the app is still cleaned up") {
      try withTemporaryDirectory("dev-profile-cleanup-") { root in
        var sampleCleanups = 0
        var appCleanups = 0
        var profile = Profile(output: root + "/profile")
        try FileManager.default.createDirectory(atPath: profile.output, withIntermediateDirectories: false)
        profile.sampleProcess = Owned(pid: 101, exit: { nil }, livePIDs: { [4242] }) {
          sampleCleanups += 1
          return [4242]
        }
        profile.appProcess = Owned(pid: 101, exit: { nil }, livePIDs: { [] }) {
          appCleanups += 1
          return []
        }
        profile.lifecycle = ["sample": ["pid": 101, "natural_exit": false], "app": ["pid": 101, "natural_exit": false]]
        profile.result["passed"] = true
        let message = try failureMessage("cleanup failure") { try profile.finish(after: nil) }
        try expect(message.contains("sample survivors: 4242"), "got: \(message)")
        try expect(sampleCleanups == 1 && appCleanups == 1, "each process is cleaned up once")
        let report = try readJSONObject(root + "/profile/profile.json")
        try expect(report["passed"] as? Bool == false, "profile did not pass")
        try expect((report["failure"] as? String)?.contains("sample survivors: 4242") == true, "failure is recorded")
        let sample = try report.object("lifecycle").object("sample")
        try expect((sample["cleanup_survivors"] as? [Int]) == [4242], "survivors are recorded")
        try expect(sample["forced_cleanup"] as? Bool == true, "cleanup is recorded as forced")
      }
    },
  ]
}

import Foundation

/// Runs one disposable, real interactive workload against a copied Terminal.app.
///
/// The app copy starts with a fixture as its shell, which relays the real
/// `files` or `codex` program. A native driver splits, drags, closes and
/// resizes panes while the window is recorded, and the run is judged from
/// what the fixtures recorded. `--prepare` checks the helpers and sends no
/// GUI input; a workload needs a frozen app, its provenance and a new report directory.
enum TUIStress {
  static let command = Command(
    name: "tui-stress",
    usage: "--prepare | --self-test | --installed --workload files|codex [--output DIR]"
      + " | --workload files|codex --app APP --output DIR --source-sha SHA --executable-sha256 SHA"
      + " [--files PATH] [--codex PATH]",
    summary: "Stress a frozen copy of the app with the real Files or Codex program.",
    run: run)

  private static let driverSource = Repository.path("tools/tui_stress/Driver.swift")
  private static let captureSource = Repository.path("tools/rendering_proof/Capture.swift")
  private static let installedApp = "~/Applications/Helge Terminal.app"

  /// What a workload run is given: the app to copy and the proof of which build it is.
  struct Plan {
    var workload: String
    var app: String
    var output: String
    var sourceSHA: String
    var executableSHA: String
    var installedReceipt: String?
    var workloadBinary: String?
  }

  static func run(_ arguments: [String]) throws {
    // The app and the runner start these two as programs of their own.
    if arguments.first == "fixture" { return try TUIStressFixture.main(Array(arguments.dropFirst())) }
    if arguments.first == "provider" { return try TUIStressProvider.main(Array(arguments.dropFirst())) }

    let options = try Options(
      arguments, flags: ["--prepare", "--self-test", "--installed"],
      values: ["--workload", "--app", "--output", "--source-sha", "--executable-sha256", "--files", "--codex"],
      command: command)
    guard options.positionals.isEmpty else { throw Failure.usage(command) }
    let workload = options.values["--workload"]
    if let workload, !["files", "codex"].contains(workload) { throw Failure("invalid argument: --workload \(workload)") }
    let prepare = options.flags.contains("--prepare")

    if options.flags.contains("--self-test") {
      guard workload == nil, !prepare else { throw Failure("--self-test cannot launch a workload") }
      return try pass(tests, otherwise: "TUI stress runner self-test failed")
    }
    var values = options.values
    var installedReceipt: String?
    if options.flags.contains("--installed") {
      guard ["--app", "--source-sha", "--executable-sha256"].allSatisfy({ values[$0] == nil }) else {
        throw Failure("--installed cannot be combined with explicit app provenance")
      }
      guard let workload else { throw Failure("--installed requires --workload") }
      let provenance = try installedProvenance(root: Repository.root, app: absolutePath(installedApp))
      values["--app"] = provenance.app
      values["--source-sha"] = provenance.sourceSHA
      values["--executable-sha256"] = provenance.executableSHA
      installedReceipt = provenance.receipt
      values["--output"] = values["--output"] ?? defaultOutput(workload)
    }

    let helpers = try prepareHelpers()
    if prepare {
      guard workload == nil else { throw Failure("--prepare cannot launch a workload") }
      print("PASS tui-stress preparation: helpers and isolated-PTY checks passed; no app, workload, capture, or GUI input launched")
      return
    }

    func required(_ name: String) throws -> String {
      guard let value = values[name] else { throw Failure("Missing \(name)") }
      return value
    }
    let plan = Plan(
      workload: try required("--workload"), app: absolutePath(try required("--app")),
      output: absolutePath(try required("--output")), sourceSHA: try required("--source-sha"),
      executableSHA: try required("--executable-sha256"), installedReceipt: installedReceipt,
      workloadBinary: values["--" + (workload ?? "")])
    try Session(plan, helpers: helpers).run()
    print("PASS real \(plan.workload) pane stress; inspect capture.mp4 and sampled PNGs visually"
      + " (marker classifications are intentionally inconclusive)")
  }

  private static func defaultOutput(_ workload: String) -> String {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    stamp.locale = Locale(identifier: "en_US_POSIX")
    return NSTemporaryDirectory() + "terminal-tui-\(workload)-\(stamp.string(from: Date()))-\(getpid())"
  }

  /// Runs tests and prints a PASS line for each. The first failure ends the run under `message`.
  private static func pass(_ cases: [SelfTest.Case], otherwise message: String) throws {
    for test in cases {
      do { try test.run() } catch { throw Failure("\(message): \(test.name): \(asFailure(error).message)") }
      print("PASS \(test.name)")
    }
  }

  /// The compiled driver and capture programs.
  struct Helpers {
    let driver: String
    let capture: String
  }

  /// Compiles the two native helpers and runs every check that needs no app:
  /// this runner's, the helpers' own, the fixture's inner PTY relay and the provider's.
  private static func prepareHelpers() throws -> Helpers {
    let directory = absolutePath(ProcessInfo.processInfo.environment["TERMINAL_TUI_STRESS_HELPERS"]
      ?? "~/.codex/artifacts/tui-stress/helpers")
    do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
    catch { throw Failure("cannot create \(directory): \(error.localizedDescription)") }
    try pass(tests, otherwise: "TUI stress runner self-test failed")
    let helpers = Helpers(driver: try compileHelper("TUIStressDriver", source: driverSource, into: directory),
                          capture: try compileHelper("TUIStressCapture", source: captureSource, into: directory))
    guard try runInherited([helpers.driver, "--self-test"]) else { throw Failure("TUI stress driver self-test failed") }
    guard try runInherited([helpers.capture, "--self-test"]) else { throw Failure("Capture self-test failed") }
    try pass(TUIStressFixture.lifecycleTests, otherwise: "Fixture self-test failed")
    try pass(TUIStressFixture.relayTests, otherwise: "Fixture PTY self-test failed")
    try pass(TUIStressProvider.tests, otherwise: "Local Codex provider self-test failed")
    return helpers
  }

  /// Compiles a helper unless the binary there was built from this exact
  /// source. Accessibility and Screen Recording are granted to a binary, so
  /// it is kept for as long as its source is unchanged.
  static func compileHelper(_ name: String, source: String, into directory: String,
                            compiler: [String] = ["/usr/bin/xcrun", "swiftc"]) throws -> String {
    let binary = directory + "/" + name
    let stamp = directory + "/\(name).build.json"
    let sourceHash = try sha256(ofFile: source)
    let previous = (try? readJSONObject(stamp)) ?? [:]
    if FileManager.default.isReadableFile(atPath: binary), previous["source_sha256"] as? String == sourceHash,
       previous["binary_sha256"] as? String == (try? sha256(ofFile: binary)) { return binary }

    let command = compiler + ["-parse-as-library", "-O", "-target", "arm64-apple-macosx15.0", source, "-o", binary]
    guard try runInherited(command) else { throw Failure("\(name) compilation failed") }
    guard try sha256(ofFile: source) == sourceHash else { throw Failure("\(name) source changed while compiling") }
    try writeJSON(["source_sha256": sourceHash, "binary_sha256": try sha256(ofFile: binary)], to: stamp)
    return binary
  }

  /// One file of an app bundle: what a symbolic link points at, or a regular file's content.
  enum BundleEntry: Equatable {
    case link(String)
    case file(sha256: String, bytes: Int)

    var json: [String: Any] {
      switch self {
      case .link(let target): return ["symlink": target]
      case .file(let hash, let bytes): return ["sha256": hash, "bytes": bytes]
      }
    }
  }

  /// Every file and link under a bundle, by relative path. Two equal
  /// manifests mean the copy is the bundle that was verified.
  static func bundleManifest(_ directory: String) throws -> [String: BundleEntry] {
    guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
      throw Failure("cannot list \(directory)")
    }
    var manifest: [String: BundleEntry] = [:]
    for case let relative as String in enumerator {
      let path = directory + "/" + relative
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory?: continue
      case .typeSymbolicLink?: manifest[relative] = .link(try FileManager.default.destinationOfSymbolicLink(atPath: path))
      default:
        manifest[relative] = .file(sha256: try sha256(ofFile: path), bytes: (attributes[.size] as? NSNumber)?.intValue ?? 0)
      }
    }
    return manifest
  }

  /// Polls until `body` returns a value, and fails with `message` after `seconds`.
  @discardableResult
  static func waitUntil<Value>(_ seconds: Double, _ message: String, _ body: () throws -> Value?) throws -> Value {
    let deadline = Clock.now + UInt64(seconds * 1_000_000_000)
    while true {
      if let value = try body() { return value }
      guard Clock.now < deadline else { throw Failure(message) }
      usleep(50_000)
    }
  }

  /// Waits for the capture to end. Its deadline counts from its launch, not
  /// from now: a 30-second recording outlasts a short driver exercise, and
  /// must still be given its whole duration plus a grace period.
  static func waitForCapture(launchedAt: Double, duration: Double = 30, grace: Double = 5,
                             clock: () -> Double, wait: (Double) -> ProcessTree.Exit?) throws -> ProcessTree.Exit {
    let deadline = launchedAt + duration + grace
    while true {
      let remaining = deadline - clock()
      guard remaining > 0 else { throw Failure("capture did not finish within its launch-relative deadline") }
      if let exit = wait(min(remaining, 0.05)) { return exit }
    }
  }

  /// The one installation receipt that vouches for an executable. None or
  /// several means the installed app cannot be tied to a source commit.
  static func matchingInstallationReceipt(_ receipts: [[String: Any]], executableSHA: String) throws -> [String: Any] {
    let matches = receipts.filter { receipt in
      guard receipt["executable_sha256"] as? String == executableSHA, let source = receipt["source_commit"] as? String else {
        return false
      }
      return source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }
    guard !matches.isEmpty else { throw Failure("no distribution installation receipt matches executable \(executableSHA)") }
    guard matches.count == 1 else {
      throw Failure("multiple distribution installation receipts match executable \(executableSHA)")
    }
    return matches[0]
  }

  /// The installed app and the commit it was built from, according to the
  /// distribution receipts under `reports/`. The app is only read.
  static func installedProvenance(root: String, app: String)
    throws -> (app: String, sourceSHA: String, executableSHA: String, receipt: String) {
    let executable = app + "/Contents/MacOS/Terminal"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw Failure("installed app executable is missing: \(executable)")
    }
    let reports = (try? FileManager.default.contentsOfDirectory(atPath: root + "/reports")) ?? []
    let receipts = try reports.filter { $0.hasPrefix("distribution-") && $0.hasSuffix("-evidence") }.sorted()
      .map { root + "/reports/\($0)/installation.json" }
      .filter { FileManager.default.fileExists(atPath: $0) }
      .map { path in try readJSONObject(path).merging(["_receipt_path": path]) { _, new in new } }
    let receipt = try matchingInstallationReceipt(receipts, executableSHA: try sha256(ofFile: executable))
    return (app, receipt["source_commit"] as? String ?? "", receipt["executable_sha256"] as? String ?? "",
            receipt["_receipt_path"] as? String ?? "")
  }

  /// Files in `directory` named with `prefix` and `suffix`, as sorted paths.
  private static func files(in directory: String, prefix: String, suffix: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
      .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted().map { directory + "/" + $0 }
  }

  static func eventFiles(_ directory: String) -> [String] { files(in: directory, prefix: "pane-", suffix: "-events.jsonl") }

  /// The pane numbers that fixtures announced when they started.
  static func metadataPanes(_ directory: String) throws -> [Int] {
    try files(in: directory, prefix: "pane-", suffix: ".json").filter { !$0.hasSuffix("-final.json") }.map { path in
      guard let pane = try readJSONObject(path)["pane"] as? Int else { throw Failure("\(path) names no pane") }
      return pane
    }.sorted()
  }

  /// The records of one fixture transcript.
  static func events(_ path: String) throws -> [[String: Any]] {
    guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
    return try data.split(separator: UInt8(ascii: "\n")).map { line in
      guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw Failure("\(path) holds a line that is not a JSON object")
      }
      return event
    }
  }

  private static func sawCanary(_ events: [[String: Any]], _ kind: String) -> Bool {
    events.contains { $0["event"] as? String == "workload_output_canary" && $0["kind"] as? String == kind }
  }

  /// Whether the real program drew its first interface.
  static func workloadStarted(_ events: [[String: Any]], _ workload: String) -> Bool {
    sawCanary(events, workload == "codex" ? "codex_banner" : "files_listing")
  }

  /// Whether the real program's own output reached the pane.
  static func workloadOutputReady(_ events: [[String: Any]], _ workload: String) -> Bool {
    sawCanary(events, workload == "codex" ? "codex_response" : "files_listing")
  }

  /// The final receipt of every pane that started, by pane number. Each must
  /// show that its fixture reaped the workload and ended without a failure.
  static func finalReceipts(_ directory: String, workload: String) throws -> [String: Any] {
    let panes = try metadataPanes(directory)
    guard !panes.isEmpty else { throw Failure("no workload pane metadata was recorded") }
    var receipts: [String: Any] = [:]
    for pane in panes {
      let path = directory + "/pane-\(pane)-final.json"
      guard FileManager.default.fileExists(atPath: path) else { throw Failure("missing final receipt for pane \(pane)") }
      let receipt = try readJSONObject(path)
      guard receipt["pane"] as? Int == pane, receipt["workload"] as? String == workload else {
        throw Failure("receipt pane mismatch for pane \(pane)")
      }
      guard receipt["child_alive"] as? Bool == false else { throw Failure("pane \(pane) retained a child after cleanup") }
      if let failure = receipt["failure"], !(failure is NSNull) {
        throw Failure("pane \(pane) wrapper reported failure: \(failure)")
      }
      receipts[String(pane)] = receipt
    }
    guard receipts.count == panes.count else { throw Failure("final receipt count does not match pane metadata") }
    return receipts
  }

  /// The real program to run: the one named on the command line, or the usual installation.
  static func workloadBinary(_ workload: String, explicit: String?) throws -> String {
    if let explicit { return try realPath(explicit) }
    let candidate = absolutePath(workload == "codex"
      ? "~/.bun/install/global/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
      : "~/.local/bin/files")
    guard FileManager.default.isExecutableFile(atPath: candidate) else {
      throw Failure("Pass --\(workload) with the actual \(workload) executable")
    }
    return candidate
  }

  /// What one pane's transcript proves about it.
  struct PaneCheck {
    let childStarted: Bool
    let workloadStarted: Bool
    let sizes: [[Int]]
    let filesRefreshComplete: Bool
    let outputVisible: Bool
    let finalReceiptBeforeCleanup: Bool
    var sizeChanged: Bool { sizes.count >= 2 }

    init(events: [[String: Any]], workload: String, directory: String) {
      func has(_ event: String) -> Bool { events.contains { $0["event"] as? String == event } }
      var seen: [[Int]] = []
      for event in events where event["event"] as? String == "winsize" {
        let size = [event["rows"] as? Int ?? 0, event["columns"] as? Int ?? 0]
        if !seen.contains(size) { seen.append(size) }
      }
      childStarted = has("child_started")
      workloadStarted = TUIStress.workloadStarted(events, workload)
      sizes = seen
      filesRefreshComplete = workload != "files" || has("files_refresh_complete")
      outputVisible = workloadOutputReady(events, workload)
      finalReceiptBeforeCleanup = (events.first?["pane"] as? Int).map {
        FileManager.default.fileExists(atPath: directory + "/pane-\($0)-final.json")
      } ?? false
    }

    var json: [String: Any] {
      ["child_started": childStarted, "real_workload_started": workloadStarted, "pty_sizes": sizes,
       "pty_size_changed": sizeChanged, "files_refresh_complete": filesRefreshComplete,
       "real_workload_output_visible": outputVisible, "final_receipt_before_runner_cleanup": finalReceiptBeforeCleanup]
    }
  }

  /// Fails unless the panes together show the stress run did what it set
  /// out to do. The driver closes one Codex pane on purpose, so exactly one
  /// has its final receipt before cleanup and is excused from showing a response.
  static func judge(_ checks: [PaneCheck], workload: String) throws {
    if workload == "codex" {
      let closed = checks.filter(\.finalReceiptBeforeCleanup), live = checks.filter { !$0.finalReceiptBeforeCleanup }
      guard closed.count == 1 else {
        throw Failure("expected exactly one deliberately closed Codex pane, found \(closed.count)")
      }
      guard live.count == 3 else { throw Failure("expected three live Codex panes, found \(live.count)") }
      guard closed.allSatisfy({ $0.childStarted && $0.workloadStarted && !$0.sizes.isEmpty }) else {
        throw Failure("closed Codex pane lacked child/banner/WINCH evidence")
      }
      guard live.allSatisfy({ $0.childStarted && $0.workloadStarted && $0.sizeChanged && $0.outputVisible }) else {
        throw Failure("live Codex pane lacked child/banner/WINCH/response evidence")
      }
    } else {
      guard checks.allSatisfy({ $0.childStarted && $0.workloadStarted && $0.sizeChanged && $0.filesRefreshComplete }) else {
        throw Failure("one or more real workload panes lacked child/readiness/WINCH evidence")
      }
      guard checks.allSatisfy(\.outputVisible) else {
        throw Failure("one or more panes lacked real workload output after the stress run")
      }
    }
  }

  /// One workload run: the frozen app copy, everything launched around it, and the report.
  final class Session {
    private let plan: Plan
    private let helpers: Helpers
    private let binary: String
    private let fixtureCWD: String
    private let executable: String
    private var environment: [String: String?]
    private var processes: [ProcessTree] = []
    private var report: [String: Any]
    private var output: String { plan.output }

    /// Checks the provenance, creates the report directory and freezes the
    /// app into it. Nothing has been launched when this fails, and no report is written.
    init(_ plan: Plan, helpers: Helpers) throws {
      self.plan = plan
      self.helpers = helpers
      guard plan.sourceSHA.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
        throw Failure("Invalid source SHA")
      }
      guard !FileManager.default.fileExists(atPath: plan.output) else { throw Failure("Use a fresh --output directory") }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: plan.app, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw Failure("App must be a Terminal.app bundle")
      }
      guard !plan.output.hasPrefix(plan.app + "/") else { throw Failure("Output cannot be inside the input app") }
      let input = plan.app + "/Contents/MacOS/Terminal"
      guard FileManager.default.isExecutableFile(atPath: input) else { throw Failure("Missing app executable") }
      guard try sha256(ofFile: input) == plan.executableSHA else {
        throw Failure("Executable SHA does not match supplied frozen provenance")
      }
      binary = try workloadBinary(plan.workload, explicit: plan.workloadBinary)
      fixtureCWD = plan.output + "/fixture-cwd"
      let frozen = plan.output + "/Frozen Terminal.app"
      executable = frozen + "/Contents/MacOS/Terminal"
      let shell = plan.output + "/fixture-shell"
      let manifest: [String: BundleEntry]
      do {
        try Self.writeFixtureDirectory(fixtureCWD)
        try Tool.writeLauncher(at: shell, subcommand: ["tui-stress", "fixture"])
        manifest = try bundleManifest(plan.app)
        try FileManager.default.copyItem(atPath: plan.app, toPath: frozen)
        guard try manifest == bundleManifest(plan.app), try manifest == bundleManifest(frozen) else {
          throw Failure("Bundle changed while being copied")
        }
      } catch { throw asFailure(error) }
      guard try sha256(ofFile: executable) == plan.executableSHA else { throw Failure("Frozen executable provenance mismatch") }

      environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell, "TERM": "xterm-256color", "COLORTERM": "truecolor",
        "LANG": nil, "LC_ALL": nil, "LC_CTYPE": nil,
        "NO_COLOR": nil, "CLICOLOR": nil, "CLICOLOR_FORCE": nil, "FORCE_COLOR": nil,
        "TERMINAL_TUI_STRESS_DIRECTORY": plan.output, "TERMINAL_TUI_STRESS_WORKLOAD": plan.workload,
        "TERMINAL_TUI_STRESS_CWD": fixtureCWD, "TERMINAL_TUI_STRESS_EXECUTABLE": executable,
        "TERMINAL_TUI_STRESS_\(plan.workload.uppercased())": binary,
      ]
      if plan.workload == "codex" {
        let state = plan.output + "/codex-private-state"
        try Self.createPrivateDirectory(state)
        environment["TERMINAL_TUI_STRESS_CODEX_DIRECTORY"] = state
      }
      report = [
        "source_sha": plan.sourceSHA, "workload": plan.workload, "workload_executable": binary,
        "workload_sha256": try sha256(ofFile: binary), "input_app": plan.app, "frozen_app": frozen,
        "executable_sha256": plan.executableSHA,
        "helper_sha256": [
          "Driver.swift": try sha256(ofFile: driverSource), "TUIStressDriver": try sha256(ofFile: helpers.driver),
          "Capture.swift": try sha256(ofFile: captureSource), "TUIStressCapture": try sha256(ofFile: helpers.capture),
          // The fixture and the provider are this tool.
          "dev": try sha256(ofFile: Tool.executable),
        ],
        "capture_marker_interpretation":
          "inconclusive for real Codex/Files workloads; video and PNGs are retained only for visual inspection",
        "verified_bundle_manifest": manifest.mapValues(\.json),
      ]
      if let receipt = plan.installedReceipt { report["installed_receipt"] = receipt }
    }

    private static func createPrivateDirectory(_ path: String) throws {
      do {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
      } catch { throw Failure("cannot create \(path): \(error.localizedDescription)") }
    }

    /// The public files the workload shows. `files` lists them; Codex starts among them.
    private static func writeFixtureDirectory(_ directory: String) throws {
      try createPrivateDirectory(directory + "/nested")
      let contents = [
        "README.md": "# TUI stress fixture\n\n猫\n", "example.swift": "print(\"TUI_STRESS_SOURCE\")\n",
        "TUI_STRESS_FILES_LISTING_READY": "stable real-files readiness entry\n", "nested/unicode-猫.txt": "fixture\n",
      ]
      for (name, text) in contents { try text.write(toFile: directory + "/" + name, atomically: false, encoding: .utf8) }
    }

    /// Runs the workload and writes `analysis.json` whatever happens. A
    /// failed cleanup or a bad final receipt fails a run that otherwise passed.
    func run() throws {
      var failure: Failure?
      do {
        try exercise()
        report["passed"] = true
      } catch {
        failure = asFailure(error)
        report["passed"] = false
        report["error"] = "Failure: \(failure?.message ?? "")"
      }
      try finish()
      if let failure { throw failure }
    }

    private func launch(_ command: [String], environment: [String: String?] = [:], log: String) throws -> ProcessTree {
      let process = try ProcessTree(command, environment: environment, output: .log(output + "/" + log))
      processes.append(process)
      return process
    }

    private func exercise() throws {
      if plan.workload == "codex" { try startProvider() }
      let app = try launch([executable, "--working-directory", fixtureCWD, "--font-size", "14"],
                           environment: environment, log: "app.log")
      try waitUntil(15, "app exited before first fixture pane started") { () -> Bool? in
        guard app.wait(seconds: 0.01) == nil else { throw Failure("app exited before fixture startup") }
        return FileManager.default.fileExists(atPath: output + "/pane-0.json") ? true : nil
      }
      try waitUntil(12, "real workload did not reach its initial visible UI state") { () -> Bool? in
        guard let first = eventFiles(output).first else { return nil }
        return try workloadStarted(events(first), plan.workload) ? true : nil
      }

      let pid = String(app.pid)
      let prepare = try launch([helpers.driver, "prepare", pid, output], environment: environment, log: "driver-prepare.log")
      guard prepare.wait(seconds: 15)?.succeeded == true else { throw Failure("owned-window preparation failed") }
      let identity = try readJSONObject(output + "/identity.json")
      guard identity["pid"] as? Int == Int(app.pid), identity["executable"] as? String == executable,
            let window = identity["window"] as? Int else { throw Failure("driver prepared the wrong app") }

      let captureStarted = Self.seconds()
      let capture = try launch([helpers.capture, String(window), output, pid, "30"], log: "capture.log")
      try waitUntil(10, "capture failed to become ready") { () -> Bool? in
        guard capture.wait(seconds: 0.01) == nil else { throw Failure("capture exited before readiness") }
        return FileManager.default.fileExists(atPath: output + "/ready") ? true : nil
      }
      let driver = try launch([helpers.driver, "exercise", pid, output], environment: environment, log: "driver-exercise.log")
      guard driver.wait(seconds: 28)?.succeeded == true else { throw Failure("native driver exercise timed out or failed") }
      guard app.wait(seconds: 0.01) == nil else { throw Failure("app exited during stress exercise") }
      let captured = try waitForCapture(launchedAt: captureStarted, clock: Self.seconds) { capture.wait(seconds: $0) }
      guard captured.succeeded else { throw Failure("capture did not finish cleanly") }

      try judgeArtefacts(identity: identity)
    }

    private static func seconds() -> Double { Double(Clock.now) / 1_000_000_000 }

    /// Starts the loopback provider and points Codex at the port it reports.
    private func startProvider() throws {
      let portFile = output + "/provider.json"
      let provider = try ProcessTree(
        [Tool.executable, "tui-stress", "provider"],
        environment: [
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE": portFile,
          "TERMINAL_TUI_STRESS_PROVIDER_SLOW_MS": "150", "TERMINAL_TUI_STRESS_PROVIDER_MAX_REQUESTS": "8",
          "TERMINAL_TUI_STRESS_PROVIDER_LIFETIME_SECONDS": "90",
        ],
        output: .logs(output: output + "/provider.stdout", errors: output + "/provider.stderr"))
      processes.append(provider)
      let info = try waitUntil(10, "loopback Codex provider did not become ready") { () -> [String: Any]? in
        guard provider.wait(seconds: 0.01) == nil else { throw Failure("loopback Codex provider exited before readiness") }
        // The file is rewritten in place, so a read can catch it half written.
        guard let candidate = try? readJSONObject(portFile), candidate["status"] as? String == "listening" else { return nil }
        return candidate
      }
      guard let port = info["port"] as? Int else { throw Failure("loopback Codex provider reported no port") }
      environment["TERMINAL_TUI_STRESS_CODEX_BASE_URL"] = "http://127.0.0.1:\(port)/v1"
      report["provider_initial"] = info
    }

    /// Judges what the driver, the fixtures, the capture and the provider left in the report directory.
    private func judgeArtefacts(identity: [String: Any]) throws {
      let finalScreen = try readJSONObject(output + "/final-screen.json")
      guard let panes = finalScreen["panes"] as? [[String: Any]],
            panes.allSatisfy({ $0["actual_workload_marker_visible"] as? Bool == true }) else {
        throw Failure("final screen invariant was not recorded")
      }
      let transcripts = eventFiles(output)
      guard !transcripts.isEmpty else { throw Failure("missing fixture event transcripts") }
      let records = try transcripts.map { (name: URL(fileURLWithPath: $0).lastPathComponent, events: try events($0)) }
      let metadata = try metadataPanes(output)
      let eventPanes = records.compactMap { $0.events.first?["pane"] as? Int }.sorted()
      guard metadata.count == 4 else {
        throw Failure("expected exactly four pane metadata records, found \(metadata.count)")
      }
      guard metadata == eventPanes, eventPanes.count == records.count, Set(eventPanes).count == 4 else {
        throw Failure("pane metadata and event transcripts do not have matching four-pane identities")
      }
      let checks = records.map { (name: $0.name, check: PaneCheck(events: $0.events, workload: plan.workload, directory: output)) }
      try judge(checks.map(\.check), workload: plan.workload)

      let summary = try readJSONObject(output + "/summary.json")
      guard summary["recording_valid"] as? Bool == true else { throw Failure("capture did not preserve a nonempty video") }
      report["identity"] = identity
      report["final_screen"] = finalScreen
      report["pane_checks"] = Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.check.json) })
      report["capture_summary"] = summary
      guard plan.workload == "codex" else { return }
      let provider = try readJSONObject(output + "/provider.json")
      let responses = (provider["requests"] as? [[String: Any]] ?? []).filter {
        $0["method"] as? String == "POST" && $0["path"] as? String == "/v1/responses" && $0["status"] as? Int == 200
      }.count
      guard responses >= 4 else {
        throw Failure("expected a local provider response for each of four created Codex panes, got \(responses)")
      }
      report["provider_requests_before_cleanup"] = provider
    }

    /// Ends everything this run launched, newest first, then completes and
    /// writes the report. The fixtures write their final receipts as the app closes their panes.
    private func finish() throws {
      let cleanup = processes.reversed().map { (pid: Int($0.pid), survivors: $0.cleanup().map { Int($0) }) }
      report["cleanup"] = cleanup.map { ["pid": $0.pid, "survivors": $0.survivors] as [String: Any] }
      var receiptFailure: Failure?
      do {
        report["final_receipts"] = try finalReceipts(output, workload: plan.workload)
      } catch {
        receiptFailure = asFailure(error)
        report["passed"] = false
        report["cleanup_receipt_error"] = "Failure: \(receiptFailure?.message ?? "")"
      }
      var hashes: [String: String] = [:]
      for name in ["identity.json", "input-events.json", "final-screen.json", "frames.jsonl", "capture.mp4", "summary.json"] {
        if let hash = try? sha256(ofFile: output + "/" + name) { hashes[name] = hash }
      }
      report["artefact_sha256"] = hashes
      if FileManager.default.fileExists(atPath: output) { try writeJSON(report, to: output + "/analysis.json") }
      if let receiptFailure { throw receiptFailure }
      guard cleanup.allSatisfy(\.survivors.isEmpty) else { throw Failure("owned diagnostic processes survived cleanup") }
    }
  }

  static let tests = [
    SelfTest.Case(name: "tui-stress capture deadline: a 30-second capture may finish after a short driver exercise") {
      var now = 6.0
      let exit = try waitForCapture(launchedAt: 0, duration: 30, grace: 5, clock: { now }) { seconds in
        now += seconds
        return now >= 30 ? ProcessTree.Exit(code: 0, signalled: false) : nil
      }
      try expect(exit.succeeded, "a capture that finished after the driver is accepted")
      try expect((30...35).contains(now), "the wait stays within the launch-relative deadline, ended at \(now)")
    },
    SelfTest.Case(name: "tui-stress capture deadline: a capture that never ends fails at its deadline") {
      var now = 0.0
      do {
        _ = try waitForCapture(launchedAt: 0, clock: { now }) { now += $0; return nil }
        throw Failure("a capture that never ended was accepted")
      } catch let failure as Failure {
        try expect(failure.message.contains("launch-relative deadline"), "got: \(failure.message)")
        try expect(now >= 35 && now < 35.1, "the wait ends at 35 seconds, ended at \(now)")
      }
    },
    SelfTest.Case(name: "tui-stress installed provenance: one matching receipt required") {
      let commit = String(repeating: "a", count: 40)
      let receipt: [String: Any] = ["source_commit": commit, "executable_sha256": "fixture"]
      let known = try matchingInstallationReceipt([receipt, ["source_commit": commit, "executable_sha256": "other"]],
                                                  executableSHA: "fixture")
      try expect(known["source_commit"] as? String == commit, "the matching record is selected")
      for (receipts, reason) in [([], "no distribution"), ([receipt, receipt], "multiple distribution"),
                                 ([["source_commit": "abc", "executable_sha256": "fixture"]], "no distribution")] {
        do {
          _ = try matchingInstallationReceipt(receipts, executableSHA: "fixture")
          throw Failure("\(receipts.count) receipts were accepted")
        } catch let failure as Failure {
          try expect(failure.message.hasPrefix(reason), "got: \(failure.message)")
        }
      }
    },
    SelfTest.Case(name: "tui-stress helpers: a helper is compiled once per source") {
      try withTemporaryDirectory("dev-tui-stress-helpers-") { directory in
        let source = directory + "/Helper.swift", count = directory + "/count"
        try "first".write(toFile: source, atomically: true, encoding: .utf8)
        // Stands in for the compiler: its last argument is the output path.
        let compiler = directory + "/compiler"
        try writeExecutable(compiler, script: "echo run >> '\(count)'; for last; do :; done; echo binary > \"$last\"")
        func runs() -> Int { ((try? String(contentsOfFile: count, encoding: .utf8)) ?? "").split(separator: "\n").count }
        let binary = try compileHelper("Helper", source: source, into: directory, compiler: [compiler])
        try expect(binary == directory + "/Helper" && runs() == 1, "the first call compiles")
        _ = try compileHelper("Helper", source: source, into: directory, compiler: [compiler])
        try expect(runs() == 1, "an unchanged source is not compiled again")
        try "second".write(toFile: source, atomically: true, encoding: .utf8)
        _ = try compileHelper("Helper", source: source, into: directory, compiler: [compiler])
        try expect(runs() == 2, "a changed source is compiled again")
        try "tampered".write(toFile: binary, atomically: true, encoding: .utf8)
        _ = try compileHelper("Helper", source: source, into: directory, compiler: [compiler])
        try expect(runs() == 3, "a binary that is not the recorded one is replaced")
      }
    },
    SelfTest.Case(name: "tui-stress bundle manifest: files, links and nested directories are compared") {
      try withTemporaryDirectory("dev-tui-stress-bundle-") { directory in
        let bundle = directory + "/A.app", copy = directory + "/B.app"
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/.hidden", withIntermediateDirectories: true)
        try "binary".write(toFile: bundle + "/Contents/Terminal", atomically: true, encoding: .utf8)
        try "secret".write(toFile: bundle + "/Contents/.hidden/file", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: bundle + "/Current", withDestinationPath: "Contents")
        let manifest = try bundleManifest(bundle)
        try expect(manifest["Current"] == .link("Contents"), "a link is recorded by its target")
        try expect(manifest["Contents/Terminal"]
                     == .file(sha256: sha256Hex(Data("binary".utf8)), bytes: 6),
                   "a file is recorded by hash and size: \(String(describing: manifest["Contents/Terminal"]))")
        try expect(manifest.count == 3, "directories are left out and hidden files kept: \(manifest.keys.sorted())")
        try FileManager.default.copyItem(atPath: bundle, toPath: copy)
        try expect(try bundleManifest(copy) == manifest, "a copy has the same manifest")
        try "changed".write(toFile: copy + "/Contents/Terminal", atomically: true, encoding: .utf8)
        try expect(try bundleManifest(copy) != manifest, "a changed file changes the manifest")
      }
    },
    SelfTest.Case(name: "tui-stress verdict: Files panes need a resize and a refresh, Codex allows one closed pane") {
      try withTemporaryDirectory("dev-tui-stress-verdict-") { directory in
        func transcript(pane: Int, kinds: [String], sizes: Int, refresh: Bool = false) -> [[String: Any]] {
          [["event": "child_started", "pane": pane]]
            + (0..<sizes).map { ["event": "winsize", "pane": pane, "rows": 24 + $0, "columns": 80] }
            + kinds.map { ["event": "workload_output_canary", "pane": pane, "kind": $0] }
            + (refresh ? [["event": "files_refresh_complete", "pane": pane]] : [])
        }
        func check(_ events: [[String: Any]], _ workload: String) -> PaneCheck {
          PaneCheck(events: events, workload: workload, directory: directory)
        }
        func rejected(_ checks: [PaneCheck], _ workload: String) -> String? {
          do { try judge(checks, workload: workload); return nil } catch { return asFailure(error).message }
        }
        let files = (0..<4).map { check(transcript(pane: $0, kinds: ["files_listing"], sizes: 2, refresh: true), "files") }
        try expect(rejected(files, "files") == nil, "four resized, refreshed Files panes pass")
        let still = check(transcript(pane: 3, kinds: ["files_listing"], sizes: 1, refresh: true), "files")
        try expect(rejected(Array(files.dropLast()) + [still], "files")?.contains("WINCH") == true,
                   "a pane that never changed size fails")

        FileManager.default.createFile(atPath: directory + "/pane-3-final.json", contents: nil)
        let live = (0..<3).map { check(transcript(pane: $0, kinds: ["codex_banner", "codex_response"], sizes: 2), "codex") }
        let closed = check(transcript(pane: 3, kinds: ["codex_banner"], sizes: 1), "codex")
        try expect(rejected(live + [closed], "codex") == nil, "three live panes and one closed pane pass")
        try expect(rejected(live, "codex")?.contains("exactly one deliberately closed") == true, "no closed pane fails")
        let silent = check(transcript(pane: 2, kinds: ["codex_banner"], sizes: 2), "codex")
        try expect(rejected(Array(live.dropLast()) + [silent, closed], "codex")?.contains("response evidence") == true,
                   "a live pane without the response fails")
      }
    },
  ]
}

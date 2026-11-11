import Foundation

/// The disposable `SHELL` replacement of a TUI stress run: `dev tui-stress fixture`.
///
/// It relays a real workload through an inner PTY of its own, forwarding
/// input, output and geometry, and records what passed as bounded binary
/// events. The runner judges a run from those records.
final class TUIStressFixture {
  static let outputLimit = 4 * 1024 * 1024
  static let readLimit = 16 * 1024
  static let reapGraceSeconds = 0.5
  static let reapKillSeconds = 1.0
  static let canaryTailLimit = 8192

  /// The numbered event records of one pane, one JSON object per line.
  final class EventLog {
    let pane: Int
    private var sequence = 0
    private let write: (Data) -> Void

    init(pane: Int, write: @escaping (Data) -> Void) {
      self.pane = pane
      self.write = write
    }

    func record(_ event: String, _ values: [String: Any] = [:]) {
      sequence += 1
      // The driver stamps its input events with ProcessInfo.systemUptime, the same clock.
      var entry: [String: Any] = ["sequence": sequence, "event": event, "pane": pane,
                                  "host_time": Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000]
      entry.merge(values) { _, new in new }
      guard let line = try? compactJSON(entry) else { return }
      write(line + Data("\n".utf8))
    }
  }

  private let environment: [String: String]
  private let directory: String
  private let workload: String
  private let cwd: String
  private let events: EventLog
  private var eventFile: Int32 = -1
  private var terminal: PseudoTerminal?
  private var child: pid_t?
  private var childExitRecorded = false
  private var stopping = false
  private var resizePending = true
  private var finalEmitted = false
  private var outputBytes = 0
  private var tail = Data()
  private var canaries: Set<String> = []

  /// Runs the fixture, or its lifecycle tests with `--self-test`. Any other
  /// arguments are the app's shell arguments and mean nothing here.
  static func main(_ arguments: [String]) throws {
    if arguments == ["--self-test"] {
      for test in lifecycleTests {
        try test.run()
        print("PASS \(test.name)")
      }
      return
    }
    try TUIStressFixture(environment: ProcessInfo.processInfo.environment).run()
  }

  init(environment: [String: String]) throws {
    func required(_ key: String) throws -> String {
      guard let value = environment[key] else { throw Failure("missing environment variable \(key)") }
      return value
    }
    self.environment = environment
    directory = try realPath(required("TERMINAL_TUI_STRESS_DIRECTORY"))
    workload = try required("TERMINAL_TUI_STRESS_WORKLOAD")
    cwd = try realPath(required("TERMINAL_TUI_STRESS_CWD"))
    guard ["codex", "files"].contains(workload) else { throw Failure("unsupported workload") }
    let pane = try claimPaneNumber(counter: directory + "/pane-counter", below: 8)
    let path = directory + "/pane-\(pane)-events.jsonl"
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else { throw Failure(SystemFailure("open \(path)").message) }
    eventFile = descriptor
    events = EventLog(pane: pane) { try? writeAll(descriptor, $0) }
    Interruption.takeOver(resize: true)
    try writeMetadata()
  }

  /// A fixture that only owns `child`, for testing how a child is reaped and what a workload is given.
  private init(reaping child: pid_t, events: EventLog, environment: [String: String] = [:]) {
    self.environment = environment
    directory = ""
    workload = environment["TERMINAL_TUI_STRESS_WORKLOAD"] ?? "files"
    cwd = ""
    self.events = events
    self.child = child
  }

  private var pane: Int { events.pane }
  private var isStopping: Bool { stopping || Interruption.stopRequested }

  /// Relays the workload until it is told to stop, then reaps the child and
  /// writes the final receipt, whatever went wrong on the way.
  func run() throws {
    var failure: Failure?
    do {
      guard try runInherited(["/bin/stty", "raw", "-echo"]) else {
        throw Failure("could not configure fixture terminal")
      }
      if workload == "files" { try runFiles() } else { try runCodex() }
    } catch { failure = Failure(wrapping: error) }
    do { try terminateAndReap() } catch { failure = failure ?? Failure(wrapping: error) }
    closeTerminal()
    do { try writeFinal(failure: failure) } catch { failure = failure ?? Failure(wrapping: error) }
    close(eventFile)
    if let failure { throw failure }
  }

  private func executable(_ name: String) throws -> String {
    let key = "TERMINAL_TUI_STRESS_\(name.uppercased())"
    guard let value = environment[key] else { throw Failure("missing environment variable \(key)") }
    let path = try realPath(value)
    guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure("\(name) is not executable") }
    return path
  }

  private func command() throws -> [String] {
    if workload == "files" { return [try executable("files"), "--color=always", "--no-git", "-L", "3", cwd] }
    let baseURL = try codexBaseURL()
    return [try executable("codex"), "--no-daemon", "--disable", "plugin_discovery_prefetch", "--disable", "remote_plugin",
            "--disable", "recommended_plugins", "--disable", "plugins", "-C", cwd,
            "-c", "model_provider=\"fixture\"", "-c", "model=\"fixture-model\"",
            "-c", "model_providers.fixture.name=\"Terminal fixture\"",
            "-c", "model_providers.fixture.base_url=\"\(baseURL)\"",
            "-c", "model_providers.fixture.env_key=\"DUMMY_CODEX_UI_KEY\"",
            "-c", "model_providers.fixture.wire_api=\"responses\"",
            "-c", "model_providers.fixture.requires_openai_auth=false",
            "-c", "model_providers.fixture.supports_websockets=false", "Render fixture output"]
  }

  private func childEnvironment() throws -> [String: String?] {
    var result: [String: String?] = [
      "TERM": environment["TERM"] ?? "xterm-256color", "COLORTERM": environment["COLORTERM"] ?? "truecolor",
      "TERM_PROGRAM": environment["TERM_PROGRAM"] ?? "HelgeTerminal", "NO_COLOR": nil,
      "CLICOLOR": "1", "CLICOLOR_FORCE": "1", "FORCE_COLOR": "1",
    ]
    guard workload == "codex" else { return result }
    guard let root = environment["TERMINAL_TUI_STRESS_CODEX_DIRECTORY"] else {
      throw Failure("missing environment variable TERMINAL_TUI_STRESS_CODEX_DIRECTORY")
    }
    let home = try realPath(root) + "/pane-\(pane)"
    do { try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true) }
    catch { throw Failure("cannot create \(home): \(error.localizedDescription)") }
    // CODEX_HOME is scoped to the Codex child only; nothing else in the run sees it.
    result["CODEX_HOME"] = home
    result["CODEX_DISABLE_DAEMON"] = "1"
    result["DUMMY_CODEX_UI_KEY"] = "fixture-not-a-secret"
    return result
  }

  /// The provider address, accepted only when it is the loopback fixture, so
  /// Codex can never be pointed at a real model from here.
  private func codexBaseURL() throws -> String {
    guard let url = environment["TERMINAL_TUI_STRESS_CODEX_BASE_URL"] else {
      throw Failure("missing environment variable TERMINAL_TUI_STRESS_CODEX_BASE_URL")
    }
    guard url.range(of: #"^http://127\.0\.0\.1:\d+/v1$"#, options: .regularExpression) != nil, !url.contains("\n") else {
      throw Failure("Codex fixture provider must be a local /v1 endpoint")
    }
    return url
  }

  private func spawnWorkload() throws {
    let command = try command()
    let terminal = try PseudoTerminal()
    // The child leads its own session with the inner PTY as controlling
    // terminal, so a size change reaches it as SIGWINCH and its process group is its own PID.
    let pid = try spawnChild(command, environment: childEnvironment(), directory: cwd,
                             terminal: terminal.slavePath, leadsSession: true)
    terminal.releaseSlave()
    self.terminal = terminal
    child = pid
    childExitRecorded = false
    resizePending = true
    events.record("child_started", ["pid": Int(pid), "executable_sha256": try sha256(ofFile: command[0]),
                                    "command": command.map { $0 == cwd ? "<fixture-cwd>" : $0 }])
  }

  private func runCodex() throws {
    try spawnWorkload()
    try relayUntilExit()
  }

  /// A listing ends at once, so it is run again and again to keep the pane busy.
  private func runFiles() throws {
    while !isStopping {
      try spawnWorkload()
      try relayUntilExit()
      if isStopping { break }
      events.record("files_refresh_complete")
      usleep(180_000)
    }
  }

  private func relayUntilExit() throws {
    var failure: Error?
    do { try relay() } catch { failure = error }
    closeTerminal()
    try terminateAndReap()
    if let failure { throw failure }
  }

  private func relay() throws {
    guard let terminal else { return }
    var status: ChildStatus?
    do {
      var innerClosed = false
      while !isStopping, status == nil, !innerClosed {
        if !finalEmitted, FileManager.default.fileExists(atPath: directory + "/final-output") { try emitFinalMarker() }
        if Interruption.takeResize() { resizePending = true }
        if resizePending { try applyResize() }
        let ready = readable([STDIN_FILENO, terminal.master], milliseconds: 80)
        if ready.contains(STDIN_FILENO) { try forwardInput() }
        if ready.contains(terminal.master) { innerClosed = try !forwardOutput() }
        status = try childStatus()
      }
    } catch let error as SystemFailure where error.code == EIO {
      // The outer terminal or the inner one went away; what the child left is still recorded.
      status = try childStatus()
    }
    try drainOutput()
    if let status { recordChildExit(status) }
  }

  private func childStatus() throws -> ChildStatus? {
    guard let child else { return nil }
    do { return try reapIfEnded(child) }
    catch let error as SystemFailure where error.code == ECHILD {
      throw Failure("inner workload process was reaped unexpectedly")
    }
  }

  private func applyResize() throws {
    resizePending = false
    guard let size = terminalSize(of: STDOUT_FILENO) else { throw Failure("fixture must run on a terminal PTY") }
    guard (1...4096).contains(size.rows), (1...4096).contains(size.columns) else {
      throw Failure("invalid outer PTY geometry")
    }
    try terminal?.setSize(rows: size.rows, columns: size.columns)
    events.record("winsize", ["rows": size.rows, "columns": size.columns, "child_pid": child.map { Int($0) } ?? NSNull()])
  }

  /// Passes typed input on to the workload. End of input means the fixture's
  /// own terminal is gone, and the fixture stops: a terminal at end of input
  /// stays readable, and the relay would otherwise never wait again.
  private func forwardInput() throws {
    guard let terminal else { return }
    switch try readAvailable(STDIN_FILENO, limit: Self.readLimit) {
    case .bytes(let bytes):
      try writeAll(terminal.master, bytes)
      recordBytes("input", bytes)
    case .endOfFile: stopping = true
    case .nothing: break
    }
  }

  /// Returns false once the inner terminal reports it is closed, by an error
  /// or by end of input: the workload has closed its end.
  private func forwardOutput() throws -> Bool {
    guard let terminal else { return false }
    do {
      switch try readAvailable(terminal.master, limit: Self.readLimit) {
      case .bytes(let bytes): try emit(bytes)
      case .endOfFile: return false
      case .nothing: break
      }
      return true
    } catch let error as SystemFailure where error.code == EIO {
      return false
    }
  }

  private func drainOutput() throws {
    guard let terminal else { return }
    while !readable([terminal.master], milliseconds: 0).isEmpty {
      do {
        guard case .bytes(let bytes) = try readAvailable(terminal.master, limit: Self.readLimit) else { return }
        try emit(bytes)
      } catch let error as SystemFailure where error.code == EIO {
        return
      }
    }
  }

  /// Passes workload output on to the outer terminal and records it. The
  /// transcript is bounded so that a runaway workload cannot fill the disk.
  private func emit(_ bytes: Data) throws {
    outputBytes += bytes.count
    guard outputBytes <= Self.outputLimit else { throw Failure("workload output exceeded \(Self.outputLimit) bytes") }
    try writeAll(STDOUT_FILENO, bytes)
    recordBytes("output", bytes)
    observe(bytes)
  }

  /// Acts on the driver's request for final output. Codex keeps running, and
  /// the request is only recorded; a Files pane prints its marker and stops.
  private func emitFinalMarker() throws {
    if workload == "codex" {
      finalEmitted = true
      events.record("final_requested", ["source": "driver-final-output"])
      return
    }
    guard canaries.contains("files_listing") else { return }
    finalEmitted = true
    try emit(Data("\r\n\u{1B}[32mTUI_STRESS_FILES_PANE_\(pane)_FINAL\u{1B}[0m\r\n".utf8))
    events.record("wrapper_marker", ["phase": "final"])
    stopping = true
  }

  /// Looks for proof that the real program drew its interface. Only the end
  /// of the output is kept, enough for a canary split across two reads.
  private func observe(_ bytes: Data) {
    tail = Data((tail + bytes).suffix(Self.canaryTailLimit))
    func seen(_ text: String) -> Bool { tail.range(of: Data(text.utf8)) != nil }
    if workload == "files" {
      if seen("README.md"), seen("\u{1B}[") { mark("files_listing") }
    } else {
      if seen("OpenAI Codex") || seen("Ask Codex") { mark("codex_banner") }
      if seen("TUI_STRESS_RESPONSE") { mark("codex_response") }
    }
  }

  private func mark(_ canary: String) {
    guard canaries.insert(canary).inserted else { return }
    events.record("workload_output_canary", ["kind": canary])
  }

  private func recordBytes(_ event: String, _ bytes: Data) {
    events.record(event, ["bytes": bytes.count, "bytes_base64": bytes.base64EncodedString()])
  }

  private func writeMetadata() throws {
    let metadata: [String: Any] = [
      "pane": pane, "wrapper_pid": Int(getpid()), "workload": workload, "cwd": cwd,
      "output_limit": Self.outputLimit, "transcript": "pane-\(pane)-events.jsonl",
      "clock_domain": "CLOCK_UPTIME_RAW / ProcessInfo.systemUptime",
    ]
    let path = directory + "/pane-\(pane).json"
    guard FileManager.default.createFile(atPath: path, contents: try compactJSON(metadata)) else {
      throw Failure("cannot write \(path)")
    }
  }

  private func stopChild(_ name: String, _ number: Int32) {
    guard let child else { return }
    let group = getpgid(child)
    guard group >= 0 else { return }
    // A group is signalled only when the child itself leads it. A stale or
    // inherited group is not this fixture's to signal; the child alone still is.
    if kill(group == child ? -child : child, number) != 0, errno == EPERM {
      if group == child {
        events.record("group_signal_denied", ["signal": name, "child_pid": Int(child), "child_pgid": Int(group)])
      }
      kill(child, number)
    }
  }

  private func closeTerminal() {
    terminal?.close()
    terminal = nil
  }

  private func recordChildExit(_ status: ChildStatus) {
    guard !childExitRecorded else { return }
    events.record("child_exited", ["status": [
      "exited": status.exitCode != nil, "exitstatus": status.exitCode.map { Int($0) } ?? NSNull(),
      "signaled": status.signal != nil, "termsig": status.signal.map { Int($0) } ?? NSNull(),
    ] as [String: Any]])
    childExitRecorded = true
    child = nil
  }

  private func terminateAndReap() throws {
    guard child != nil else { return }
    // A short listing can have ended after the relay last looked. Reap
    // first, before any signal goes to a process group.
    var status = try waitForChild(0)
    if status == nil {
      stopChild("TERM", SIGTERM)
      status = try waitForChild(Self.reapGraceSeconds)
    }
    if status == nil {
      stopChild("KILL", SIGKILL)
      status = try waitForChild(Self.reapKillSeconds)
    }
    guard let status else { throw Failure("could not reap inner workload process") }
    recordChildExit(status)
  }

  private func waitForChild(_ seconds: Double) throws -> ChildStatus? {
    guard let child else { return nil }
    do { return try reap(child, within: seconds) }
    catch let error as SystemFailure where error.code == ECHILD {
      throw Failure("inner workload process was reaped unexpectedly")
    }
  }

  /// The receipt the runner requires from every pane. It is created
  /// exclusively: a second receipt for one pane would mean two fixtures shared a number.
  private func writeFinal(failure: Failure?) throws {
    let receipt: [String: Any] = [
      "pane": pane, "wrapper_pid": Int(getpid()), "workload": workload, "output_bytes": outputBytes,
      "stopping": isStopping, "child_alive": child != nil, "workload_canaries": canaries.sorted(),
      "failure": failure.map { "Failure: \($0.message)" } ?? NSNull(),
    ]
    let path = directory + "/pane-\(pane)-final.json"
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw Failure(SystemFailure("create \(path)").message) }
    defer { close(descriptor) }
    do { try writeAll(descriptor, try compactJSON(receipt)) } catch { throw Failure(wrapping: error) }
  }

  static let tests = lifecycleTests + relayTests

  static let lifecycleTests = [
    SelfTest.Case(name: "tui-stress fixture: binary transcript, PTY geometry and lifecycle bounds") {
      try expect(Data("猫".utf8).base64EncodedString() == "54yr", "base64 keeps multi-byte text")
      try expect(outputLimit > readLimit, "the transcript bound exceeds one read")
      try expect(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > 0, "the uptime clock runs")
      var lines: [Data] = []
      let child = try spawnChild(["/usr/bin/true"])
      let fixture = TUIStressFixture(reaping: child, events: EventLog(pane: 0) { lines.append($0) })
      usleep(20_000)
      try fixture.terminateAndReap()
      let receipt = try JSONSerialization.jsonObject(with: lines.first ?? Data()) as? [String: Any]
      let status = receipt?["status"] as? [String: Any]
      try expect(status?["exited"] as? Bool == true && status?["exitstatus"] as? Int == 0,
                 "an exited child is reaped, not signalled: \(String(describing: receipt))")
    },
  ]

  static let relayTests = [
    SelfTest.Case(name: "tui-stress fixture: real inner command, Unicode transcript and WINCH relay") {
      try withFixtureDirectory { directory, environment in
        // Written a byte at a time so that multi-byte text arrives split across reads.
        let payload = Array("\u{1B}[38;2;1;2;3m猫 FILES_FIXTURE README.md\u{1B}[0m".utf8)
          .map { String($0, radix: 8) }.joined(separator: " ")
        let binary = directory + "/files-fixture"
        try writeScript("""
          trap 'set -- $(/bin/stty size); printf " CHILD_RESIZE=%sx%s" "$2" "$1"' WINCH
          for byte in \(payload); do printf "\\\\$byte"; sleep 0.001; done
          sleep 0.75 &
          wait $!
          """, to: binary)
        let outer = try PseudoTerminal()
        try outer.setSize(rows: 21, columns: 71)
        let errors = Pipe()
        var settings = environment
        settings["TERMINAL_TUI_STRESS_FILES"] = binary
        let wrapper = try spawnChild([directory + "/fixture", "-l"], environment: settings,
                                     terminal: outer.slavePath, standardError: errors.fileHandleForWriting.fileDescriptor)
        outer.releaseSlave()
        try? errors.fileHandleForWriting.close()
        var status: ChildStatus?
        defer { if status == nil { kill(wrapper, SIGTERM); _ = try? reap(wrapper, within: 3) } }

        var output = Data()
        func pump() throws {
          while !readable([outer.master], milliseconds: 0).isEmpty {
            guard case .bytes(let bytes) = try readAvailable(outer.master, limit: 16_384) else { return }
            output += bytes
          }
        }
        func shows(_ text: String) -> Bool { output.range(of: Data(text.utf8)) != nil }
        let transcript = directory + "/pane-0-events.jsonl"
        func has(_ events: [[String: Any]], _ event: String, _ key: String? = nil, _ value: String? = nil) -> Bool {
          events.contains { $0["event"] as? String == event && (key == nil || $0[key!] as? String == value) }
        }

        try waitFor(4, "fixture startup") {
          try pump()
          return FileManager.default.fileExists(atPath: transcript) && shows("FILES_FIXTURE")
        }
        try outer.setSize(rows: 24, columns: 79)
        kill(wrapper, SIGWINCH)
        var events: [[String: Any]] = []
        try waitFor(3, "fixture resize relay to the child") {
          try pump()
          events = try TUIStress.events(transcript)
          return shows("CHILD_RESIZE=79x24") && events.contains {
            $0["event"] as? String == "winsize" && $0["rows"] as? Int == 24 && $0["columns"] as? Int == 79
          }
        }
        FileManager.default.createFile(atPath: directory + "/final-output", contents: nil)
        try waitFor(3, "fixture final marker") {
          try pump()
          events = try TUIStress.events(transcript)
          return events.contains { $0["event"] as? String == "wrapper_marker" && $0["phase"] as? String == "final" }
        }

        let recorded = events.filter { $0["event"] as? String == "output" }
          .compactMap { ($0["bytes_base64"] as? String).flatMap { Data(base64Encoded: $0) } }
          .reduce(Data(), +)
        try expect(recorded.range(of: Data("猫 FILES_FIXTURE".utf8)) != nil, "unicode output is preserved")
        try expect(recorded.range(of: Data("TUI_STRESS_FILES_PANE_0_FINAL".utf8)) != nil, "the final marker is preserved")
        try expect(has(events, "child_started"), "the real child's start is recorded")
        try expect(has(events, "workload_output_canary", "kind", "files_listing"), "the listing canary is recorded")
        try expect(events.allSatisfy { $0["host_time"] is NSNumber && $0["monotonic"] == nil },
                   "every event carries uptime host time")

        status = try reap(wrapper, within: 1)
        if status == nil {
          kill(wrapper, SIGTERM)
          status = try reap(wrapper, within: 3)
        }
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().suffix(4096), as: UTF8.self)
        try expect(status != nil, "the fixture exits: \(stderr)")
        try expect(status?.succeeded == true, "the fixture succeeds: \(String(describing: status)), \(stderr)")

        let metadata = try readJSONObject(directory + "/pane-0.json")
        try expect(metadata["clock_domain"] as? String == "CLOCK_UPTIME_RAW / ProcessInfo.systemUptime",
                   "the metadata names the clock")
        try expectCleanReceipt(directory + "/pane-0-final.json")
      }
    },
    SelfTest.Case(name: "tui-stress fixture: a child that ignores hang-up and closes its terminal is killed") {
      try withFixtureDirectory { directory, environment in
        let ready = directory + "/closed-tty-linger-ready"
        let binary = directory + "/closed-tty-linger"
        try writeScript("""
          trap '' TERM HUP
          : > "$TUI_STRESS_LINGER_READY"
          exec <&- >&- 2>&-
          while :; do sleep 1; done
          """, to: binary)
        let outer = try PseudoTerminal()
        try outer.setSize(rows: 18, columns: 62)
        var settings = environment
        settings["TERMINAL_TUI_STRESS_FILES"] = binary
        settings["TUI_STRESS_LINGER_READY"] = ready
        let wrapper = try spawnChild([directory + "/fixture", "-l"], environment: settings, terminal: outer.slavePath)
        outer.releaseSlave()
        var status: ChildStatus?
        defer { if status == nil { kill(wrapper, SIGTERM); _ = try? reap(wrapper, within: 3) } }

        let transcript = directory + "/pane-0-events.jsonl"
        try waitFor(4, "closed-terminal child start") {
          guard FileManager.default.fileExists(atPath: transcript), FileManager.default.fileExists(atPath: ready) else {
            return false
          }
          return try TUIStress.events(transcript).contains { $0["event"] as? String == "child_started" }
        }
        kill(wrapper, SIGTERM)
        status = try reap(wrapper, within: 3)
        try expect(status != nil, "the fixture exits after TERM")
        let killed = try TUIStress.events(transcript).contains { event in
          guard event["event"] as? String == "child_exited", let exit = event["status"] as? [String: Any] else { return false }
          return exit["signaled"] as? Bool == true && exit["termsig"] as? Int == Int(SIGKILL)
        }
        try expect(killed, "the lingering child is killed and reaped")
        try expectCleanReceipt(directory + "/pane-0-final.json")
      }
    },
    SelfTest.Case(name: "tui-stress fixture: a child that closes its terminal ends the relay without a signal") {
      try withFixtureDirectory { directory, environment in
        let binary = directory + "/closed-tty-linger"
        try writeScript("""
          trap '' TERM HUP
          exec <&- >&- 2>&-
          while :; do sleep 1; done
          """, to: binary)
        let outer = try PseudoTerminal()
        try outer.setSize(rows: 18, columns: 62)
        var settings = environment
        settings["TERMINAL_TUI_STRESS_FILES"] = binary
        let wrapper = try spawnChild([directory + "/fixture", "-l"], environment: settings, terminal: outer.slavePath)
        outer.releaseSlave()
        var status: ChildStatus?
        defer { if status == nil { kill(wrapper, SIGTERM); _ = try? reap(wrapper, within: 3) } }

        // The relay ends at the inner terminal's end of input, and the child is then reaped.
        let transcript = directory + "/pane-0-events.jsonl"
        try waitFor(4, "the relay to end at the inner terminal's end of input") {
          guard FileManager.default.fileExists(atPath: transcript) else { return false }
          return try TUIStress.events(transcript).contains { $0["event"] as? String == "child_exited" }
        }
        kill(wrapper, SIGTERM)
        status = try reap(wrapper, within: 3)
        try expect(status?.succeeded == true, "the fixture ends cleanly after TERM: \(String(describing: status))")
        try expectCleanReceipt(directory + "/pane-0-final.json")
      }
    },
    SelfTest.Case(name: "tui-stress fixture: end of input on its own terminal ends the fixture") {
      try withFixtureDirectory { directory, environment in
        let binary = directory + "/quiet"
        try writeScript("exec /bin/sleep 30", to: binary)
        let outer = try PseudoTerminal()
        try outer.setSize(rows: 18, columns: 62)
        var settings = environment
        settings["TERMINAL_TUI_STRESS_FILES"] = binary
        let wrapper = try spawnChild([directory + "/fixture", "-l"], environment: settings, terminal: outer.slavePath)
        outer.releaseSlave()
        var status: ChildStatus?
        defer { if status == nil { kill(wrapper, SIGTERM); _ = try? reap(wrapper, within: 3) } }

        let transcript = directory + "/pane-0-events.jsonl"
        try waitFor(4, "the relay to start") {
          guard FileManager.default.fileExists(atPath: transcript) else { return false }
          return try TUIStress.events(transcript).contains { $0["event"] as? String == "winsize" }
        }
        outer.close()
        status = try reap(wrapper, within: 3)
        try expect(status?.succeeded == true, "the fixture ends by itself: \(String(describing: status))")
        let receipt = try readJSONObject(directory + "/pane-0-final.json")
        try expect(receipt["child_alive"] as? Bool == false && receipt["failure"] is NSNull,
                   "the child is reaped and nothing failed: \(receipt)")
      }
    },
    SelfTest.Case(name: "tui-stress fixture: Codex gets the loopback provider, a private home and a recorded final request") {
      try withFixtureDirectory { directory, environment in
        let arguments = directory + "/codex-arguments", state = directory + "/codex-state"
        let binary = directory + "/codex-fixture"
        try writeScript("""
          { printf '%s\\n' "$@"; echo "home=$CODEX_HOME"; echo "key=$DUMMY_CODEX_UI_KEY"; } > "$TUI_STRESS_ARGUMENTS"
          printf 'OpenAI Codex\\r\\nTUI_STRESS_RESPONSE'
          sleep 30 &
          wait $!
          """, to: binary)
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let outer = try PseudoTerminal()
        try outer.setSize(rows: 30, columns: 100)
        var settings = environment
        settings["TERMINAL_TUI_STRESS_WORKLOAD"] = "codex"
        settings["TERMINAL_TUI_STRESS_CODEX"] = binary
        settings["TERMINAL_TUI_STRESS_CODEX_DIRECTORY"] = state
        settings["TERMINAL_TUI_STRESS_CODEX_BASE_URL"] = "http://127.0.0.1:9/v1"
        settings["TUI_STRESS_ARGUMENTS"] = arguments
        let wrapper = try spawnChild([directory + "/fixture", "-l"], environment: settings, terminal: outer.slavePath)
        outer.releaseSlave()
        var status: ChildStatus?
        defer { if status == nil { kill(wrapper, SIGTERM); _ = try? reap(wrapper, within: 3) } }

        let transcript = directory + "/pane-0-events.jsonl"
        func recorded(_ event: String, _ kind: String? = nil) throws -> Bool {
          guard FileManager.default.fileExists(atPath: transcript) else { return false }
          return try TUIStress.events(transcript).contains {
            $0["event"] as? String == event && (kind == nil || $0["kind"] as? String == kind)
          }
        }
        try waitFor(4, "Codex banner and response") {
          try recorded("workload_output_canary", "codex_banner") && recorded("workload_output_canary", "codex_response")
        }
        FileManager.default.createFile(atPath: directory + "/final-output", contents: nil)
        try waitFor(3, "final request record") { try recorded("final_requested") }
        try expect(try reap(wrapper, within: 0.3) == nil, "Codex keeps running after the final request")
        kill(wrapper, SIGTERM)
        status = try reap(wrapper, within: 3)
        try expect(status?.succeeded == true, "the fixture ends cleanly after TERM: \(String(describing: status))")

        let seen = try String(contentsOfFile: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        try expect(seen.contains("model_providers.fixture.base_url=\"http://127.0.0.1:9/v1\""),
                   "Codex is pointed at the provider: \(seen)")
        try expect(seen.first == "--no-daemon" && seen.contains("Render fixture output"), "the fixed prompt is passed")
        try expect(seen.contains("home=\(state)/pane-0") && seen.contains("key=fixture-not-a-secret"),
                   "Codex gets a home of its own and the placeholder key")
        let started = try TUIStress.events(transcript).first { $0["event"] as? String == "child_started" }
        try expect((started?["command"] as? [String])?.contains("<fixture-cwd>") == true, "the transcript hides the directory")
        try expectCleanReceipt(directory + "/pane-0-final.json")
      }
    },
    SelfTest.Case(name: "tui-stress fixture: Codex is refused any provider but the loopback one") {
      try withFixtureDirectory { directory, environment in
        var settings = environment.compactMapValues { $0 }
        settings["TERMINAL_TUI_STRESS_WORKLOAD"] = "codex"
        settings["TERMINAL_TUI_STRESS_CODEX"] = "/usr/bin/true"
        for url in ["https://api.openai.com/v1", "http://127.0.0.1:80/v1/x", "http://127.0.0.1.example.test:80/v1"] {
          settings["TERMINAL_TUI_STRESS_CODEX_BASE_URL"] = url
          do {
            _ = try TUIStressFixture(reaping: 0, events: EventLog(pane: 0) { _ in }, environment: settings).command()
            throw Failure("\(url) was accepted")
          } catch let failure as Failure {
            try expect(failure.message == "Codex fixture provider must be a local /v1 endpoint", "got: \(failure.message)")
          }
        }
      }
    },
  ]

  /// Runs `body` with a run directory holding a launcher for the fixture, and the environment a fixture needs.
  private static func withFixtureDirectory(_ body: (String, [String: String?]) throws -> Void) throws {
    try withTemporaryDirectory("dev-tui-stress-fixture-") { temporary in
      let directory = try realPath(temporary)
      let cwd = directory + "/cwd"
      try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
      try Tool.writeLauncher(at: directory + "/fixture", subcommand: ["tui-stress", "fixture"])
      do {
        try body(directory, [
          "TERMINAL_TUI_STRESS_DIRECTORY": directory, "TERMINAL_TUI_STRESS_WORKLOAD": "files",
          "TERMINAL_TUI_STRESS_CWD": cwd, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
      } catch { throw Failure(wrapping: error) }
    }
  }

  private static func waitFor(_ seconds: Double, _ what: String, _ condition: () throws -> Bool) throws {
    let deadline = Clock.now + UInt64(seconds * 1_000_000_000)
    while try !condition() {
      guard Clock.now < deadline else { throw Failure("\(what) timed out") }
      usleep(10_000)
    }
  }

  private static func expectCleanReceipt(_ path: String) throws {
    let receipt = try readJSONObject(path)
    try expect(receipt["stopping"] as? Bool == true && receipt["child_alive"] as? Bool == false
                 && receipt["failure"] is NSNull, "the final receipt reports a clean stop: \(receipt)")
  }
}

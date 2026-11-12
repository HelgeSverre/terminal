import CryptoKit
import Foundation

/// Exercises the app's AppleScript dictionary through a signed copy of the built app.
///
/// The copy has its own name and bundle identifier. The stable identity lets
/// macOS keep the user's automation decision between runs, and the lock and
/// the exact bundle path keep this runner from scripting any other instance.
///
/// `TERMINAL_AUTOMATION_REQUEST_CONSENT=1` lets the permission check show the
/// macOS consent prompt; `TERMINAL_AUTOMATION_PREFLIGHT_ONLY=1` stops after
/// that check. The exit status is 2 when consent has not been given yet and 3
/// when it was refused.
///
/// With `--receipt-shell` the tool is the program the fixture's first pane
/// runs, started by the script that `writeFixtureShell` writes.
enum AppleScriptSmoke {
  static let command = Command(
    name: "applescript-smoke", usage: "",
    summary: "Drive a signed fixture copy of the app through its AppleScript dictionary.",
    run: run)

  static let fixtureBundleID = "no.helgesverre.terminal.automation-fixture"
  static let fixtureName = "Terminal Automation Fixture"
  /// The event the permission check asks about: class HTer, identifier mfcs.
  static let eventClass = 0x4854_6572
  static let eventID = 0x6d66_6373
  static let commandTimeout = 4.0
  /// Long enough for a person to read and answer the consent prompt.
  static let consentTimeout = 60.0
  static let outputLimit = 8 * 1024
  static let largeCommittedText = "AUTOMATION_TEXT_" + String(repeating: "x", count: 4096) + "_END"
  static let scenarios = ["permission", "invalid-target", "bounded-read", "preferences", "window", "split", "tab", "focus",
                          "settings", "inactive", "large-committed-text", "clear", "close", "cleanup"]

  /// The permission check's answer, when it is not a plain yes.
  enum Consent: Error {
    case required(String)
    case denied(String)
    var message: String {
      switch self {
      case .required(let message), .denied(let message): return message
      }
    }
  }

  /// How a bounded command ended.
  struct CommandStatus {
    let exitStatus: Int32?
    let signal: Int32?
    var succeeded: Bool { exitStatus == 0 }
  }

  /// A bounded command that did not finish in time and was ended.
  struct CommandTimeout: Error {
    let seconds: Double
    let output: String
    let status: CommandStatus?
    var message: String { "Automation command timed out after \(seconds.plain) seconds." }
  }

  static func run(_ arguments: [String]) throws {
    if arguments == ["--receipt-shell"] { try receiptShell() }
    guard arguments.isEmpty else { throw Failure.usage(command) }
    Interruption.observe()
    do {
      try Session(root: Repository.root, environment: ProcessInfo.processInfo.environment).run()
    } catch let consent as Consent {
      var lines = consent.message + "\n"
      if case .required = consent {
        lines += "Run with TERMINAL_AUTOMATION_REQUEST_CONSENT=1 and TERMINAL_AUTOMATION_PREFLIGHT_ONLY=1 to request "
          + "standard macOS consent for the stable fixture.\n"
      }
      FileHandle.standardError.write(Data(lines.utf8))
      if case .required = consent { exit(2) }
      exit(3)
    } catch {
      throw Failure("AppleScript smoke failed: \(message(error))")
    }
  }

  static func message(_ error: Error) -> String {
    switch error {
    case let failure as Failure: return failure.message
    case let consent as Consent: return consent.message
    case let timeout as CommandTimeout: return timeout.message
    default: return error.localizedDescription
    }
  }

  /// The program in the fixture's first pane. It records its PID, reads the
  /// text sent to the pane up to the return key, prints a digest of it, and
  /// then echoes like `cat`. The digest proves that every byte of a large
  /// committed text arrived, without the screen having to show the text.
  static func receiptShell() throws -> Never {
    guard let record = ProcessInfo.processInfo.environment["TERMINAL_AUTOMATION_CHILD_PIDS"] else {
      throw Failure("TERMINAL_AUTOMATION_CHILD_PIDS is not set")
    }
    let descriptor = open(record, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else { throw Failure("cannot open \(record)") }
    let line = Array("\(getpid())\n".utf8)
    _ = write(descriptor, line, line.count)
    close(descriptor)
    // Raw and silent, so a line longer than the canonical limit arrives whole.
    // The self-test feeds this shell through a pipe, which has no mode to set.
    if isatty(STDIN_FILENO) != 0 { try makeStandardInputRaw() }

    var digest = SHA256()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(STDIN_FILENO, &buffer, buffer.count)
      guard count > 0 else { throw Failure("input ended before the return key") }
      let terminator = buffer[..<count].firstIndex(of: 0x0D)
      digest.update(data: buffer[..<(terminator ?? count)])
      if terminator != nil { break }
    }
    let receipt = digest.finalize().map { String(format: "%02x", $0) }.joined()
    FileHandle.standardOutput.write(Data("AUTOMATION_RECEIPT \(receipt)\n".utf8))
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/cat"), nil]
    execv("/bin/cat", &arguments)
    throw Failure("cannot run /bin/cat")
  }

  /// Runs a command with no input and returns everything it printed. A
  /// command still printing after `timeout` seconds is ended, politely and
  /// then by force, and reaped.
  static func capture(_ command: [String], timeout: Double = commandTimeout) throws -> (output: String, status: CommandStatus) {
    final class Collected { var data = Data() }
    let process = Process(), pipe = Pipe(), collected = Collected(), finished = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { throw Failure("cannot run \(command[0]): \(error.localizedDescription)") }
    DispatchQueue.global().async {
      collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
      finished.signal()
    }
    func status() -> CommandStatus {
      process.waitUntilExit()
      let signalled = process.terminationReason == .uncaughtSignal
      return CommandStatus(exitStatus: signalled ? nil : process.terminationStatus,
                           signal: signalled ? process.terminationStatus : nil)
    }
    if finished.wait(timeout: .now() + timeout) == .success {
      return (String(decoding: collected.data, as: UTF8.self), status())
    }
    if process.isRunning {
      process.terminate()
      let deadline = Clock.now + 1_000_000_000
      while process.isRunning, Clock.now < deadline { usleep(10_000) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    let ended = status()
    // A descendant can keep the pipe open; what was read by then is enough.
    let partial = finished.wait(timeout: .now() + 1) == .success ? String(decoding: collected.data, as: UTF8.self) : ""
    throw CommandTimeout(seconds: timeout, output: partial, status: ended)
  }

  /// One run: its configuration, what it observed, and the stages in order.
  /// The stages are separate methods so that tests can replace the ones that
  /// need a signed app and a window server.
  class Session {
    let root: String
    let environment: [String: String]
    let source: String
    let fixtureRoot: String
    let fixture: String
    let executable: String
    let reportPath: String
    let lockPath: String
    let requestConsent: Bool
    let preflightOnly: Bool
    /// The program that runs scripts. Tests point this at a script of their own.
    var osascript = "/usr/bin/osascript"

    var commands: [JSONValue] = []
    var childPIDs: [Int] = []
    var cleanup: JSONValue = [:]
    var permission: JSONValue = nil
    var targeting: JSONValue = nil
    var completed = false
    var failure: String?
    var process: AppleScriptFixtureProcess?
    var fixturePID: pid_t?
    var signingIdentity: String?
    var fixtureSignature: String?
    var sourceSignature: String?
    var sourceSHA256: String?
    var sourceRevision: String?
    var fixtureOutput: String?
    var appLog: String?
    var childPIDsPath: String?
    var fixtureShell: String?
    var receiptShell: String?
    private var lock: Int32 = -1
    private var ownsLock = false

    init(root: String, environment: [String: String]) {
      self.root = root
      self.environment = environment
      source = environment["TERMINAL_AUTOMATION_SOURCE"] ?? root + "/dist/Terminal.app"
      fixtureRoot = environment["TERMINAL_AUTOMATION_FIXTURE_ROOT"] ?? root + "/target/automation-fixture"
      fixture = fixtureRoot + "/\(fixtureName).app"
      executable = fixture + "/Contents/MacOS/Terminal"
      reportPath = environment["TERMINAL_AUTOMATION_REPORT"] ?? root + "/reports/applescript-smoke.json"
      lockPath = environment["TERMINAL_AUTOMATION_LOCK"] ?? root + "/target/automation-fixture.lock"
      requestConsent = environment["TERMINAL_AUTOMATION_REQUEST_CONSENT"] == "1"
      preflightOnly = environment["TERMINAL_AUTOMATION_PREFLIGHT_ONLY"] == "1"
    }

    /// Runs every stage, then always cleans up and writes the report. The
    /// run's own error is reported in preference to a cleanup error.
    func run() throws {
      var runError: Error?
      do {
        try acquireLock()
        try validateConfiguration()
        try prepareFixture()
        try launchFixture()
        try preflightPermission()
        // In preflight-only mode the permission check, with its prompt when
        // requested, is the whole run; cleanup and the report are the same.
        if !preflightOnly {
          try exerciseDictionary()
          try verifyCleanExit()
        }
        completed = true
      } catch {
        failure = message(error)
        runError = error
      }
      let cleanupError = try finalize()
      if let runError { throw runError }
      if let cleanupError { throw cleanupError }
      let covered = preflightOnly ? "consent preflight"
        : "command delivery, bounded reads, validated preferences, and clean PTY exit"
      print("PASS AppleScript fixture: \(covered)")
    }

    func validateConfiguration() throws {
      guard FileManager.default.isExecutableFile(atPath: source + "/Contents/MacOS/Terminal") else {
        throw Failure("Missing built app: \(source)")
      }
      signingIdentity = try findSigningIdentity()
    }

    /// The identity to sign the fixture with: an override, the release
    /// identity from the environment or the release configuration, or the
    /// keychain's Developer ID when there is exactly one.
    private func findSigningIdentity() throws -> String {
      for key in ["TERMINAL_AUTOMATION_SIGN_IDENTITY", "APPLE_APPLICATION_SIGNING_IDENTITY"] {
        if let value = environment[key], !value.isEmpty { return value }
      }
      let path = NSHomeDirectory() + "/.config/terminal/release.json"
      if let data = FileManager.default.contents(atPath: path) {
        let configuration: JSONValue
        do { configuration = try JSONValue(parsing: data) } catch let failure as Failure {
          throw Failure("Could not parse ~/.config/terminal/release.json: \(failure.message)")
        }
        if let configured = configuration["applicationIdentity"]?.display, !configured.isEmpty { return configured }
      }
      let identities = try capture(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
      guard identities.status.succeeded else {
        throw Failure("Could not inspect Developer ID identities: \(identities.output.trimmed)")
      }
      let matches = identities.output.matches(of: "\"(Developer ID Application:[^\"]+)\"", group: 1)
      if matches.count == 1 { return matches[0] }
      throw Failure("Configure APPLE_APPLICATION_SIGNING_IDENTITY or applicationIdentity in ~/.config/terminal/release.json.")
    }

    func acquireLock() throws {
      try FileManager.default.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                                              withIntermediateDirectories: true)
      lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      guard lock >= 0 else { throw Failure("cannot open \(lockPath): \(String(cString: strerror(errno)))") }
      chmod(lockPath, 0o600)
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw Failure("Another AppleScript fixture owns \(fixtureRoot); wait for that harness to finish.")
      }
      ownsLock = true
    }

    private func releaseLock() {
      guard lock >= 0 else { return }
      flock(lock, LOCK_UN)
      close(lock)
      lock = -1
    }

    /// Copies the built app, gives the copy the fixture identity and signs it.
    func prepareFixture() throws {
      let active = try activeFixturePIDs()
      guard active.isEmpty else { throw Failure("Refusing to replace active fixture process(es): \(active.listed)") }
      if isDirectory(fixtureRoot) { try FileManager.default.removeItem(atPath: fixtureRoot) }
      try FileManager.default.createDirectory(atPath: fixtureRoot, withIntermediateDirectories: true)
      try FileManager.default.copyItem(atPath: source, toPath: fixture)
      let plist = fixture + "/Contents/Info.plist"
      for (key, value) in [("CFBundleIdentifier", fixtureBundleID), ("CFBundleName", fixtureName), ("CFBundleDisplayName", fixtureName)] {
        try runQuietly(["/usr/libexec/PlistBuddy", "-c", "Set :\(key) \(value)", plist])
      }
      try writeFixtureShell()
      // --deep re-signs the embedded Sparkle.framework too: under the hardened
      // runtime dyld refuses a framework whose Team ID differs from the app's.
      try runQuietly(["/usr/bin/codesign", "--force", "--deep", "--options", "runtime", "--sign", signingIdentity ?? "", fixture])
      fixtureSignature = try codeSignature(fixture)
      sourceSignature = try codeSignature(source)
      sourceSHA256 = try sha256(ofFile: source + "/Contents/MacOS/Terminal")
      sourceRevision = environment["TERMINAL_AUTOMATION_SOURCE_REVISION"]
      if sourceRevision == nil {
        let revision = try capture(["/usr/bin/git", "-C", root, "rev-parse", "HEAD"])
        guard revision.status.succeeded else { throw Failure("Could not determine source revision: \(revision.output.trimmed)") }
        sourceRevision = revision.output.trimmed
      }
    }

    func launchFixture() throws {
      try requireFixtureTargetAvailable()
      let log = fixtureRoot + "/fixture.log"
      appLog = log
      let tree = try ProcessTree(
        [executable, "--working-directory", "/tmp", "--execute", "/bin/sh", "-c", "exec \"$TERMINAL_AUTOMATION_RECEIPT_SHELL\""],
        environment: ["SHELL": fixtureShell, "TERMINAL_AUTOMATION_CHILD_PIDS": childPIDsPath,
                      "TERMINAL_AUTOMATION_RECEIPT_SHELL": receiptShell],
        // The fixture directory is new, but the log was never required to be.
        output: .log(log, replacing: true))
      process = tree
      fixturePID = tree.pid
      childPIDs = try waitUntil("fixture PTY child") {
        try self.requireFixtureRunning()
        let pids = self.recordedChildren()
        return pids.count == 1 ? pids : nil
      }
    }

    /// Asks macOS whether this process may script the fixture. Without the
    /// consent request the check never prompts, so an unattended run cannot
    /// stall on a dialog.
    func preflightPermission() throws {
      let status = try permissionStatus(askUserIfNeeded: requestConsent, timeout: requestConsent ? consentTimeout : commandTimeout)
      permission = ["status": .int(status), "outcome": .string(permissionName(status)),
                    "requested_standard_consent": .bool(requestConsent)]
      if status == 0 { return }
      if status == -1744, !requestConsent {
        throw Consent.required("consent_required: non-prompting AppleEvent preflight returned -1744.")
      }
      throw Consent.denied("consent_denied: AppleEvent preflight returned \(status).")
    }

    func exerciseDictionary() throws {
      let app = "tell application id \(literal(fixtureBundleID)) to "
      try runScript(app + "get name", name: "get fixture name")
      try runScript(app + "get id", name: "get fixture id")
      // The app can still be starting; only this first command is retried.
      let pane = try waitForFixture { try self.runScript(app + "focus pane", name: "initial focus pane") }
      guard pane.hasPrefix("no.helgesverre.terminal.pane.") else { throw Failure("Invalid pane identifier: \(pane.debugDescription)") }
      try expectFailure(app + "read screen from pane \"no.helgesverre.terminal.pane.missing\"", -1728,
                        "An unknown pane identifier was accepted.", name: "reject unknown pane")

      let otherPane = try runScript(app + "new window", name: "new window")
      guard otherPane != pane else { throw Failure("new window did not return a distinct pane: \(otherPane.debugDescription)") }
      let rightPane = try runScript(app + "split right pane id \(literal(pane))", name: "split right")
      let belowPane = try runScript(app + "split below pane id \(literal(rightPane))", name: "split below")
      try runScript(app + "show settings", name: "show settings")
      let tabPane = try runScript(app + "new tab", name: "new tab")
      childPIDs = try waitUntil("split and tab PTY children") {
        try self.requireFixtureRunning()
        let pids = self.recordedChildren()
        return pids.count >= 5 ? pids : nil
      }
      let expected = [pane, otherPane, rightPane, belowPane, tabPane].sorted()
      let panes = paneIDs(try runScript(app + "list panes", name: "list panes"))
      guard panes.sorted() == expected else { throw Failure("list panes did not return the complete fixture set: \(panes)") }
      let focused = try runScript(app + "focus pane pane id \(literal(pane))", name: "focus named pane")
      guard focused == pane else { throw Failure("focus pane returned a different pane: \(focused.debugDescription)") }

      try expectFailure(app + "read screen max characters 0", -1700,
                        "A zero screen read limit was accepted.", name: "reject zero read limit")
      try expectFailure(app + "read screen max characters 262145", -1700,
                        "An oversized screen read limit was accepted.", name: "reject oversized read limit")
      try expectFailure(app + "configure preferences font size 7.0", -1700,
                        "An invalid font size was accepted.", name: "reject invalid font size")
      try expectFailure(app + "configure preferences starting directory \"/does/not/exist\"", -1700,
                        "An invalid starting directory was accepted.", name: "reject invalid directory")
      try expectFailure(app + "configure preferences word characters \"not valid\"", -1700,
                        "Invalid selection word characters were accepted.", name: "reject invalid word characters")
      try runScript(app + "show settings", name: "show settings while focused")
      // The rest must work while the app is not the active one.
      try hideFixture()

      let accepted = try runScript(app + "send text (\(literal(largeCommittedText)) & return)", name: "send large committed text")
      guard accepted == pane else { throw Failure("send text returned a different pane: \(accepted.debugDescription)") }
      let receipt = sha256(of: Data(largeCommittedText.utf8))
      let screen = try waitUntil("committed text receipt in screen snapshot") {
        let output = try self.runScript(app + "read screen max characters 2048", name: "read screen")
        return receiptInSnapshot(output, receipt) ? output : nil
      }
      guard receiptInSnapshot(screen, receipt) else { throw Failure("read screen did not return the exact committed-text receipt.") }

      let configured = try runScript(
        app + "configure preferences font size 15.0 scrollback rows 1000 "
          + "option sends escape true follows tail on input false starting directory \"/tmp\" word characters \"@_/-@\"",
        name: "configure preferences")
      guard configured.contains("15") else {
        throw Failure("configure preferences did not return the saved font size: \(configured.debugDescription)")
      }
      guard configured.contains("word characters -/@_") else {
        throw Failure("configure preferences did not return canonical word characters: \(configured.debugDescription)")
      }
      let cleared = try runScript(app + "clear screen", name: "clear screen")
      guard cleared == pane else { throw Failure("clear screen returned a different pane: \(cleared.debugDescription)") }

      for (id, name) in [(tabPane, "close tab pane"), (belowPane, "close below pane"), (rightPane, "close right pane"),
                         (otherPane, "close other window")] {
        try runScript(app + "close pane pane id \(literal(id))", name: name)
      }
      let remaining = paneIDs(try runScript(app + "list panes", name: "list remaining panes"))
      guard remaining == [pane] else { throw Failure("close pane left the wrong pane set: \(remaining)") }
      try runScript(app + "quit", name: "quit fixture")
    }

    /// After `quit` the app must exit cleanly, and every pane's program with it.
    func verifyCleanExit() throws {
      guard let process, let exit = process.wait(seconds: 8) else { throw Failure("Fixture app did not exit after quit.") }
      guard exit.succeeded else { throw Failure("Fixture app exited with \(describe(exit).compact)") }
      mergeRecordedChildren()
      let survivors = childPIDs.filter(isAlive)
      guard survivors.isEmpty else { throw Failure("Fixture PTY children survived application exit: \(survivors.listed)") }
      let descendants = process.livePIDs
      guard descendants.isEmpty else { throw Failure("Fixture app left descendants: \(descendants.listed)") }
    }

    @discardableResult
    func runScript(_ source: String, name: String) throws -> String {
      let result = try invoke(name, "AppleScript", source)
      guard result.status.succeeded else { throw Failure("osascript failed: \(result.output.trimmed)") }
      return result.output.trimmed
    }

    /// The script must fail, and with AppleScript error `code`.
    func expectFailure(_ source: String, _ code: Int, _ message: String, name: String) throws {
      let result = try invoke(name, "AppleScript", source)
      guard !result.status.succeeded else { throw Failure(message) }
      guard result.output.contains("(\(code))") else {
        throw Failure("\(message) Expected AppleScript error \(code), got: \(result.output.trimmed)")
      }
    }

    private func hideFixture() throws {
      let script = """
        ObjC.import('AppKit');
        const application = $.NSRunningApplication.runningApplicationWithProcessIdentifier(\(fixturePID ?? 0));
        if (application) application.hide;

        """
      guard try invoke("hide fixture", "JavaScript", script).status.succeeded else { throw Failure("Could not hide the fixture.") }
    }

    func permissionStatus(askUserIfNeeded: Bool, timeout: Double) throws -> Int {
      let script = """
        ObjC.import('Foundation');
        ObjC.import('CoreServices');
        ObjC.bindFunction('AEDeterminePermissionToAutomateTarget', ['int', ['void*', 'uint32', 'uint32', 'bool']]);
        const target = $.NSAppleEventDescriptor.descriptorWithBundleIdentifier("\(fixtureBundleID)");
        console.log(String($.AEDeterminePermissionToAutomateTarget(target.aeDesc, \(eventClass), \(eventID), \(askUserIfNeeded))));

        """
      let result = try invoke("AppleEvent permission preflight", "JavaScript", script, timeout: timeout)
      guard result.status.succeeded else { throw Failure("AppleEvent permission preflight failed: \(result.output.trimmed)") }
      guard let status = Int(result.output.trimmed) else {
        throw Failure("AppleEvent permission preflight returned non-numeric output: \(result.output.debugDescription)")
      }
      return status
    }

    /// Runs one script and records it, whether it finishes, fails or times out.
    func invoke(_ name: String, _ language: String, _ source: String,
                timeout: Double = commandTimeout) throws -> (output: String, status: CommandStatus) {
      try Interruption.check()
      do {
        let result = try capture([osascript, "-l", language, "-e", source], timeout: timeout)
        commands.append(commandRecord(name, language, source, result.output, result.status, timedOut: false, timeout: timeout))
        return result
      } catch let timedOut as CommandTimeout {
        commands.append(commandRecord(name, language, source, timedOut.output, timedOut.status, timedOut: true, timeout: timeout))
        throw timedOut
      }
    }

    /// Calls `body` every 50 ms until it returns a value.
    func waitUntil<Value>(_ label: String, timeout: Double = 8, _ body: () throws -> Value?) throws -> Value {
      let deadline = Clock.now + UInt64(timeout * 1_000_000_000)
      while true {
        if let value = try body() { return value }
        if Clock.now >= deadline { throw Failure("Timed out waiting for \(label).") }
        try Interruption.check()
        usleep(50_000)
      }
    }

    /// Repeats a command that times out while the app is still starting.
    func waitForFixture<Value>(timeout: Double = 12, _ body: () throws -> Value) throws -> Value {
      let deadline = Clock.now + UInt64(timeout * 1_000_000_000)
      while true {
        do { return try body() } catch let timedOut as CommandTimeout {
          if Clock.now >= deadline { throw timedOut }
          usleep(100_000)
        }
      }
    }

    private func requireFixtureRunning() throws {
      if let exit = process?.wait(seconds: 0) { throw Failure("Fixture app exited during startup: \(describe(exit).compact)") }
    }

    /// Writes the two programs the fixture's panes run. Each records its PID,
    /// so that the run can prove every pane's program ended with the app. New
    /// panes run the plain shell; the first pane runs the receipt shell.
    func writeFixtureShell() throws {
      let pids = fixtureRoot + "/children.pids", shell = fixtureRoot + "/fixture-shell", receipt = fixtureRoot + "/fixture-receipt"
      childPIDsPath = pids
      fixtureShell = shell
      receiptShell = receipt
      try writeScript("""
        printf '%s\\n' "$$" >> "$TERMINAL_AUTOMATION_CHILD_PIDS"
        exec /bin/sh -c 'stty raw -echo; exec /bin/cat'
        """, to: shell, mode: 0o700)
      try Tool.writeLauncher(at: receipt, subcommand: ["applescript-smoke", "--receipt-shell"])
    }

    func recordedChildren() -> [Int] {
      guard let childPIDsPath, let text = try? String(contentsOfFile: childPIDsPath, encoding: .utf8) else { return [] }
      var seen = Set<Int>()
      return text.split(separator: "\n").compactMap { Int($0) }.filter { seen.insert($0).inserted }
    }

    private func mergeRecordedChildren() {
      for pid in recordedChildren() where !childPIDs.contains(pid) { childPIDs.append(pid) }
    }

    /// Every process running the fixture's executable, whoever started it.
    func activeFixturePIDs() throws -> [Int] {
      let listing = try runCommand(["/bin/ps", "-axo", "pid=,command="])
      guard listing.succeeded else { throw Failure("Cannot inspect active fixture process ownership.") }
      return listing.output.split(separator: "\n").compactMap { line in
        let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        return fields.count == 2 && fields[1].contains(executable) ? Int(fields[0]) : nil
      }
    }

    /// Scripts address the fixture by bundle identifier, so no other app with
    /// that identifier may be running, from this path or any other.
    private func requireFixtureTargetAvailable() throws {
      let expected = try realPath(fixture)
      let identities = try runningFixtureIdentities()
      targeting = ["bundle_id": .string(fixtureBundleID), "expected_path": .string(expected),
                   "running": .array(identities.map { ["pid": .int($0.pid), "bundle_path": .string($0.path)] })]
      let conflicts = identities.filter { $0.path != expected }
      guard conflicts.isEmpty else {
        throw Failure("Refusing AppleScript target collision for \(fixtureBundleID): \(conflicts.map { "\($0.pid) \($0.path)" })")
      }
      guard identities.isEmpty else {
        throw Failure("Refusing to launch over active fixture PID(s): \(identities.map(\.pid).listed)")
      }
    }

    private func runningFixtureIdentities() throws -> [(pid: Int, path: String)] {
      let script = """
        ObjC.import('AppKit');
        const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("\(fixtureBundleID)");
        for (let index = 0; index < applications.count; index += 1) {
          const application = applications.objectAtIndex(index);
          console.log(`${application.processIdentifier}\\t${ObjC.unwrap(application.bundleURL.path)}`);
        }

        """
      let result = try capture([osascript, "-l", "JavaScript", "-e", script])
      guard result.status.succeeded else { throw Failure("Could not inspect AppleScript target ownership: \(result.output.trimmed)") }
      return result.output.split(separator: "\n").compactMap { line in
        let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "\t", maxSplits: 1)
        guard fields.count == 2, let pid = Int(fields[0]), let path = try? realPath(String(fields[1])) else { return nil }
        return (pid, path)
      }
    }

    private func codeSignature(_ path: String) throws -> String {
      let result = try capture(["/usr/bin/codesign", "-dv", "--verbose=2", path])
      guard result.status.succeeded else { throw Failure("Could not inspect code signature for \(path): \(result.output.trimmed)") }
      return result.output
    }

    /// Runs a helper whose output is of no interest; it must succeed.
    private func runQuietly(_ command: [String]) throws {
      guard quiet(command) else { throw Failure("Command failed: \(command.joined(separator: " "))") }
    }

    private func quiet(_ command: [String]) -> Bool { (try? runCommand(command))?.succeeded ?? false }

    func commandRecord(_ name: String, _ language: String, _ source: String, _ output: String, _ status: CommandStatus?,
                       timedOut: Bool, timeout: Double) -> JSONValue {
      ["name": .string(name), "language": .string(language),
       "command": .strings([osascript, "-l", language, "-e", source]),
       "timeout_seconds": timeout == timeout.rounded() ? .int(Int(timeout)) : .number(timeout),
       "script_sha256": .string(sha256(of: Data(source.utf8))),
       "stdout": .string(truncate(output)),
       "exit_status": .optional(status?.exitStatus.map(Int.init)),
       "signaled": status.map { JSONValue.bool($0.signal != nil) } ?? .null,
       "signal": .optional(status?.signal.map(Int.init)),
       "timed_out": .bool(timedOut)]
    }

    /// Releases the lock, and when this run held it also cleans up and writes
    /// the report. A run that lost the lock leaves the owner's report alone.
    private func finalize() throws -> Failure? {
      defer { releaseLock() }
      guard ownsLock else { return nil }
      if childPIDsPath != nil { mergeRecordedChildren() }
      let cleanupError = cleanupProcess()
      try writeReport()
      return cleanupError
    }

    /// Ends the fixture app, then removes the fixture and its preferences
    /// unless some process still runs from it.
    private func cleanupProcess() -> Failure? {
      var failure = cleanupOwnedProcess()
      if isDirectory(fixtureRoot) {
        do {
          let active = try activeFixturePIDs()
          cleanup["active_fixture_pids_after_cleanup"] = .array(active.map(JSONValue.int))
          if active.isEmpty {
            forgetFixturePreferences()
            try FileManager.default.removeItem(atPath: fixtureRoot)
          } else if failure == nil {
            failure = Failure("Refusing to remove active fixture process(es): \(active.listed)")
          }
        } catch {
          failure = Failure(message(error))
        }
      }
      // Recorded with or without a fixture directory, so the report cannot pass a failed cleanup.
      if let failure { recordCleanupFailure(failure) }
      return failure
    }

    /// Removes the preferences the fixture saved under its own bundle identifier.
    /// Deleting the domain leaves an empty file behind, so the file goes too.
    func forgetFixturePreferences() {
      _ = quiet(["/usr/bin/defaults", "delete", fixtureBundleID])
      try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(fixtureBundleID).plist")
    }

    private func cleanupOwnedProcess() -> Failure? {
      guard let process else { return nil }
      _ = process.wait(seconds: 0)
      cleanup["owned_pids_before_cleanup"] = .array(process.livePIDs.map { .int(Int($0)) })
      let survivors = process.cleanup()
      cleanup["owned_pids_after_cleanup"] = .array(process.livePIDs.map { .int(Int($0)) })
      cleanup["survivors"] = .array(survivors.map { .int(Int($0)) })
      cleanup["app_exit_status"] = describe(process.exit)
      mergeRecordedChildren()
      cleanup["recorded_child_pids"] = .array(childPIDs.map(JSONValue.int))
      let exited = !childPIDs.contains(where: isAlive)
      cleanup["recorded_children_exited"] = .bool(exited)
      if let appLog, let data = FileManager.default.contents(atPath: appLog) {
        fixtureOutput = truncate(String(decoding: data, as: UTF8.self))
      }
      guard survivors.isEmpty else { return Failure("Fixture cleanup left processes: \(survivors.listed)") }
      return exited ? nil : Failure("Fixture cleanup left a recorded PTY child.")
    }

    private func recordCleanupFailure(_ error: Failure) {
      if cleanup["error"] == nil { cleanup["error"] = .string(error.message) }
      if failure == nil { failure = cleanup["error"]?.text }
    }

    func writeReport() throws {
      try FileManager.default.createDirectory(atPath: (reportPath as NSString).deletingLastPathComponent,
                                              withIntermediateDirectories: true)
      let report: JSONValue = [
        "passed": .bool(completed && failure == nil && cleanup["error"] == nil),
        "failure": .optional(failure),
        "source": ["bundle_path": .string(source), "revision": .optional(sourceRevision),
                   "executable_sha256": .optional(sourceSHA256), "code_signature": .optional(sourceSignature)],
        "fixture": ["bundle_id": .string(fixtureBundleID), "display_name": .string(fixtureName), "path": .string(fixture),
                    "pid": .optional(fixturePID.map(Int.init)), "signing_identity": .optional(signingIdentity),
                    "code_signature": .optional(fixtureSignature)],
        "permission": permission,
        "targeting": targeting,
        "preflight_only": .bool(preflightOnly),
        "commands": .array(commands),
        "cleanup": cleanup,
        "fixture_stdout_stderr": .string(fixtureOutput ?? ""),
        "scenarios": .strings(scenarios),
      ]
      try report.write(to: reportPath)
    }
  }

  /// Whether a process with this PID exists, including one this user may not signal.
  static func isAlive(_ pid: Int) -> Bool {
    guard let pid = pid_t(exactly: pid) else { return false }
    return kill(pid, 0) == 0 || errno != ESRCH
  }

  static func describe(_ exit: ProcessTree.Exit?) -> JSONValue {
    guard let exit else { return ["observed": false] }
    return ["observed": true, "exited": .bool(!exit.signalled), "exit_status": exit.signalled ? .null : .int(Int(exit.code)),
            "signaled": .bool(exit.signalled), "signal": exit.signalled ? .int(Int(exit.code)) : .null]
  }

  static func permissionName(_ status: Int) -> String {
    switch status {
    case 0: return "permitted"
    case -1744: return "consent_required"
    case -1743: return "consent_denied"
    default: return "unexpected_status_\(status)"
    }
  }

  static func paneIDs(_ output: String) -> [String] {
    var seen = Set<String>()
    return output.matches(of: "no\\.helgesverre\\.terminal\\.pane\\.[0-9A-Fa-f-]+", group: 0).filter { seen.insert($0).inserted }
  }

  /// Whether the screen text holds the receipt. The terminal may wrap the
  /// line anywhere, so whitespace is ignored.
  static func receiptInSnapshot(_ snapshot: String, _ receipt: String) -> Bool {
    // Scalars, not characters: a carriage return and line feed together are one character.
    let kept = snapshot.unicodeScalars.filter { ![" ", "\t", "\r", "\n"].contains($0) }
    return String(String.UnicodeScalarView(kept)).contains("AUTOMATION_RECEIPT" + receipt)
  }

  /// The text as an AppleScript string literal. Backslashes are doubled
  /// first, so that the ones added before quotes are not doubled again.
  static func literal(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  /// At most `outputLimit` bytes of the text, still valid UTF-8, with a note of how much was cut.
  static func truncate(_ text: String) -> String {
    let bytes = Array(text.utf8)
    guard bytes.count > outputLimit else { return text }
    return String(decoding: bytes[..<outputLimit], as: UTF8.self) + "… [truncated \(bytes.count - outputLimit) bytes]"
  }
}

/// The launched fixture app, as much of it as the AppleScript runner uses.
protocol AppleScriptFixtureProcess: AnyObject {
  var pid: pid_t { get }
  var exit: ProcessTree.Exit? { get }
  var livePIDs: [pid_t] { get }
  func wait(seconds: Double) -> ProcessTree.Exit?
  func cleanup() -> [pid_t]
}

extension ProcessTree: AppleScriptFixtureProcess {}

private extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Every match of a regular expression, or of one of its groups.
  func matches(of pattern: String, group: Int) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    return expression.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap {
      Range($0.range(at: group), in: self).map { String(self[$0]) }
    }
  }
}

private extension Double {
  /// Without a fraction when there is none: 4, 0.1.
  var plain: String { self == rounded() ? String(Int(self)) : String(self) }
}

private extension Array where Element: BinaryInteger {
  var listed: String { map { String($0) }.joined(separator: ", ") }
}

import Foundation
import Testing
@testable import dev

@Suite struct AppleScriptSmokeTests {
  @Test("applescript smoke: the dictionary exposes selection word characters with the automation key") func theDictionaryExposesSelectionWordCharacters() throws {
    let dictionary = try String(contentsOfFile: Repository.path("Resources/Terminal/Terminal.sdef"), encoding: .utf8)
    let parameter = "<parameter name=\"word characters\" code=\"Hwrd\" type=\"text\" optional=\"yes\".*"
      + "<cocoa key=\"SelectionWordCharacters\"/></parameter>"
    #expect(dictionary.range(of: parameter, options: .regularExpression) != nil, "the word characters parameter is missing")
  }

  @Test("applescript smoke: the dictionary exposes pane colors") func theDictionaryExposesPaneColors() throws {
    let dictionary = try String(contentsOfFile: Repository.path("Resources/Terminal/Terminal.sdef"), encoding: .utf8)
    for pattern in [
      "(?s)<command name=\"apply pane color\" code=\"HTermapc\".*<cocoa class=\"TerminalApplyPaneColorCommand\"/>",
      "(?s)<command name=\"read pane color\" code=\"HTermrpc\".*<cocoa class=\"TerminalReadPaneColorCommand\"/>",
      "<parameter name=\"default pane color\" code=\"Hdpc\" type=\"text\" optional=\"yes\".*"
        + "<cocoa key=\"DefaultPaneColor\"/></parameter>",
    ] {
      #expect(dictionary.range(of: pattern, options: .regularExpression) != nil, "missing: \(pattern)")
    }
  }

  @Test("applescript smoke: a bounded command that times out is ended and reaped") func aBoundedCommandThatTimesOut() throws {
    let timeout = try #require(throws: AppleScriptSmoke.CommandTimeout.self) {
      _ = try AppleScriptSmoke.capture(["/bin/sleep", "30"], timeout: 0.1)
    }
    #expect(timeout.status?.signal == SIGTERM && timeout.status?.exitStatus == nil, "ended by the polite request")
    #expect(timeout.message == "Automation command timed out after 0.1 seconds.", "got: \(timeout.message)")
    let finished = try AppleScriptSmoke.capture(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"])
    #expect(finished.output == "out\nerr\n" && finished.status.exitStatus == 3, "output and status of a finished command")
  }

  @Test("applescript smoke: a failed lock never overwrites another fixture's report") func aFailedLockNeverOverwrites() throws {
    try withTemporaryDirectory("dev-applescript-lock-") { root in
      try FileManager.default.createDirectory(atPath: root + "/target", withIntermediateDirectories: true)
      let held = open(root + "/target/automation-fixture.lock", O_RDWR | O_CREAT, 0o600)
      defer { close(held) }
      #expect(flock(held, LOCK_EX | LOCK_NB) == 0, "the test holds the lock")
      let message = failureMessage { try AppleScriptSmoke.Session(root: root, environment: [:]).run() }
      #expect(message?.contains("Another AppleScript fixture owns") == true, "got: \(message ?? "no failure")")
      #expect(!FileManager.default.fileExists(atPath: root + "/reports/applescript-smoke.json"), "a report was written")
      #expect(flock(held, LOCK_EX | LOCK_NB) == 0, "the owner still holds the lock")
    }
  }

  @Test("applescript smoke: a cleanup failure is reported as a failed run") func aCleanupFailureIsReported() throws {
    try withTemporaryDirectory("dev-applescript-cleanup-") { root in
      let message = failureMessage { try CleanupFailureSession(root: root, environment: [:]).run() }
      #expect(message?.contains("Fixture cleanup left processes: 4242") == true, "got: \(message ?? "no failure")")
      let report = try JSONValue(parsingFile: root + "/reports/applescript-smoke.json")
      #expect(report["passed"]?.truth == false, "the report says passed")
      #expect(report["failure"]?.text?.contains("Fixture cleanup left processes") == true, "the report names the failure")
      #expect(report["cleanup"]?["survivors"]?.compact == "[4242]", "the survivors are recorded")
      #expect(!FileManager.default.fileExists(atPath: root + "/target/automation-fixture"), "the fixture is removed")
    }
  }

  @Test("applescript smoke: a cleanup failure is reported when the fixture directory is already gone") func aCleanupFailureIsReportedWhenTheDirectoryIsGone() throws {
    try withTemporaryDirectory("dev-applescript-gone-") { root in
      let message = failureMessage { try MissingFixtureSession(root: root, environment: [:]).run() }
      #expect(message?.contains("Fixture cleanup left processes: 4242") == true, "got: \(message ?? "no failure")")
      let report = try JSONValue(parsingFile: root + "/reports/applescript-smoke.json")
      #expect(report["passed"]?.truth == false, "the report says passed")
      #expect(report["failure"]?.text == "Fixture cleanup left processes: 4242", "the report names the failure")
      #expect(report["cleanup"]?["error"]?.text == "Fixture cleanup left processes: 4242", "the cleanup records it")
    }
  }

  @Test("applescript smoke: a string literal escapes backslashes before quotes") func aStringLiteralEscapesBackslashes() throws {
    #expect(AppleScriptSmoke.literal("plain") == "\"plain\"", "plain text is quoted")
    #expect(AppleScriptSmoke.literal(#"a\b"c"#) == #""a\\b\"c""#, "got: \(AppleScriptSmoke.literal(#"a\b"c"#))")
    #expect(AppleScriptSmoke.literal(#"ends with \"#) == #""ends with \\""#, "a final backslash does not escape the closing quote")
  }

  @Test("applescript smoke: a report failure still releases the lock and fails the run") func aReportFailureStillReleasesTheLock() throws {
    try withTemporaryDirectory("dev-applescript-report-") { root in
      let message = failureMessage { try ReportFailureSession(root: root, environment: [:]).run() }
      #expect(message == "report device full", "got: \(message ?? "no failure")")
      let lock = open(root + "/target/automation-fixture.lock", O_RDWR | O_CREAT, 0o600)
      defer { close(lock) }
      #expect(flock(lock, LOCK_EX | LOCK_NB) == 0, "the lock is still held")
    }
  }

  @Test("applescript smoke: the receipt shell hashes every byte before return") func theReceiptShellHashesEveryByte() throws {
    try withTemporaryDirectory("dev-applescript-receipt-") { root in
      let session = AppleScriptSmoke.Session(root: root, environment: ["TERMINAL_AUTOMATION_FIXTURE_ROOT": root])
      try session.writeFixtureShell()
      let process = Process(), input = Pipe(), output = Pipe()
      process.executableURL = URL(fileURLWithPath: session.receiptShell!)
      process.environment = ["TERMINAL_AUTOMATION_CHILD_PIDS": root + "/children.pids"]
      process.standardInput = input
      process.standardOutput = output
      process.standardError = output
      try process.run()
      input.fileHandleForWriting.write(Data((AppleScriptSmoke.largeCommittedText + "\rafter").utf8))
      input.fileHandleForWriting.closeFile()
      let transcript = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()
      #expect(process.terminationStatus == 0, "the receipt shell failed: \(transcript)")
      let receipt = sha256(of: Data(AppleScriptSmoke.largeCommittedText.utf8))
      #expect(transcript.contains("AUTOMATION_RECEIPT \(receipt)\n"), "got: \(transcript)")
      #expect(session.recordedChildren() == [Int(process.processIdentifier)], "the shell records its PID")
      let wrapped = "AUTOMATION_RECEIPT \(receipt.prefix(38))\r\n\(receipt.dropFirst(38))"
      #expect(AppleScriptSmoke.receiptInSnapshot(wrapped, receipt), "a wrapped receipt is found")
      #expect(!AppleScriptSmoke.receiptInSnapshot(wrapped, String(receipt.reversed())), "another receipt is not")
    }
  }

  @Test("applescript smoke: a truncated transcript stays valid UTF-8 and a record keeps its own timeout") func aTruncatedTranscriptStaysValidUTF8() throws {
    let text = String(repeating: "x", count: AppleScriptSmoke.outputLimit - 1) + "é" + "trailing"
    let truncated = AppleScriptSmoke.truncate(text)
    #expect(truncated.hasPrefix(String(repeating: "x", count: AppleScriptSmoke.outputLimit - 1) + "\u{FFFD}… [truncated 9 bytes]"),
               "got: \(truncated.suffix(40))")
    #expect(AppleScriptSmoke.truncate("short") == "short", "short text is kept")
    let session = AppleScriptSmoke.Session(root: "/nowhere", environment: [:])
    let record = session.commandRecord("permission", "JavaScript", "0", "", nil, timedOut: false, timeout: AppleScriptSmoke.consentTimeout)
    #expect(record["timeout_seconds"]?.whole == 60, "the consent timeout is recorded")
    #expect(record["exit_status"]?.compact == "null" && record["signaled"]?.compact == "null", "no status is recorded as null")
    #expect(record["script_sha256"]?.text == sha256(of: Data("0".utf8)), "the script is identified by its hash")
  }

  @Test("applescript smoke: the permission check maps its answer to an outcome") func thePermissionCheckMapsItsAnswer() throws {
    try withTemporaryDirectory("dev-applescript-permission-") { root in
      func outcome(_ answer: String, _ environment: [String: String] = [:]) throws -> (session: AppleScriptSmoke.Session, error: Error?) {
        let session = AppleScriptSmoke.Session(root: root, environment: environment)
        session.osascript = root + "/osascript"
        try writeScript("echo '\(answer)' >&2", to: session.osascript)
        do { try session.preflightPermission() } catch { return (session, error) }
        return (session, nil)
      }
      let permitted = try outcome("0")
      #expect(permitted.error == nil && permitted.session.permission["outcome"]?.text == "permitted", "0 is permitted")
      #expect(permitted.session.commands.first?["timeout_seconds"]?.whole == 4, "an unattended check is short")
      #expect(permitted.session.commands.first?["command"]?.elements?.last?.text?.contains("1213490546, 1835426675, false") == true,
                 "the check names the event and does not prompt")
      func kind(_ error: Error?) -> String {
        switch error as? AppleScriptSmoke.Consent {
        case .required?: return "required"
        case .denied?: return "denied"
        case nil: return "other"
        }
      }
      #expect(kind(try outcome("-1744").error) == "required", "-1744 without a request is consent_required")
      let asked = try outcome("-1744", ["TERMINAL_AUTOMATION_REQUEST_CONSENT": "1"])
      #expect(kind(asked.error) == "denied", "-1744 after a request is consent_denied")
      #expect(asked.session.commands.first?["timeout_seconds"]?.whole == 60, "a requested check waits for the person")
      #expect(asked.session.permission["requested_standard_consent"]?.truth == true, "the request is recorded")
      #expect(kind(try outcome("-1743").error) == "denied", "-1743 is consent_denied")
      #expect(AppleScriptSmoke.message(try outcome("maybe").error ?? Failure("")).contains("non-numeric"), "other output is an error")
    }
  }

  @Test("applescript smoke: the dictionary conversation passes against a scripted fake") func theDictionaryConversationPasses() throws {
    try withTemporaryDirectory("dev-applescript-dictionary-") { root in
      let session = try fakeDictionarySession(root: root, pane: "no.helgesverre.terminal.pane.")
      try session.exerciseDictionary()
      let names = session.commands.compactMap { $0["name"]?.text }
      #expect(names.count == 34 && names.first == "get fixture name" && names.last == "quit fixture", "commands: \(names)")
      #expect(names.contains("hide fixture") && names.filter { $0.hasPrefix("reject") }.count == 7, "commands: \(names)")
      #expect(session.childPIDs.count == 5, "every pane's program is recorded")
      #expect(session.commands.allSatisfy { $0["timed_out"]?.truth == false }, "nothing timed out")
    }
  }

  @Test("applescript smoke: a wrong answer from the app fails the conversation") func aWrongAnswerFailsTheConversation() throws {
    try withTemporaryDirectory("dev-applescript-wrong-") { root in
      let session = try fakeDictionarySession(root: root, pane: "pane.")
      let message = failureMessage { try session.exerciseDictionary() }
      #expect(message?.contains("Invalid pane identifier: \"pane.A1\"") == true, "got: \(message ?? "no failure")")
      #expect(session.commands.last?["name"]?.text == "initial focus pane", "the conversation stops there")
    }
  }
}

/// The message of the error `body` throws, or nil when it throws nothing.
private func failureMessage(_ body: () throws -> Void) -> String? {
  do { try body() } catch { return AppleScriptSmoke.message(error) }
  return nil
}

/// A session whose scripts go to a shell script that answers as the app
/// would, naming its panes `pane` and a suffix. No script reaches
/// `osascript`, so no Apple event is sent.
private func fakeDictionarySession(root: String, pane: String) throws -> AppleScriptSmoke.Session {
  let session = AppleScriptSmoke.Session(root: root, environment: ["TERMINAL_AUTOMATION_FIXTURE_ROOT": root])
  try session.writeFixtureShell()
  try "11\n12\n13\n14\n15\n".write(toFile: session.childPIDsPath!, atomically: true, encoding: .utf8)
  session.process = FakeFixtureProcess()
  session.osascript = root + "/osascript"
  // The source is the fourth argument. The first matching pattern answers.
  try writeScript("""
    refuse() { echo "execution error: refused ($1)" >&2; exit 1; }
    case "$4" in
      *"to get name") echo "\(AppleScriptSmoke.fixtureName)" ;;
      *"to get id") echo "\(AppleScriptSmoke.fixtureBundleID)" ;;
      *"pane.missing\\"") refuse -1728 ;;
      *"to focus pane"|*"focus pane pane id"*|*"send text"*|*"to clear screen") echo "\(pane)A1" ;;
      *"to new window") echo "\(pane)B2" ;;
      *"chartreuse"*) refuse -1700 ;;
      *"apply pane color \\"OCEAN\\""*) touch "$0.ocean"; echo "\(pane)C3" ;;
      *"apply pane color \\"default\\""*) rm -f "$0.ocean"; echo "\(pane)C3" ;;
      *"read pane color"*"C3"*) if [ -e "$0.ocean" ]; then echo "#2E6376"; else echo "#18191C"; fi ;;
      *"read pane color"*) echo "#18191C" ;;
      *"split right"*) echo "\(pane)C3" ;;
      *"split below"*) echo "\(pane)D4" ;;
      *"to new tab") echo "\(pane)E5" ;;
      *"close pane"*) touch "$0.closed" ;;
      *"to list panes")
        if [ -e "$0.closed" ]; then echo "\(pane)A1"; else echo "\(pane)A1, \(pane)B2, \(pane)C3, \(pane)D4, \(pane)E5"; fi ;;
      *"max characters 0"|*"max characters 262145"|*"font size 7.0"|*"/does/not/exist\\""|*"\\"not valid\\"") refuse -1700 ;;
      *"max characters 2048") echo "AUTOMATION_RECEIPT \(sha256(of: Data(AppleScriptSmoke.largeCommittedText.utf8)))" ;;
      *"configure preferences"*) echo "font size 15, word characters -/@_, default pane color #2B6A65" ;;
    esac
    """, to: session.osascript)
  return session
}

private final class FakeFixtureProcess: AppleScriptFixtureProcess {
  var survivors: [pid_t] = []
  var pid: pid_t { 0 }
  var exit: ProcessTree.Exit? { nil }
  var livePIDs: [pid_t] { [] }
  func wait(seconds: Double) -> ProcessTree.Exit? { nil }
  func cleanup() -> [pid_t] { survivors }
}

/// Skips the stages that need a signed app, and reports a process that survives cleanup.
private class CleanupFailureSession: AppleScriptSmoke.Session {
  override func validateConfiguration() throws { signingIdentity = "test identity" }
  override func prepareFixture() throws {
    try FileManager.default.createDirectory(atPath: fixtureRoot, withIntermediateDirectories: true)
  }
  override func launchFixture() throws {
    let fake = FakeFixtureProcess()
    fake.survivors = [4242]
    process = fake
  }
  override func preflightPermission() throws { permission = ["status": 0, "outcome": "permitted"] }
  override func exerciseDictionary() throws {}
  override func verifyCleanExit() throws {}
  override func forgetFixturePreferences() {}
}

/// The same, with the fixture directory never made.
private final class MissingFixtureSession: CleanupFailureSession {
  override func prepareFixture() throws {}
}

private final class ReportFailureSession: CleanupFailureSession {
  override func launchFixture() throws {}
  override func writeReport() throws { throw Failure("report device full") }
}

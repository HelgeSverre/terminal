import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

@Suite @MainActor struct SessionEndTests {
  /// A left shell closes its pane; a shell that fails as it starts, and any
  /// other command, leave it open to be read.
  @Test func onlyALeftShellClosesItsPane() {
    func closes(_ clean: Bool, _ seconds: Double, shell: Bool = true) -> Bool {
      SessionEnd(exitedCleanly: clean, seconds: seconds, ranLoginShell: shell).closesPane
    }
    #expect(closes(true, 0.2), "exit straight away")
    #expect(closes(true, 3600), "exit after a long session")
    #expect(closes(false, 30), "exit with the last command's failure status")
    #expect(!closes(false, 0.3), "a shell that cannot start")
    #expect(!closes(true, 30, shell: false), "a command run with --execute")
    #expect(!closes(false, 30, shell: false))
  }

  @Test(arguments: [(0, true), (3, false)])
  func theEndReportsHowTheChildExited(status: Int, clean: Bool) async {
    let session = Session(launch: TestEnvironment.shell("printf SESSION_END_READY; exit \(status)"))
    defer { session.close() }
    var end: SessionEnd?
    var ends = 0
    session.onEnd = { end = $0; ends += 1 }
    #expect(await TestEnvironment.wait { end != nil })
    #expect(end?.exitedCleanly == clean)
    #expect(end?.exitCode == Int32(status))
    #expect(end?.terminatingSignal == nil)
    #expect(end?.ranLoginShell == false, "/bin/sh -c is not the login shell")
    // Told once, also after the session is closed.
    session.close()
    _ = await TestEnvironment.wait(seconds: 0.3) { false }
    #expect(ends == 1)
  }

  @Test func theEndNamesTheSignalThatKilledTheChild() async {
    let session = Session(launch: TestEnvironment.shell("printf SESSION_END_READY; kill -TERM $$"))
    defer { session.close() }
    var end: SessionEnd?
    session.onEnd = { end = $0 }
    #expect(await TestEnvironment.wait { end != nil })
    #expect(end?.exitCode == nil)
    #expect(end?.terminatingSignal == SIGTERM)
    #expect(end?.exitedCleanly == false)
  }

  /// A host names the variables its child gets, the terminal's own included.
  @Test func theLaunchEnvironmentReplacesTheChildsVariables() async {
    var launch = TestEnvironment.shell(#"printf 'ENV<%s|%s|%s>' "$TERM_PROGRAM" "$HOST_MARK" "$TERM"; exit 0"#)
    launch.environment = ["TERM_PROGRAM": "HostApp", "HOST_MARK": "a b=c"]
    let session = Session(launch: launch)
    defer { session.close() }
    var text = ""
    session.onSnapshot = { text = $0.rows.map { $0.cells.map(\.text).joined() }.joined() }
    #expect(await TestEnvironment.wait { text.contains("ENV<HostApp|a b=c|xterm-256color>") }, "\(text.prefix(80))")
  }

  /// A launch that cannot start says which step failed, as a value.
  @Test func aFailedLaunchIsReportedWithItsStage() async {
    let missing = Session(launch: LaunchSpec(
      executable: "/nonexistent/program", arguments: ["program"], cwd: "/tmp", launcher: TestEnvironment.launcher))
    defer { missing.close() }
    var failure: SessionLaunchFailure?
    missing.onLaunchFailure = { failure = $0 }
    #expect(await TestEnvironment.wait { failure != nil })
    #expect(failure == .stage(.execute, errno: ENOENT))

    let nowhere = Session(launch: LaunchSpec(
      executable: "/bin/sh", arguments: ["/bin/sh"], cwd: "/nonexistent/directory", launcher: TestEnvironment.launcher))
    defer { nowhere.close() }
    var second: SessionLaunchFailure?
    nowhere.onLaunchFailure = { second = $0 }
    #expect(await TestEnvironment.wait { second != nil })
    #expect(second == .stage(.workingDirectory, errno: ENOENT))

    let invalid = Session(launch: LaunchSpec(
      executable: "/bin/sh", arguments: [], cwd: "/tmp", launcher: TestEnvironment.launcher))
    defer { invalid.close() }
    var third: SessionLaunchFailure?
    invalid.onLaunchFailure = { third = $0 }
    #expect(await TestEnvironment.wait { third != nil })
    #expect(third == .invalidArguments)
  }

  /// A host that lets go of a session without closing it must not leave the
  /// child running.
  @Test func releasingASessionEndsItsChild() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("session-release-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    var session: Session? = Session(launch: TestEnvironment.shell("echo $$ > '\(file.path)'; exec /bin/sleep 60"))
    var status: [String] = []
    session?.onStatus = { status.append($0) }
    #expect(await TestEnvironment.wait { (try? String(contentsOf: file, encoding: .utf8))?.hasSuffix("\n") == true })
    let child = try #require(Int32((try String(contentsOf: file, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(child, 0) == 0, "the child runs while its session lives")
    weak let released = session
    session = nil
    #expect(await TestEnvironment.wait(seconds: 2) { released == nil }, "something still holds the session")
    // A child that is dead but not reaped still answers `kill`.
    let gone = await TestEnvironment.wait(seconds: 5) { kill(child, 0) != 0 }
    #expect(gone, "the child outlived its session")
  }

  /// The host's status handler and the view's are separate: neither replaces
  /// the other.
  @Test func theHostAndTheViewBothHearStatus() async {
    let session = Session(launch: TestEnvironment.shell("printf SESSION_END_READY; exit 0"))
    defer { session.close() }
    var host: [String] = []
    var view: [String] = []
    session.onStatus = { host.append($0) }
    session.onViewStatus = { view.append($0) }
    #expect(await TestEnvironment.wait { host.contains("Session finished") && view.contains("Session finished") })
  }

  /// A background job that keeps the terminal open must not keep the pane
  /// after the shell itself has exited.
  @Test func theEndArrivesWhileABackgroundJobHoldsTheTerminal() async {
    let session = Session(launch: TestEnvironment.shell("sleep 30 & printf SESSION_END_READY; exit 0"))
    defer { session.close() }
    var end: SessionEnd?
    session.onEnd = { end = $0 }
    #expect(await TestEnvironment.wait(seconds: 3) { end != nil }, "no end while a background job holds the PTY")
  }
}

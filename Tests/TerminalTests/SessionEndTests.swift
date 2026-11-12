import Foundation
import Testing
@testable import TerminalApp

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
    #expect(end?.ranLoginShell == false, "/bin/sh -c is not the login shell")
    // Told once, also after the session is closed.
    session.close()
    _ = await TestEnvironment.wait(seconds: 0.3) { false }
    #expect(ends == 1)
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

import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession

@Suite @MainActor struct SessionStartTests {
  private func screen(_ snapshot: TerminalSnapshot) -> String {
    snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
  }

  /// A pane's shell must start on a terminal of the pane's size, not on an
  /// 80 by 24 one that is resized a moment later: the child reads the size
  /// once, as it starts, and must see the real one.
  @Test func aChildStartedAtTheFirstGridSeesThatGrid() async {
    let session = Session(
      launch: TestEnvironment.shell("printf 'SIZE=%s.' \"$(stty size)\"; exec /bin/cat"), startsAtFirstGrid: true)
    defer { session.close() }
    var text = ""
    session.onSnapshot = { text = self.screen($0) }
    // Nothing runs until the size is known.
    _ = await TestEnvironment.wait(seconds: 0.3) { false }
    #expect(!text.contains("SIZE="), "the child must wait for its grid")
    session.resize(cols: 40, rows: 10, cellWidth: 9, cellHeight: 19)
    #expect(await TestEnvironment.wait { text.contains("SIZE=") })
    #expect(text.contains("SIZE=10 40."), "got: \(text.trimmingCharacters(in: .whitespaces))")
  }

  /// A pane that is never laid out still gets its child, at the default size.
  @Test func aChildWithoutAGridStartsAfterAMoment() async {
    let session = Session(
      launch: TestEnvironment.shell("printf 'SIZE=%s.' \"$(stty size)\"; exec /bin/cat"), startsAtFirstGrid: true)
    defer { session.close() }
    var text = ""
    session.onSnapshot = { text = self.screen($0) }
    #expect(await TestEnvironment.wait(seconds: 4) { text.contains("SIZE=24 80.") })
  }

  /// Closing before the child exists must not start one.
  @Test func closingBeforeTheFirstGridStartsNothing() async {
    let session = Session(launch: TestEnvironment.shell("printf STARTED; exec /bin/cat"), startsAtFirstGrid: true)
    var text = ""
    session.onSnapshot = { text = self.screen($0) }
    session.close()
    _ = await TestEnvironment.wait(seconds: 1.5) { false }
    #expect(!text.contains("STARTED"))
  }
}

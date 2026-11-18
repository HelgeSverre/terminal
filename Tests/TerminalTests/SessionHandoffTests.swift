import Darwin
import Foundation
import Testing
@testable import TerminalEngine
@testable import TerminalHost

/// A child given up by one session and adopted by another keeps running,
/// with the screen and modes it had.
@Suite(.serialized) @MainActor struct SessionHandoffTests {
  private func text(_ snapshot: TerminalSnapshot?) -> String {
    snapshot?.rows.map { $0.cells.map(\.text).joined() }.joined(separator: "\n") ?? ""
  }
  private func detach(_ session: TerminalSession) async -> SessionHandoff? {
    var result: SessionHandoff??
    session.detachForHandoff { result = .some($0) }
    _ = await TestEnvironment.wait { result != nil }
    return result ?? nil
  }

  @Test func aChildSurvivesTwoHandoffsWithItsScreenAndInput() async throws {
    let script = #"printf '\033[?1049h\033[?25l\033[3;5HALT_READY'; while read line; do printf 'got:%s\n' "$line"; done"#
    let first = TerminalSession(launch: TestEnvironment.shell(script))
    var latest: TerminalSnapshot?
    first.onSnapshot = { latest = $0 }
    #expect(await TestEnvironment.wait { text(latest).contains("ALT_READY") })
    let pid = try #require(first.processIdentifier)
    let handoff = try #require(await detach(first))
    #expect(handoff.processIdentifier == pid && handoff.descriptor >= 0)
    #expect(await detach(first) == nil, "a session hands its child off once")
    first.close()
    try await Task.sleep(for: .milliseconds(300))
    #expect(kill(pid, 0) == 0, "closing the old session leaves the child running")

    var current = handoff
    var sessions: [TerminalSession] = []
    for round in 1...2 {
      let next = TerminalSession(adopting: current, launch: TestEnvironment.shell(script))
      sessions.append(next)
      var seen: TerminalSnapshot?
      next.onSnapshot = { seen = $0 }
      next.resize(cols: 80, rows: 24)
      #expect(await TestEnvironment.wait { text(seen).contains("ALT_READY") }, "round \(round) restores the screen")
      #expect(seen?.alternate == true && seen?.cursor.visible == false)
      #expect(next.processIdentifier == pid)
      #expect(next.input("ping\(round)\n"))
      #expect(await TestEnvironment.wait { text(seen).contains("got:ping\(round)") }, "round \(round) reaches the same child")
      guard round == 1 else { break }
      current = try #require(await detach(next))
      next.close()
    }
    #expect(kill(pid, 0) == 0)
    sessions.last?.close()
    #expect(await TestEnvironment.wait(seconds: 4) { kill(pid, 0) != 0 }, "closing the last owner ends the child")
  }

  @Test func aSessionWithoutARunningChildHasNothingToHandOff() async throws {
    let ended = TerminalSession(launch: TestEnvironment.shell("exit 0"))
    var finished = false
    ended.onEnd = { _ in finished = true }
    #expect(await TestEnvironment.wait { finished })
    #expect(await detach(ended) == nil)
    ended.close()
    #expect(await detach(ended) == nil)
  }
}

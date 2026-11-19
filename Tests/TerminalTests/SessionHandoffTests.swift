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

  @Test func aProcessIsToldFromALaterOneWithItsNumber() throws {
    let own = try #require(ProcessIdentity.start(of: getpid()))
    #expect(ProcessIdentity.holds(getpid(), startedAt: own))
    #expect(!ProcessIdentity.holds(getpid(), startedAt: own + 1))
    let ended = Process()
    ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try ended.run()
    ended.waitUntilExit()
    #expect(ProcessIdentity.start(of: ended.processIdentifier) == nil)
  }

  /// The adopted child ended and its number went to a process that has
  /// nothing to do with the terminal: closing the pane must leave that one be.
  @Test func closingAnAdoptedSessionSparesAProcessThatTookItsChildsNumber() async throws {
    let first = TerminalSession(launch: TestEnvironment.shell("printf READY; while read line; do :; done"))
    var latest: TerminalSnapshot?
    first.onSnapshot = { latest = $0 }
    #expect(await TestEnvironment.wait { text(latest).contains("READY") })
    let handoff = try #require(await detach(first))
    first.close()
    defer { kill(handoff.processIdentifier, SIGKILL) }

    let starter = Process(), output = Pipe()
    starter.executableURL = URL(fileURLWithPath: "/bin/sh")
    starter.arguments = ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"]
    starter.standardOutput = output
    try starter.run()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    starter.waitUntilExit()
    let stranger = try #require(Int32(printed.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(stranger, SIGKILL) }
    #expect(kill(stranger, 0) == 0)

    let stale = SessionHandoff(descriptor: handoff.descriptor, processIdentifier: stranger,
                               processStart: handoff.processStart, terminal: handoff.terminal)
    let session = TerminalSession(adopting: stale, launch: TestEnvironment.shell("true"))
    var seen: TerminalSnapshot?
    session.onSnapshot = { seen = $0 }
    session.resize(cols: 80, rows: 24)
    #expect(await TestEnvironment.wait { text(seen).contains("READY") })
    session.close()
    // A child still there two seconds after its hangup is killed.
    try await Task.sleep(for: .milliseconds(2600))
    #expect(kill(stranger, 0) == 0)
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

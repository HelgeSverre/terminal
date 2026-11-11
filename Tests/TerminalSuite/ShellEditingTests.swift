import Darwin
import Foundation
import Testing
@testable import TerminalApp

// An end-to-end guard for the class of bugs where a shell's line editor and
// terminal disagree about the width of a Unicode prompt. This owns an isolated
// interactive zsh and reaches it through Session's real PTY; it deliberately
// does not inherit shell startup files, history, or completion configuration.
// Serialized: it sets TERMINAL_SHELL_EDIT_STATE and clears locale and color
// variables in the process environment while the child runs.
@Suite(.serialized) @MainActor struct ShellEditingTests {
  /// Variables the old recipe removed from the test's environment. A
  /// non-UTF-8 LC_ALL or LC_CTYPE would override the UTF-8 LANG the spawner
  /// gives the child and fail the locale check, and color settings change
  /// what the shell and completion print. The child inherits the process
  /// environment, so the test clears them and restores them afterwards.
  private static let isolatedVariables = ["LANG", "LC_ALL", "LC_CTYPE", "NO_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "FORCE_COLOR"]

  @Test static func isolatedZshEditing() async throws {
    let runID = UUID().uuidString
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("Terminal shell editing 猫 \(runID)", isDirectory: true)
    let statePath = fixture.appendingPathComponent("zle-state")
    var latest: TerminalSnapshot?
    var reaped = false
    var statuses: [String] = []

    var saved: [String: String] = [:]
    for name in isolatedVariables {
      if let value = getenv(name) { saved[name] = String(cString: value) }
      unsetenv(name)
    }
    defer { for (name, value) in saved { setenv(name, value, 1) } }

    func text(_ snapshot: TerminalSnapshot?) -> String {
      snapshot?.rows.flatMap(\.cells).map(\.text).joined() ?? ""
    }
    func currentRow(_ snapshot: TerminalSnapshot?) -> String {
      guard let snapshot, snapshot.cursor.row >= 0, snapshot.cursor.row < snapshot.rows.count else { return "" }
      return snapshot.rows[snapshot.cursor.row].cells.map(\.text).joined()
    }
    func renderedInput(_ snapshot: TerminalSnapshot?) -> String {
      currentRow(snapshot)
        .replacingOccurrences(of: "SHELL_EDIT_REDRAW_RPROMPT", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func waitFor(_ label: String, timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
      let completed = await TestEnvironment.wait(seconds: timeout, until: condition)
      #expect(completed, "timed out waiting for \(label); visible=\(text(latest).suffix(512))")
      return completed
    }
    func send(_ session: Session, _ value: String, key: UInt32 = 0) {
      #expect(session.input(value, key: key), "input rejected: key=\(key), bytes=\(value.utf8.count)")
    }
    func enter(_ session: Session) { session.rawInput(Data([13])) }
    func probe(_ session: Session) { session.rawInput(Data([7])) } // Bound to a private zle widget below.
    func readState() -> [String]? {
      guard let value = try? String(contentsOf: statePath, encoding: .utf8) else { return nil }
      return value.trimmingCharacters(in: .newlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }
    func probeReceipt(after sequence: Int, buffer: String, cursor: Int) async -> Int? {
      var received: Int?
      let label = "probe \(sequence + 1) \(buffer) at \(cursor)"
      guard await waitFor(label, {
        guard let state = readState(), state.count == 4, state[0] == "PROBE",
          let next = Int(state[1]), next == sequence + 1, state[2] == buffer, state[3] == String(cursor),
          latest?.cursor.visible == true, latest?.cursor.col == 2 + cursor,
          renderedInput(latest) == "❯ \(buffer)"
        else { return false }
        received = next
        return true
      }) else { return nil }
      return received
    }

    defer { try? FileManager.default.removeItem(at: fixture) }
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
    for name in ["crescat", "crescat-app", "crescat-printer", "crescat-猫"] {
      try FileManager.default.createDirectory(at: fixture.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    try #require(setenv("TERMINAL_SHELL_EDIT_STATE", statePath.path, 1) == 0, "set state environment")
    defer { unsetenv("TERMINAL_SHELL_EDIT_STATE") }

    let session = Session(launch: LaunchSpec(
      executable: "/bin/zsh", arguments: ["/bin/zsh", "-dfi"], cwd: fixture.path, launcher: TestEnvironment.launcher))
    session.onSnapshot = { latest = $0 }
    session.onStatus = {
      statuses.append($0)
      if $0.hasPrefix("Process exited") { reaped = true }
    }

    var continueTesting = await waitFor("initial isolated zsh prompt", {
      latest?.cursor.visible == true && !text(latest).isEmpty
    })

    // ZLE's widget observes the shell's real BUFFER and CURSOR, rather than
    // inferring an edit from terminal text. The control-G byte comes through
    // Session's real PTY write after each edit transaction.
    let setup = [
      "autoload -Uz compinit", "compinit -D", "bindkey '^I' expand-or-complete",
      "PS1=$'%F{blue}猫 SHELL_EDIT_PROMPT%f\\n%F{magenta}❯%f '",
      "RPS1=$'%F{green}SHELL_EDIT_RPROMPT%f'",
      "typeset -g TERMINAL_SHELL_EDIT_PROBE=0",
      "function terminal_edit_probe() { (( TERMINAL_SHELL_EDIT_PROBE += 1 )); print -r -- \"PROBE|${TERMINAL_SHELL_EDIT_PROBE}|${BUFFER}|${CURSOR}\" >| \"$TERMINAL_SHELL_EDIT_STATE\"; zle redisplay; }",
      "function terminal_edit_redraw() { PS1=$'%F{cyan}猫 SHELL_EDIT_REDRAW_PROMPT%f\\n%F{magenta}❯%f '; RPS1=$'%F{yellow}SHELL_EDIT_REDRAW_RPROMPT%f'; zle reset-prompt; }",
      "zle -N terminal_edit_probe", "bindkey '^G' terminal_edit_probe",
      "zle -N terminal_edit_redraw", "bindkey '^T' terminal_edit_redraw",
      "print -r -- \"READY|$PWD|$(locale charmap)\" >| \"$TERMINAL_SHELL_EDIT_STATE\"",
    ]
    if continueTesting {
      for command in setup { send(session, command); enter(session) }
      continueTesting = await waitFor("isolated zsh setup receipt", {
        guard let state = readState(), state.count == 3, state[0] == "READY" else { return false }
        return state[1] == fixture.path && (state[2] == "UTF-8" || state[2] == "UTF8")
      })
    }

    if continueTesting {
      // Ctrl-T is a fixture-owned ZLE widget that replaces the colored Unicode
      // prompt and calls reset-prompt while ZLE owns an incomplete command.
      // This models prompt engines' asynchronous redraw boundary without making
      // unsupported claims about arbitrary background output interleaving.
      send(session, "cd cresca")
      session.rawInput(Data([20]))
      continueTesting = await waitFor("prompt redraw during editable line", {
        text(latest).contains("SHELL_EDIT_REDRAW_PROMPT") && currentRow(latest).contains("cd cresca")
      })
    }
    if continueTesting {
      session.resize(cols: 34, rows: 12)
      session.resize(cols: 88, rows: 20)
      continueTesting = await waitFor("post-edit resize", { latest?.cols == 88 })
    }
    var sequence = 0
    if continueTesting {
      send(session, "", key: 21)
      send(session, "", key: 21)
      continueTesting = await waitFor("real directory completion listing", {
        let visible = text(latest)
        return visible.contains("crescat-app") && visible.contains("crescat-printer")
      })
    }
    if continueTesting {
      probe(session)
      if let next = await probeReceipt(after: sequence, buffer: "cd crescat", cursor: 10) { sequence = next } else { continueTesting = false }
    }
    if continueTesting {
      for _ in 0..<3 { send(session, "", key: 20) }
      send(session, "cat")
      probe(session)
      if let next = await probeReceipt(after: sequence, buffer: "cd crescat", cursor: 10) { sequence = next } else { continueTesting = false }
    }
    if continueTesting {
      send(session, "", key: 13)
      send(session, "", key: 13)
      probe(session)
      if let next = await probeReceipt(after: sequence, buffer: "cd crescat", cursor: 8) { sequence = next } else { continueTesting = false }
      send(session, "X")
      probe(session)
      if let next = await probeReceipt(after: sequence, buffer: "cd crescXat", cursor: 9) { sequence = next } else { continueTesting = false }
      send(session, "", key: 20)
      probe(session)
      if await probeReceipt(after: sequence, buffer: "cd crescat", cursor: 8) == nil { continueTesting = false }
    }

    session.close()
    let childReaped = await waitFor("zsh child reaping", timeout: 3, { reaped })
    #expect(childReaped && reaped)
    #expect(!statuses.contains(where: { $0.hasPrefix("Process failed") }), "zsh session failed: \(statuses)")
  }
}

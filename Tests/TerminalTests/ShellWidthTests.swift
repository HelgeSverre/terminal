import Foundation
import Testing
import TerminalEngine
@testable import TerminalHost

/// zsh's line editor moves the cursor by its own count of columns, one code
/// point at a time. The terminal must count the same way or an edit lands in
/// the wrong place; see "Shell line editing after emoji sequences" in BUGS.md.
@Suite(.serialized) @MainActor struct ShellWidthTests {
  /// Types a line holding an emoji with a skin tone, edits it at both ends,
  /// and returns the edited line as the terminal shows it.
  private func editedLine(graphemeClustering: Bool) async -> String {
    let session = TerminalSession(launch: LaunchSpec(
      executable: "/bin/zsh", arguments: ["/bin/zsh", "-dfi"], cwd: NSTemporaryDirectory(),
      launcher: TestEnvironment.launcher, environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]))
    defer { session.close() }
    var configuration = TerminalSessionConfiguration()
    configuration.graphemeClustering = graphemeClustering
    session.configure(configuration)
    var rows: [String] = []
    session.onSnapshot = { snapshot in
      rows = snapshot.rows.map { row in
        var line = row.cells.map { $0.kind == .continuation ? "" : ($0.text.isEmpty ? " " : $0.text) }.joined()
        while line.hasSuffix(" ") { line.removeLast() }
        return line
      }
    }
    func type(_ text: String) { session.rawInput(Data(text.utf8)) }
    func shows(_ line: String) async -> Bool { await TestEnvironment.wait(seconds: 5) { rows.contains(line) } }

    _ = await TestEnvironment.wait(seconds: 5) { rows.contains { !$0.isEmpty } }
    type("unset HISTFILE; PS1='W> '; unsetopt PROMPT_SP\r")
    guard await TestEnvironment.wait(seconds: 5, until: { rows.last(where: { !$0.isEmpty }) == "W>" }) else { return "no prompt: \(rows)" }
    type(": \u{1F469}\u{1F3FD} tail")
    guard await shows("W> : \u{1F469}\u{1F3FD} tail") else { return "not typed: \(rows)" }
    // Left five times, to just after the emoji; insert there.
    type(String(repeating: "\u{1b}[D", count: 5) + "A")
    _ = await shows("W> : \u{1F469}\u{1F3FD}A tail")
    // To the start of the line; insert, then delete what was inserted.
    type("\u{01}xy")
    _ = await TestEnvironment.wait(seconds: 2) { rows.contains { $0.hasPrefix("W> xy") } }
    type("\u{7f}\u{7f}Z")
    _ = await TestEnvironment.wait(seconds: 3) { rows.contains("W> Z: \u{1F469}\u{1F3FD}A tail") }
    _ = await TestEnvironment.wait(seconds: 0.3) { false }
    return rows.last(where: { !$0.isEmpty }) ?? ""
  }

  /// The disagreement the other layout exists for: zsh counts four columns
  /// for the emoji, the clustered layout uses two, and zsh's redraw from the
  /// start of the line then overwrites its own prompt.
  @Test func zshOverwritesItsPromptWhenTheEmojiIsOneCluster() async {
    let line = await editedLine(graphemeClustering: true)
    #expect(line != "W> Z: \u{1F469}\u{1F3FD}A tail", "zsh and the clustered layout agree now: \(line)")
  }

  @Test func zshEditsALineWithASkinToneEmojiWhenLaidOutByCodePoint() async {
    #expect(await editedLine(graphemeClustering: false) == "W> Z: \u{1F469}\u{1F3FD}A tail")
  }
}

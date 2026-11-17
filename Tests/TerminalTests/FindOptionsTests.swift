#if os(macOS)
import AppKit
import Testing
@testable import TerminalUI
import TerminalEngine

@Suite @MainActor struct FindOptionsTests {
  @Test func togglesSubmitTheExistingQueryWithCurrentOptions() throws {
    let bar = TerminalFindBar(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
    let field = try #require(bar.subviews.first {
      $0.accessibilityIdentifier() == "no.helgesverre.terminal.find.query"
    } as? NSTextField)
    field.stringValue = "cat"
    var submitted: [String] = []
    bar.onQuery = { submitted.append($0) }
    #expect(bar.options == TerminalSearchOptions())
    for (identifier, expected) in [
      ("case", TerminalSearchOptions(caseSensitive: true)),
      ("word", TerminalSearchOptions(caseSensitive: true, wholeWord: true)),
      ("regex", TerminalSearchOptions(caseSensitive: true, wholeWord: true, regularExpression: true)),
    ] {
      let button = try #require(bar.subviews.first {
        $0.accessibilityIdentifier() == "no.helgesverre.terminal.find." + identifier
      } as? NSButton)
      button.performClick(nil)
      #expect(bar.options == expected)
    }
    #expect(submitted == ["cat", "cat", "cat"])
  }
}
#endif

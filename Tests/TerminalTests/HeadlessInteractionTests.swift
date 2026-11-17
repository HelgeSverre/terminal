import Foundation
import Testing
import TerminalEngine

/// Uses only the public embedding surface.
@Suite struct HeadlessInteractionTests {
  private func search(_ terminal: HeadlessTerminal, _ query: String, options: TerminalSearchOptions = .init()) -> HeadlessTerminal.SearchResult {
    var result = terminal.beginSearch(query, options: options)
    for _ in 0..<10_000 where result == .working { result = terminal.advanceSearch() }
    #expect(result != .working)
    return result
  }
  private func finish(_ terminal: HeadlessTerminal, _ progress: HeadlessTerminal.SelectionProgress) -> HeadlessTerminal.SelectionProgress {
    var result = progress
    for _ in 0..<10_000 where result == .pending { result = terminal.advanceSelection() }
    #expect(result != .pending)
    return result
  }

  private func singleMatch(_ result: HeadlessTerminal.SearchResult) -> Bool {
    guard case .found(let position) = result else { return false }
    return position.index == 1 && position.total == 1 && !position.capped
  }

  @Test func historySearchUsesOptionsAndNavigation() throws {
    let terminal = try #require(HeadlessTerminal(columns: 20, rows: 2))
    terminal.feed("cat\r\nCat\r\ncat2\r\ncat!")
    guard case .found(let position) = search(terminal, "cat", options: .init(caseSensitive: true, wholeWord: true)) else {
      Issue.record("expected accepted matches"); return
    }
    #expect(position.index == 1 && position.total == 2 && !position.capped)
    #expect(try #require(terminal.currentScreen()).activeSearchHighlights.count == 1)
    #expect(terminal.navigateSearch(older: true)?.index == 2)
    #expect(try #require(terminal.currentScreen()).rows.contains("cat"))
    #expect(terminal.navigateSearch(older: true)?.index == 1)
    #expect(singleMatch(search(terminal, "^c.t!$", options: .init(regularExpression: true))))
    terminal.clearSearch()
    #expect(terminal.searchPosition == nil)
    #expect(terminal.navigateSearch(older: true) == nil)
  }

  @Test func searchAdmissionCancellationAndLiveEdits() throws {
    let terminal = try #require(HeadlessTerminal(columns: 100, rows: 2))
    terminal.feed(String(repeating: "a", count: 90))
    #expect(terminal.beginSearch("z") == .working)
    #expect(terminal.advanceSearch() == .working)
    terminal.cancelSearch()
    #expect(terminal.advanceSearch() == .cancelled)
    #expect(terminal.beginSearch("a{2}", options: .init(regularExpression: true)) == .invalidQuery)
    #expect(terminal.beginSearch("") == .invalidQuery)
    #expect(terminal.beginSearch(String(repeating: "a", count: 4097)) == .invalidQuery)
    #expect(terminal.beginSearch("aaa") == .working)
    #expect(terminal.advanceSearch() == .working)
    terminal.feed("\r\u{1b}[2Kchanged")
    #expect(terminal.advanceSearch() == .working)
    #expect(terminal.advanceSearch() == .changed)
    #expect(singleMatch(search(terminal, "changed")))
    terminal.feed("\r\u{1b}[2Kgone")
    #expect(terminal.navigateSearch(older: true) == nil)
  }

  @Test func selectionCopiesWideCellsAndSoftWraps() throws {
    let terminal = try #require(HeadlessTerminal(columns: 6, rows: 3))
    terminal.feed("ab猫cdEF\r\nlast")
    let screen = try #require(terminal.screen())
    let start = try #require(screen.selectionPoint(row: 0, column: 1))
    let end = try #require(screen.selectionPoint(row: 1, column: 2))
    #expect(finish(terminal, terminal.select(from: start, to: end)) == .completed(text: nil))
    let selected = try #require(terminal.screen()).selection
    #expect(selected.isCommitted && !selected.isRectangular)
    #expect(finish(terminal, terminal.copySelection(selected)) == .completed(text: "b猫cdEF"))
    terminal.clearSelection()
    #expect(try #require(terminal.screen()).selection.segments.isEmpty)
    #expect(terminal.copySelection(selected) == .rejected(.noSelection))
  }

  @Test func rectangularAndStaleSelectionUseEngineValidation() throws {
    let terminal = try #require(HeadlessTerminal(columns: 10, rows: 3))
    terminal.feed("abcde\r\nfghij")
    let screen = try #require(terminal.screen())
    let start = try #require(screen.selectionPoint(row: 0, column: 1))
    let end = try #require(screen.selectionPoint(row: 1, column: 3))
    #expect(finish(terminal, terminal.select(from: start, to: end, rectangular: true)) == .completed(text: nil))
    let selection = try #require(terminal.screen()).selection
    #expect(selection.isRectangular)
    #expect(finish(terminal, terminal.copySelection(selection)) == .completed(text: "bc\ngh"))
    terminal.feed("\u{1b}[Hchanged")
    guard case .rejected = terminal.select(from: start, to: end) else {
      Issue.record("stale screen points must be rejected"); return
    }
    let other = try #require(HeadlessTerminal(columns: 10, rows: 3))
    guard case .rejected(.staleTarget) = other.select(from: start, to: end) else {
      Issue.record("points from a different terminal must be rejected"); return
    }
    #expect(screen.selectionPoint(row: -1, column: 0) == nil)
    #expect(screen.selectionPoint(row: 0, column: 11) == nil)
  }
}

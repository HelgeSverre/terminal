import AppKit
import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalHost

@Suite(.serialized) @MainActor struct NativeTextTests {
  @Test func markedClausesRetainAttributesAndReplaceOnlyPendingText() {
    var storage = MarkedTextStorage()
    let marked = NSMutableAttributedString(string: "日本語😀")
    marked.addAttributes([.markedClauseSegment: 1, .underlineStyle: NSUnderlineStyle.double.rawValue],
      range: NSRange(location: 1, length: 2))
    let initialAccepted = storage.update(marked, selection: NSRange(location: 1, length: 2),
      replacement: NSRange(location: NSNotFound, length: 0))
    #expect(initialAccepted)
    #expect(storage.selection == NSRange(location: 1, length: 2))
    #expect(storage.text.attribute(.markedClauseSegment, at: 1, effectiveRange: nil) as? Int == 1)
    let replacementAccepted = storage.update(NSAttributedString(string: "本"), selection: NSRange(location: 1, length: 0),
      replacement: NSRange(location: 1, length: 1))
    #expect(replacementAccepted)
    #expect(storage.text.string == "日本語😀")
    #expect(storage.selection == NSRange(location: 2, length: 0))
    #expect(storage.committing("語句", replacement: NSRange(location: 2, length: 1)) == "日本語句😀")
    #expect(storage.committing("x", replacement: NSRange(location: 4, length: 1)) == nil,
      "A replacement must not split an emoji's UTF-16 surrogate pair")
    let invalidAccepted = storage.update(NSAttributedString(string: "shell edit"), selection: .init(location: 0, length: 0),
      replacement: NSRange(location: 100, length: 1))
    #expect(!invalidAccepted)
    #expect(storage.text.string == "日本語😀")
    storage.clear()
    #expect(!storage.hasText)
    #expect(storage.committing("x", replacement: NSRange(location: 1, length: 0)) == nil)
  }

  @Test func longPreeditWrapsAndSharesUTF16HitAndCandidateGeometry() throws {
    let text = NSMutableAttributedString(string: String(repeating: "日", count: 30) + "e\u{301}😀")
    text.addAttributes([.markedClauseSegment: 2, .underlineStyle: NSUnderlineStyle.double.rawValue],
      range: NSRange(location: 20, length: 10))
    let layout = PreeditPresentation(text: text, selection: NSRange(location: 20, length: 10),
      columns: 12, rows: 10, cursorRow: 9, cursorColumn: 8)
    #expect(layout.spans.count == 32, "Long preedit must not stop after 20 cells")
    let first = try #require(layout.spans.first(where: { $0.range.location == 20 }))
    #expect(first.selected && first.clause == 2 && first.underlineStyle == NSUnderlineStyle.double.rawValue)
    #expect(layout.caret.row == first.row && layout.caret.column == first.column)
    #expect(layout.characterIndex(row: first.row, column: Double(first.column) + 0.25) == 20)
    #expect(layout.characterIndex(row: first.row, column: Double(first.column) + 1.75) == 21)
    let combining = try #require(layout.spans.first(where: { $0.text == "e\u{301}" }))
    #expect(combining.range.length == 2 && combining.cells == 1)
    let emoji = try #require(layout.spans.first(where: { $0.text == "😀" }))
    #expect(emoji.range.length == 2 && emoji.cells == 2)
    let segment = try #require(layout.firstSegment(for: NSRange(location: 20, length: 10)))
    #expect(segment.row == first.row && segment.range.length < 10,
      "Candidate rectangles describe just the first physical line")
    #expect(layout.firstSegment(for: NSRange(location: NSNotFound, length: 0)) == nil)
  }

  @Test func boundedPreeditWindowFollowsCaretWithoutChangingDocumentOffsets() throws {
    let text = NSAttributedString(string: String(repeating: "あ", count: 500))
    let layout = PreeditPresentation(text: text, selection: NSRange(location: 490, length: 0),
      columns: 20, rows: 4, cursorRow: 3, cursorColumn: 0)
    #expect(layout.spans.count <= 40)
    #expect(layout.spans.first?.range.location ?? 0 > 0)
    let caretSpan = try #require(layout.spans.first(where: { $0.range.location == 490 }))
    #expect(caretSpan.row == layout.caret.row && caretSpan.column == layout.caret.column)
    #expect((0..<4).contains(layout.caret.row))
    #expect(layout.firstSegment(for: NSRange(location: 0, length: 1)) == nil)
    #expect(layout.characterIndex(row: -1, column: 0) == NSNotFound)
  }

  @Test func excessiveCompositionIsRejectedWithoutDiscardingCurrentInput() {
    var storage = MarkedTextStorage()
    let initialAccepted = storage.update(NSAttributedString(string: "pending"), selection: NSRange(location: 7, length: 0),
      replacement: NSRange(location: NSNotFound, length: 0))
    let oversizedAccepted = storage.update(NSAttributedString(string: String(repeating: "x", count: 65_537)),
      selection: NSRange(location: 0, length: 0), replacement: NSRange(location: NSNotFound, length: 0))
    #expect(initialAccepted)
    #expect(!oversizedAccepted)
    #expect(storage.text.string == "pending")
  }

  @MainActor @Test func nativeClientPreservesAttributesAndCommitsOnlyPendingStorage() async throws {
    let transport = HistoryPageTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    let view = TerminalCanvasView(frame: .zero, session: session, rendering: nil, clipboard: nil)
    #expect(await TestEnvironment.wait { transport.connection != nil })
    let marked = NSAttributedString(string: "日本", attributes: [.markedClauseSegment: 3])
    view.setMarkedText(marked, selectedRange: NSRange(location: 1, length: 1),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.hasMarkedText() && view.markedRange() == NSRange(location: 0, length: 2))
    #expect(view.selectedRange() == NSRange(location: 1, length: 1))
    var actual = NSRange(location: 99, length: 99)
    let substring = try #require(view.attributedSubstring(forProposedRange: NSRange(location: 1, length: 99),
      actualRange: &actual))
    #expect(actual == NSRange(location: 1, length: 1))
    #expect(substring.attribute(.markedClauseSegment, at: 0, effectiveRange: nil) as? Int == 3)
    #expect(view.attributedSubstring(forProposedRange: NSRange(location: NSNotFound, length: 1),
      actualRange: &actual) == nil)
    #expect(actual.location == NSNotFound)
    view.insertText("語", replacementRange: NSRange(location: 1, length: 1))
    #expect(await TestEnvironment.wait { transport.sent == "日語" })
    #expect(!view.hasMarkedText())
    view.insertText("shell edit", replacementRange: NSRange(location: 100, length: 1))
    view.unmarkText()
    #expect(transport.sent == "日語")
  }
}

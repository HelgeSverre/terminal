import Foundation
import TerminalEngine

/// Immutable cell geometry shared by the renderer and native input client.
/// UTF-16 ranges always refer to the complete composition, including text
/// outside the bounded display window. Shell output is never editable storage.
struct PreeditPresentation: Sendable {
  struct Span: Sendable {
    let range: NSRange
    let text: String
    let row: Int
    let column: Int
    let cells: Int
    let selected: Bool
    let underlineStyle: Int
    let clause: Int?
  }
  struct Caret: Sendable { let row: Int; let column: Int }
  let spans: [Span]
  let caret: Caret
  let length: Int
  private let caretOffset: Int

  init(text: NSAttributedString, selection: NSRange, columns: Int, rows: Int,
       cursorRow: Int, cursorColumn: Int) {
    let columns = max(1, columns), rows = max(1, rows)
    let height = min(rows, 8)
    let caretOffset = min(text.length, max(0, selection.location == NSNotFound ? text.length : selection.location))
    self.caretOffset = caretOffset
    let selected = NSRange(location: caretOffset,
      length: min(max(0, selection.length), text.length - caretOffset))
    var content: [Span] = []
    var row = 0, column = min(columns - 1, max(0, cursorColumn)), offset = 0
    var caretRow = 0, caretColumn = column
    for character in text.string {
      let string = String(character), count = string.utf16.count
      let cells = min(columns, max(1, terminalPreeditCellWidth(string)))
      if column + cells > columns { row += 1; column = 0 }
      if offset <= caretOffset { caretRow = row; caretColumn = column }
      let range = NSRange(location: offset, length: count)
      let attributes = text.attributes(at: offset, effectiveRange: nil)
      content.append(Span(range: range, text: string, row: row, column: column, cells: cells,
        selected: selection.location != NSNotFound && NSIntersectionRange(range, selected).length > 0,
        underlineStyle: (attributes[NSAttributedString.Key("NSUnderline")] as? NSNumber)?.intValue ?? 1,
        clause: (attributes[NSAttributedString.Key("NSMarkedClauseSegment")] as? NSNumber)?.intValue))
      column += cells
      offset += count
      if offset <= caretOffset { caretRow = row; caretColumn = column }
    }
    if caretColumn == columns { caretRow += 1; caretColumn = 0 }
    let firstRow = max(0, caretRow - height + 1)
    let origin = min(max(0, cursorRow), rows - min(height, max(1, max(row, caretRow) - firstRow + 1)))
    spans = content.filter { (firstRow..<(firstRow + height)).contains($0.row) }.map {
      Span(range: $0.range, text: $0.text, row: origin + $0.row - firstRow, column: $0.column,
        cells: $0.cells, selected: $0.selected, underlineStyle: $0.underlineStyle, clause: $0.clause)
    }
    caret = Caret(row: min(rows - 1, origin + caretRow - firstRow), column: caretColumn)
    length = text.length
  }

  /// Only a first physical row is returned, as NSTextInputClient requires.
  func firstSegment(for range: NSRange) -> (range: NSRange, row: Int, column: Int, cells: Int)? {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
      range.location <= length, range.length <= length - range.location else { return nil }
    if range.length == 0 {
      if range.location == length {
        if caretOffset == length { return (range, caret.row, caret.column, 0) }
        guard let last = spans.last, NSMaxRange(last.range) == length else { return nil }
        return (range, last.row, last.column + last.cells, 0)
      }
      guard let span = spans.first(where: { NSLocationInRange(range.location, $0.range) }) else { return nil }
      return (NSRange(location: span.range.location, length: 0), span.row, span.column, 0)
    }
    let hits = spans.filter { NSIntersectionRange($0.range, range).length > 0 }
    guard let first = hits.first else { return nil }
    let sameRow = hits.prefix { $0.row == first.row }
    guard let last = sameRow.last else { return nil }
    return (NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location),
      first.row, first.column, last.column + last.cells - first.column)
  }
  func characterIndex(row: Int, column: Double) -> Int {
    let line = spans.filter { $0.row == row }
    guard let first = line.first, let last = line.last else { return NSNotFound }
    if column <= Double(first.column) { return first.range.location }
    for span in line where column < Double(span.column + span.cells) {
      return column < Double(span.column) + Double(span.cells) / 2 ? span.range.location : NSMaxRange(span.range)
    }
    return NSMaxRange(last.range)
  }
}

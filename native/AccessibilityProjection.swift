import Foundation

/// A bounded UTF-16 projection of the displayed immutable grid. No actor/GPU calls.
struct AccessibilityProjection {
  struct Span {
    let range: NSRange
    let row: Int
    let column: Int
    let cells: Int
    let gridStart: Int
    let gridEnd: Int
  }
  let text: String
  let lines: [NSRange]
  let spans: [Span]
  let columns: Int
  let gridCount: Int
  let truncated: Bool
  var length: Int { (text as NSString).length }
  init(snapshot: TerminalSnapshot, limit: Int = 262_144) {
    columns = snapshot.cols
    gridCount = snapshot.cols * snapshot.rows.count
    var output = ""
    var offsets: [NSRange] = []
    var mapping: [Span] = []
    var count = 0
    var clipped = false
    for (row, value) in snapshot.rows.enumerated() {
      let start = count
      var end =
        value.cells.lastIndex { $0.kind != "Empty" && $0.kind != "WrapSpacer" }.map { $0 + 1 } ?? 0
      if snapshot.following_tail && row == snapshot.cursor.row {
        end = max(end, min(value.cells.count, snapshot.cursor.col))
      }
      for column in 0..<end {
        let cell = value.cells[column]
        if cell.kind == "Continuation" || cell.kind == "WrapSpacer" { continue }
        let string = cell.kind == "Empty" ? " " : cell.text
        let size = string.utf16.count
        if count + size > max(0, limit) {
          clipped = true
          break
        }
        let width = cell.kind == "Lead2" ? 2 : 1
        mapping.append(
          Span(
            range: NSRange(location: count, length: size), row: row, column: column,
            cells: width, gridStart: row * columns + column,
            gridEnd: row * columns + column + width))
        output.append(string)
        count += size
      }
      if !clipped && row + 1 < snapshot.rows.count {
        if count < max(0, limit) {
          mapping.append(
            Span(
              range: NSRange(location: count, length: 1), row: row, column: end,
              cells: 0, gridStart: row * columns + end, gridEnd: (row + 1) * columns))
          output.append("\n")
          count += 1
        } else {
          clipped = true
        }
      }
      offsets.append(NSRange(location: start, length: count - start))
      if clipped { break }
    }
    text = output
    lines = offsets
    spans = mapping
    truncated = clipped
  }
  func valid(_ range: NSRange) -> Bool {
    range.location != NSNotFound && range.location >= 0 && range.length >= 0
      && range.location <= length && range.length <= length - range.location
  }
  func string(in range: NSRange) -> String? {
    guard valid(range) else { return nil }
    return (text as NSString).substring(with: range)
  }
  func range(for index: Int) -> NSRange {
    guard index >= 0, index < length else { return NSRange(location: NSNotFound, length: 0) }
    return spans.first { NSLocationInRange(index, $0.range) }?.range
      ?? NSRange(location: NSNotFound, length: 0)
  }
  func line(for index: Int) -> Int {
    guard index >= 0, index <= length else { return -1 }
    if index == length { return max(0, lines.count - 1) }
    return lines.firstIndex { NSLocationInRange(index, $0) } ?? -1
  }
  func range(forLine line: Int) -> NSRange {
    guard lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
    return lines[line]
  }
  func textRange(gridStart: Int, gridEnd: Int) -> NSRange {
    let lower = max(0, min(gridStart, gridEnd))
    let upper = min(gridCount, max(gridStart, gridEnd))
    let a = spans.first { $0.gridEnd > lower }?.range.location ?? length
    if lower == upper { return NSRange(location: a, length: 0) }
    let b = spans.last { $0.gridStart < upper }.map { NSMaxRange($0.range) } ?? a
    return NSRange(location: a, length: max(0, b - a))
  }
  func gridRange(for range: NSRange) -> Range<Int>? {
    guard valid(range) else { return nil }
    let first = spans.first { NSMaxRange($0.range) > range.location }
    let a = first?.gridStart ?? gridCount
    if range.length == 0 { return a..<a }
    let last = spans.last { $0.range.location < NSMaxRange(range) }
    return a..<max(a, last?.gridEnd ?? a)
  }
  func spans(for range: NSRange) -> [Span] {
    guard valid(range) else { return [] }
    if range.length == 0 {
      if let span = spans.first(where: { NSMaxRange($0.range) > range.location }) { return [span] }
      if let last = spans.last {
        let row = last.cells == 0 ? last.row + 1 : last.row
        let column = last.cells == 0 ? 0 : last.column + last.cells
        return [
          Span(
            range: range, row: row, column: column, cells: 0,
            gridStart: last.gridEnd, gridEnd: last.gridEnd)
        ]
      }
      return [Span(range: range, row: 0, column: 0, cells: 0, gridStart: 0, gridEnd: 0)]
    }
    return spans.filter { NSIntersectionRange($0.range, range).length > 0 }
  }
}

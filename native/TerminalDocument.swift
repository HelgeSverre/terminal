import Foundation

// Canonical rich storage for the emulator. Every editing operation below acts
// on these cells directly: there is no text-only or generic-grid side model.
struct TerminalStyle: Equatable {
  var foreground: UInt32 = 0; var background: UInt32 = 0; var underline: UInt32 = 0
  var flags: UInt16 = 0; var underlineKind: UInt8 = 0
  func erased() -> TerminalStyle { TerminalStyle(background: background) }
}
struct TerminalCell: Equatable {
  // 0 empty, 1 single-width lead, 2 double-width lead, 3 continuation,
  // 4 a single-column spacer left by a wide glyph that wrapped.
  var text = ""; var kind: UInt8 = 0; var style = TerminalStyle(); var link: String?
  var flags: UInt8 = 0; var protected = false
  static func erased(_ style: TerminalStyle = TerminalStyle()) -> TerminalCell {
    TerminalCell(text: "", kind: 0, style: style.erased())
  }
}
struct TerminalRow: Equatable {
  let id: UInt64; var revision: UInt64; var cells: [TerminalCell]; var softWrapped = false
  init(id: UInt64 = 0, revision: UInt64 = 0, cells: [TerminalCell]) { self.id = id; self.revision = revision; self.cells = cells }
  init(columns: Int) { self.init(cells: Array(repeating: TerminalCell(), count: columns)) }
}
struct TerminalScreen: Equatable {
  var rows: [TerminalRow]; var cursorRow = 0; var cursorColumn = 0; var pendingWrap = false
  var savedRow = 0; var savedColumn = 0; var savedOrigin = false
  var topMargin: Int; var bottomMargin: Int; var leftMargin: Int; var rightMargin: Int
  init(rows: [TerminalRow], columns: Int) {
    self.rows = rows; topMargin = 0; bottomMargin = max(0, rows.count - 1)
    leftMargin = 0; rightMargin = max(0, columns - 1)
  }
  init(columns: Int, rows count: Int) { self.init(rows: Array(repeating: TerminalRow(columns: columns), count: count), columns: columns) }
}
struct TerminalDocument {
  private(set) var columns: Int; private(set) var rowCount: Int
  var history: [TerminalRow] = []; var primary: TerminalScreen; var alternate: TerminalScreen
  fileprivate var nextRowID: UInt64 = 1
  init(columns: Int, rows: Int) {
    self.columns = columns; rowCount = rows
    primary = TerminalScreen(rows: [], columns: columns); alternate = TerminalScreen(rows: [], columns: columns)
    primary.rows = makeRows(rows); alternate.rows = makeRows(rows)
    primary.bottomMargin = rows - 1; alternate.bottomMargin = rows - 1
  }
  mutating func blankRow() -> TerminalRow {
    defer { nextRowID &+= 1 }
    return TerminalRow(id: nextRowID, cells: Array(repeating: TerminalCell(), count: columns))
  }
  mutating func eraseRow(_ style: TerminalStyle) -> TerminalRow {
    var row = blankRow(); row.cells = Array(repeating: .erased(style), count: columns); return row
  }
  mutating func setSize(columns: Int, rows: Int) { self.columns = columns; rowCount = rows }

  // This is the rich editing seam. The caller selects a screen; document code
  // owns pair repair and rectangular copying so command handlers do not learn
  // about continuations, links, styles, protection, or row identities.
  mutating func shift(_ screen: inout TerminalScreen, row: Int, column: Int, right: Int,
                      count: Int, inserting: Bool, eraseStyle: TerminalStyle) {
    guard screen.rows.indices.contains(row), column <= right, right < columns else { return }
    let amount = min(count, right - column + 1); guard amount > 0 else { return }
    if inserting {
      if column + amount <= right { for destination in stride(from: right, through: column + amount, by: -1) { screen.rows[row].cells[destination] = screen.rows[row].cells[destination - amount] } }
      for index in column..<(column + amount) { screen.rows[row].cells[index] = .erased(eraseStyle) }
    } else {
      if column <= right - amount { for destination in column...(right - amount) { screen.rows[row].cells[destination] = screen.rows[row].cells[destination + amount] } }
      for index in (right - amount + 1)...right { screen.rows[row].cells[index] = .erased(eraseStyle) }
    }
    repairWidePairs(&screen.rows[row], eraseStyle: eraseStyle); screen.rows[row].revision &+= 1
  }
  mutating func erase(_ screen: inout TerminalScreen, row: Int, columns range: Range<Int>, style: TerminalStyle, selective: Bool = false) {
    guard screen.rows.indices.contains(row) else { return }
    let lower = max(0, range.lowerBound), upper = min(columns, range.upperBound); guard lower < upper else { return }
    for column in lower..<upper where !selective || !screen.rows[row].cells[column].protected { screen.rows[row].cells[column] = .erased(style) }
    repairWidePairs(&screen.rows[row], eraseStyle: style); screen.rows[row].revision &+= 1
  }
  mutating func scrollRectangle(_ screen: inout TerminalScreen, top: Int, bottom: Int, left: Int, right: Int, count: Int, up: Bool, eraseStyle: TerminalStyle) {
    guard top >= 0, bottom < screen.rows.count, top <= bottom, left >= 0, right < columns, left <= right else { return }
    let amount = min(count, bottom - top + 1); guard amount > 0 else { return }
    let originals = screen.rows
    for step in 0...(bottom - top) {
      let destination = up ? top + step : bottom - step; let source = up ? destination + amount : destination - amount
      if source >= top && source <= bottom { screen.rows[destination].cells.replaceSubrange(left...right, with: originals[source].cells[left...right]) }
      else { for column in left...right { screen.rows[destination].cells[column] = .erased(eraseStyle) }; screen.rows[destination].softWrapped = false }
      repairWidePairs(&screen.rows[destination], eraseStyle: eraseStyle); screen.rows[destination].revision &+= 1
    }
    if left != 0 || right != columns - 1 { screen.rows[top].softWrapped = false }
  }
  mutating func resize(_ screen: TerminalScreen, columns nextColumns: Int, rows nextRows: Int) -> TerminalScreen {
    var result = TerminalScreen(rows: [], columns: nextColumns); setSize(columns: nextColumns, rows: nextRows); result.rows = makeRows(nextRows)
    let start = max(0, screen.rows.count - nextRows)
    for (destination, source) in screen.rows.suffix(nextRows).enumerated() {
      var row = source; row.cells = Array(source.cells.prefix(nextColumns))
      if row.cells.count < nextColumns { row.cells.append(contentsOf: repeatElement(TerminalCell(), count: nextColumns - row.cells.count)) }
      repairWidePairs(&row, eraseStyle: TerminalStyle()); result.rows[destination] = row
    }
    result.cursorRow = min(nextRows - 1, max(0, screen.cursorRow - start)); result.cursorColumn = min(nextColumns - 1, screen.cursorColumn); result.pendingWrap = false
    return result
  }
  func repairedCellOwner(in row: TerminalRow, at column: Int) -> Int { row.cells.indices.contains(column) && row.cells[column].kind == 3 && column > 0 ? column - 1 : column }
  private mutating func makeRows(_ count: Int) -> [TerminalRow] { (0..<count).map { _ in blankRow() } }
  private func repairWidePairs(_ row: inout TerminalRow, eraseStyle: TerminalStyle) {
    guard !row.cells.isEmpty else { return }
    for index in row.cells.indices {
      if row.cells[index].kind == 2 && (index + 1 >= row.cells.count || row.cells[index + 1].kind != 3) { row.cells[index] = .erased(eraseStyle) }
      if row.cells[index].kind == 3 && (index == 0 || row.cells[index - 1].kind != 2) { row.cells[index] = .erased(eraseStyle) }
    }
  }
}

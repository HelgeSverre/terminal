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
  var id: UInt64; var revision: UInt64; var cells: [TerminalCell]; var softWrapped = false
  init(id: UInt64 = 0, revision: UInt64 = 0, cells: [TerminalCell]) { self.id = id; self.revision = revision; self.cells = cells }
  init(columns: Int) { self.init(cells: Array(repeating: TerminalCell(), count: columns)) }
}
struct PromptAnchor: Equatable {
  var row: UInt64
  var column: Int
  var pendingWrap: Bool
}
struct TerminalScreen: Equatable {
  var rows: [TerminalRow]; var cursorRow = 0; var cursorColumn = 0; var pendingWrap = false
  var savedRow = 0; var savedColumn = 0; var savedPendingWrap = false; var savedOrigin = false
  var savedStyle = TerminalStyle(); var savedLink: String?
  var keyboardFlags: UInt32 = 0
  // OSC 133 prompt identity is screen-local and survives resize by row ID.
  var atPrompt = false; var inputReady = false; var promptRedraw = false
  var promptAnchor: PromptAnchor?
  var topMargin: Int; var bottomMargin: Int; var leftMargin: Int; var rightMargin: Int
  init(rows: [TerminalRow], columns: Int) {
    self.rows = rows; topMargin = 0; bottomMargin = max(0, rows.count - 1)
    leftMargin = 0; rightMargin = max(0, columns - 1)
  }
  init(columns: Int, rows count: Int) { self.init(rows: Array(repeating: TerminalRow(columns: columns), count: count), columns: columns) }
}
struct TerminalDocument {
  struct ASCIIPlacement {
    var appendedHistory: [TerminalRow]
    var owner: (row: Int, column: Int)
  }
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

  // The common printable-ASCII path must not materialize a complete
  // TerminalScreen just to change one cell.  Keep this deliberately specific:
  // it is the document's placement operation, not a mutable-grid callback for
  // callers to assemble their own terminal edits.  The Unicode/cluster path
  // continues through the richer editor until it moves here as one transaction.
  @discardableResult
  mutating func placeASCII(_ text: String, usingAlternate: Bool,
                           leftRightMargins: Bool, autoWrap: Bool,
                           insertMode: Bool, style: TerminalStyle,
                           link: String?, protected: Bool) -> ASCIIPlacement? {
    var appended: [TerminalRow] = []
    var replacements: [Int] = []
    var owner: (row: Int, column: Int)?
    if usingAlternate {
      Self.placeASCII(text, in: &alternate, columns: columns,
                      leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                      insertMode: insertMode, style: style, link: link,
                      protected: protected, history: &appended,
                      replacementRows: &replacements, retainHistory: false, owner: &owner)
      Self.assignRowIDs(&alternate, at: replacements, nextRowID: &nextRowID)
    } else {
      Self.placeASCII(text, in: &primary, columns: columns,
                      leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                      insertMode: insertMode, style: style, link: link,
                      protected: protected, history: &appended,
                      replacementRows: &replacements, retainHistory: true, owner: &owner)
      Self.assignRowIDs(&primary, at: replacements, nextRowID: &nextRowID)
      history.append(contentsOf: appended)
    }
    return owner.map { ASCIIPlacement(appendedHistory: appended, owner: $0) }
  }

  private static func assignRowIDs(_ screen: inout TerminalScreen, at indices: [Int], nextRowID: inout UInt64) {
    for index in indices where screen.rows.indices.contains(index) {
      // The placeholder is installed while the selected screen is held
      // inout; allocating its identity afterwards avoids a temporary screen
      // copy and makes row allocation explicit at the ownership seam.
      screen.rows[index].id = nextRowID
      nextRowID &+= 1
    }
  }

  private static func placeASCII(_ text: String, in screen: inout TerminalScreen,
                                 columns: Int, leftRightMargins: Bool,
                                 autoWrap: Bool, insertMode: Bool,
                                 style: TerminalStyle, link: String?,
                                 protected: Bool, history: inout [TerminalRow],
                                 replacementRows: inout [Int], retainHistory: Bool,
                                 owner: inout (row: Int, column: Int)?) {
    guard text.unicodeScalars.count == 1 else { return }
    let horizontal = leftRightMargins ? (screen.leftMargin, screen.rightMargin) : (0, columns - 1)
    func writeBounds(_ column: Int) -> (left: Int, right: Int) {
      return column <= horizontal.1 ? (horizontal.0, horizontal.1) : (0, columns - 1)
    }
    func erase(_ row: Int, _ range: Range<Int>, _ eraseStyle: TerminalStyle) {
      let lower = max(0, range.lowerBound), upper = min(columns, range.upperBound)
      guard screen.rows.indices.contains(row), lower < upper else { return }
      for column in lower..<upper { screen.rows[row].cells[column] = .erased(eraseStyle) }
      Self.repairWidePairsInPlace(&screen.rows[row], eraseStyle: eraseStyle)
      screen.rows[row].revision &+= 1
    }
    func shift(_ row: Int, _ column: Int, _ right: Int, _ amount: Int, _ eraseStyle: TerminalStyle) {
      guard screen.rows.indices.contains(row), column <= right else { return }
      let count = min(amount, right - column + 1)
      guard count > 0 else { return }
      if column + count <= right {
        for destination in stride(from: right, through: column + count, by: -1) {
          screen.rows[row].cells[destination] = screen.rows[row].cells[destination - count]
        }
      }
      for index in column..<(column + count) { screen.rows[row].cells[index] = .erased(eraseStyle) }
      Self.repairWidePairsInPlace(&screen.rows[row], eraseStyle: eraseStyle)
      screen.rows[row].revision &+= 1
    }
    func scrollUpFullWidth() {
      let removed = screen.rows.remove(at: screen.topMargin)
      let replacement = TerminalRow(id: 0, cells: Array(repeating: .erased(style), count: columns))
      screen.rows.insert(replacement, at: screen.bottomMargin)
      replacementRows.append(screen.bottomMargin)
      if retainHistory && screen.topMargin == 0 && screen.bottomMargin == screen.rows.count - 1 {
        history.append(removed)
      }
    }
    func wrap() {
      let old = screen.cursorRow
      screen.rows[old].softWrapped = horizontal.0 == 0 && horizontal.1 == columns - 1
      let inside = (horizontal.0...horizontal.1).contains(screen.cursorColumn)
      if screen.cursorRow == screen.bottomMargin && inside {
        if horizontal.0 == 0 && horizontal.1 == columns - 1 {
          scrollUpFullWidth()
        } else {
          Self.scrollRectangleInPlace(&screen, columns: columns, top: screen.topMargin, bottom: screen.bottomMargin,
                                      left: horizontal.0, right: horizontal.1, count: 1,
                                      up: true, eraseStyle: style)
        }
      } else {
        screen.cursorRow = min(screen.rows.count - 1, screen.cursorRow + 1)
      }
      screen.cursorColumn = writeBounds(screen.cursorColumn).left
      screen.pendingWrap = false
    }

    if screen.pendingWrap && autoWrap { wrap() }
    guard screen.rows.indices.contains(screen.cursorRow),
          (0..<columns).contains(screen.cursorColumn) else { return }
    let bounds = writeBounds(screen.cursorColumn)
    if insertMode, (horizontal.0...horizontal.1).contains(screen.cursorColumn) {
      shift(screen.cursorRow, screen.cursorColumn, horizontal.1, 1, style.erased())
    }
    erase(screen.cursorRow, screen.cursorColumn..<(screen.cursorColumn + 1), style.erased())
    let row = screen.cursorRow, column = screen.cursorColumn
    screen.rows[row].cells[column] = TerminalCell(text: text, kind: 1, style: style,
                                                   link: link, flags: protected ? 2 : 0,
                                                   protected: protected)
    owner = (row, column)
    let reachesPastRight = column + 1 > bounds.right
    screen.cursorColumn = min(bounds.right, column + 1)
    screen.pendingWrap = reachesPastRight && autoWrap
  }

  func hasValidInvariants(_ screen: TerminalScreen) -> Bool {
    guard columns > 0, rowCount > 0, screen.rows.count == rowCount,
          (0..<rowCount).contains(screen.cursorRow), (0..<columns).contains(screen.cursorColumn),
          screen.topMargin >= 0, screen.topMargin <= screen.bottomMargin, screen.bottomMargin < rowCount,
          screen.leftMargin >= 0, screen.leftMargin <= screen.rightMargin, screen.rightMargin < columns else {
      return false
    }
    return screen.rows.allSatisfy { row in
      guard row.cells.count == columns else { return false }
      for index in row.cells.indices {
        switch row.cells[index].kind {
        case 2:
          guard index + 1 < row.cells.count, row.cells[index + 1].kind == 3 else { return false }
        case 3:
          guard index > 0, row.cells[index - 1].kind == 2 else { return false }
        default: break
        }
      }
      return true
    }
  }

  // The text at a redrawable OSC 133 marker belongs to the shell. Before a
  // width reflow, retain terminal output before the marker and move the cursor
  // back to that exact boundary. A deferred-wrap marker starts on the next row.
  mutating func clearPromptSuffix(_ screen: inout TerminalScreen, eraseStyle: TerminalStyle) -> Bool {
    guard let anchor = screen.promptAnchor,
          let rowIndex = screen.rows.firstIndex(where: { $0.id == anchor.row }) else {
      screen.promptAnchor = nil; screen.promptRedraw = false; screen.atPrompt = false; screen.inputReady = false
      return false
    }
    if !anchor.pendingWrap {
      erase(&screen, row: rowIndex,
            columns: min(columns, max(0, anchor.column))..<columns,
            style: eraseStyle)
    }
    if rowIndex + 1 < screen.rows.count {
      for index in (rowIndex + 1)..<screen.rows.count {
        screen.rows[index] = eraseRow(eraseStyle)
      }
    }
    screen.cursorRow = rowIndex
    screen.cursorColumn = min(columns - 1, max(0, anchor.column))
    screen.pendingWrap = anchor.pendingWrap
    return true
  }

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
    Self.scrollRectangleInPlace(&screen, columns: columns, top: top, bottom: bottom, left: left, right: right,
                                count: count, up: up, eraseStyle: eraseStyle)
  }
  private static func scrollRectangleInPlace(_ screen: inout TerminalScreen, columns: Int, top: Int, bottom: Int, left: Int, right: Int, count: Int, up: Bool, eraseStyle: TerminalStyle) {
    guard top >= 0, bottom < screen.rows.count, top <= bottom, left >= 0, right < columns, left <= right else { return }
    let amount = min(count, bottom - top + 1); guard amount > 0 else { return }
    let originals = screen.rows
    for step in 0...(bottom - top) {
      let destination = up ? top + step : bottom - step; let source = up ? destination + amount : destination - amount
      if source >= top && source <= bottom { screen.rows[destination].cells.replaceSubrange(left...right, with: originals[source].cells[left...right]) }
      else { for column in left...right { screen.rows[destination].cells[column] = .erased(eraseStyle) }; screen.rows[destination].softWrapped = false }
      repairWidePairsInPlace(&screen.rows[destination], eraseStyle: eraseStyle); screen.rows[destination].revision &+= 1
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
    Self.repairWidePairsInPlace(&row, eraseStyle: eraseStyle)
  }
  private static func repairWidePairsInPlace(_ row: inout TerminalRow, eraseStyle: TerminalStyle) {
    guard !row.cells.isEmpty else { return }
    for index in row.cells.indices {
      if row.cells[index].kind == 2 && (index + 1 >= row.cells.count || row.cells[index + 1].kind != 3) { row.cells[index] = .erased(eraseStyle) }
      if row.cells[index].kind == 3 && (index == 0 || row.cells[index - 1].kind != 2) { row.cells[index] = .erased(eraseStyle) }
    }
  }
}

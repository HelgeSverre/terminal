import Foundation

// Canonical rich storage for the emulator. Every cell-bearing algorithm uses
// this representation, so styles, links, flags and wide continuations survive
// edits instead of being converted through a text-only helper grid.
struct TerminalStyle { var foreground: UInt32 = 0; var background: UInt32 = 0; var underline: UInt32 = 0; var flags: UInt16 = 0; var underlineKind: UInt8 = 0 }
struct TerminalCell { var text = ""; var kind: UInt8 = 0; var style = TerminalStyle(); var link: String?; var flags: UInt8 = 0; var protected = false }
struct TerminalRow { let id: UInt64; var revision: UInt64; var cells: [TerminalCell]; var softWrapped = false; init(id: UInt64 = 0, revision: UInt64 = 0, cells: [TerminalCell]) { self.id = id; self.revision = revision; self.cells = cells }; init(columns: Int) { self.init(cells: Array(repeating: TerminalCell(), count: columns)) } }
struct TerminalScreen { var rows: [TerminalRow]; var cursorRow = 0; var cursorColumn = 0; var pendingWrap = false; var savedRow = 0; var savedColumn = 0; init(rows: [TerminalRow]) { self.rows = rows }; init(columns: Int, rows count: Int) { rows = Array(repeating: TerminalRow(columns: columns), count: count) } }
struct TerminalDocument {
  private(set) var columns: Int; private(set) var rowCount: Int
  var history: [TerminalRow] = []; var primary: TerminalScreen; var alternate: TerminalScreen
  private var nextRowID: UInt64 = 1
  init(columns: Int, rows: Int) { self.columns = columns; rowCount = rows; primary = TerminalScreen(rows: []); alternate = TerminalScreen(rows: []); primary.rows = makeRows(rows); alternate.rows = makeRows(rows) }
  mutating func blankRow() -> TerminalRow { defer { nextRowID &+= 1 }; return TerminalRow(id: nextRowID, revision: 0, cells: Array(repeating: TerminalCell(), count: columns)) }
  private mutating func makeRows(_ count: Int) -> [TerminalRow] { (0..<count).map { _ in blankRow() } }
}

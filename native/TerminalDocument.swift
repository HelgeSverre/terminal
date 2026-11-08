import Foundation

// Canonical rich terminal storage.  This is intentionally a document owner,
// not a generic grid: all future edits/reflow/search preserve every cell
// attribute and stable row identity through this representation.
struct TerminalDocumentCell: Equatable {
  enum Kind: UInt8 { case empty, lead1, lead2, continuation, wrapSpacer }
  var text: String = ""
  var kind: Kind = .empty
  var foreground: UInt32 = 0
  var background: UInt32 = 0
  var underlineColor: UInt32 = 0
  var styleFlags: UInt16 = 0
  var underline: UInt8 = 0
  var flags: UInt8 = 0
  var link: String?
  var protected: Bool = false
}

struct TerminalDocumentRow: Equatable {
  let id: UInt64
  var revision: UInt64
  var softWrapped: Bool
  var cells: [TerminalDocumentCell]
}

/// The single storage owner for primary history and both screens.  Its compact
/// interface keeps callers from knowing row identity allocation or blank-cell
/// construction; editing/reflow/search extensions belong here, not in VT
/// command handlers.
struct TerminalDocument {
  private(set) var columns: Int
  private(set) var rows: Int
  private(set) var history: [TerminalDocumentRow] = []
  private(set) var primary: [TerminalDocumentRow]
  private(set) var alternate: [TerminalDocumentRow]
  private var nextRowID: UInt64 = 1

  init(columns: Int, rows: Int) {
    self.columns = columns; self.rows = rows
    primary = []; alternate = []
    primary = makeRows(rows); alternate = makeRows(rows)
  }
  mutating func blankRow() -> TerminalDocumentRow {
    defer { nextRowID &+= 1 }
    return TerminalDocumentRow(id: nextRowID, revision: 0, softWrapped: false,
      cells: Array(repeating: TerminalDocumentCell(), count: columns))
  }
  private mutating func makeRows(_ count: Int) -> [TerminalDocumentRow] {
    (0..<count).map { _ in blankRow() }
  }
}

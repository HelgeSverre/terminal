import Foundation

/// A bounded, immutable view of primary rows. Recovery never observes the
/// alternate screen or runs stored bytes through the escape parser.
package final class TerminalRecoveryCapture {
  private let rows: [TerminalRow]
  private var row: Int
  private var column: Int
  private var cellParts: [String] = []
  private var lines: [String] = []
  private var byteCount = 0
  private var exhausted = false
  package private(set) var capturedRows = 0
  private static let maximumBytes = 16 * 1024 * 1024

  init(rows: [TerminalRow]) {
    self.rows = rows
    row = rows.count - 1
    column = rows.last.map { $0.count - 1 } ?? -1
  }

  /// At most 512 cells and approximately one millisecond per owner turn.
  /// Rows use value semantics, so output and input may proceed between turns.
  package func advance() -> String? {
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000
    var units = 0
    while row >= 0 && !exhausted && units < 512 {
      if units.isMultiple(of: 32), DispatchTime.now().uptimeNanoseconds >= deadline { return nil }
      units += 1
      if column >= 0 {
        let cell = rows[row].cell(column)
        column -= 1
        if cell.kind == 3 || cell.kind == 4 { continue }
        let value = cell.kind == 0 ? " " : cell.text
        guard value.utf8.count <= Self.maximumBytes - byteCount else { exhausted = true; break }
        cellParts.append(value)
        byteCount += value.utf8.count
      } else {
        finishRow()
        row -= 1
        column = row >= 0 ? rows[row].count - 1 : -1
      }
    }
    guard row < 0 || exhausted else { return nil }
    if !cellParts.isEmpty { finishRow() }
    return lines.reversed().joined()
  }

  private func finishRow() {
    var text = cellParts.reversed().joined()
    if !rows[row].softWrapped {
      while text.last == " " { text.removeLast() }
      if byteCount < Self.maximumBytes { text += "\n"; byteCount += 1 }
      else { exhausted = true }
    }
    lines.append(text)
    cellParts.removeAll(keepingCapacity: true)
    capturedRows += 1
  }
}

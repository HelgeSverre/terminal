import Foundation

/// A bounded, immutable view of primary rows. Recovery never observes the
/// alternate screen or runs stored bytes through the escape parser.
package final class TerminalRecoveryCapture {
  private let history: TerminalHistory
  private let primary: [TerminalRow]
  private let first: Int
  private var row: Int
  private var column: Int
  private var cellParts: [String] = []
  private var lines: [String] = []
  private var byteCount = 0
  private var exhausted = false
  package private(set) var capturedRows = 0
  private let maximumBytes: Int

  init(history: TerminalHistory, primary: [TerminalRow], limit: Int, maximumBytes: Int) {
    // Retain the two COW containers in constant time. Never materialize an
    // array of up to 50,000 rows on the interactive owner at capture start.
    self.history = history
    self.primary = primary
    self.maximumBytes = min(16 * 1024 * 1024, max(0, maximumBytes))
    let total = history.count + primary.count
    // The limit bounds history; the screen itself is always captured.
    first = max(0, history.count - limit)
    row = total - 1
    column = -1
    if row >= first { column = source(row).count - 1 }
  }
  private func source(_ index: Int) -> TerminalRow {
    index < history.count ? history[index] : primary[index - history.count]
  }

  /// At most 512 cells and approximately one millisecond per owner turn.
  /// Rows use value semantics, so output and input may proceed between turns.
  package func advance() -> String? {
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000
    var units = 0
    while row >= first && !exhausted && units < 512 {
      if units.isMultiple(of: 32), DispatchTime.now().uptimeNanoseconds >= deadline { return nil }
      units += 1
      if column >= 0 {
        let cell = source(row).cell(column)
        column -= 1
        if cell.kind == 3 || cell.kind == 4 { continue }
        let value = cell.kind == 0 ? " " : cell.text
        guard value.utf8.count <= maximumBytes - byteCount else { exhausted = true; break }
        cellParts.append(value)
        byteCount += value.utf8.count
      } else {
        finishRow()
        row -= 1
        column = row >= first ? source(row).count - 1 : -1
      }
    }
    guard row < first || exhausted else { return nil }
    if !cellParts.isEmpty { finishRow() }
    return lines.reversed().joined()
  }

  private func finishRow() {
    var text = cellParts.reversed().joined()
    if !source(row).softWrapped {
      while text.last == " " { text.removeLast() }
      if byteCount < maximumBytes { text += "\n"; byteCount += 1 }
      else { exhausted = true }
    }
    lines.append(text)
    cellParts.removeAll(keepingCapacity: true)
    capturedRows += 1
  }
}

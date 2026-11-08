import Foundation

// Internal implementation partition of TerminalDocument. It retains rich cell
// payloads while rebuilding physical rows, and returns only the small mapping
// needed by the emulator to retain cursor and viewport identity.
extension TerminalDocument {
  struct ReflowMapping {
    var anchor: UInt64?
    var cursor: (row: Int, column: Int, pending: Bool)
    var saved: (row: Int, column: Int, pending: Bool)
  }

  mutating func reflowPrimary(columns nextColumns: Int, rows nextRows: Int,
                              anchor: UInt64?) -> ReflowMapping {
    let oldColumns = columns
    let oldRows = rowCount
    let oldHistoryCount = history.count
    let oldPrimary = primary
    let input = history + primary.rows
    // New physical rows are born at the replacement width while `input`
    // retains its old-width value copy for atom traversal.
    setSize(columns: nextColumns, rows: nextRows)
    var output: [TerminalRow] = []
    var row = blankRow()
    var column = 0
    var mappedAnchor: UInt64?
    var cursorMap = (row: 0, column: 0, pending: false)
    var savedMap = (row: 0, column: 0, pending: false)

    func finish(_ soft: Bool) {
      row.softWrapped = soft
      output.append(row)
      row = blankRow()
      column = 0
    }
    func map(_ sourceIndex: Int, _ sourceColumn: Int) {
      if sourceIndex == oldHistoryCount + oldPrimary.cursorRow,
         sourceColumn == oldPrimary.cursorColumn + (oldPrimary.pendingWrap ? 1 : 0) {
        cursorMap = (output.count, min(column, nextColumns - 1), column == nextColumns)
      }
      if sourceIndex == oldHistoryCount + oldPrimary.savedRow,
         sourceColumn == oldPrimary.savedColumn {
        savedMap = (output.count, min(column, nextColumns - 1), false)
      }
    }

    for (sourceIndex, source) in input.enumerated() {
      let soft = source.softWrapped
      var end = source.cells.lastIndex { cell in
        cell.kind != 0 || cell.style.background != 0
      }.map { $0 + 1 } ?? 0
      if soft { end = oldColumns }
      if sourceIndex == oldHistoryCount + oldPrimary.cursorRow {
        end = max(end, min(oldColumns, oldPrimary.cursorColumn + (oldPrimary.pendingWrap ? 1 : 0)))
      }
      if sourceIndex == oldHistoryCount + oldPrimary.savedRow { end = max(end, min(oldColumns, oldPrimary.savedColumn)) }
      var sourceColumn = 0
      while sourceColumn <= end {
        if sourceColumn == 0, source.id == anchor {
          // An anchor on a soft-continuation row denotes the leading boundary
          // of its whole logical line. If narrowing already emitted that
          // leading part, retain it instead of rebasing at the continuation.
          if sourceIndex > 0, input[sourceIndex - 1].softWrapped, let leading = output.last {
            mappedAnchor = leading.id
          } else {
            mappedAnchor = row.id
          }
        }
        map(sourceIndex, sourceColumn)
        guard sourceColumn < end else { break }
        let sourceCell = source.cells[sourceColumn]
        if sourceCell.kind == 3 || sourceCell.kind == 4 { sourceColumn += 1; continue }
        let nominal = (sourceCell.kind == 2 || sourceCell.flags & 1 != 0) ? 2 : 1
        let width = min(nominal, nextColumns)
        if column + width > nextColumns {
          if column < nextColumns { row.cells[column].kind = 4 }
          finish(true)
          if source.id == anchor, mappedAnchor == nil { mappedAnchor = row.id }
        }
        if sourceCell.kind == 0 {
          row.cells[column] = .erased(sourceCell.style)
        } else {
          var copied = sourceCell
          copied.kind = width == 2 ? 2 : 1
          if width < nominal { copied.flags |= 1 }
          row.cells[column] = copied
          if width == 2 {
            var continuation = source.cells.indices.contains(sourceColumn + 1) ? source.cells[sourceColumn + 1] : TerminalCell()
            continuation.text = ""; continuation.kind = 3
            row.cells[column + 1] = continuation
          }
        }
        column += width
        sourceColumn += nominal
      }
      if !soft { finish(false) }
    }
    if output.isEmpty { finish(false) }

    // Height growth can expose retained history; preserve the visible cursor.
    // The anchored row is a leading logical boundary, not merely the old
    // history/screen split. Reflow may join a history row onto an earlier row.
    // The live grid remains the tail of the physical document. An anchored
    // viewport is represented by its row identity in retained history rather
    // than by moving that historical row into the live screen and discarding
    // newer content.
    var start = max(0, output.count - nextRows)
    if nextRows > oldRows { start = max(0, start - (nextRows - oldRows)) }
    start = min(start, max(0, output.count - 1))
    history = Array(output.prefix(start))
    var screenRows = Array(output.dropFirst(start).prefix(nextRows))
    while screenRows.count < nextRows { screenRows.append(blankRow()) }
    primary = TerminalScreen(rows: screenRows, columns: nextColumns)
    primary.cursorRow = min(nextRows - 1, max(0, cursorMap.row - start))
    primary.cursorColumn = min(nextColumns - 1, cursorMap.column)
    primary.pendingWrap = cursorMap.pending
    primary.savedRow = min(nextRows - 1, max(0, savedMap.row - start))
    primary.savedColumn = min(nextColumns - 1, savedMap.column)
    return ReflowMapping(anchor: mappedAnchor, cursor: cursorMap, saved: savedMap)
  }
}

import Foundation

@main enum SwiftReflowTests {
  typealias Cell = SwiftReflow.Cell
  typealias Row = SwiftReflow.Row

  static func letters(_ value: String, soft: Bool = false) -> Row {
    Row(cells: value.map { Cell(String($0)) }, softWrapped: soft)
  }

  static func text(_ row: Row) -> String {
    row.cells.filter { !$0.continuation }.map(\.text).joined()
  }

  static func main() {
    // A two-row soft chain becomes three rows without creating a dangling wide
    // continuation and keeps the old viewport's logical start visible.
    var wide = [Cell("a"), Cell("b")]
    wide.append(contentsOf: Cell.wide("猫"))
    let source = [
      Row(cells: wide, softWrapped: true),
      letters("cdef"),
      letters("hard"),
    ]
    let result = SwiftReflow.reflow(
      .init(rows: source, oldColumns: 4, newColumns: 3, viewportTop: 1))
    precondition(result.rows.allSatisfy { $0.cells.count == 3 })
    precondition(result.rows[0].softWrapped)
    precondition(result.rows[1].cells[0].width == 2)
    precondition(result.rows[1].cells[0].continuation == false)
    precondition(result.rows[1].cells[1].continuation == true)
    precondition(result.viewportTop == 1)
    precondition(text(result.rows[3]).hasPrefix("har"))

    // Hard lines stay distinct, and invalid source viewport positions clamp.
    let hard = SwiftReflow.reflow(
      .init(rows: [letters("abcd"), letters("efgh")], oldColumns: 4, newColumns: 8, viewportTop: 99))
    precondition(hard.rows.count == 2)
    precondition(hard.rows.allSatisfy { !$0.softWrapped })
    precondition(hard.clamped && hard.viewportTop == 1)
    print("PASS Swift reflow: soft chains, wide glyph continuity, hard lines, viewport anchor")
  }
}

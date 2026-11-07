import Foundation

@main enum SwiftMarginsTests {
  static func main() {
    var grid = SwiftMarginGrid(rows: (0..<4).map { r in (0..<6).map { "\(r)\($0)" } }, blank: { "_" })
    precondition(grid.setVertical(top: 1, bottom: 3)); precondition(grid.setHorizontal(left: 1, right: 4))
    grid.originMode = true; grid.home(); precondition(grid.cursor == .init(row: 1, column: 1))
    grid.cup(row: 0, column: 1); grid.insertCharacters(2); precondition(grid.rows[1][2] == "_" && grid.rows[1][3] == "_")
    grid.deleteCharacters(1); precondition(grid.rows[1][4] != "_")
    let before = grid.rows[2][1]; grid.scrollUp(1); precondition(grid.rows[1][1] == before)
    grid.rectangularErase(.init(top: 1, bottom: 2, left: 1, right: 2)); precondition(grid.rows[2][2] == "_")
    print("PASS Swift margins: origin, horizontal edits, regional scroll, rectangle erase")
  }
}

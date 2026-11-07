import Foundation

/// Owns all rectangular grid mutation policy.  `Value` remains opaque so the
/// terminal model keeps styles, links, protection and wide-cell repair local.
struct SwiftMarginGrid<Value> {
  struct Cursor: Equatable { var row = 0; var column = 0 }
  struct Region: Equatable { var top: Int; var bottom: Int; var left: Int; var right: Int }
  private(set) var rows: [[Value]]
  private(set) var cursor = Cursor()
  private(set) var vertical: ClosedRange<Int>
  private(set) var horizontal: ClosedRange<Int>
  private let blank: () -> Value
  var originMode = false

  init(rows: [[Value]], blank: @escaping () -> Value) {
    precondition(!rows.isEmpty && !rows[0].isEmpty)
    precondition(rows.allSatisfy { $0.count == rows[0].count })
    self.rows = rows; self.blank = blank
    vertical = 0...(rows.count - 1); horizontal = 0...(rows[0].count - 1)
  }
  var height: Int { rows.count }; var width: Int { rows[0].count }
  var active: Region { Region(top: vertical.lowerBound, bottom: vertical.upperBound, left: horizontal.lowerBound, right: horizontal.upperBound) }
  mutating func setVertical(top: Int, bottom: Int) -> Bool { guard 0 <= top, top < bottom, bottom < height else { return false }; vertical = top...bottom; home(); return true }
  mutating func setHorizontal(left: Int, right: Int) -> Bool { guard 0 <= left, left < right, right < width else { return false }; horizontal = left...right; home(); return true }
  mutating func home() { let r = originMode ? vertical.lowerBound : 0; let c = originMode ? horizontal.lowerBound : 0; cursor = Cursor(row: r, column: c) }
  mutating func cup(row: Int, column: Int) { let r = originMode ? vertical.lowerBound + row : row; let c = originMode ? horizontal.lowerBound + column : column; cursor.row = clamp(r, 0, height - 1); cursor.column = clamp(c, 0, width - 1) }
  mutating func insertCharacters(_ count: Int) { shift(row: cursor.row, from: cursor.column, to: horizontal.upperBound, count: count, right: true) }
  mutating func deleteCharacters(_ count: Int) { shift(row: cursor.row, from: cursor.column, to: horizontal.upperBound, count: count, right: false) }
  mutating func insertLines(_ count: Int) { scroll(top: cursor.row, bottom: vertical.upperBound, left: horizontal.lowerBound, right: horizontal.upperBound, count: count, up: false) }
  mutating func deleteLines(_ count: Int) { scroll(top: cursor.row, bottom: vertical.upperBound, left: horizontal.lowerBound, right: horizontal.upperBound, count: count, up: true) }
  mutating func scrollUp(_ count: Int, region: Region? = nil) { let r = region ?? active; scroll(top: r.top, bottom: r.bottom, left: r.left, right: r.right, count: count, up: true) }
  mutating func scrollDown(_ count: Int, region: Region? = nil) { let r = region ?? active; scroll(top: r.top, bottom: r.bottom, left: r.left, right: r.right, count: count, up: false) }
  mutating func rectangularErase(_ region: Region) { guard valid(region) else { return }; for r in region.top...region.bottom { for c in region.left...region.right { rows[r][c] = blank() } } }
  private mutating func shift(row: Int, from: Int, to: Int, count: Int, right: Bool) {
    guard rows.indices.contains(row), horizontal.contains(from), from <= to else { return }; let n = min(max(0, count), to - from + 1); guard n > 0 else { return }
    if right { for c in stride(from: to, through: from + n, by: -1) { rows[row][c] = rows[row][c - n] }; for c in from..<(from+n) { rows[row][c] = blank() } }
    else { for c in from...(to-n) { rows[row][c] = rows[row][c+n] }; for c in (to-n+1)...to { rows[row][c] = blank() } }
  }
  private mutating func scroll(top: Int, bottom: Int, left: Int, right: Int, count: Int, up: Bool) {
    guard top >= 0, left >= 0, bottom < height, right < width, top <= bottom, left <= right else { return }; let n = min(max(0,count), bottom-top+1); guard n > 0 else { return }
    for step in 0...(bottom-top) { let target = up ? top+step : bottom-step; let source = up ? target+n : target-n; if source >= top && source <= bottom { for c in left...right { rows[target][c] = rows[source][c] } } else { for c in left...right { rows[target][c] = blank() } } }
  }
  private func valid(_ r: Region) -> Bool { r.top >= 0 && r.left >= 0 && r.bottom < height && r.right < width && r.top <= r.bottom && r.left <= r.right }
  private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int { max(lower, min(upper, value)) }
}

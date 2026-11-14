import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

@Suite enum GeometryTests {
  /// All block characters stay in bounds; half blocks tile odd and even cells
  /// without gaps; box strokes meet the cell edges.
  @Test static func blockCharactersTileAndStayInBounds() throws {
    for (w, h) in [(9, 21), (18, 42), (1, 1)] {
      for code in UInt32(0x2580)...0x259f {
        let text = String(UnicodeScalar(code)!)
        guard let shapes = GeometricGlyph.rectangles(text: text, width: w, height: h) else {
          Issue.record("missing block")
          return
        }
        for rect in shapes {
          #expect(
            rect.x >= 0 && rect.y >= 0 && rect.width >= 0 && rect.height >= 0
              && rect.x + rect.width <= w && rect.y + rect.height <= h)
        }
      }
      let halves =
        try #require(GeometricGlyph.rectangles(text: "▀", width: w, height: h))
        + (try #require(GeometricGlyph.rectangles(text: "▄", width: w, height: h)))
      for y in 0..<h {
        for x in 0..<w {
          let coverage = halves.filter {
            x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height
          }.count
          #expect(coverage == 1, "gap/overlap at \(x),\(y)")
        }
      }
    }
    let horizontal = try #require(GeometricGlyph.rectangles(text: "─", width: 9, height: 21))
    #expect(horizontal.contains { $0.x == 0 })
    #expect(horizontal.contains { $0.x + $0.width == 9 })
    #expect(GeometricGlyph.rectangles(text: "a", width: 9, height: 21) == nil)
    #expect(GeometricGlyph.rectangles(text: "é", width: 9, height: 21) == nil)
  }
}

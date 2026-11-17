import Foundation

/// Device-pixel decoration geometry shared by frame assembly and pixel tests.
/// Patterns are anchored to the grid so adjacent and wide cells join cleanly.
package enum UnderlineGeometry {
  package struct Rect: Equatable {
    package let x: Int
    package let y: Int
    package let width: Int
    package let height: Int
  }

  /// The thickness of every decoration line: one point, within an eighth of the cell.
  package static func stroke(height: Int, scale: Int) -> Int { max(1, min(max(1, scale), max(1, height / 8))) }

  package static func rectangles(kind: Int, x: Int, width: Int, height: Int, scale: Int) -> [Rect] {
    var result: [Rect] = []
    forEach(kind: kind, x: x, width: width, height: height, scale: scale) { result.append($0) }
    return result
  }

  /// Visits the rectangles of one cell's underline. Frame assembly calls this
  /// for every underlined cell, so it builds no array.
  package static func forEach(kind: Int, x: Int, width: Int, height: Int, scale: Int, _ body: (Rect) -> Void) {
    guard kind > 0, width > 0, height > 0 else { return }
    let stroke = stroke(height: height, scale: scale)
    let baseline = max(0, height - 3 * stroke)
    func line(_ y: Int) { body(Rect(x: 0, y: min(height - stroke, max(0, y)), width: width, height: stroke)) }
    switch kind {
    case 2:
      line(baseline - stroke); line(baseline + stroke)
    case 3:
      let amplitude = max(1, stroke)
      let period = 4 * amplitude
      for column in 0..<width {
        let phase = ((x + column) % period + period) % period
        let dy = phase < 2 * amplitude ? phase - amplitude : 3 * amplitude - phase
        body(Rect(x: column, y: min(height - stroke, max(0, baseline + dy)), width: 1, height: stroke))
      }
    case 4, 5:
      let on = kind == 4 ? stroke : 3 * stroke
      let period = on + (kind == 4 ? stroke : 2 * stroke)
      var column = 0
      while column < width {
        let phase = ((x + column) % period + period) % period
        let length = min(width - column, phase < on ? on - phase : period - phase)
        if phase < on { body(Rect(x: column, y: baseline, width: length, height: stroke)) }
        column += length
      }
    default: line(baseline)
    }
  }
}

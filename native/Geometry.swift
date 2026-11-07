import Foundation

struct GlyphRectangle: Equatable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  var coverage: Float = 1
}
// Box/block characters represent cell geometry, not font ascent/descent. Keeping
// them on the pixel grid prevents horizontal seams in ANSI half-block video.
enum GeometricGlyph {
  static func rectangles(text: String, width w: Int, height h: Int) -> [GlyphRectangle]? {
    guard w > 0, h > 0, text.unicodeScalars.count == 1, let code = text.unicodeScalars.first?.value
    else { return nil }
    func r(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ coverage: Float = 1) -> GlyphRectangle
    { GlyphRectangle(x: x, y: y, width: width, height: height, coverage: coverage) }
    let halfW = w / 2
    let halfH = h / 2
    switch code {
    case 0x2580: return [r(0, 0, w, halfH)]
    case 0x2581...0x2587:
      let n = Int(code - 0x2580)
      let size = max(1, (h * n + 7) / 8)
      return [r(0, h - size, w, size)]
    case 0x2588: return [r(0, 0, w, h)]
    case 0x2589...0x258f:
      let n = Int(0x2590 - code)
      return [r(0, 0, max(1, (w * n + 7) / 8), h)]
    case 0x2590: return [r(halfW, 0, w - halfW, h)]
    case 0x2591...0x2593: return [r(0, 0, w, h, Float(code - 0x2590) / 4)]
    case 0x2594: return [r(0, 0, w, max(1, (h + 7) / 8))]
    case 0x2595:
      let size = max(1, (w + 7) / 8)
      return [r(w - size, 0, size, h)]
    case 0x2596...0x259f:
      let masks: [UInt8] = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14]
      let mask = masks[Int(code - 0x2596)]
      let quadrants = [
        r(0, 0, halfW, halfH), r(halfW, 0, w - halfW, halfH), r(0, halfH, halfW, h - halfH),
        r(halfW, halfH, w - halfW, h - halfH),
      ]
      return quadrants.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { $0.element }
    default: break
    }
    // Arms use left/right/up/down bits and meet at exactly the same cell center.
    let arms: Int
    switch code {
    case 0x2500, 0x2501: arms = 3
    case 0x2502, 0x2503: arms = 12
    case 0x250c, 0x250f, 0x256d: arms = 10
    case 0x2510, 0x2513, 0x256e: arms = 9
    case 0x2514, 0x2517, 0x2570: arms = 6
    case 0x2518, 0x251b, 0x256f: arms = 5
    case 0x251c, 0x2523: arms = 14
    case 0x2524, 0x252b: arms = 13
    case 0x252c, 0x2533: arms = 11
    case 0x2534, 0x253b: arms = 7
    case 0x253c, 0x254b: arms = 15
    default: return nil
    }
    let heavy: Set<UInt32> = [
      0x2501, 0x2503, 0x250f, 0x2513, 0x2517, 0x251b, 0x2523, 0x252b, 0x2533, 0x253b, 0x254b,
    ]
    let stroke = min(w, h, max(1, h / 20) * (heavy.contains(code) ? 2 : 1))
    let x = (w - stroke) / 2
    let y = (h - stroke) / 2
    var out: [GlyphRectangle] = []
    if arms & 1 != 0 { out.append(r(0, y, x + stroke, stroke)) }
    if arms & 2 != 0 { out.append(r(x, y, w - x, stroke)) }
    if arms & 4 != 0 { out.append(r(x, 0, stroke, y + stroke)) }
    if arms & 8 != 0 { out.append(r(x, y, stroke, h - y)) }
    return out
  }
}

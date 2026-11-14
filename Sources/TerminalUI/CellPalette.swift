import Foundation
import TerminalEngine

/// Resolves terminal colors once for drawing and accessibility. Values are
/// linear sRGB; selection/search may replace the rendered foreground later.
struct CellPalette {
  struct Colors {
    let foreground: SIMD4<Float>
    let background: SIMD4<Float>
    fileprivate let explicitUnderline: SIMD4<Float>?
    func underline(matching foreground: SIMD4<Float>) -> SIMD4<Float> {
      explicitUnderline ?? foreground
    }
  }
  private let palette: [[Int]]
  private let defaultForeground: [Int]
  private let defaultBackground: [Int]
  private let reverseVideo: Bool

  init(snapshot: TerminalSnapshot) {
    palette = snapshot.palette
    defaultForeground = snapshot.default_fg
    defaultBackground = snapshot.default_bg
    reverseVideo = snapshot.modes.reverse_video
  }
  var background: SIMD4<Float> { Self.linear(defaultBackground) }

  func resolve(_ style: CellStyle) -> Colors {
    var foreground = color(style.foreground, fallback: defaultForeground)
    var background = color(style.background, fallback: defaultBackground)
    if style.inverse != reverseVideo { swap(&foreground, &background) }
    if style.faint { foreground *= SIMD4(0.65, 0.65, 0.65, 1) }
    let underline = style.underline_color.index == nil && style.underline_color.rgb == nil
      ? nil : color(style.underline_color, fallback: defaultForeground)
    return Colors(foreground: foreground, background: background, explicitUnderline: underline)
  }
  private func color(_ value: TerminalColor, fallback: [Int]) -> SIMD4<Float> {
    let rgb = value.rgb.flatMap { $0.count == 3 ? $0 : nil }
      ?? value.index.flatMap { palette.indices.contains($0) && palette[$0].count == 3 ? palette[$0] : nil }
      ?? fallback
    return Self.linear(rgb)
  }
  /// Decode one normalized sRGB component, also used for glyph bitmap uploads.
  static func linear(_ encoded: Float) -> Float {
    encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
  }
  private static func linear(_ rgb: [Int]) -> SIMD4<Float> {
    guard rgb.count == 3 else { return SIMD4(0, 0, 0, 1) }
    func component(_ value: Int) -> Float {
      let encoded = Float(min(255, max(0, value))) / 255
      return linear(encoded)
    }
    return SIMD4(component(rgb[0]), component(rgb[1]), component(rgb[2]), 1)
  }
}

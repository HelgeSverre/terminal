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
  private let defaultForeground: SIMD4<Float>
  private let defaultBackground: SIMD4<Float>
  private let reverseVideo: Bool
  private static let linearByte: [Float] = (0...255).map { linear(Float($0) / 255) }

  init(snapshot: TerminalSnapshot) {
    palette = snapshot.palette
    defaultForeground = Self.linear(snapshot.default_fg)
    defaultBackground = Self.linear(snapshot.default_bg)
    reverseVideo = snapshot.modes.reverse_video
  }
  var background: SIMD4<Float> { defaultBackground }

  func resolve(_ style: CellStyle) -> Colors {
    var foreground = color(style.foreground, fallback: defaultForeground)
    var background = color(style.background, fallback: defaultBackground)
    if style.inverse != reverseVideo { swap(&foreground, &background) }
    if style.faint { foreground *= SIMD4(0.65, 0.65, 0.65, 1) }
    let underline = style.underline_color.isDefault
      ? nil : color(style.underline_color, fallback: defaultForeground)
    return Colors(foreground: foreground, background: background, explicitUnderline: underline)
  }
  private func color(_ value: TerminalColor, fallback: SIMD4<Float>) -> SIMD4<Float> {
    let packed = value.packed
    switch packed >> 24 {
    case 2:
      return SIMD4(
        Self.linearByte[Int((packed >> 16) & 0xff)],
        Self.linearByte[Int((packed >> 8) & 0xff)],
        Self.linearByte[Int(packed & 0xff)], 1)
    case 1:
      let index = Int(packed & 0xff)
      if palette.indices.contains(index), palette[index].count == 3 {
        return Self.linear(palette[index])
      }
      return fallback
    default:
      return fallback
    }
  }
  /// Decode one normalized sRGB component, also used for glyph bitmap uploads.
  static func linear(_ encoded: Float) -> Float {
    encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
  }
  private static func linear(_ rgb: [Int]) -> SIMD4<Float> {
    guard rgb.count == 3 else { return SIMD4(0, 0, 0, 1) }
    return SIMD4(
      linearByte[min(255, max(0, rgb[0]))],
      linearByte[min(255, max(0, rgb[1]))],
      linearByte[min(255, max(0, rgb[2]))], 1)
  }
}

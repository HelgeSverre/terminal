import AppKit

// Shared visual language from Trace/Splash/Glue/Shepherd. Terminal text uses
// user-installed Obel Mono; surrounding controls retain native macOS typography.
enum TerminalTheme {
  static let background: UInt32 = 0x0a0a0b
  static let surface: UInt32 = 0x111113
  static let raised: UInt32 = 0x1b1c1f
  static let border: UInt32 = 0x222326
  static let text: UInt32 = 0xe6e6e6
  static let secondary: UInt32 = 0xb4b5ba
  static let muted: UInt32 = 0x8e8f96
  static let accent: UInt32 = 0xfacc15
  static let selection: UInt32 = 0x463b0e
  static let danger: UInt32 = 0xf87171
  static let contentInset: CGFloat = 8
  static let windowInset: CGFloat = 24
  static func color(_ rgb: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
  }
  static func linear(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
    func channel(_ value: UInt32) -> Float {
      let s = Float(value & 255) / 255
      return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return SIMD4(channel(rgb >> 16), channel(rgb >> 8), channel(rgb), alpha)
  }
  static func apply(to window: NSWindow) {
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = color(surface)
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .line
  }
}

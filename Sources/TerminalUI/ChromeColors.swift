import TerminalEngine

/// The colors of what the view draws around the text: the find bar and the
/// selection notice. The standard scheme has the app's own; any other
/// scheme gets colors mixed from its text and background, so a light
/// terminal does not carry a dark bar.
struct TerminalChromeColors: Equatable {
  var background: UInt32
  var raised: UInt32
  var border: UInt32
  var text: UInt32
  var secondary: UInt32
  var muted: UInt32
  var accent: UInt32
  var danger: UInt32

  static let standard = TerminalChromeColors(
    background: TerminalTheme.background, raised: TerminalTheme.raised, border: TerminalTheme.border,
    text: TerminalTheme.text, secondary: TerminalTheme.secondary, muted: TerminalTheme.muted,
    accent: TerminalTheme.accent, danger: TerminalTheme.danger)

  init(background: UInt32, raised: UInt32, border: UInt32, text: UInt32, secondary: UInt32, muted: UInt32,
       accent: UInt32, danger: UInt32) {
    self.background = background; self.raised = raised; self.border = border; self.text = text
    self.secondary = secondary; self.muted = muted; self.accent = accent; self.danger = danger
  }
  init(_ scheme: TerminalColorScheme) {
    guard scheme != .standard else { self = .standard; return }
    let ground = scheme.background, ink = scheme.foreground
    self.init(
      background: ground, raised: Self.mix(ground, ink, 0.07), border: Self.mix(ground, ink, 0.18),
      text: ink, secondary: Self.mix(ink, ground, 0.2), muted: Self.mix(ink, ground, 0.4),
      accent: scheme.cursor, danger: scheme.ansi.count == 16 ? scheme.ansi[9] : TerminalTheme.danger)
  }
  /// `from` moved `amount` of the way to `to`, per channel of the encoded color.
  static func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> UInt32 {
    [16, 8, 0].reduce(0) { result, shift in
      let a = Double((from >> shift) & 255), b = Double((to >> shift) & 255)
      return result | UInt32((a + (b - a) * amount).rounded()) << shift
    }
  }
}

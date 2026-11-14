/// The colors a terminal starts with and returns to on a reset. Each is
/// 0xRRGGBB in sRGB. A program can still change the text colors and the
/// palette for itself with OSC 4, 10 and 11.
public struct TerminalColorScheme: Equatable, Sendable {
  /// Text with no color of its own.
  public var foreground: UInt32
  public var background: UInt32
  /// The sixteen ANSI colors: black, red, green, yellow, blue, magenta, cyan
  /// and white, then their bright forms. A shorter or longer list is ignored.
  public var ansi: [UInt32]
  /// The cursor while the view has focus.
  public var cursor: UInt32
  public var selectionBackground: UInt32
  public var selectionForeground: UInt32

  public init(
    foreground: UInt32 = 0xe6e6e6, background: UInt32 = 0x0a0a0b,
    ansi: [UInt32] = TerminalColorScheme.standardANSI,
    cursor: UInt32 = 0xfacc15, selectionBackground: UInt32 = 0x463b0e, selectionForeground: UInt32 = 0xe6e6e6
  ) {
    self.foreground = foreground
    self.background = background
    self.ansi = ansi
    self.cursor = cursor
    self.selectionBackground = selectionBackground
    self.selectionForeground = selectionForeground
  }

  /// The colors of Helge Terminal.
  public static let standard = TerminalColorScheme()
  public static let standardANSI: [UInt32] = [
    0x1b1c1f, 0xef4444, 0x22c55e, 0xfacc15, 0x60a5fa, 0xc084fc, 0x22d3ee, 0xd4d4d8,
    0x6b6f76, 0xf87171, 0x4ade80, 0xfde047, 0x93c5fd, 0xd8b4fe, 0x67e8f9, 0xfafafa,
  ]
}

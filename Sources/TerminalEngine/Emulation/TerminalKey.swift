/// A key a host sends to the terminal without an AppKit event: from its own
/// controls, a script or a test. The terminal turns it into the bytes the
/// program expects in its current modes (application cursor keys, the Kitty
/// keyboard protocol and so on).
public enum TerminalKey: Hashable, Sendable {
  case up, down, right, left
  case home, end, pageUp, pageDown, insert, forwardDelete
  case backspace, tab, enter, escape
  /// F1 to F12.
  case function(Int)
  /// A key that types a character, for use with modifiers: `.character("c")`
  /// with `.control` is Control-C. The character is the key's unshifted one.
  case character(Character)

  /// The emulator's number for the key.
  package var code: UInt32? {
    switch self {
    case .up: return 10
    case .down: return 11
    case .right: return 12
    case .left: return 13
    case .home: return 14
    case .end: return 15
    case .pageUp: return 16
    case .pageDown: return 17
    case .insert: return 18
    case .forwardDelete: return 19
    case .backspace: return 20
    case .tab: return 21
    case .enter: return 22
    case .escape: return 23
    case .function(let number): return (1...12).contains(number) ? UInt32(99 + number) : nil
    case .character: return 200
    }
  }
  package var character: String {
    if case .character(let value) = self { return String(value) }
    return ""
  }
}

/// The modifiers held with a `TerminalKey`.
public struct TerminalKeyModifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let shift = TerminalKeyModifiers(rawValue: 1)
  public static let option = TerminalKeyModifiers(rawValue: 2)
  public static let control = TerminalKeyModifiers(rawValue: 4)
  public static let command = TerminalKeyModifiers(rawValue: 8)
}

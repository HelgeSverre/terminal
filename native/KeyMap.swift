import AppKit

// macOS virtual key codes from HIToolbox/Events.h. Bridge keypad IDs follow
// Kitty's KP_0..KP_SEPARATOR order; numeric-pad Enter stays distinct from Return.
enum NativeKeyMap {
  enum Route {
    case shortcut(String)
    case encoded(key: UInt32, text: String, modifiers: UInt32)
    case inputMethod
  }
  // Host editing bindings match the macOS Ghostty defaults. These are consumed
  // actions, so their physical releases must not leak into negotiated key events.
  static func route(_ event: NSEvent) -> Route {
    let flags = modifiers(event.modifierFlags)
    switch (event.keyCode, flags) {
    case (123, 8): return .shortcut("\u{01}")
    case (124, 8): return .shortcut("\u{05}")
    case (51, 8): return .shortcut("\u{15}")
    case (123, 2): return .shortcut("\u{1b}b")
    case (124, 2): return .shortcut("\u{1b}f")
    default: break
    }
    let optionEsc = TerminalPreferences.load().optionSendsEscape
    let nativeOption = flags & 2 != 0 && !optionEsc && flags & (4 | 8) == 0
    if let key = special[event.keyCode], !(nativeOption && isTextKeypad(key)) {
      return .encoded(key: key, text: event.charactersIgnoringModifiers ?? "", modifiers: flags)
    }
    if flags & 4 != 0 || (flags & 2 != 0 && optionEsc) {
      return .encoded(key: 200, text: event.charactersIgnoringModifiers ?? "", modifiers: flags)
    }
    return .inputMethod
  }
  static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    (flags.contains(.shift) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
      | (flags.contains(.control) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
  }
  private static let special: [UInt16: UInt32] = [
    126: 10, 125: 11, 124: 12, 123: 13, 115: 14, 119: 15, 116: 16, 121: 17, 114: 18, 117: 19,
    51: 20, 48: 21, 36: 22, 53: 23, 122: 100, 120: 101, 99: 102, 118: 103, 96: 104,
    97: 105, 98: 106, 100: 107, 101: 108, 109: 109, 103: 110, 111: 111,
    82: 300, 83: 301, 84: 302, 85: 303, 86: 304, 87: 305, 88: 306, 89: 307, 91: 308, 92: 309,
    65: 310, 75: 311, 67: 312, 78: 313, 69: 314, 76: 315, 81: 316, 95: 317,
  ]
  private static func isTextKeypad(_ code: UInt32) -> Bool { (300...317).contains(code) && code != 315 }
}

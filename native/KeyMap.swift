import AppKit

// macOS virtual key codes from HIToolbox/Events.h. Bridge keypad IDs follow
// Kitty's KP_0..KP_SEPARATOR order; numeric-pad Enter stays distinct from Return.
enum NativeKeyMap {
  enum Route {
    case shortcut(String)
    case encoded(KeyEvent)
    case inputMethod
  }
  struct KeyEvent {
    let key: UInt32
    let logical: String
    let text: String
    let shifted: String
    let baseLayout: String
    let legacyText: String
    let modifiers: UInt32
  }
  struct ModifierState {
    private var active = Set<UInt32>()
    private var unknownOnFocus: UInt32 = 0
    mutating func beginFocus(modifiers: UInt32) {
      active.removeAll()
      unknownOnFocus = modifiers & (1 | 2 | 4 | 8 | 64)
    }
    mutating func resolve(_ change: (event: KeyEvent, release: Bool)) -> (event: KeyEvent, release: Bool)? {
      let bit = NativeKeyMap.modifierBit(for: change.event.key)
      // AppKit only exposes aggregated left/right flags. A modifier already
      // held when focus arrives can first surface as the other side's release;
      // suppress that ambiguous transition rather than inventing a press.
      if unknownOnFocus & bit != 0 {
        if change.release { unknownOnFocus &= ~bit }
        return nil
      }
      let release = change.release || active.contains(change.event.key)
      if release {
        active.remove(change.event.key)
      } else {
        active.insert(change.event.key)
      }
      return (change.event, release)
    }
    mutating func releaseAll(modifiers: UInt32) -> [(key: UInt32, modifiers: UInt32)] {
      var remaining = modifiers
      unknownOnFocus = 0
      var releases: [(key: UInt32, modifiers: UInt32)] = []
      for key in active.sorted() {
        active.remove(key)
        let bit = NativeKeyMap.modifierBit(for: key)
        if !active.contains(where: { NativeKeyMap.modifierBit(for: $0) == bit }) { remaining &= ~bit }
        releases.append((key, remaining))
      }
      return releases
    }
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
      return .encoded(keyEvent(event, key: key, modifiers: flags))
    }
    if flags & (4 | 8) != 0 || (flags & 2 != 0 && optionEsc) {
      return .encoded(keyEvent(event, key: 200, modifiers: flags))
    }
    return .inputMethod
  }
  static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    (flags.contains(.shift) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
      | (flags.contains(.control) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
      | (flags.contains(.capsLock) ? 64 : 0)
  }
  static func textEvent(_ event: NSEvent, text: String, modifiers: UInt32) -> KeyEvent {
    keyEvent(event, key: 200, modifiers: modifiers, text: text)
  }
  static func modifierEvent(_ event: NSEvent) -> (event: KeyEvent, release: Bool)? {
    let key: UInt32
    let mask: NSEvent.ModifierFlags
    switch event.keyCode {
    case 56: key = 400; mask = .shift
    case 59: key = 401; mask = .control
    case 58: key = 402; mask = .option
    case 55: key = 403; mask = .command
    case 60: key = 406; mask = .shift
    case 62: key = 407; mask = .control
    case 61: key = 408; mask = .option
    case 54: key = 409; mask = .command
    case 57: key = 412; mask = .capsLock
    default: return nil
    }
    let flags = modifiers(event.modifierFlags)
    // `charactersIgnoringModifiers` is invalid for AppKit flags-changed
    // events. Modifier key codes carry the complete kitty identity themselves.
    return (
      KeyEvent(
        key: key, logical: "", text: "", shifted: "", baseLayout: "", legacyText: "",
        modifiers: flags),
      !event.modifierFlags.contains(mask))
  }
  static func modifierBit(for key: UInt32) -> UInt32 {
    switch key {
    case 400, 406: return 1
    case 401, 407: return 4
    case 402, 408: return 2
    case 403, 409: return 8
    case 412: return 64
    default: return 0
    }
  }
  private static func keyEvent(
    _ event: NSEvent, key: UInt32, modifiers: UInt32, text: String? = nil
  ) -> KeyEvent {
    // `charactersIgnoringModifiers` deliberately preserves Shift. Kitty's
    // primary key must instead be the current-layout value with all modifiers
    // replaced, while its shifted alternate is a separate value.
    let committed = text ?? event.characters ?? ""
    let unmodified = event.charactersIgnoringModifiers.flatMap { $0.isEmpty ? nil : $0 } ?? committed
    // AppKit can return an empty translation for an unmapped keypad code.
    // Preserve its committed symbol when no translated text is available.
    let logical = event.characters(byApplyingModifiers: []).flatMap { $0.isEmpty ? nil : $0 } ?? unmodified
    let shifted = modifiers & 1 != 0
      ? event.characters(byApplyingModifiers: .shift).flatMap { $0.isEmpty ? nil : $0 } ?? unmodified : ""
    var legacyModifiers: NSEvent.ModifierFlags = []
    if modifiers & 1 != 0 { legacyModifiers.insert(.shift) }
    if modifiers & 64 != 0 { legacyModifiers.insert(.capsLock) }
    let legacyText = event.characters(byApplyingModifiers: legacyModifiers).flatMap { $0.isEmpty ? nil : $0 }
      ?? unmodified
    return KeyEvent(
      key: key, logical: logical, text: committed, shifted: shifted,
      baseLayout: baseLayout[event.keyCode] ?? "", legacyText: legacyText, modifiers: modifiers)
  }
  private static let special: [UInt16: UInt32] = [
    126: 10, 125: 11, 124: 12, 123: 13, 115: 14, 119: 15, 116: 16, 121: 17, 114: 18, 117: 19,
    51: 20, 48: 21, 36: 22, 53: 23, 122: 100, 120: 101, 99: 102, 118: 103, 96: 104,
    97: 105, 98: 106, 100: 107, 101: 108, 109: 109, 103: 110, 111: 111,
    82: 300, 83: 301, 84: 302, 85: 303, 86: 304, 87: 305, 88: 306, 89: 307, 91: 308, 92: 309,
    65: 310, 75: 311, 67: 312, 78: 313, 69: 314, 76: 315, 81: 316, 95: 317,
  ]
  private static let baseLayout: [UInt16: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
    11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
    39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
  ]
  private static func isTextKeypad(_ code: UInt32) -> Bool { (300...317).contains(code) && code != 315 }
}

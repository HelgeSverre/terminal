#if os(iOS)
import UIKit
import TerminalHost

extension TerminalKeyEvent {
  var released: TerminalKeyEvent {
    TerminalKeyEvent(text: "", logical: logical, shifted: shifted, baseLayout: baseLayout,
                     legacyText: legacyText, key: key, modifiers: modifiers, event: 2)
  }
}

enum TouchHardwareInput {
  static func modifiers(_ flags: UIKeyModifierFlags) -> UInt32 {
    (flags.contains(.shift) ? 1 : 0) | (flags.contains(.alternate) ? 2 : 0)
      | (flags.contains(.control) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
      | (flags.contains(.alphaShift) ? 64 : 0)
  }
  static func mapped(_ key: UIKey, text: String? = nil, event: UInt32 = 0) -> TerminalKeyEvent {
    let hid = Int(key.keyCode.rawValue)
    let code = special[hid] ?? 200
    let logical = key.charactersIgnoringModifiers
    let flags = key.modifierFlags
    let onlyShiftOrCaps = flags.intersection([.alternate, .control, .command]).isEmpty
    // UIKit supplies layout-dependent characters plus a HID physical identity,
    // but no API equivalent to AppKit's characters(byApplyingModifiers:).
    // Keep unavailable alternates empty instead of inventing them.
    return TerminalKeyEvent(text: text ?? key.characters, logical: logical,
      shifted: flags.contains(.shift) && onlyShiftOrCaps ? key.characters : "",
      baseLayout: baseLayout(hid), legacyText: onlyShiftOrCaps ? key.characters : logical,
      key: code, modifiers: modifiers(key.modifierFlags), event: event)
  }
  static func handles(_ key: UIKey, optionSendsEscape: Bool) -> Bool {
    special[Int(key.keyCode.rawValue)] != nil || key.modifierFlags.contains(.control)
      || key.modifierFlags.contains(.command) || (optionSendsEscape && key.modifierFlags.contains(.alternate))
  }
  static func baseLayout(_ hid: Int) -> String {
    if (4...29).contains(hid) { return String(Unicode.Scalar(97 + hid - 4)!) }
    if (30...38).contains(hid) { return String(hid - 29) }
    if hid == 39 { return "0" }
    return [44: " ", 45: "-", 46: "=", 47: "[", 48: "]", 49: "\\", 51: ";", 52: "'", 53: "`", 54: ",", 55: ".", 56: "/"][hid] ?? ""
  }
  static let special: [Int: UInt32] = [
    40: 22, 41: 23, 42: 20, 43: 21, 57: 412,
    58: 100, 59: 101, 60: 102, 61: 103, 62: 104, 63: 105,
    64: 106, 65: 107, 66: 108, 67: 109, 68: 110, 69: 111,
    73: 18, 74: 14, 75: 16, 76: 19, 77: 15, 78: 17, 79: 12, 80: 13, 81: 11, 82: 10,
    84: 311, 85: 312, 86: 313, 87: 314, 88: 315,
    89: 301, 90: 302, 91: 303, 92: 304, 93: 305, 94: 306, 95: 307, 96: 308, 97: 309,
    98: 300, 99: 310, 103: 316,
    224: 401, 225: 400, 226: 402, 227: 403, 228: 407, 229: 406, 230: 408, 231: 409,
  ]
}
#endif

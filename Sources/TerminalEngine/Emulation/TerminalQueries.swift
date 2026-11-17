import Foundation

/// The small, audited discovery surface. No terminfo database or filesystem
/// access happens on the terminal owner. Unknown names fail explicitly.
enum TerminalQueries {
  static let maximumPayloadBytes = 4096
  static let maximumCapabilities = 32

  static func termcap(_ payload: String, applicationCursor: Bool) -> String {
    let invalid = "\u{1b}P0+r\u{1b}\\"
    let names = payload.split(separator: ";", omittingEmptySubsequences: false)
    guard payload.utf8.count <= maximumPayloadBytes,
          !names.isEmpty, names.count <= maximumCapabilities else { return invalid }
    var answers: [String] = []
    var rejected = false
    for encoded in names {
      guard let name = unhex(encoded), let value = capability(name, applicationCursor: applicationCursor) else {
        rejected = true
        break
      }
      answers.append("\(encoded)=\(hex(value))")
    }
    return (answers.isEmpty ? "" : "\u{1b}P1+r\(answers.joined(separator: ";"))\u{1b}\\")
      + (rejected ? invalid : "")
  }

  private static func capability(_ name: String, applicationCursor: Bool) -> String? {
    let cursor = applicationCursor ? "\u{1b}O" : "\u{1b}["
    switch name {
    case "TN", "name": return "helge-terminal"
    case "Co", "colors": return "256"
    // ncurses' boolean direct-color capability.
    case "RGB", "Tc": return "1"
    case "ku", "kcuu1": return cursor + "A"
    case "kd", "kcud1": return cursor + "B"
    case "kr", "kcuf1": return cursor + "C"
    case "kl", "kcub1": return cursor + "D"
    case "kh", "khome": return cursor + "H"
    case "@7", "kend": return cursor + "F"
    case "kb", "kbs": return "\u{7f}"
    case "kB", "kcbt": return "\u{1b}[Z"
    case "kI", "kich1": return "\u{1b}[2~"
    case "kD", "kdch1": return "\u{1b}[3~"
    case "kP", "kpp": return "\u{1b}[5~"
    case "kN", "knp": return "\u{1b}[6~"
    case "k1", "kf1": return "\u{1b}OP"
    case "k2", "kf2": return "\u{1b}OQ"
    case "k3", "kf3": return "\u{1b}OR"
    case "k4", "kf4": return "\u{1b}OS"
    case "k5", "kf5": return "\u{1b}[15~"
    case "k6", "kf6": return "\u{1b}[17~"
    case "k7", "kf7": return "\u{1b}[18~"
    case "k8", "kf8": return "\u{1b}[19~"
    case "k9", "kf9": return "\u{1b}[20~"
    case "k;", "kf10": return "\u{1b}[21~"
    case "F1", "kf11": return "\u{1b}[23~"
    case "F2", "kf12": return "\u{1b}[24~"
    default: return nil
    }
  }

  static func status(_ request: String, style: TerminalStyle, protected: Bool,
                     top: Int, bottom: Int, left: Int, right: Int, cursorShape: UInt8) -> String {
    let value: String?
    switch request {
    case "m": value = sgr(style) + "m"
    case "r": value = "\(top + 1);\(bottom + 1)r"
    case "s": value = "\(left + 1);\(right + 1)s"
    case " q": value = "\(cursorShape) q"
    case "\"q": value = "\(protected ? 1 : 0)\"q"
    default: value = nil
    }
    return "\u{1b}P\(value == nil ? 0 : 1)$r\(value ?? "")\u{1b}\\"
  }

  /// A reset followed by all active attributes round-trips through SGR,
  /// including underline style and color. This describes the pen, not a cell.
  private static func sgr(_ style: TerminalStyle) -> String {
    var fields = ["0"]
    let flags: [(UInt16, Int)] = [(1, 1), (2, 2), (4, 3), (8, 7), (16, 8), (32, 9), (64, 53), (128, 5)]
    for (bit, code) in flags {
      if style.flags & bit != 0 { fields.append(String(code)) }
    }
    if style.underlineKind != 0 { fields.append("4:\(style.underlineKind)") }
    for (color, code) in [(style.foreground, 38), (style.background, 48), (style.underline, 58)] {
      if color >> 24 == 1 { fields.append("\(code);5;\(color & 255)") }
      else if color >> 24 == 2 { fields.append("\(code);2;\((color >> 16) & 255);\((color >> 8) & 255);\(color & 255)") }
    }
    return fields.joined(separator: ";")
  }

  static func hex(_ value: String) -> String {
    value.utf8.map { String(format: "%02x", $0) }.joined()
  }
  private static func unhex(_ value: Substring) -> String? {
    let input = Array(value.utf8)
    guard !input.isEmpty, input.count <= 128, input.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: return byte - 48
      case 65...70: return byte - 65 + 10
      case 97...102: return byte - 97 + 10
      default: return nil
      }
    }
    for index in stride(from: 0, to: input.count, by: 2) {
      guard let high = nibble(input[index]), let low = nibble(input[index + 1]) else { return nil }
      let byte = high << 4 | low
      guard (0x20...0x7e).contains(byte) else { return nil }
      bytes.append(byte)
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

/// Mutable terminal color state and the OSC palette grammar.
///
/// This deliberately owns wire details (including query reply spelling) so
/// the terminal state machine only has to route OSC code/value pairs and
/// publish snapshots. OSC 110/111 are intentionally not handled.
struct TerminalPalette {
  private struct RGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var snapshotValue: [Int] { [Int(red), Int(green), Int(blue)] }

    fileprivate var oscValue: String {
      "rgb:\(Self.doubledHex(red))/\(Self.doubledHex(green))/\(Self.doubledHex(blue))"
    }

    private static func doubledHex(_ value: UInt8) -> String {
      let text = String(value, radix: 16)
      let pair = text.count == 1 ? "0" + text : text
      return pair + pair
    }
  }

  private var entries: [RGB]
  private var defaultForeground: RGB
  private var defaultBackground: RGB

  init() {
    entries = Self.defaultEntries()
    defaultForeground = Self.initialForeground
    defaultBackground = Self.initialBackground
  }

  var snapshotPalette: [[Int]] { entries.map(\.snapshotValue) }
  var snapshotDefaultForeground: [Int] { defaultForeground.snapshotValue }
  var snapshotDefaultBackground: [Int] { defaultBackground.snapshotValue }

  mutating func reset() {
    entries = Self.defaultEntries()
    defaultForeground = Self.initialForeground
    defaultBackground = Self.initialBackground
  }

  /// Applies the OSC color commands implemented by the compatibility core.
  /// Query replies are returned in wire order for the caller to enqueue.
  @discardableResult
  mutating func applyOSC(command: String, value: String) -> [String] {
    switch command {
    case "4":
      let fields = value.split(separator: ";", omittingEmptySubsequences: false)
      var replies: [String] = []
      var index = 0
      while index + 1 < fields.count {
        guard let slot = Self.paletteIndex(fields[index]) else {
          index += 2
          continue
        }
        let requested = fields[index + 1]
        if requested == "?" {
          replies.append("\u{1b}]4;\(slot);\(entries[slot].oscValue)\u{1b}\\")
        } else if let color = Self.parseColor(requested) {
          entries[slot] = color
        }
        index += 2
      }
      return replies

    case "10", "11":
      if value == "?" {
        let color = command == "10" ? defaultForeground : defaultBackground
        return ["\u{1b}]\(command);\(color.oscValue)\u{1b}\\"]
      }
      guard let color = Self.parseColor(value) else { return [] }
      if command == "10" { defaultForeground = color }
      else { defaultBackground = color }
      return []

    case "104":
      let defaults = Self.defaultEntries()
      if value.isEmpty {
        entries = defaults
      } else {
        for field in value.split(separator: ";") {
          if let slot = Self.paletteIndex(field) { entries[slot] = defaults[slot] }
        }
      }
      return []

    default:
      return []
    }
  }

  private static let initialForeground = RGB(red: 230, green: 230, blue: 230)
  private static let initialBackground = RGB(red: 10, green: 10, blue: 11)

  private static func defaultEntries() -> [RGB] {
    var palette = [
      RGB(red: 27, green: 28, blue: 31), RGB(red: 239, green: 68, blue: 68),
      RGB(red: 34, green: 197, blue: 94), RGB(red: 250, green: 204, blue: 21),
      RGB(red: 96, green: 165, blue: 250), RGB(red: 192, green: 132, blue: 252),
      RGB(red: 34, green: 211, blue: 238), RGB(red: 212, green: 212, blue: 216),
      RGB(red: 107, green: 111, blue: 118), RGB(red: 248, green: 113, blue: 113),
      RGB(red: 74, green: 222, blue: 128), RGB(red: 253, green: 224, blue: 71),
      RGB(red: 147, green: 197, blue: 253), RGB(red: 216, green: 180, blue: 254),
      RGB(red: 103, green: 232, blue: 249), RGB(red: 250, green: 250, blue: 250),
    ]
    for red: UInt8 in [0, 95, 135, 175, 215, 255] {
      for green: UInt8 in [0, 95, 135, 175, 215, 255] {
        for blue: UInt8 in [0, 95, 135, 175, 215, 255] {
          palette.append(RGB(red: red, green: green, blue: blue))
        }
      }
    }
    for index in 0..<24 {
      let value = UInt8(8 + index * 10)
      palette.append(RGB(red: value, green: value, blue: value))
    }
    return palette
  }

  private static func paletteIndex(_ text: Substring) -> Int? {
    let bytes = text.utf8
    let digits = bytes.first == 0x2b ? bytes.dropFirst() : bytes[bytes.startIndex...]
    guard !digits.isEmpty else { return nil }
    var index = 0
    for byte in digits {
      guard byte >= 48 && byte <= 57 else { return nil }
      index = index * 10 + Int(byte - 48)
      guard index < 256 else { return nil }
    }
    return index
  }

  private static func parseColor(_ text: some StringProtocol) -> RGB? {
    let bytes = Array(text.utf8)
    if bytes.first == 0x23 {
      guard bytes.count == 7,
            let red = byte(hexHigh: bytes[1], low: bytes[2]),
            let green = byte(hexHigh: bytes[3], low: bytes[4]),
            let blue = byte(hexHigh: bytes[5], low: bytes[6])
      else { return nil }
      return RGB(red: red, green: green, blue: blue)
    }
    guard bytes.starts(with: [0x72, 0x67, 0x62, 0x3a]) else { return nil }
    let components = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    var values: [UInt8] = []
    values.reserveCapacity(3)
    for component in components {
      let componentBytes = component.utf8
      guard !componentBytes.isEmpty, componentBytes.count <= 4,
            let value = hex(componentBytes)
      else { return nil }
      let maximum = (UInt32(1) << (componentBytes.count * 4)) - 1
      values.append(UInt8(value * 255 / maximum))
    }
    return RGB(red: values[0], green: values[1], blue: values[2])
  }

  private static func byte(hexHigh: UInt8, low: UInt8) -> UInt8? {
    guard let value = hex([hexHigh, low]), value <= UInt32(UInt8.max) else { return nil }
    return UInt8(value)
  }

  private static func hex<S: Collection>(_ bytes: S) -> UInt32? where S.Element == UInt8 {
    let digits = bytes.first == 0x2b ? bytes.dropFirst() : bytes[bytes.startIndex...]
    guard !digits.isEmpty else { return nil }
    var value: UInt32 = 0
    for byte in digits {
      guard let digit = nibble(byte) else { return nil }
      value = value << 4 | UInt32(digit)
    }
    return value
  }

  private static func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: return byte - 48
    case 65...70: return byte - 65 + 10
    case 97...102: return byte - 97 + 10
    default: return nil
    }
  }
}

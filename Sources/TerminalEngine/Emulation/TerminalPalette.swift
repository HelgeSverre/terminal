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
    init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
    init(_ rgb: UInt32) { red = UInt8((rgb >> 16) & 255); green = UInt8((rgb >> 8) & 255); blue = UInt8(rgb & 255) }

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
  /// What a reset returns to: the host's scheme.
  private var scheme = TerminalColorScheme.standard

  init() {
    entries = Self.entries(for: scheme)
    defaultForeground = RGB(scheme.foreground)
    defaultBackground = RGB(scheme.background)
  }

  /// Makes `value` the colors to start from. A color the program has set
  /// for itself is kept; the others change now.
  mutating func setScheme(_ value: TerminalColorScheme) {
    let old = Self.entries(for: scheme), new = Self.entries(for: value)
    for slot in 0..<16 where entries[slot] == old[slot] { entries[slot] = new[slot] }
    if defaultForeground == RGB(scheme.foreground) { defaultForeground = RGB(value.foreground) }
    if defaultBackground == RGB(scheme.background) { defaultBackground = RGB(value.background) }
    scheme = value
  }

  var snapshotPalette: [[Int]] { entries.map(\.snapshotValue) }
  var snapshotDefaultForeground: [Int] { defaultForeground.snapshotValue }
  var snapshotDefaultBackground: [Int] { defaultBackground.snapshotValue }

  mutating func reset() {
    entries = Self.entries(for: scheme)
    defaultForeground = RGB(scheme.foreground)
    defaultBackground = RGB(scheme.background)
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
      let defaults = Self.entries(for: scheme)
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

  /// The 256 colors: the scheme's sixteen, the color cube and the grays.
  private static func entries(for scheme: TerminalColorScheme) -> [RGB] {
    let sixteen = scheme.ansi.count == 16 ? scheme.ansi : TerminalColorScheme.standardANSI
    var palette = sixteen.map { RGB($0) }
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

/// Mutable terminal color state and the OSC palette grammar.
///
/// This deliberately owns wire details (including query reply spelling) so
/// the terminal state machine only has to route OSC code/value pairs and
/// publish snapshots. Resets return to the current host scheme.
struct TerminalPalette {
  private struct RGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
    init(_ rgb: UInt32) { red = UInt8((rgb >> 16) & 255); green = UInt8((rgb >> 8) & 255); blue = UInt8(rgb & 255) }

    var snapshotValue: [Int] { [Int(red), Int(green), Int(blue)] }
    var packed: UInt32 { UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue) }

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
  private var cursor: RGB
  private var overriddenEntries = Set<Int>()
  private var foregroundOverridden = false
  private var backgroundOverridden = false
  private var cursorOverridden = false
  private var special: [RGB?] = Array(repeating: nil, count: 5)
  private var specialEnabled = Array(repeating: false, count: 6)
  /// What a reset returns to: the host's scheme.
  private var scheme = TerminalColorScheme.standard

  init() {
    entries = Self.entries(for: scheme)
    defaultForeground = RGB(scheme.foreground)
    defaultBackground = RGB(scheme.background)
    cursor = RGB(scheme.cursor)
  }

  /// Makes `value` the colors to start from. A color the program has set
  /// for itself is kept; the others change now.
  mutating func setScheme(_ value: TerminalColorScheme) {
    let new = Self.entries(for: value)
    for slot in 0..<16 where !overriddenEntries.contains(slot) { entries[slot] = new[slot] }
    if !foregroundOverridden { defaultForeground = RGB(value.foreground) }
    if !backgroundOverridden { defaultBackground = RGB(value.background) }
    if !cursorOverridden { cursor = RGB(value.cursor) }
    scheme = value
  }

  var hostScheme: TerminalColorScheme { scheme }
  // Report the user's configured scheme, not an OSC color chosen by a child.
  var schemeIsDark: Bool {
    let color = RGB(scheme.background)
    return Int(color.red) * 299 + Int(color.green) * 587 + Int(color.blue) * 114 < 128_000
  }
  var cursorRGB: UInt32 { cursor.packed }

  /// xterm attribute colors are opt-in (OSC 6/106). They affect retained
  /// output at presentation time, rather than replacing the stored SGR pen.
  func presentationStyle(_ original: TerminalStyle) -> TerminalStyle {
    guard specialEnabled.contains(true) else { return original }
    var style = original
    let active = [style.flags & 1 != 0, style.underlineKind != 0,
                  style.flags & 128 != 0, style.flags & 8 != 0, style.flags & 4 != 0]
    // xterm's colorUL changes the characters' foreground, independently of
    // SGR 58's line color. Color modes replace the selected attribute's visual
    // effect. Foreground precedence is blink, bold, underline, then italic.
    if original.foreground == 0 || specialEnabled[5],
       let slot = [2, 0, 1, 4].first(where: { active[$0] && specialEnabled[$0] }) {
      style.foreground = 0x0200_0000 | (special[slot] ?? RGB(scheme.foreground)).packed
      switch slot {
      case 0: style.flags &= ~UInt16(1)
      case 1: style.underlineKind = 0
      case 2: style.flags &= ~UInt16(128)
      case 4: style.flags &= ~UInt16(4)
      default: break
      }
    }
    if active[3] && specialEnabled[3], original.background == 0 || specialEnabled[5] {
      // Reverse swaps this background into the displayed foreground.
      style.background = 0x0200_0000 | (special[3] ?? RGB(scheme.foreground)).packed
    }
    return style
  }

  var snapshotPalette: [[Int]] { entries.map(\.snapshotValue) }
  var snapshotDefaultForeground: [Int] { defaultForeground.snapshotValue }
  var snapshotDefaultBackground: [Int] { defaultBackground.snapshotValue }
  /// Kitty's indexed formats reserve the last eight slots for presentation
  /// colors rather than the end of the SGR grayscale ramp.
  var snapshotGraphicsPalette: [[Int]] {
    var colors = snapshotPalette
    colors[248] = snapshotDefaultBackground
    colors[249] = snapshotDefaultForeground
    colors[250] = RGB(scheme.selectionBackground).snapshotValue
    colors[251] = RGB(scheme.selectionForeground).snapshotValue
    colors[252] = RGB(cursorRGB).snapshotValue
    colors[253] = snapshotDefaultBackground
    colors[254] = snapshotDefaultForeground
    colors[255] = snapshotDefaultForeground
    return colors
  }

  mutating func reset() {
    entries = Self.entries(for: scheme)
    defaultForeground = RGB(scheme.foreground)
    defaultBackground = RGB(scheme.background)
    cursor = RGB(scheme.cursor)
    overriddenEntries.removeAll(keepingCapacity: true)
    foregroundOverridden = false; backgroundOverridden = false; cursorOverridden = false
    special = Array(repeating: nil, count: 5)
    specialEnabled = Array(repeating: false, count: 6)
  }

  /// Applies the OSC color commands implemented by the compatibility core.
  /// Query replies are returned in wire order for the caller to enqueue.
  @discardableResult
  mutating func applyOSC(command: String, value: String) -> [String] {
    switch command {
    case "4", "5":
      let fields = value.split(separator: ";", omittingEmptySubsequences: false)
      var replies: [String] = []
      var index = 0
      while index + 1 < fields.count {
        guard let requestedSlot = Self.paletteIndex(fields[index], maximum: 260) else {
          index += 2
          continue
        }
        let slot = command == "5" ? requestedSlot + 256 : requestedSlot
        guard slot < 261 else { index += 2; continue }
        let requested = fields[index + 1]
        if requested == "?" {
          let color = slot < 256 ? entries[slot] : (special[slot - 256] ?? RGB(scheme.foreground))
          replies.append("\u{1b}]\(command);\(requestedSlot);\(color.oscValue)\u{1b}\\")
        } else if let color = Self.parseColor(requested) {
          if slot < 256 { entries[slot] = color; overriddenEntries.insert(slot) }
          else { special[slot - 256] = color }
        }
        index += 2
      }
      return replies

    case "6", "106":
      let fields = value.split(separator: ";", omittingEmptySubsequences: false)
      for index in stride(from: 0, to: max(0, fields.count - 1), by: 2) {
        if let slot = Self.paletteIndex(fields[index], maximum: 5), let enabled = Int(fields[index + 1]) {
          specialEnabled[slot] = enabled != 0
        }
      }
      return []

    case "10", "11", "12":
      var replies: [String] = []
      let first = Int(command)!
      for (offset, requested) in value.split(separator: ";", omittingEmptySubsequences: false).enumerated() {
        let slot = first + offset
        guard slot <= 12 else { break }
        if requested == "?" {
          let color = slot == 10 ? defaultForeground : (slot == 11 ? defaultBackground : cursor)
          replies.append("\u{1b}]\(slot);\(color.oscValue)\u{1b}\\")
        } else if let color = Self.parseColor(requested) {
          if slot == 10 { defaultForeground = color; foregroundOverridden = true }
          else if slot == 11 { defaultBackground = color; backgroundOverridden = true }
          else { cursor = color; cursorOverridden = true }
        }
      }
      return replies

    case "110": defaultForeground = RGB(scheme.foreground); foregroundOverridden = false; return []
    case "111": defaultBackground = RGB(scheme.background); backgroundOverridden = false; return []
    case "112": cursor = RGB(scheme.cursor); cursorOverridden = false; return []
    case "105":
      if value.isEmpty { special = Array(repeating: nil, count: 5) }
      else {
        for field in value.split(separator: ";") {
          if let slot = Self.paletteIndex(field, maximum: 4) { special[slot] = nil }
        }
      }
      return []

    case "104":
      let defaults = Self.entries(for: scheme)
      if value.isEmpty {
        entries = defaults
        overriddenEntries.removeAll(keepingCapacity: true)
      } else {
        for field in value.split(separator: ";") {
          if let slot = Self.paletteIndex(field) { entries[slot] = defaults[slot]; overriddenEntries.remove(slot) }
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

  private static func paletteIndex(_ text: Substring, maximum: Int = 255) -> Int? {
    let bytes = text.utf8
    let digits = bytes.first == 0x2b ? bytes.dropFirst() : bytes[bytes.startIndex...]
    guard !digits.isEmpty else { return nil }
    var index = 0
    for byte in digits {
      guard byte >= 48 && byte <= 57 else { return nil }
      index = index * 10 + Int(byte - 48)
      guard index <= maximum else { return nil }
    }
    return index
  }

  private static let namedColors: [String: UInt32] = ["black": 0x000000, "white": 0xffffff, "red": 0xff0000,
    "green": 0x00ff00, "blue": 0x0000ff, "yellow": 0xffff00, "magenta": 0xff00ff, "cyan": 0x00ffff,
    "gray": 0xbebebe, "grey": 0xbebebe]
  private static func parseColor(_ text: some StringProtocol) -> RGB? {
    let bytes = Array(text.utf8)
    if bytes.first == 0x23 {
      // XParseColor's #RGB/#RRGGBB/#RRRGGGBBB/#RRRRGGGGBBBB:
      // components occupy the most significant bits of a 16-bit channel.
      let count = bytes.count - 1
      guard [3, 6, 9, 12].contains(count) else { return nil }
      let width = count / 3
      var components: [UInt8] = []
      for index in 0..<3 {
        guard let value = hex(bytes[(1 + index * width)..<(1 + (index + 1) * width)]) else { return nil }
        let channel = value << (16 - width * 4)
        components.append(UInt8(channel >> 8))
      }
      return RGB(red: components[0], green: components[1], blue: components[2])
    }
    guard bytes.starts(with: [0x72, 0x67, 0x62, 0x3a]) else {
      return Self.namedColors[String(text).lowercased()].map { RGB($0) }
    }
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

extension TerminalPalette {
  /// The OSC commands that set what a program has overridden, for a
  /// terminal that takes this one's place.
  var handoffCommands: [[String]] {
    var commands = overriddenEntries.sorted().map { ["4", "\($0);\(entries[$0].oscValue)"] }
    if foregroundOverridden { commands.append(["10", defaultForeground.oscValue]) }
    if backgroundOverridden { commands.append(["11", defaultBackground.oscValue]) }
    if cursorOverridden { commands.append(["12", cursor.oscValue]) }
    return commands
  }
}

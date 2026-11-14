import Foundation

/// The one place that turns an AppKit key event into bytes for a PTY.  Callers
/// supply semantic key/mode data; they do not decide between legacy and Kitty
/// encodings, filter a paste, or special-case keypad values themselves.
enum TerminalInputEncoder {
  struct Modes: Equatable {
    var applicationCursor = false
    var applicationKeypad = false
    var newline = false
    var bracketedPaste = false
    var focusReporting = false
    /// Kitty progressive-enhancement flags (CSI > 1 u): disambiguate,
    /// report events, alternate keys, associated text, respectively.
    var kittyFlags: UInt32 = 0
  }

  struct Modifiers: Equatable {
    var shift = false
    var option = false
    var control = false
    var command = false
    var capsLock = false
    var numLock = false

    init(shift: Bool = false, option: Bool = false, control: Bool = false, command: Bool = false,
         capsLock: Bool = false, numLock: Bool = false) {
      self.shift = shift
      self.option = option
      self.control = control
      self.command = command
      self.capsLock = capsLock
      self.numLock = numLock
    }

    fileprivate var kitty: UInt32 {
      var value: UInt32 = 1
      if shift { value += 1 }; if option { value += 2 }; if control { value += 4 }
      if command { value += 8 }; if capsLock { value += 64 }; if numLock { value += 128 }
      return value
    }
    fileprivate var legacyKitty: UInt32 {
      var value: UInt32 = 1
      if shift { value += 1 }; if option { value += 2 }; if control { value += 4 }
      if command { value += 8 }
      return value
    }
  }

  struct KeyMetadata: Equatable {
    var shifted: Character?
    var baseLayout: Character?
    var associatedText: String?
    var legacyText: String?
    init(shifted: Character? = nil, baseLayout: Character? = nil,
         associatedText: String? = nil, legacyText: String? = nil) {
      self.shifted = shifted
      self.baseLayout = baseLayout
      self.associatedText = associatedText
      self.legacyText = legacyText
    }
  }

  enum Event: Equatable { case press, repeatKey, release }

  enum KeypadKey: Int, CaseIterable, Equatable {
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
    case decimal, divide, multiply, subtract, add, enter, equal, separator

    fileprivate var symbol: Character {
      Array("0123456789./*-+\r=,")[rawValue]
    }
    fileprivate var application: Character {
      Array("pqrstuvwxynojmkMXl")[rawValue]
    }
    fileprivate var kitty: UInt32 { 57_399 + UInt32(rawValue) }
  }

  enum Key: Equatable {
    case up, down, right, left, home, end, pageUp, pageDown, insert, delete
    case backspace, tab, enter, escape
    case function(Int)
    case character(Character)
    case keypad(KeypadKey, nativeText: Character?)
    case modifier(UInt32)
  }

  /// Empty output means a negotiated release is intentionally suppressed.
  static func key(_ key: Key, modifiers: Modifiers = .init(), event: Event = .press,
                  modes: Modes, metadata suppliedMetadata: KeyMetadata? = nil) -> Data {
    // Convenience callers supply a semantic key; explicit metadata callers
    // can independently report that no committed text accompanied that key.
    let metadata: KeyMetadata
    if let suppliedMetadata { metadata = suppliedMetadata }
    else {
      let associated: String?
      let shifted: Character?
      switch key {
      case .character(let value):
        associated = String(value)
        shifted = modifiers.shift ? value : nil
      case .keypad(let keypad, let native) where keypad != .enter:
        associated = String(keypadSymbol(keypad, native))
        shifted = nil
      default: associated = nil; shifted = nil
      }
      metadata = KeyMetadata(shifted: shifted, associatedText: associated)
    }
    let flags = modes.kittyFlags
    // Physical modifier presses are meaningful only in Kitty's full keyboard
    // reporting mode.  The report-events flag alone must never leak CSI=u
    // sequences for Option/Control/Command transitions.
    if case .modifier = key, flags & 8 == 0 { return Data() }
    if event == .release && flags & 2 == 0 { return Data() }
    let protectedLegacy: Bool
    switch key { case .enter, .tab, .backspace: protectedLegacy = true; default: protectedLegacy = false }
    let textKey: Bool
    switch key {
    case .character: textKey = true
    case .keypad(let keypad, _): textKey = keypad != .enter && !modes.applicationKeypad
    default: textKey = false
    }
    let plainText = textKey && !modifiers.control && !modifiers.option && !modifiers.command
    if event == .release && ((plainText && flags & 8 == 0) || (protectedLegacy && flags & 8 == 0)) {
      return Data()
    }
    // Disambiguate keeps legacy bytes for Enter, Tab and Backspace only
    // when no modifier is held, so `reset` still works after a crash. With
    // Shift they are reported (Shift-Enter is `CSI 13 ; 2 u`), as in kitty
    // and Ghostty; Claude Code and editors rely on that for a newline.
    let enhanced = flags & 8 != 0
      || (!protectedLegacy && flags & 2 != 0 && !plainText)
      || (flags & 1 != 0 && (modifiers.control || modifiers.option || isEscapeOrKeypad(key)
        || (protectedLegacy && modifiers.shift)))
      || modifiers.command
    if enhanced { return kitty(key, modifiers: modifiers, event: event, flags: flags, metadata: metadata) }
    if event == .release { return Data() }
    if case .keypad(let keypad, let native) = key {
      if modes.applicationKeypad {
        var output = Data([27, 79, ascii(keypad.application)])
        if modifiers.option { output.insert(27, at: 0) }
        return output
      }
      return self.key(keypad == .enter ? .enter : .character(keypadSymbol(keypad, native)), modifiers: modifiers, modes: modes, metadata: metadata)
    }
    let modifier = modifiers.legacyKitty
    let cursorPrefix = modes.applicationCursor ? "\u{1b}O" : "\u{1b}["
    if let final = arrowFinal(key) {
      return Data((modifier == 1 ? "\(cursorPrefix)\(final)" : "\u{1b}[1;\(modifier)\(final)").utf8)
    }
    if let number = tildeNumber(key) {
      return Data((modifier == 1 ? "\u{1b}[\(number)~" : "\u{1b}[\(number);\(modifier)~").utf8)
    }
    var output: Data
    switch key {
    case .function(let value) where (1...4).contains(value):
      let final = Character(UnicodeScalar(UInt8(ascii: "P") + UInt8(value - 1)))
      output = Data((modifier == 1 ? "\u{1b}O\(final)" : "\u{1b}[1;\(modifier)\(final)").utf8)
    case .backspace: output = Data([127])
    case .enter: output = modes.newline ? Data([13, 10]) : Data([13])
    case .tab: output = Data((modifiers.shift ? "\u{1b}[Z" : "\t").utf8)
    case .escape: output = Data([27])
    case .character(let character):
      if modifiers.control, let scalar = singleScalar(character), scalar.isASCII,
        (scalar.properties.isAlphabetic || scalar == "@" || scalar == "[" || scalar == "\\" || scalar == "]" || scalar == "^" || scalar == "_" || scalar == " " || scalar == "?")
      {
        output = Data([scalar == "?" ? 127 : UInt8(scalar.properties.uppercaseMapping.unicodeScalars.first?.value ?? scalar.value) & 31])
      } else {
        // Ordinary typing uses committed text; Option-as-Escape uses text
        // with Option removed. Other chords retain the logical character.
        let candidate: String?
        if !modifiers.control && !modifiers.option && !modifiers.command {
          candidate = metadata.associatedText
        } else if modifiers.option && !modifiers.control {
          candidate = metadata.legacyText
        } else {
          candidate = nil
        }
        let committed = candidate.flatMap { text in
          text.unicodeScalars.contains { $0.properties.generalCategory == .control } ? nil : text
        }
        output = Data((committed ?? String(character)).utf8)
      }
    default: output = Data()
    }
    if modifiers.option { output.insert(27, at: 0) }
    return output
  }

  static func paste(_ text: String, modes: Modes) -> Data? {
    guard text.utf8.count <= 1_048_576 else { return nil }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let clean = String(normalized.unicodeScalars.filter {
      $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\r" || $0 == "\t"
    }.map(Character.init))
      .replacingOccurrences(of: "\n", with: "\r")
    return Data((modes.bracketedPaste ? "\u{1b}[200~\(clean)\u{1b}[201~" : clean).utf8)
  }

  static func focus(_ focused: Bool, modes: Modes) -> Data {
    guard modes.focusReporting else { return Data() }
    return Data((focused ? "\u{1b}[I" : "\u{1b}[O").utf8)
  }

  private static func kitty(_ key: Key, modifiers: Modifiers, event: Event, flags: UInt32,
                            metadata: KeyMetadata) -> Data {
    let eventSuffix: String
    if flags & 2 == 0 { eventSuffix = "" }
    else { eventSuffix = event == .press ? ":1" : event == .repeatKey ? ":2" : ":3" }
    let modifier = modifiers.kitty
    if let (number, final) = kittyFunctional(key) {
      return Data("\u{1b}[\(number);\(modifier)\(eventSuffix)\(final)".utf8)
    }
    let code: UInt32
    switch key {
    case .character(let value):
      code = normalizedCode(value)
    case .modifier(let value): code = value
    case .enter: code = 13
    case .tab: code = 9
    case .backspace: code = 127
    case .escape: code = 27
    case .keypad(let keypad, _): code = keypad.kitty
    default: return Data()
    }
    let alternate: String
    if flags & 4 != 0, case .character = key {
      let shifted = metadata.shifted.flatMap(singleScalar).flatMap {
        modifiers.shift && $0.value != code ? $0.value : nil
      }
      let base = metadata.baseLayout.flatMap(singleScalar).map(\.value)
      switch (shifted, base) {
      case (.some(let shifted), .some(let base)): alternate = ":\(shifted):\(base)"
      case (.some(let shifted), nil): alternate = ":\(shifted)"
      case (nil, .some(let base)): alternate = "::\(base)"
      case (nil, nil): alternate = ""
      }
    } else { alternate = "" }
    let associated: String
    if flags & 16 != 0, event != .release, !modifiers.control, !modifiers.command,
       let associatedText = metadata.associatedText,
       let codepoints = associatedCodepoints(associatedText) {
      associated = ";\(codepoints)"
    } else { associated = "" }
    return Data("\u{1b}[\(code)\(alternate);\(modifier)\(eventSuffix)\(associated)u".utf8)
  }

  private static func isEscapeOrKeypad(_ key: Key) -> Bool {
    if case .escape = key { return true }
    if case .keypad = key { return true }
    return false
  }
  private static func keypadSymbol(_ key: KeypadKey, _ native: Character?) -> Character {
    guard let native, let scalar = singleScalar(native), scalar.properties.generalCategory != .control else { return key.symbol }
    return native
  }
  private static func singleScalar(_ value: Character) -> Unicode.Scalar? {
    value.unicodeScalars.count == 1 ? value.unicodeScalars.first : nil
  }
  /// Kitty associated text is a colon-delimited scalar list.  It is emitted
  /// only for printable committed text: controls in IME metadata are not
  /// terminal input and must not become protocol metadata.
  private static func associatedCodepoints(_ text: String) -> String? {
    guard !text.isEmpty,
      text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
    else { return nil }
    return text.unicodeScalars.map { String($0.value) }.joined(separator: ":")
  }
  private static func normalizedCode(_ value: Character) -> UInt32 {
    guard let scalar = singleScalar(value) else { return 0 }
    if scalar.isASCII, scalar.properties.isAlphabetic { return UInt32(scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? scalar.value) }
    return scalar.value
  }
  private static func arrowFinal(_ key: Key) -> Character? {
    switch key { case .up: return "A"; case .down: return "B"; case .right: return "C"; case .left: return "D"; case .home: return "H"; case .end: return "F"; default: return nil }
  }
  private static func tildeNumber(_ key: Key) -> Int? {
    switch key { case .insert: return 2; case .delete: return 3; case .pageUp: return 5; case .pageDown: return 6; case .function(let value): return [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24][value]; default: return nil }
  }
  private static func kittyFunctional(_ key: Key) -> (UInt32, Character)? {
    switch key {
    case .up: return (1, "A"); case .down: return (1, "B"); case .right: return (1, "C"); case .left: return (1, "D")
    case .home: return (1, "H"); case .end: return (1, "F"); case .insert: return (2, "~"); case .delete: return (3, "~")
    case .pageUp: return (5, "~"); case .pageDown: return (6, "~")
    case .function(let value):
      switch value { case 1: return (1, "P"); case 2: return (1, "Q"); case 3: return (13, "~"); case 4: return (1, "S"); case 5: return (15, "~"); case 6: return (17, "~"); case 7: return (18, "~"); case 8: return (19, "~"); case 9: return (20, "~"); case 10: return (21, "~"); case 11: return (23, "~"); case 12: return (24, "~"); default: return (57_363 + UInt32(value), "u") }
    default: return nil
    }
  }
  private static func ascii(_ value: Character) -> UInt8 { UInt8(value.unicodeScalars.first?.value ?? 0) }
}

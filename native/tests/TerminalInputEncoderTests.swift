import Foundation

@main enum TerminalInputEncoderTests {
  typealias Encoder = TerminalInputEncoder
  static func bytes(_ text: String) -> Data { Data(text.utf8) }
  static func main() {
    var modes = Encoder.Modes()
    precondition(Encoder.key(.up, modes: modes) == bytes("\u{1b}[A"))
    modes.applicationCursor = true
    precondition(Encoder.key(.up, modes: modes) == bytes("\u{1b}OA"))
    precondition(Encoder.key(.left, modifiers: .init(option: true), modes: modes) == bytes("\u{1b}[1;3D"))
    precondition(Encoder.key(.tab, modifiers: .init(shift: true), modes: modes) == bytes("\u{1b}[Z"))
    precondition(Encoder.key(.character("c"), modifiers: .init(control: true), modes: modes) == Data([3]))
    precondition(Encoder.key(.character("x"), modifiers: .init(option: true), modes: modes) == bytes("\u{1b}x"))
    legacyTextSelection()

    modes.applicationKeypad = true
    precondition(Encoder.key(.keypad(.digit1, nativeText: nil), modes: modes) == bytes("\u{1b}Oq"))
    precondition(Encoder.key(.keypad(.enter, nativeText: nil), modifiers: .init(option: true), modes: modes) == bytes("\u{1b}\u{1b}OM"))
    modes.applicationKeypad = false
    // Numeric-pad decimal keys use the committed localized character, not the
    // physical US layout symbol supplied by the key identifier.
    precondition(Encoder.key(.keypad(.decimal, nativeText: ","), modes: modes) == bytes(","))

    modes = Encoder.Modes(bracketedPaste: true)
    precondition(Encoder.paste("a\r\nb\u{1b}c\td", modes: modes) == bytes("\u{1b}[200~a\rbc\td\u{1b}[201~"))
    precondition(Encoder.paste(String(repeating: "x", count: 1_048_577), modes: modes) == nil)
    precondition(Encoder.focus(true, modes: modes).isEmpty)
    modes.focusReporting = true
    precondition(Encoder.focus(false, modes: modes) == bytes("\u{1b}[O"))

    // Kitty report-events: ordinary release is suppressed unless the mode asks
    // for it; functional repeat is encoded with the press/repeat/release tag.
    modes = Encoder.Modes(kittyFlags: 2)
    precondition(Encoder.key(.up, event: .repeatKey, modes: modes) == bytes("\u{1b}[1;1:2A"))
    precondition(Encoder.key(.character("x"), event: .release, modes: modes).isEmpty)
    modes.kittyFlags = 10
    precondition(Encoder.key(.character("x"), event: .release, modes: modes) == bytes("\u{1b}[120;1:3u"))
    modes.kittyFlags = 12
    precondition(Encoder.key(.character("A"), modifiers: .init(shift: true), modes: modes)
      == bytes("\u{1b}[97:65;2u"))
    precondition(Encoder.key(.character("A"), modifiers: .init(shift: true), modes: modes,
      metadata: Encoder.KeyMetadata()) == bytes("\u{1b}[97;2u"))
    precondition(Encoder.key(.character("a"), modes: modes, metadata: .init(shifted: "A"))
      == bytes("\u{1b}[97;1u"))
    precondition(Encoder.key(.character("a"), modifiers: .init(shift: true), modes: modes,
      metadata: .init(shifted: "a", baseLayout: "q")) == bytes("\u{1b}[97::113;2u"))
    modes.kittyFlags = 24
    precondition(Encoder.key(.character("X"), modes: modes) == bytes("\u{1b}[120;1;88u"))
    precondition(Encoder.key(.character("X"), modes: modes, metadata: Encoder.KeyMetadata())
      == bytes("\u{1b}[120;1u"))
    precondition(Encoder.key(.character("X"), modes: modes, metadata: .init(associatedText: ""))
      == bytes("\u{1b}[120;1u"))
    let multiScalar = Encoder.KeyMetadata(associatedText: "👨‍💻")
    precondition(Encoder.key(.character("x"), modes: modes, metadata: multiScalar)
      == bytes("\u{1b}[120;1;128104:8205:128187u"))
    let controlMetadata = Encoder.KeyMetadata(associatedText: "x\u{1b}y")
    precondition(Encoder.key(.character("x"), modes: modes, metadata: controlMetadata)
      == bytes("\u{1b}[120;1u"))
    modes.kittyFlags = 2
    precondition(Encoder.key(.modifier(57_442), modes: modes).isEmpty)
    modes.kittyFlags = 10
    precondition(Encoder.key(.modifier(57_442), modes: modes) == bytes("\u{1b}[57442;1:1u"))
    print("PASS Swift input encoder: legacy, application keypad, paste/focus, Kitty events")
  }

  static func legacyTextSelection() {
    let modes = Encoder.Modes()
    func check(_ logical: Character, _ associated: String?, _ legacy: String?,
               _ modifiers: Encoder.Modifiers = .init(), _ expected: String,
               file: StaticString = #fileID, line: UInt = #line) {
      let actual = Encoder.key(.character(logical), modifiers: modifiers, modes: modes,
        metadata: .init(associatedText: associated, legacyText: legacy))
      guard actual == bytes(expected) else {
        FileHandle.standardError.write(Data("FAIL text selection at \(file):\(line): expected \(Array(expected.utf8)), got \(Array(actual))\n".utf8))
        Foundation.exit(1)
      }
    }
    check(".", ",", ".", .init(), ",")
    check("a", "A", "a", .init(shift: true), "A")
    check("a", nil, "legacy", .init(), "a")
    // Typed metadata distinguishes present-empty from absent; the public C ABI
    // normalizes its empty strings to absent before reaching this encoder.
    check("a", "", "legacy", .init(), "")
    check("a", "👨‍💻", "legacy", .init(), "👨‍💻")
    check("a", "\u{200d}\u{200e}", "legacy", .init(), "\u{200d}\u{200e}")
    for control in ["\u{0}", "\u{1b}", "\u{7f}", "\u{85}"] {
      check("a", "x\(control)y", "legacy", .init(), "a")
      check("a", "committed", "x\(control)y", .init(option: true), "\u{1b}a")
    }
    check("a", "æ", "A", .init(option: true), "\u{1b}A")
    check("a", "æ", nil, .init(option: true), "\u{1b}a")
    check("a", "æ", "", .init(option: true), "\u{1b}")
    check("a", "æ", "👨‍💻", .init(option: true), "\u{1b}👨‍💻")
    check("c", "ç", "legacy", .init(control: true), "\u{3}")
    check("c", "ç", "legacy", .init(option: true, control: true), "\u{1b}\u{3}")
    check("1", "committed", "legacy", .init(control: true), "1")
    check("å", "committed", "legacy", .init(option: true, control: true), "\u{1b}å")
    precondition(Encoder.key(.keypad(.decimal, nativeText: ","), modes: modes,
      metadata: .init(associatedText: ",", legacyText: ".")) == bytes(","))
  }
}

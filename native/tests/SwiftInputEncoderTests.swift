import Foundation

@main enum SwiftInputEncoderTests {
  typealias Encoder = SwiftInputEncoder
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

    modes.applicationKeypad = true
    precondition(Encoder.key(.keypad(.digit1, nativeText: nil), modes: modes) == bytes("\u{1b}Oq"))
    precondition(Encoder.key(.keypad(.enter, nativeText: nil), modifiers: .init(option: true), modes: modes) == bytes("\u{1b}\u{1b}OM"))

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
    modes.kittyFlags = 24
    precondition(Encoder.key(.character("X"), modes: modes) == bytes("\u{1b}[120;1;88u"))
    print("PASS Swift input encoder: legacy, application keypad, paste/focus, Kitty events")
  }
}

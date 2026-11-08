import Foundation
import AppKit

private final class Capture { var data = Data() }
@main struct KeyMapTests {
  static func main() {
    let core = terminal_create(80, 24)!
    defer { terminal_destroy(core) }
    func encode(_ physical: UInt16, _ text: String = "", release: Bool = false) -> Data {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
        isARepeat: false, keyCode: physical)!
      guard case .encoded(let mapped) = NativeKeyMap.route(event) else {
        fatalError("physical key must route to the terminal")
      }
      let capture = Capture()
      let primary = (300...317).contains(mapped.key) ? mapped.text : mapped.logical
      let accepted = terminal_input_with_metadata(
        core, primary, mapped.key, mapped.modifiers, release ? 2 : 0,
        mapped.text, mapped.legacyText,
        mapped.shifted.unicodeScalars.count == 1 ? mapped.shifted.unicodeScalars.first!.value : 0,
        mapped.baseLayout.unicodeScalars.count == 1 ? mapped.baseLayout.unicodeScalars.first!.value : 0,
        Unmanaged.passUnretained(capture).toOpaque(),
        { context, bytes, count in
          guard let context, let bytes else { return }
          Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(
            bytes, count: count)
        })
      precondition(accepted)
      return capture.data
    }
    func feed(_ text: String) {
      let bytes = Array(text.utf8)
      let used = bytes.withUnsafeBufferPointer { terminal_feed(core, $0.baseAddress, $0.count, 0) }
      precondition(used == bytes.count)
    }
    for (code, expected) in [
      (82, "0"), (83, "1"), (84, "2"), (85, "3"), (86, "4"), (87, "5"), (88, "6"),
      (89, "7"), (91, "8"), (92, "9"), (65, ","), (75, "/"), (67, "*"), (78, "-"),
      (69, "+"), (81, "="), (95, ","), (76, "\r"), (36, "\r"),
    ] {
      let actual = encode(UInt16(code), expected)
      guard actual == Data(expected.utf8) else {
        FileHandle.standardError.write(
          Data("keypad code \(code): expected \(Array(expected.utf8)), got \(Array(actual))\n".utf8))
        Foundation.exit(1)
      }
    }
    let localizedKeypad = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ".",
      isARepeat: false, keyCode: 65)!
    guard case .encoded(let localized) = NativeKeyMap.route(localizedKeypad) else {
      fatalError("localized keypad must route to terminal")
    }
    let localizedCapture = Capture()
    precondition(terminal_input_with_metadata(
      core, localized.text, localized.key, localized.modifiers, 0,
      localized.text, localized.legacyText,
      localized.shifted.unicodeScalars.count == 1 ? localized.shifted.unicodeScalars.first!.value : 0,
      localized.baseLayout.unicodeScalars.count == 1 ? localized.baseLayout.unicodeScalars.first!.value : 0,
      Unmanaged.passUnretained(localizedCapture).toOpaque(), { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    precondition(localizedCapture.data == Data(",".utf8))
    feed("\u{1b}=")
    precondition(encode(76) == Data("\u{1b}OM".utf8))
    precondition(encode(36) == Data([13]))
    precondition(encode(82) == Data("\u{1b}Op".utf8))
    precondition(encode(76, release: true).isEmpty)
    feed("\u{1b}[>3u")
    precondition(encode(76) == Data("\u{1b}[57414;1:1u".utf8))
    precondition(encode(76, release: true) == Data("\u{1b}[57414;1:3u".utf8))
    // SwiftCore's metadata ABI differs from main's typed physical-key ABI,
    // but must retain primary, shifted, base-layout, associated, and legacy
    // facts through its adapter.
    feed("\u{1b}[=31u")
    let shiftedPunctuation = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
      windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "!",
      isARepeat: false, keyCode: 18)!
    let punctuation = NativeKeyMap.textEvent(
      shiftedPunctuation, text: "!", modifiers: NativeKeyMap.modifiers(shiftedPunctuation.modifierFlags))
    precondition(punctuation.logical == "1" && punctuation.shifted == "!" && punctuation.baseLayout == "1")
    let alternateCapture = Capture()
    precondition(terminal_input_with_metadata(
      core, punctuation.logical, punctuation.key, punctuation.modifiers, 0,
      punctuation.text, punctuation.legacyText,
      punctuation.shifted.unicodeScalars.first!.value, punctuation.baseLayout.unicodeScalars.first!.value,
      Unmanaged.passUnretained(alternateCapture).toOpaque(), { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    precondition(alternateCapture.data == Data("\u{1b}[49:33:49;2:1;33u".utf8))
    let modifierDown = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: .control, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 59)!
    guard let control = NativeKeyMap.modifierEvent(modifierDown), !control.release else {
      fatalError("missing left-Control press")
    }
    precondition(control.event.key == 401 && control.event.modifiers == 4)
    var modifierState = NativeKeyMap.ModifierState()
    precondition(modifierState.resolve(control)?.release == false)
    let rightControl = NativeKeyMap.KeyEvent(
      key: 407, logical: "", text: "", shifted: "", baseLayout: "", legacyText: "", modifiers: 4)
    precondition(modifierState.resolve((rightControl, false))?.release == false)
    precondition(modifierState.releaseAll(modifiers: 4).map(\.key) == [401, 407])
    for (physical, flags, expected): (UInt16, NSEvent.ModifierFlags, String) in [
      (123, .command, "\u{01}"), (124, .command, "\u{05}"), (51, .command, "\u{15}"),
      (123, .option, "\u{1b}b"), (124, .option, "\u{1b}f"),
    ] {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: physical)!
      guard case .shortcut(let text) = NativeKeyMap.route(event) else { fatalError("missing shortcut") }
      precondition(text == expected)
    }
    print(
      "PASS native key map: all numeric-pad keys, localized decimal, Return distinction, application mode, enhanced release"
    )
  }
}

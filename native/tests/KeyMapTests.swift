import Foundation
import AppKit

private final class Capture { var data = Data() }
@main struct KeyMapTests {
  static func main() {
    let core = terminal_create(80, 24)!
    defer { terminal_destroy(core) }
    func encode(
      _ physical: UInt16, _ text: String = "", flags: NSEvent.ModifierFlags = [],
      release: Bool = false
    ) -> Data {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
        isARepeat: false, keyCode: physical)!
      guard case .encoded(let mapped) = NativeKeyMap.route(event) else {
        fatalError("physical key must route to the terminal")
      }
      let capture = Capture()
      let accepted = terminal_input_key(
        core, mapped.text, mapped.logical, mapped.shifted, mapped.baseLayout, mapped.legacyText,
        mapped.key, mapped.modifiers, release ? 2 : 0,
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
      precondition(encode(UInt16(code), expected) == Data(expected.utf8))
    }
    feed("\u{1b}=")
    precondition(encode(76) == Data("\u{1b}OM".utf8))
    precondition(encode(36) == Data([13]))
    precondition(encode(82) == Data("\u{1b}Op".utf8))
    feed("\u{1b}[?1h")
    precondition(encode(115) == Data("\u{1b}OH".utf8))
    precondition(encode(119) == Data("\u{1b}OF".utf8))
    feed("\u{1b}[?1l")
    precondition(encode(76, release: true).isEmpty)
    feed("\u{1b}[>3u")
    precondition(encode(76) == Data("\u{1b}[57414;1:1u".utf8))
    precondition(encode(76, release: true) == Data("\u{1b}[57414;1:3u".utf8))
    feed("\u{1b}[=31u")
    let shiftedPunctuation = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
      windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "!",
      isARepeat: false, keyCode: 18)!
    guard case .inputMethod = NativeKeyMap.route(shiftedPunctuation) else {
      fatalError("ordinary shifted text must remain an input-method event")
    }
    let mappedPunctuation = NativeKeyMap.textEvent(
      shiftedPunctuation, text: "!", modifiers: NativeKeyMap.modifiers(shiftedPunctuation.modifierFlags))
    let unshifted = shiftedPunctuation.characters(byApplyingModifiers: [])!
    let shifted = shiftedPunctuation.characters(byApplyingModifiers: .shift)!
    precondition(mappedPunctuation.logical == unshifted)
    precondition(mappedPunctuation.shifted == shifted)
    precondition(mappedPunctuation.logical != mappedPunctuation.shifted)
    precondition(mappedPunctuation.baseLayout == "1")
    precondition(mappedPunctuation.modifiers & 1 == 1)
    let alternateCapture = Capture()
    precondition(terminal_input_key(
      core, "!", "1", "!", "1", "!", mappedPunctuation.key, mappedPunctuation.modifiers, 0,
      Unmanaged.passUnretained(alternateCapture).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    precondition(alternateCapture.data == Data("\u{1b}[49:33:49;2:1;33u".utf8))
    let modifierDown = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: .control, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 59)!
    guard let controlDown = NativeKeyMap.modifierEvent(modifierDown), !controlDown.release else {
      fatalError("missing left-Control press")
    }
    precondition(controlDown.event.key == 401 && controlDown.event.modifiers == 4)
    let modifierUp = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 59)!
    guard let controlUp = NativeKeyMap.modifierEvent(modifierUp), controlUp.release else {
      fatalError("missing left-Control release")
    }
    precondition(controlUp.event.key == 401 && controlUp.event.modifiers == 0)
    let capsLock = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: .capsLock, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 57)!
    guard let capsLockDown = NativeKeyMap.modifierEvent(capsLock), !capsLockDown.release else {
      fatalError("missing Caps Lock press")
    }
    precondition(capsLockDown.event.key == 412 && capsLockDown.event.modifiers == 64)
    let capsNonASCII = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .capsLock, timestamp: 0,
      windowNumber: 0, context: nil, characters: "Å", charactersIgnoringModifiers: "Å",
      isARepeat: false, keyCode: 39)!
    let mappedCaps = NativeKeyMap.textEvent(
      capsNonASCII, text: "Å", modifiers: NativeKeyMap.modifiers(capsNonASCII.modifierFlags))
    precondition(mappedCaps.logical == capsNonASCII.characters(byApplyingModifiers: [])!)
    precondition(mappedCaps.baseLayout == "'")
    precondition(mappedCaps.modifiers == 64)
    let modifierCapture = Capture()
    precondition(terminal_input_key(
      core, "", "", "", "", "", controlDown.event.key, controlDown.event.modifiers, 0,
      Unmanaged.passUnretained(modifierCapture).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    precondition(modifierCapture.data == Data("\u{1b}[57442;5:1u".utf8))
    let counterpartRelease = Capture()
    precondition(terminal_input_key(
      core, "", "", "", "", "", controlDown.event.key, controlDown.event.modifiers, 2,
      Unmanaged.passUnretained(counterpartRelease).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    precondition(counterpartRelease.data == Data("\u{1b}[57442;5:3u".utf8))
    var modifierState = NativeKeyMap.ModifierState()
    let leftDown = modifierState.resolve(controlDown)!
    precondition(!leftDown.release)
    let rightDown = modifierState.resolve((
      NativeKeyMap.KeyEvent(
        key: 407, logical: "", text: "", shifted: "", baseLayout: "", legacyText: "", modifiers: 4),
      false))!
    precondition(!rightDown.release)
    let leftRelease = modifierState.resolve((controlDown.event, false))!
    precondition(leftRelease.release)
    let focusReleases = modifierState.releaseAll(modifiers: 4)
    precondition(focusReleases.count == 1 && focusReleases[0].key == 407)
    precondition(focusReleases[0].modifiers == 0)
    var focusState = NativeKeyMap.ModifierState()
    focusState.beginFocus(modifiers: 4)
    precondition(focusState.resolve(controlDown) == nil)
    precondition(focusState.resolve(controlUp) == nil)
    precondition(focusState.resolve(controlDown)?.release == false)
    feed("\u{1b}[=0u")
    func physical(
      _ text: String, logical: String, shifted: String = "", base: String = "", legacy: String = "",
      modifiers: UInt32
    ) -> Data {
      let capture = Capture()
      precondition(terminal_input_key(
        core, text, logical, shifted, base, legacy, 200, modifiers, 0,
        Unmanaged.passUnretained(capture).toOpaque(),
        { context, bytes, count in
          guard let context, let bytes else { return }
          Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
        }))
      return capture.data
    }
    precondition(physical("A", logical: "a", shifted: "A", base: "a", modifiers: 1) == Data("A".utf8))
    precondition(physical("!", logical: "1", shifted: "!", base: "1", modifiers: 1) == Data("!".utf8))
    precondition(physical("æ", logical: "a", modifiers: 0) == Data("æ".utf8))
    precondition(physical("Å", logical: "å", modifiers: 64) == Data("Å".utf8))
    precondition(physical("ç", logical: "c", modifiers: 4) == Data([3]))
    precondition(physical("æ", logical: "a", modifiers: 2) == Data("\u{1b}a".utf8))
    precondition(physical("¡", logical: "1", shifted: "!", base: "1", legacy: "!", modifiers: 3)
      == Data("\u{1b}!".utf8))
    precondition(physical("å", logical: "a", shifted: "A", base: "a", legacy: "A", modifiers: 3)
      == Data("\u{1b}A".utf8))
    precondition(physical("ø", logical: "å", legacy: "Å", modifiers: 66) == Data("\u{1b}Å".utf8))
    precondition(physical("!", logical: "1", shifted: "!", base: "1", modifiers: 9)
      == Data("\u{1b}[49;10u".utf8))
    let commandShiftPunctuation = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
      windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "!",
      isARepeat: false, keyCode: 18)!
    guard case .encoded = NativeKeyMap.route(commandShiftPunctuation) else {
      fatalError("Command-Shift punctuation must retain physical-key metadata")
    }
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
      "PASS native key map: keypad/application wire, alternate layout facts, modifiers, and enhanced release"
    )
  }
}

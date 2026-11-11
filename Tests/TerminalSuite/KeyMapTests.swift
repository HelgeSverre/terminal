import Foundation
import AppKit
import Testing
@testable import TerminalApp

private final class Capture { var data = Data() }
@Suite struct KeyMapTests {
  /// Keypad and application-mode wire output, alternate-layout facts,
  /// modifier keys and enhanced release events. The terminal core carries mode
  /// state from one block to the next, so this is one test.
  @Test static func nativeKeyMap() {
    var context = "startup"
    func scalar(_ text: String) -> UInt32 {
      text.unicodeScalars.count == 1 ? text.unicodeScalars.first!.value : 0
    }
    func hex(_ data: Data) -> String {
      data.map { String(format: "%02x", $0) }.joined()
    }
    func unmodifiedText(_ event: NSEvent, committed: String) -> String {
      event.charactersIgnoringModifiers.flatMap { $0.isEmpty ? nil : $0 } ?? committed
    }
    // Every check carries the current synthetic key and its mapped/wire facts
    // in `context`, so a failure names the key that produced it.
    func check(
      _ condition: @autoclosure () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) {
      #expect(condition(), Comment(rawValue: context), sourceLocation: sourceLocation)
    }
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
        Issue.record("physical key must route to the terminal"); return Data()
      }
      let capture = Capture()
      let accepted = terminal_input_with_metadata(
        core, (300...317).contains(mapped.key) ? mapped.text : mapped.logical,
        mapped.key, mapped.modifiers, release ? 2 : 0, mapped.text, mapped.legacyText,
        scalar(mapped.shifted), scalar(mapped.baseLayout),
        Unmanaged.passUnretained(capture).toOpaque(),
        { context, bytes, count in
          guard let context, let bytes else { return }
          Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(
            bytes, count: count)
        })
      context =
        "encode keyCode=\(physical) text=\(text.debugDescription) flags=\(flags.rawValue) "
        + "mapped(key=\(mapped.key), logical=\(mapped.logical.debugDescription), "
        + "shifted=\(mapped.shifted.debugDescription), base=\(mapped.baseLayout.debugDescription), "
        + "legacy=\(mapped.legacyText.debugDescription), modifiers=\(mapped.modifiers)) "
        + "accepted=\(accepted) wire=\(hex(capture.data))"
      check(accepted)
      return capture.data
    }
    func feed(_ text: String) {
      let bytes = Array(text.utf8)
      let used = bytes.withUnsafeBufferPointer { terminal_feed(core, $0.baseAddress, $0.count, 0) }
      context = "feed bytes=\(bytes.count) used=\(used)"
      check(used == bytes.count)
    }
    for (code, expected) in [
      (82, "0"), (83, "1"), (84, "2"), (85, "3"), (86, "4"), (87, "5"), (88, "6"),
      (89, "7"), (91, "8"), (92, "9"), (65, ","), (75, "/"), (67, "*"), (78, "-"),
      (69, "+"), (81, "="), (95, ","), (76, "\r"), (36, "\r"),
    ] {
      context = "keypad legacy keyCode=\(code) expected=\(expected.debugDescription)"
      check(encode(UInt16(code), expected) == Data(expected.utf8))
    }
    let localizedKeypad = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ".",
      isARepeat: false, keyCode: 65)!
    guard case .encoded(let localized) = NativeKeyMap.route(localizedKeypad) else {
      Issue.record("localized keypad must route to terminal"); return
    }
    let localizedCapture = Capture()
    check(terminal_input_with_metadata(
      core, localized.text, localized.key, localized.modifiers, 0,
      localized.text, localized.legacyText,
      localized.shifted.unicodeScalars.count == 1 ? localized.shifted.unicodeScalars.first!.value : 0,
      localized.baseLayout.unicodeScalars.count == 1 ? localized.baseLayout.unicodeScalars.first!.value : 0,
      Unmanaged.passUnretained(localizedCapture).toOpaque(), { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    check(localizedCapture.data == Data(",".utf8))
    let separatorEvent = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",",
      isARepeat: false, keyCode: 95)!
    guard case .encoded(let separator) = NativeKeyMap.route(separatorEvent) else {
      Issue.record("keypad separator must route to the terminal"); return
    }
    context = "keypad separator logical=\(separator.logical.debugDescription) legacy=\(separator.legacyText.debugDescription)"
    check(separator.key == 317 && separator.text == ",")
    check(separator.logical == "," && separator.legacyText == ",")
    // The keypad's current-layout symbol is protocol metadata; numeric-mode
    // legacy input must use the text AppKit committed for this press instead.
    let committedKeypadComma = Capture()
    check(terminal_input_with_metadata(
      core, ",", 310, 0, 0, ",", ".", 0, 0,
      Unmanaged.passUnretained(committedKeypadComma).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    context = "numeric keypad comma committed=\(",".debugDescription) logical=\(".".debugDescription) wire=\(hex(committedKeypadComma.data))"
    check(committedKeypadComma.data == Data(",".utf8))
    feed("\u{1b}=")
    check(encode(76) == Data("\u{1b}OM".utf8))
    check(encode(36) == Data([13]))
    check(encode(82) == Data("\u{1b}Op".utf8))
    feed("\u{1b}[?1h")
    check(encode(115) == Data("\u{1b}OH".utf8))
    check(encode(119) == Data("\u{1b}OF".utf8))
    feed("\u{1b}[?1l")
    check(encode(76, release: true).isEmpty)
    feed("\u{1b}[>3u")
    check(encode(76) == Data("\u{1b}[57414;1:1u".utf8))
    check(encode(76, release: true) == Data("\u{1b}[57414;1:3u".utf8))
    feed("\u{1b}[=31u")
    let shiftedPunctuation = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
      windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "!",
      isARepeat: false, keyCode: 18)!
    guard case .inputMethod = NativeKeyMap.route(shiftedPunctuation) else {
      Issue.record("ordinary shifted text must remain an input-method event"); return
    }
    let mappedPunctuation = NativeKeyMap.textEvent(
      shiftedPunctuation, text: "!", modifiers: NativeKeyMap.modifiers(shiftedPunctuation.modifierFlags))
    let unshifted = shiftedPunctuation.characters(byApplyingModifiers: [])
    let shifted = shiftedPunctuation.characters(byApplyingModifiers: .shift)
    let punctuationFallback = unmodifiedText(shiftedPunctuation, committed: "!")
    context =
      "shifted punctuation input=\(shiftedPunctuation.characters.debugDescription) "
      + "unshifted=\(String(describing: unshifted)) shifted=\(String(describing: shifted)) "
      + "fallback=\(punctuationFallback.debugDescription) "
      + "mapped(logical=\(mappedPunctuation.logical.debugDescription), "
      + "shifted=\(mappedPunctuation.shifted.debugDescription), base=\(mappedPunctuation.baseLayout.debugDescription), "
      + "mods=\(mappedPunctuation.modifiers))"
    if let unshifted, !unshifted.isEmpty { check(mappedPunctuation.logical == unshifted) }
    else { check(mappedPunctuation.logical == punctuationFallback) }
    if let shifted, !shifted.isEmpty { check(mappedPunctuation.shifted == shifted) }
    else { check(mappedPunctuation.shifted == punctuationFallback) }
    check(mappedPunctuation.baseLayout == "1")
    check(mappedPunctuation.modifiers & 1 == 1)
    let alternateCapture = Capture()
    check(terminal_input_with_metadata(
      core, "1", mappedPunctuation.key, mappedPunctuation.modifiers, 0, "!", "!", 33, 49,
      Unmanaged.passUnretained(alternateCapture).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    check(alternateCapture.data == Data("\u{1b}[49:33:49;2:1;33u".utf8))
    let modifierDown = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: .control, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 59)!
    guard let controlDown = NativeKeyMap.modifierEvent(modifierDown), !controlDown.release else {
      Issue.record("missing left-Control press"); return
    }
    check(controlDown.event.key == 401 && controlDown.event.modifiers == 4)
    let modifierUp = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 59)!
    guard let controlUp = NativeKeyMap.modifierEvent(modifierUp), controlUp.release else {
      Issue.record("missing left-Control release"); return
    }
    check(controlUp.event.key == 401 && controlUp.event.modifiers == 0)
    let capsLock = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: .capsLock, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 57)!
    guard let capsLockDown = NativeKeyMap.modifierEvent(capsLock), !capsLockDown.release else {
      Issue.record("missing Caps Lock press"); return
    }
    check(capsLockDown.event.key == 412 && capsLockDown.event.modifiers == 64)
    let capsNonASCII = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .capsLock, timestamp: 0,
      windowNumber: 0, context: nil, characters: "Å", charactersIgnoringModifiers: "Å",
      isARepeat: false, keyCode: 39)!
    let mappedCaps = NativeKeyMap.textEvent(
      capsNonASCII, text: "Å", modifiers: NativeKeyMap.modifiers(capsNonASCII.modifierFlags))
    let capsLogical = capsNonASCII.characters(byApplyingModifiers: [])
    let capsFallback = unmodifiedText(capsNonASCII, committed: "Å")
    context =
      "caps non-ASCII input=\(capsNonASCII.characters.debugDescription) "
      + "translated=\(String(describing: capsLogical)) fallback=\(capsFallback.debugDescription) "
      + "logical=\(mappedCaps.logical.debugDescription) "
      + "base=\(mappedCaps.baseLayout.debugDescription) "
      + "modifiers=\(mappedCaps.modifiers)"
    if let capsLogical, !capsLogical.isEmpty { check(mappedCaps.logical == capsLogical) }
    else { check(mappedCaps.logical == capsFallback) }
    check(mappedCaps.baseLayout == "'")
    check(mappedCaps.modifiers == 64)
    let modifierCapture = Capture()
    check(terminal_input_with_metadata(
      core, "", controlDown.event.key, controlDown.event.modifiers, 0, nil, nil, 0, 0,
      Unmanaged.passUnretained(modifierCapture).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    check(modifierCapture.data == Data("\u{1b}[57442;5:1u".utf8))
    let counterpartRelease = Capture()
    check(terminal_input_with_metadata(
      core, "", controlDown.event.key, controlDown.event.modifiers, 2, nil, nil, 0, 0,
      Unmanaged.passUnretained(counterpartRelease).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    check(counterpartRelease.data == Data("\u{1b}[57442;5:3u".utf8))
    var modifierState = NativeKeyMap.ModifierState()
    let leftDown = modifierState.resolve(controlDown)!
    check(!leftDown.release)
    let rightDown = modifierState.resolve((
      NativeKeyMap.KeyEvent(
        key: 407, logical: "", text: "", shifted: "", baseLayout: "", legacyText: "", modifiers: 4),
      false))!
    check(!rightDown.release)
    let leftRelease = modifierState.resolve((controlDown.event, false))!
    check(leftRelease.release)
    let focusReleases = modifierState.releaseAll(modifiers: 4)
    check(focusReleases.count == 1 && focusReleases[0].key == 407)
    check(focusReleases[0].modifiers == 0)
    var focusState = NativeKeyMap.ModifierState()
    focusState.beginFocus(modifiers: 4)
    check(focusState.resolve(controlDown) == nil)
    check(focusState.resolve(controlUp) == nil)
    check(focusState.resolve(controlDown)?.release == false)
    feed("\u{1b}[=0u")
    func physical(
      _ text: String, logical: String, shifted: String = "", base: String = "", legacy: String? = nil,
      modifiers: UInt32
    ) -> Data {
      let capture = Capture()
      func send(_ legacyPointer: UnsafePointer<CChar>?) {
        check(terminal_input_with_metadata(
          core, logical, 200, modifiers, 0, text, legacyPointer, scalar(shifted), scalar(base),
          Unmanaged.passUnretained(capture).toOpaque(),
          { context, bytes, count in
            guard let context, let bytes else { return }
            Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
          }))
      }
      if let legacy { legacy.withCString { send($0) } } else { send(nil) }
      context =
        "physical text=\(text.debugDescription) logical=\(logical.debugDescription) "
        + "shifted=\(shifted.debugDescription) base=\(base.debugDescription) "
        + "legacy=\(legacy.debugDescription) modifiers=\(modifiers) wire=\(hex(capture.data))"
      return capture.data
    }
    context = "committed text overrides legacy layout text"
    // Empty C strings mean absent metadata in the public ABI, matching the
    // archived Rust adapter; a typed encoder can still represent present-empty.
    check(physical("", logical: "a", legacy: "legacy", modifiers: 0) == Data("a".utf8))
    check(physical("æ", logical: "a", legacy: "", modifiers: 2) == Data("\u{1b}a".utf8))
    check(physical("", logical: "e\u{301}", modifiers: 0) == Data("e".utf8))
    check(physical("", logical: "👨‍💻", modifiers: 0) == Data("👨".utf8))
    check(physical(",", logical: ".", legacy: ".", modifiers: 0) == Data(",".utf8))
    check(physical("A", logical: "a", legacy: "a", modifiers: 1) == Data("A".utf8))
    check(physical("x\u{1b}y", logical: "a", legacy: "legacy", modifiers: 0) == Data("a".utf8))
    check(physical("👨‍💻", logical: "a", legacy: "legacy", modifiers: 0) == Data("👨‍💻".utf8))
    check(physical("committed", logical: "1", legacy: "legacy", modifiers: 4) == Data("1".utf8))
    check(physical("æ", logical: "a", legacy: "x\u{85}y", modifiers: 2) == Data("\u{1b}a".utf8))
    context = "legacy physical shifted ASCII"
    check(physical("A", logical: "a", shifted: "A", base: "a", modifiers: 1) == Data("A".utf8))
    context = "legacy physical shifted punctuation"
    check(physical("!", logical: "1", shifted: "!", base: "1", modifiers: 1) == Data("!".utf8))
    context = "legacy physical native Option"
    check(physical("æ", logical: "a", modifiers: 0) == Data("æ".utf8))
    context = "legacy physical Caps non-ASCII"
    check(physical("Å", logical: "å", modifiers: 64) == Data("Å".utf8))
    context = "legacy physical Control"
    check(physical("ç", logical: "c", modifiers: 4) == Data([3]))
    context = "legacy physical Option-as-Escape"
    check(physical("æ", logical: "a", modifiers: 2) == Data("\u{1b}a".utf8))
    check(physical("¡", logical: "1", shifted: "!", base: "1", legacy: "!", modifiers: 3)
      == Data("\u{1b}!".utf8))
    check(physical("å", logical: "a", shifted: "A", base: "a", legacy: "A", modifiers: 3)
      == Data("\u{1b}A".utf8))
    check(physical("ø", logical: "å", legacy: "Å", modifiers: 66) == Data("\u{1b}Å".utf8))
    check(physical("!", logical: "1", shifted: "!", base: "1", modifiers: 9)
      == Data("\u{1b}[49;10u".utf8))
    func missingAssociated(_ associated: UnsafePointer<CChar>?) -> Data {
      let capture = Capture()
      check(terminal_input_with_metadata(
        core, "a", 200, 0, 0, associated, nil, 0, 0,
        Unmanaged.passUnretained(capture).toOpaque(),
        { context, bytes, count in
          guard let context, let bytes else { return }
          Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
        }))
      return capture.data
    }
    context = "nil and empty ABI metadata fall back only in legacy mode"
    check(missingAssociated(nil) == Data("a".utf8))
    check("".withCString { missingAssociated($0) } == Data("a".utf8))
    feed("\u{1b}[=24u")
    check(physical("e\u{301}", logical: "e\u{301}", modifiers: 0)
      == Data("\u{1b}[101;1;101:769u".utf8))
    check(physical("👨‍💻", logical: "👨‍💻", modifiers: 0)
      == Data("\u{1b}[128104;1;128104:8205:128187u".utf8))
    check(missingAssociated(nil) == Data("\u{1b}[97;1u".utf8))
    check("".withCString { missingAssociated($0) } == Data("\u{1b}[97;1u".utf8))
    let defaultCapture = Capture()
    check(terminal_input(
      core, "a", 200, 0, 0, Unmanaged.passUnretained(defaultCapture).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    check(defaultCapture.data == Data("\u{1b}[97;1;97u".utf8))
    feed("\u{1b}[=12u")
    let shiftedDefault = Capture()
    check(terminal_input(
      core, "A", 200, 1, 0, Unmanaged.passUnretained(shiftedDefault).toOpaque(),
      { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }))
    check(shiftedDefault.data == Data("\u{1b}[97:65;2u".utf8))
    check(physical("A", logical: "A", modifiers: 1) == Data("\u{1b}[97;2u".utf8))
    feed("\u{1b}[=0u")
    let commandShiftPunctuation = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
      windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "!",
      isARepeat: false, keyCode: 18)!
    guard case .encoded = NativeKeyMap.route(commandShiftPunctuation) else {
      Issue.record("Command-Shift punctuation must retain physical-key metadata"); return
    }
    for (physical, flags, expected): (UInt16, NSEvent.ModifierFlags, String) in [
      (123, .command, "\u{01}"), (124, .command, "\u{05}"), (51, .command, "\u{15}"),
      (123, .option, "\u{1b}b"), (124, .option, "\u{1b}f"),
    ] {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: physical)!
      guard case .shortcut(let text) = NativeKeyMap.route(event) else { Issue.record("missing shortcut"); return }
      context = "shortcut keyCode=\(physical) flags=\(flags.rawValue) expected=\(expected.debugDescription) actual=\(text.debugDescription)"
      check(text == expected)
    }
  }
}

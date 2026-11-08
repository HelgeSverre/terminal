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
      guard case .encoded(let key, _, let modifiers) = NativeKeyMap.route(event) else {
        fatalError("physical key must route to the terminal")
      }
      let capture = Capture()
      let accepted = terminal_input(
        core, text, key, modifiers, release ? 2 : 0,
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
      "PASS native key map: numeric-pad keys, Home/End/Return application wire, localized decimal, and enhanced release"
    )
  }
}

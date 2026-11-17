import Foundation
import Testing
import TerminalInterop
@testable import TerminalEngine
@testable import TerminalUI
#if os(macOS)
import AppKit
#endif

@Suite enum TerminalInputCompatibilityTests {
  typealias Encoder = TerminalInputEncoder
  private static func bytes(_ text: String) -> Data { Data(text.utf8) }
  private final class Capture { var data = Data() }
  private static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    guard let context, let bytes, count > 0 else { return }
    Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
  }
  private static func replies(_ terminal: OpaquePointer) -> Data {
    let capture = Capture()
    helge_terminal_replies(terminal, Unmanaged.passUnretained(capture).toOpaque(), collect)
    return capture.data
  }
  private static func input(_ terminal: OpaquePointer, _ text: String, key: UInt32,
                            modifiers: UInt32, event: UInt32) -> Data {
    let capture = Capture()
    #expect(text.withCString {
      helge_terminal_input(terminal, $0, key, modifiers, event,
        Unmanaged.passUnretained(capture).toOpaque(), collect)
    })
    return capture.data
  }
  private static func feed(_ terminal: OpaquePointer, _ text: String) {
    let data = bytes(text)
    let consumed = data.withUnsafeBytes {
      helge_terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress, data.count, 0)
    }
    #expect(consumed == data.count)
  }

  @Test static func modifyOtherKeysLevelsAndKittyPrecedence() {
    var modes = Encoder.Modes(modifyOtherKeys: 1)
    #expect(Encoder.key(.character("c"), modifiers: .init(control: true), modes: modes) == Data([3]))
    #expect(Encoder.key(.character("a"), modifiers: .init(shift: true), modes: modes,
      metadata: .init(shifted: "A", associatedText: "A")) == bytes("A"))
    #expect(Encoder.key(.tab, modifiers: .init(option: true), modes: modes) == bytes("\u{1b}[27;3;9~"))
    #expect(Encoder.key(.character("a"), modifiers: .init(shift: true, option: true), modes: modes,
      metadata: .init(shifted: "A")) == bytes("\u{1b}[27;3;65~"))
    modes.modifyOtherKeys = 2
    #expect(Encoder.key(.character("c"), modifiers: .init(control: true), modes: modes) == bytes("\u{1b}[27;5;99~"))
    #expect(Encoder.key(.character("1"), modifiers: .init(shift: true, control: true), modes: modes,
      metadata: .init(shifted: "!")) == bytes("\u{1b}[27;6;33~"))
    #expect(Encoder.key(.character("å"), modifiers: .init(control: true), modes: modes) == bytes("\u{1b}[27;5;229~"))
    #expect(Encoder.key(.tab, modifiers: .init(shift: true), modes: modes) == bytes("\u{1b}[27;2;9~"))
    #expect(Encoder.key(.enter, modifiers: .init(shift: true), modes: modes) == bytes("\u{1b}[27;2;13~"))
    #expect(Encoder.key(.enter, modes: modes) == Data([13]))
    #expect(Encoder.key(.escape, modes: modes) == Data([27]))
    #expect(Encoder.key(.up, modifiers: .init(control: true), modes: modes) == bytes("\u{1b}[1;5A"))
    #expect(Encoder.key(.character("c"), modifiers: .init(control: true), event: .repeatKey, modes: modes)
      == bytes("\u{1b}[27;5;99~"))
    #expect(Encoder.key(.character("c"), modifiers: .init(control: true), event: .release, modes: modes).isEmpty)
    modes.kittyFlags = 3
    #expect(Encoder.key(.character("c"), modifiers: .init(control: true), modes: modes) == bytes("\u{1b}[99;5:1u"))
    #expect(Encoder.key(.character("c"), modifiers: .init(control: true), event: .release, modes: modes)
      == bytes("\u{1b}[99;5:3u"))
    modes.kittyFlags = 4 // Even alternate-key-only Kitty negotiation owns input.
    #expect(Encoder.key(.character("c"), modifiers: .init(control: true), modes: modes) == Data([3]))
    modes.kittyFlags = 0
    modes.modifyOtherKeys = 3
    #expect(Encoder.key(.character("x"), modes: modes) == bytes("\u{1b}[27;1;120~"))
    #expect(Encoder.key(.enter, modes: modes) == bytes("\u{1b}[27;1;13~"))
  }

  @Test static func modifyOtherKeysDispatchQueryAndReset() throws {
    let terminal = helge_terminal_create(16, 2)!
    defer { helge_terminal_destroy(terminal) }
    feed(terminal, "\u{1b}[>4;2m\u{1b}[?4m")
    #expect(replies(terminal) == bytes("\u{1b}[>4;2m"))
    #expect(input(terminal, "c", key: 200, modifiers: 4, event: 0) == bytes("\u{1b}[27;5;99~"))
    // Committed IME text and paste do not become physical-key reports.
    #expect(input(terminal, "日本語", key: 0, modifiers: 0, event: 0) == bytes("日本語"))
    #expect(input(terminal, "hello", key: 1, modifiers: 0, event: 0) == bytes("hello"))
    feed(terminal, "\u{1b}[>4;99m\u{1b}[>4:1;1m\u{1b}[?2m\u{1b}[?4m")
    #expect(replies(terminal) == bytes("\u{1b}[>4;2m"))
    // Private m must never set underline/faint attributes as an SGR command.
    feed(terminal, "X")
    let snapshot = try #require(swiftTerminalSnapshot(terminal, scroll: nil, now: 0).snapshot)
    #expect(snapshot.rows[0].cells[0].style.underline == 0)
    #expect(!snapshot.rows[0].cells[0].style.faint)
    feed(terminal, "\u{1b}[>4n\u{1b}[?4m")
    #expect(replies(terminal) == bytes("\u{1b}[>4;-1m"))
    #expect(input(terminal, "c", key: 200, modifiers: 4, event: 0) == Data([3]))
    feed(terminal, "\u{1b}[>4;2m\u{1b}[>4m\u{1b}[?4m")
    #expect(replies(terminal) == bytes("\u{1b}[>4;0m"))
    for reset in ["\u{1b}[!p", "\u{1b}c"] {
      feed(terminal, "\u{1b}[>4;2m" + reset + "\u{1b}[?4m")
      #expect(replies(terminal) == bytes("\u{1b}[>4;0m"))
    }
  }

  @Test static func mouseEncodingNegotiationAndReset() throws {
    let terminal = helge_terminal_create(16, 2)!
    defer { helge_terminal_destroy(terminal) }
    for encoding in [1005, 1006, 1015, 1016] {
      feed(terminal, "\u{1b}[?1002h\u{1b}[?\(encoding)h\u{1b}[?\(encoding)$p")
      #expect(replies(terminal) == bytes("\u{1b}[?\(encoding);1$y"))
      let snapshot = try #require(swiftTerminalSnapshot(terminal, scroll: nil, now: 0).snapshot)
      #expect(snapshot.modes.mouse_encoding == encoding)
      #expect(snapshot.modes.sgr_mouse == (encoding == 1006 || encoding == 1016))
    }
    // Resetting an inactive mutually exclusive mode cannot disable the active one.
    feed(terminal, "\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?1002$p\u{1b}[?1016$p\u{1b}[?1006$p\u{1b}[?1001$p")
    #expect(replies(terminal) == bytes("\u{1b}[?1002;1$y\u{1b}[?1016;1$y\u{1b}[?1006;2$y\u{1b}[?1001;0$y"))
    for reset in ["\u{1b}[!p", "\u{1b}c"] {
      feed(terminal, "\u{1b}[?1002;1016h" + reset)
      let snapshot = try #require(swiftTerminalSnapshot(terminal, scroll: nil, now: 0).snapshot)
      #expect(snapshot.modes.mouse == 0 && snapshot.modes.mouse_encoding == 0)
    }
  }

  @Test static func mouseWireFormatsAndCoordinateBounds() {
    func encode(_ encoding: Int, column: Int = 3, row: Int = 4,
                release: Bool = false, button: Int = 0, modifiers: Int = 0) -> Data {
      TerminalMouseEncoder.encode(button: button, release: release, modifiers: modifiers,
        column: column, row: row, pixelX: 21, pixelY: 61, encoding: encoding)
    }
    #expect(encode(0) == Data([27, 91, 77, 32, 35, 36]))
    #expect(encode(0, column: 223) == Data([27, 91, 77, 32, 255, 36]))
    #expect(encode(0, column: 224).isEmpty)
    #expect(encode(1005, column: 2015) == bytes("\u{1b}[M \u{7ff}$"))
    #expect(encode(1005, column: 2016).isEmpty)
    #expect(encode(1005, button: 65, modifiers: 28) == bytes("\u{1b}[M}#$"))
    #expect(encode(1006, release: true, button: 2, modifiers: 16) == bytes("\u{1b}[<18;3;4m"))
    #expect(encode(1015, release: true, button: 2, modifiers: 16) == bytes("\u{1b}[51;3;4M"))
    #expect(encode(1015, column: 4000) == bytes("\u{1b}[32;4000;4M"))
    #expect(encode(1016, button: 32, modifiers: 8) == bytes("\u{1b}[<40;21;61M"))
    #expect(encode(1016, release: true, button: 1) == bytes("\u{1b}[<1;21;61m"))
    #expect(TerminalMouseEncoder.encode(button: 0, release: false, modifiers: 24,
      column: 1, row: 1, pixelX: 1, pixelY: 1, encoding: 0, x10: true) == bytes("\u{1b}[M !!"))
    let retina = NativeMouseCoordinates.position(CGPoint(x: 18.75, y: 39.4), scale: 2,
      inset: 16, width: 800, height: 480)
    #expect(retina.x == 22 && retina.y == 63)
    let clamped = NativeMouseCoordinates.position(CGPoint(x: -10, y: 900), scale: 2,
      inset: 16, width: 800, height: 480)
    #expect(clamped.x == 1 && clamped.y == 480)
  }

  /// Byte fixture from the 2026-11-17 kitten0.45.0/private-tmux3.7c probe.
  /// The client accepts CSI keys, but drops legacy CR/Escape/ETX. The terminal
  /// must honor the outer negotiation rather than forcing Kitty on tmux.
  @Test static func kittenHoldNegotiatedAndLegacyBytes() {
    let terminal = helge_terminal_create(80, 24)!
    defer { helge_terminal_destroy(terminal) }
    let keys: [(String, UInt32, UInt32, Data, Data)] = [
      ("", 22, 0, Data([13]), bytes("\u{1b}[13;1u")),
      ("", 23, 0, Data([27]), bytes("\u{1b}[27;1u")),
      ("c", 200, 4, Data([3]), bytes("\u{1b}[99;5u")),
    ]
    for (text, key, modifiers, legacy, _) in keys {
      #expect(input(terminal, text, key: key, modifiers: modifiers, event: 0) == legacy)
    }
    // HoldTillEnter's loop SetStateEscapeCodes requests these exact flags.
    feed(terminal, "\u{1b}[>29u")
    for (text, key, modifiers, _, negotiated) in keys {
      #expect(input(terminal, text, key: key, modifiers: modifiers, event: 0) == negotiated)
    }
    feed(terminal, "\u{1b}[<u")
    for (text, key, modifiers, legacy, _) in keys {
      #expect(input(terminal, text, key: key, modifiers: modifiers, event: 0) == legacy)
    }
  }

  #if os(macOS)
  @Test static func physicalOptionSidePolicies() {
    var configuration = TerminalViewConfiguration()
    configuration.leftOptionSendsEscape = true
    configuration.rightOptionSendsEscape = false
    let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
    let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
    #expect(NativeKeyMap.optionSendsEscape(left, configuration: configuration))
    #expect(!NativeKeyMap.optionSendsEscape(right, configuration: configuration))
    #expect(NativeKeyMap.optionSendsEscape(left.union(right), configuration: configuration))
    #expect(!NativeKeyMap.optionSendsEscape(.option, configuration: configuration))
    configuration.optionSendsEscape = true
    configuration.leftOptionSendsEscape = nil
    #expect(NativeKeyMap.optionSendsEscape(left, configuration: configuration))
    #expect(!NativeKeyMap.optionSendsEscape(right, configuration: configuration))
    #expect(NativeKeyMap.optionSendsEscape(.option, configuration: configuration))
  }
  #endif
}

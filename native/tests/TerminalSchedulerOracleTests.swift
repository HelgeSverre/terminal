import Foundation

// ABI-level scheduling and invariant checks copied from the production semantic
// contract. These deliberately never reach into SwiftTerminalCore directly.
@main enum TerminalSchedulerOracleTests {
  final class Bytes { var value = Data() }
  static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    guard let context, let bytes, count > 0 else { return }
    Unmanaged<Bytes>.fromOpaque(context).takeUnretainedValue().value.append(bytes, count: count)
  }
  static func feed(_ terminal: OpaquePointer, _ bytes: Data, now: UInt64 = 0) -> Int {
    bytes.withUnsafeBytes { terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, now) }
  }
  static func feed(_ terminal: OpaquePointer, _ text: String, now: UInt64 = 0) { _ = feed(terminal, Data(text.utf8), now: now) }
  static func snapshot(_ terminal: OpaquePointer, now: UInt64 = 0) -> [String: Any]? {
    TerminalSnapshotTestSupport.ownerSnapshot(terminal, now: now)
  }
  static func text(_ value: [String: Any]) -> String {
    (value["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }.map { $0["text"] as! String }.joined()
  }
  static func replies(_ terminal: OpaquePointer) -> Data {
    let box = Bytes(); terminal_replies(terminal, Unmanaged.passUnretained(box).toOpaque(), collect); return box.value
  }
  static func input(_ terminal: OpaquePointer, text: String = "", key: UInt32) -> Data {
    let box = Bytes()
    precondition(text.withCString {
      terminal_input(terminal, $0, key, 0, 0, Unmanaged.passUnretained(box).toOpaque(), collect)
    })
    return box.value
  }

  static func resumableREPDoesNotOvertakeSuffix() {
    let terminal = terminal_create(80, 24)!; defer { terminal_destroy(terminal) }
    let bytes = Data("X\u{1b}[10000bY".utf8)
    let consumed = feed(terminal, bytes)
    precondition(consumed < bytes.count && terminal_has_work(terminal))
    // An empty ABI turn must make bounded REP progress. Only after it drains
    // may the caller replay the unconsumed suffix containing Y.
    while terminal_has_work(terminal) {
      precondition(terminal_feed(terminal, nil, 0, 1) == 0)
      precondition(terminal_validate(terminal))
    }
    _ = bytes.withUnsafeBytes {
      terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress!.advanced(by: consumed), bytes.count - consumed, 1)
    }
    let value = snapshot(terminal)!
    precondition(text(value).contains("Y"))
    precondition(terminal_validate(terminal))
  }

  static func synchronizedOutputUsesABIClockDeadline() {
    let terminal = terminal_create(8, 2)!; defer { terminal_destroy(terminal) }
    feed(terminal, "a\u{1b}[?2026hX\u{1b}[6n", now: 0)
    precondition(snapshot(terminal, now: 0) == nil && !replies(terminal).isEmpty)
    feed(terminal, "\u{1b}[?2026hY", now: 100)
    precondition(snapshot(terminal, now: 149) == nil)
    let released = snapshot(terminal, now: 150)!
    precondition(text(released).contains("aXY") && terminal_validate(terminal))
  }

  static func keyboardFlagsAreScreenLocal() {
    let terminal = terminal_create(8, 2)!; defer { terminal_destroy(terminal) }
    feed(terminal, "\u{1b}[>3u\u{1b}[?1049h\u{1b}[>8u\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?8u".utf8))
    feed(terminal, "\u{1b}[?1049l\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?3u".utf8))
    // The active primary flag also reaches the C input path.
    precondition(input(terminal, key: 10) == Data("\u{1b}[1;1:1A".utf8))
  }

  static func protocolModesAndTabs() {
    let terminal = terminal_create(16, 2)!; defer { terminal_destroy(terminal) }
    feed(terminal, "\u{1b}[?9h\u{1b}[?1002h\u{1b}[?1006h")
    var modes = snapshot(terminal)!["modes"] as! [String: Any]
    precondition(modes["mouse"] as? Int == 1002 && modes["sgr_mouse"] as? Bool == true)
    feed(terminal, "\u{1b}[?1002l\u{1b}[?1006l")
    modes = snapshot(terminal)!["modes"] as! [String: Any]
    precondition(modes["mouse"] as? Int == 0 && modes["sgr_mouse"] as? Bool == false)

    feed(terminal, "\u{1b}[>3u\u{1b}[>8u\u{1b}[<u\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?3u".utf8))
    feed(terminal, "\u{1b}[>8u\u{1b}[<0u\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?3u".utf8))
    feed(terminal, "\u{1b}[=4;1u\u{1b}[=2;2u\u{1b}[=1;3u\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?6u".utf8))
    feed(terminal, "\u{1b}[?1049h\u{1b}[>8u\u{1b}[?u\u{1b}[?1049l\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?8u\u{1b}[?6u".utf8))
    precondition(terminal_resize(terminal, 24, 2))
    feed(terminal, "\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?6u".utf8))

    feed(terminal, "\u{1b}[>1u" + String(repeating: "\u{1b}[>2u", count: 32) + "\u{1b}[<32u\u{1b}[?u")
    precondition(replies(terminal) == Data("\u{1b}[?1u".utf8))

    feed(terminal, "\u{1b}[3g\u{1b}[1;4H\u{1b}H\u{1b}[1;1H\t")
    precondition((snapshot(terminal)!["cursor"] as! [String: Any])["col"] as? Int == 3)
    feed(terminal, "\u{1b}[0g")
    precondition(terminal_resize(terminal, 32, 2))
    feed(terminal, "\u{1b}[1;1H\t")
    precondition((snapshot(terminal)!["cursor"] as! [String: Any])["col"] as? Int == 31)

    feed(terminal, "\u{1b}[20h\u{1b}[1;5H\u{1b}D")
    precondition((snapshot(terminal)!["cursor"] as! [String: Any])["col"] as? Int == 4)
    feed(terminal, "\u{1b}[1;1HA\nB")
    modes = snapshot(terminal)!["modes"] as! [String: Any]
    precondition(modes["newline"] as? Bool == true && (snapshot(terminal)!["cursor"] as! [String: Any])["col"] as? Int == 1)
    precondition(input(terminal, key: 22) == Data([13, 10]))
    feed(terminal, "\u{1b}[20l\u{1b}[1;1HA\nB")
    precondition((snapshot(terminal)!["cursor"] as! [String: Any])["col"] as? Int == 2)

    feed(terminal, "\u{1b}[?25l\u{1b}[5 q")
    var cursor = snapshot(terminal)!["cursor"] as! [String: Any]
    precondition(cursor["visible"] as? Bool == false && cursor["shape"] as? Int == 5)
    feed(terminal, "\u{1b}[3q")
    precondition((snapshot(terminal)!["cursor"] as! [String: Any])["shape"] as? Int == 5)
    feed(terminal, "\u{1b}[?1049h")
    cursor = snapshot(terminal)!["cursor"] as! [String: Any]
    precondition(cursor["visible"] as? Bool == true && cursor["shape"] as? Int == 0)
    feed(terminal, "\u{1b}[?1049l")
    cursor = snapshot(terminal)!["cursor"] as! [String: Any]
    precondition(cursor["visible"] as? Bool == false && cursor["shape"] as? Int == 5)

    feed(terminal, "\u{1b}[?1h\u{1b}=\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?5h\u{1b}[?1003h\u{1b}[?1006h\u{1b}]8;;https://example.test/\u{1b}\\X\u{1b}cZ")
    modes = snapshot(terminal)!["modes"] as! [String: Any]
    precondition(modes["application_cursor"] as? Bool == false && modes["application_keypad"] as? Bool == false && modes["bracketed_paste"] as? Bool == false && modes["focus"] as? Bool == false && modes["newline"] as? Bool == false && modes["reverse_video"] as? Bool == false && modes["mouse"] as? Int == 0 && modes["sgr_mouse"] as? Bool == false)
    cursor = snapshot(terminal)!["cursor"] as! [String: Any]
    precondition(cursor["visible"] as? Bool == true && cursor["shape"] as? Int == 0)
    precondition(input(terminal, key: 10) == Data("\u{1b}[A".utf8))
    precondition(input(terminal, text: "1", key: 301) == Data("1".utf8))
    precondition(!text(snapshot(terminal)!).contains("X"))
    let resetCell = (snapshot(terminal)!["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }.first { $0["text"] as? String == "Z" }!
    precondition(resetCell["link"] is NSNull)

    let repeated = terminal_create(8, 2)!; defer { terminal_destroy(repeated) }
    precondition(terminal_feed(repeated, nil, 0, 0) == 0)
    let suffix = Data("X\u{1b}c\u{1b}[2bZ".utf8)
    precondition(feed(repeated, suffix) == suffix.count)
    var turns = 0
    while terminal_has_work(repeated) {
      turns += 1; precondition(turns <= 2)
      _ = terminal_feed(repeated, nil, 0, 0)
    }
    precondition(text(snapshot(repeated)!).contains("Z") && !text(snapshot(repeated)!).contains("X"))
  }

  static func replyPressurePreservesUnconsumedInput() {
    let terminal = terminal_create(8, 2)!; defer { terminal_destroy(terminal) }
    let requests = Data((String(repeating: "\u{1b}[5n", count: 10_000) + "Z").utf8)
    let accepted = feed(terminal, requests)
    precondition(accepted == 32_768)
    let suffix = Data(requests.dropFirst(accepted))
    precondition(feed(terminal, suffix) == 0)
    precondition(!text(snapshot(terminal)!).contains("Z"))
    let first = replies(terminal)
    precondition(first == Data(String(repeating: "\u{1b}[0n", count: 8192).utf8))
    precondition(feed(terminal, suffix) == suffix.count)
    precondition(replies(terminal) == Data(String(repeating: "\u{1b}[0n", count: 1808).utf8))
    precondition(text(snapshot(terminal)!).contains("Z") && terminal_validate(terminal))
  }

  static func main() {
    if CommandLine.arguments.contains("--reply-pressure") { replyPressurePreservesUnconsumedInput(); return }
    resumableREPDoesNotOvertakeSuffix(); synchronizedOutputUsesABIClockDeadline(); keyboardFlagsAreScreenLocal(); protocolModesAndTabs(); replyPressurePreservesUnconsumedInput()
    print("PASS Terminal scheduler oracle: resumable REP, FIFO suffix, reply pressure, sync deadline, screen-local keyboard, invariants")
  }
}

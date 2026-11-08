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
    guard let raw = terminal_snapshot(terminal, Int.max, now) else { return nil }
    defer { terminal_string_free(raw) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any]
  }
  static func text(_ value: [String: Any]) -> String {
    (value["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }.map { $0["text"] as! String }.joined()
  }
  static func replies(_ terminal: OpaquePointer) -> Data {
    let box = Bytes(); terminal_replies(terminal, Unmanaged.passUnretained(box).toOpaque(), collect); return box.value
  }
  static func input(_ terminal: OpaquePointer, key: UInt32) -> Data {
    let box = Bytes()
    precondition(terminal_input(terminal, "", key, 0, 0, Unmanaged.passUnretained(box).toOpaque(), collect))
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

  static func main() {
    resumableREPDoesNotOvertakeSuffix(); synchronizedOutputUsesABIClockDeadline(); keyboardFlagsAreScreenLocal()
    print("PASS Terminal scheduler oracle: resumable REP, FIFO suffix, sync deadline, screen-local keyboard, invariants")
  }
}

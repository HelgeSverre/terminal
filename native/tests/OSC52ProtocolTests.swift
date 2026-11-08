import Foundation

// Exercise the decoder through the C ABI as well as directly. These tests
// only collect core-owned requests and never touch a system pasteboard.
@main enum OSC52ProtocolTests {
  private final class Capture { var requests: [(UInt64, Data, Bool)] = []; var replies = Data() }
  private static let collect: ClipboardCallback = { context, id, bytes, count in
    guard let context, count >= 0 else { return }
    let data = bytes.map { Data(bytes: $0, count: count) } ?? Data()
    Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().requests.append((id, data, bytes != nil))
  }
  private static let collectReply: BytesCallback = { context, bytes, count in
    guard let context, let bytes, count > 0 else { return }
    Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().replies.append(bytes, count: count)
  }
  static func decode(_ text: String) -> Data? {
    let decoder = OSC52Decoder()
    for byte in text.utf8 where decoder.push(byte) == .rejected { return nil }
    if case .write(let data) = decoder.finish() { return data }; return nil
  }
  static func feed(_ terminal: OpaquePointer, _ data: Data, chunk: Int = .max) {
    var offset = 0
    while offset < data.count || terminal_has_work(terminal) {
      let count = min(chunk, data.count - offset)
      let used = data.withUnsafeBytes { terminal_feed(terminal, count == 0 ? nil : $0.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), count, 0) }
      precondition(used > 0 || terminal_has_work(terminal) || offset == data.count); offset += used
    }
  }
  static func feed(_ terminal: OpaquePointer, _ text: String, chunk: Int = .max) { feed(terminal, Data(text.utf8), chunk: chunk) }
  private static func take(_ terminal: OpaquePointer, _ capture: Capture) { terminal_take_clipboard_requests(terminal, Unmanaged.passUnretained(capture).toOpaque(), collect) }
  static func decoderStrictness() {
    precondition(decode("aGVsbG8=") == Data("hello".utf8))
    precondition(decode("AB==") == nil && decode("AAB=") == nil)
    precondition(decode("A") == nil && decode("AAAA=") == nil)
    precondition(decode("YQ==Yg==") == nil, "padding seals the stream")
    let decoder = OSC52Decoder()
    for _ in 0..<1_398_100 { precondition(decoder.push(UInt8(ascii: "A")) == .accepting) }
    for _ in 0..<4 { _ = decoder.push(UInt8(ascii: "A")) }
    precondition(decoder.push(UInt8(ascii: "A")) == .rejected)
  }
  static func coreLifecycle() {
    let terminal = terminal_create(8, 2)!; defer { terminal_destroy(terminal) }; let capture = Capture()
    feed(terminal, "\u{1b}]52;c;aGk=\u{7}")
    feed(terminal, "\u{1b}]52;c;eA==\u{1b}", chunk: 1); feed(terminal, "\\", chunk: 1)
    for ending in ["\u{18}", "\u{1a}", "\u{1b}[31m", ""] { feed(terminal, "\u{1b}]52;c;YmFk\(ending)", chunk: 1); if ending.isEmpty { terminal_finish(terminal) } }
    take(terminal, capture)
    precondition(capture.requests.map(\.1) == [Data("hi".utf8), Data("x".utf8)])
    precondition(capture.requests.map(\.0) == [1, 2])
    precondition(terminal_complete_clipboard_request(terminal, 1)); precondition(!terminal_complete_clipboard_request(terminal, 1)); precondition(terminal_complete_clipboard_request(terminal, 2))
    feed(terminal, "\u{1b}]52;c;\u{7}"); terminal_take_clipboard_requests(terminal, nil, nil); take(terminal, capture)
    guard let empty = capture.requests.last else { fatalError("empty write missing") }
    precondition(empty.1.isEmpty && empty.2, "empty callback has a non-null pointer"); precondition(terminal_complete_clipboard_request(terminal, empty.0))
    feed(terminal, "\u{1b}]52;c;?\u{1b}\\", chunk: 1); terminal_replies(terminal, Unmanaged.passUnretained(capture).toOpaque(), collectReply)
    precondition(capture.replies == Data("\u{1b}]52;c;\u{1b}\\".utf8))
    for _ in 0..<12 { feed(terminal, "\u{1b}]52;c;eA==\u{7}") }; take(terminal, capture)
    let saturated = Array(capture.requests.suffix(4)); precondition(saturated.count == 4 && saturated.allSatisfy { $0.1 == Data("x".utf8) })
    for request in saturated { precondition(terminal_complete_clipboard_request(terminal, request.0)) }
  }
  static func boundedMaximumPayload() {
    let terminal = terminal_create(8, 2)!; defer { terminal_destroy(terminal) }; let capture = Capture()
    let data = Data(repeating: 0xff, count: OSC52Decoder.maximumDecodedBytes)
    feed(terminal, Data("\u{1b}]52;c;".utf8) + data.base64EncodedData() + Data("\u{1b}\\".utf8), chunk: 257); take(terminal, capture)
    precondition(capture.requests.count == 1 && capture.requests[0].1 == data); precondition(terminal_complete_clipboard_request(terminal, capture.requests[0].0))
    let oversized = Data(repeating: 0, count: OSC52Decoder.maximumDecodedBytes + 1)
    feed(terminal, Data("\u{1b}]52;c;".utf8) + oversized.base64EncodedData() + Data("\u{7}VISIBLE".utf8), chunk: 503); take(terminal, capture)
    precondition(capture.requests.count == 1, "oversized payload leaked a request")
  }
  static func main() { decoderStrictness(); coreLifecycle(); boundedMaximumPayload(); print("PASS OSC 52: streaming parser/C ABI, strict padding, aborts, bounded payloads, queue lifecycle") }
}

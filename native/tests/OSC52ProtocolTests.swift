import Foundation

@main enum OSC52ProtocolTests {
  static func decode(_ text: String) -> Data? {
    var decoder = OSC52Decoder()
    for byte in text.utf8 where decoder.push(byte) == .rejected { return nil }
    return decoder.finish()
  }
  static func main() {
    precondition(decode("aGVsbG8=") == Data("hello".utf8))
    precondition(decode("AB==") == nil && decode("AAB=") == nil)
    precondition(decode("A") == nil && decode("AAAA=") == nil)
    var decoder = OSC52Decoder()
    for _ in 0..<1_398_100 { precondition(decoder.push(UInt8(ascii: "A")) == .accepting) }
    for _ in 0..<4 { _ = decoder.push(UInt8(ascii: "A")) }
    precondition(decoder.push(UInt8(ascii: "A")) == .rejected)
    print("PASS OSC 52 decoder: streaming quanta, strict padding, bounded input")
  }
}

import Foundation

@main enum TerminalTextTests {
  static func main() {
    func append(_ emission: TerminalText.UTF8Decoder.Emission, to output: inout [Unicode.Scalar]) {
      switch emission {
      case .none: break
      case .one(let scalar): output.append(scalar)
      case .two(let first, let second): output.append(first); output.append(second)
      }
    }
    func decode(_ bytes: [UInt8], finish: Bool = true) -> String {
      var decoder = TerminalText.UTF8Decoder()
      var output: [Unicode.Scalar] = []
      for byte in bytes { append(decoder.push(byte), to: &output) }
      if finish { append(decoder.finish(), to: &output) }
      return String(String.UnicodeScalarView(output))
    }

    precondition(TerminalText.clusters(in: "e\u{301}") == ["e\u{301}"])
    precondition(TerminalText.clusters(in: "👩\u{200d}💻") == ["👩\u{200d}💻"])
    precondition(TerminalText.clusters(in: "🇳🇴🇯🇵").count == 2)
    precondition(TerminalText.cellWidth(of: "界") == 2)
    precondition(TerminalText.cellWidth(of: "e\u{301}") == 1)
    // Supplementary private-use Nerd glyphs are printable single-width cells.
    precondition(TerminalText.cellWidth(of: "\u{f101}") == 1)

    var decoder = TerminalText.UTF8Decoder()
    var output: [Unicode.Scalar] = []
    for byte in Array("€".utf8) { append(decoder.push(byte), to: &output) }
    append(decoder.finish(), to: &output)
    precondition(String(String.UnicodeScalarView(output)) == "€")

    let malformed: [UInt8] = [0xe2, 0x28, 0xa1]
    precondition(decode(malformed) == "\u{fffd}(\u{fffd}")
    // A malformed prefix and its following printable byte share one push, so
    // this also guards the bounded two-scalar emission contract.
    precondition(decode([0xe1, 0x80, 0x41]) == "\u{fffd}A")
    precondition(decode([0xe0, 0x80]) == "\u{fffd}\u{fffd}")
    precondition(decode([0xf0, 0x9f, 0x92]) == "\u{fffd}")

    // Exercise every possible two-byte stream byte-by-byte. This keeps the
    // no-Array emission path aligned with Swift's maximal-subpart decoder.
    for first in UInt8.min...UInt8.max {
      for second in UInt8.min...UInt8.max {
        let bytes = [first, second]
        precondition(decode(bytes) == String(decoding: bytes, as: UTF8.self))
      }
    }
    // A pending viable prefix followed by one byte can either stay pending,
    // emit one scalar, or reject the prefix and emit that byte. Cover each
    // prefix length and each possible continuation/non-continuation.
    let viablePrefixes: [[UInt8]] = [
      [0xc2], [0xdf], [0xe0], [0xed], [0xf0], [0xf4],
      [0xe1, 0x80], [0xe0, 0xa0], [0xed, 0x9f],
      [0xf1, 0x80, 0x80], [0xf0, 0x90, 0x80], [0xf4, 0x8f, 0xbf],
    ]
    for prefix in viablePrefixes {
      for byte in UInt8.min...UInt8.max {
        let bytes = prefix + [byte]
        precondition(decode(bytes) == String(decoding: bytes, as: UTF8.self))
      }
    }
    precondition(TerminalText.unicode18Parity)
    print("PASS Swift Unicode smoke: clusters, widths, chunked UTF-8, malformed-prefix oracle and Unicode 18 pin")
  }
}

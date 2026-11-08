import Foundation

@main enum SwiftUnicodeTests {
  static func main() {
    precondition(SwiftUnicode.clusters(in: "e\u{301}") == ["e\u{301}"])
    precondition(SwiftUnicode.clusters(in: "👩\u{200d}💻") == ["👩\u{200d}💻"])
    precondition(SwiftUnicode.clusters(in: "🇳🇴🇯🇵").count == 2)
    precondition(SwiftUnicode.cellWidth(of: "界") == 2)
    precondition(SwiftUnicode.cellWidth(of: "e\u{301}") == 1)
    // Supplementary private-use Nerd glyphs are printable single-width cells.
    precondition(SwiftUnicode.cellWidth(of: "\u{f101}") == 1)

    var decoder = SwiftUnicode.UTF8Decoder()
    var output: [Unicode.Scalar] = []
    for byte in Array("€".utf8) { output += decoder.push(byte) }
    output += decoder.finish()
    precondition(String(String.UnicodeScalarView(output)) == "€")

    var invalid = SwiftUnicode.UTF8Decoder()
    let malformed: [UInt8] = [0xe2, 0x28, 0xa1]
    var replacements: [Unicode.Scalar] = []
    for byte in malformed { replacements += invalid.push(byte) }
    replacements += invalid.finish()
    precondition(replacements.filter { $0.value == 0xfffd }.count >= 1)
    precondition(SwiftUnicode.unicode18Parity)
    print("PASS Swift Unicode smoke: clusters, widths, chunked UTF-8 and Unicode 18 pin")
  }
}

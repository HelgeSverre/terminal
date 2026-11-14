import CryptoKit
import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

@Suite enum Unicode18CorpusTests {
  private static let root = TestEnvironment.repository

  /// Every code point, including surrogates, against an independent range lookup.
  @Test static func categoryOracle() throws {
    let url = root.appendingPathComponent("tools/unicode/grapheme-ranges-18.0.0.txt")
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "df81b11f8af22806c3d5f0fecd8ca93537e129d4b8cd7a3270dfb3fc83babec5")
    let categories: [String: Unicode18GraphemeTables.Category] = [
      "Other": .Other, "CR": .CR, "Control": .Control, "Extend": .Extend,
      "Extended_Pictographic": .Extended_Pictographic, "InCB_Consonant": .InCB_Consonant,
      "L": .L, "LF": .LF, "LV": .LV, "LVT": .LVT, "Prepend": .Prepend,
      "Regional_Indicator": .Regional_Indicator, "SpacingMark": .SpacingMark,
      "T": .T, "V": .V, "ZWJ": .ZWJ,
    ]
    let ranges = String(decoding: data, as: UTF8.self).split(separator: "\n").map {
      record -> (UInt32, UInt32, Unicode18GraphemeTables.Category) in
      let fields = record.split(separator: ";")
      return (UInt32(fields[0], radix: 16)!, UInt32(fields[1], radix: 16)!, categories[String(fields[2])]!)
    }
    var checked = 0
    for value in UInt32(0)...0x10FFFF {
      // Independent range oracle: retain the previous lookup algorithm in
      // tests, using the pinned neutral input rather than generated pages.
      var low = 0, high = ranges.count
      while low < high {
        let mid = (low + high) / 2
        if ranges[mid].1 < value { low = mid + 1 } else { high = mid }
      }
      let expected: Unicode18GraphemeTables.Category =
        low < ranges.count && ranges[low].0 <= value ? ranges[low].2 : .Other
      #expect(Unicode18GraphemeTables.category(value) == expected,
              "category mismatch at U+\(String(value, radix: 16))")
      checked += 1
    }
    #expect(Unicode18GraphemeTables.category(0x110000) == .Other)
    #expect(Unicode18GraphemeTables.category(UInt32.max) == .Other)
    #expect(checked == 0x110000)
  }

  /// Every boundary in the Unicode 18 grapheme corpus must match.
  @Test static func graphemeBreakCorpus() throws {
    let fixture = root.appendingPathComponent("tools/unicode/GraphemeBreakTest-18.0.0.txt")
    let bytes = try Data(contentsOf: fixture)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31",
      "Unicode 18 corpus checksum changed")
    let data = String(decoding: bytes, as: UTF8.self)
    var cases = 0, failures = 0
    var first: String?
    for (lineNumber, source) in data.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let line = source.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      var segmenter = TerminalText.Segmenter()
      var expected = true
      for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        if token == "÷" { expected = true; continue }
        if token == "×" { expected = false; continue }
        guard let value = UInt32(token, radix: 16), let scalar = Unicode.Scalar(value) else {
          Issue.record("bad fixture token \(token) on line \(lineNumber + 1)")
          return
        }
        if segmenter.push(scalar) != expected {
          failures += 1
          if first == nil { first = "line \(lineNumber + 1), U+\(String(value, radix: 16).uppercased())" }
        }
      }
      cases += 1
    }
    let report = "Unicode 18 corpus: \(cases) cases, \(failures) boundary failures\(first.map { "; first \($0)" } ?? "")\n"
    FileHandle.standardOutput.write(Data(report.utf8))
    #expect(failures == 0)
  }
}

import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession

/// Source-exact regressions for unicode-width 0.2.3's non-CJK string mode.
@Suite enum TerminalWidthTests {
  @Test static func sourceExactSequences() {
    let examples: [(String, Int, String)] = [
      ("", 0, "empty"), ("A", 1, "ASCII"), ("界", 2, "East Asian wide"),
      ("e\u{301}", 1, "combining mark"), ("\r\n", 1, "CRLF"), ("\n\r", 2, "reverse CRLF"),
      ("©", 1, "copyright text default"), ("©\u{FE0E}", 1, "copyright text selector"), ("©\u{FE0F}", 2, "copyright emoji selector"),
      ("™", 1, "trade-mark text default"), ("™\u{FE0E}", 1, "trade-mark text selector"), ("™\u{FE0F}", 2, "trade-mark emoji selector"),
      ("ℹ", 1, "information text default"), ("ℹ\u{FE0E}", 1, "information text selector"), ("ℹ\u{FE0F}", 2, "information emoji selector"),
      ("“\u{FE01}", 2, "VS2 quotation sequence"), ("🇳", 1, "single regional indicator"), ("🇳🇴", 2, "regional-indicator flag"), ("🇳🇴🇯", 3, "odd regional indicator"),
      ("#\u{FE0F}\u{20E3}", 2, "keycap"), ("👍🏽", 2, "emoji modifier"), ("👩\u{200D}💻", 2, "emoji ZWJ"),
      ("لا", 1, "Arabic Lam-Alef"), ("\u{2D31}\u{200D}\u{2D31}", 1, "Tifinagh ZWJ ligature"),
    ]
    for (text, expected, label) in examples {
      #expect(TerminalWidth.width(of: text) == expected, "\(label): expected \(expected), got \(TerminalWidth.width(of: text))")
    }
    for value in UInt32(0)...0x10FFFF {
      guard let scalar = Unicode.Scalar(value) else { continue }
      #expect(TerminalWidth.width(of: scalar) == TerminalWidth.width(of: String(scalar)),
              "singleton width mismatch at U+\(String(value, radix: 16))")
    }
  }
}

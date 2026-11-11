import Foundation
import Testing
@testable import TerminalApp

/// Source-exact regressions for unicode-width 0.2.3's non-CJK string mode.
/// Pass a development-only Rust oracle path as `--oracle /path` to compare
/// every Unicode scalar (surrogates excluded) byte-for-byte.
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

  /// Compares every scalar with the locked Rust oracle. `TERMINAL_WIDTH_ORACLE`
  /// holds the path of the development-only oracle executable.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMINAL_WIDTH_ORACLE"] != nil))
  static func matchesRustOracle() throws {
    try compareEveryScalar(with: ProcessInfo.processInfo.environment["TERMINAL_WIDTH_ORACLE"]!)
  }

  private static func compareEveryScalar(with executable: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let widths = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { Issue.record("Rust oracle exited \(process.terminationStatus)"); return }
    var offset = 0
    for value in UInt32(0)...0x10FFFF where !(0xD800...0xDFFF).contains(value) {
      guard offset < widths.count else { Issue.record("Rust oracle ended at U+\(String(value, radix: 16))"); return }
      let scalar = Unicode.Scalar(value)!
      let actual = TerminalWidth.width(of: String(scalar))
      #expect(actual == Int(widths[offset]), "scalar mismatch at U+\(String(value, radix: 16).uppercased()): Swift \(actual), Rust \(widths[offset])")
      offset += 1
    }
    #expect(offset == widths.count, "Rust oracle emitted unexpected trailing data")
  }
}

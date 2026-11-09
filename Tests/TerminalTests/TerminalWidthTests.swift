import Foundation

/// Source-exact regressions for unicode-width 0.2.3's non-CJK string mode.
/// Pass a development-only Rust oracle path as `--oracle /path` to compare
/// every Unicode scalar (surrogates excluded) byte-for-byte.
@main enum TerminalWidthTests {
  static func main() throws {
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
      precondition(TerminalWidth.width(of: text) == expected, "\(label): expected \(expected), got \(TerminalWidth.width(of: text))")
    }
    for value in UInt32(0)...0x10FFFF {
      guard let scalar = Unicode.Scalar(value) else { continue }
      precondition(TerminalWidth.width(of: scalar) == TerminalWidth.width(of: String(scalar)),
                   "singleton width mismatch at U+\(String(value, radix: 16))")
    }
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--oracle") {
      guard arguments.indices.contains(index + 1) else { fatalError("--oracle requires an executable path") }
      try compareEveryScalar(with: arguments[index + 1])
    }
    print("PASS terminal width: \(examples.count) source-exact sequences\(arguments.contains("--oracle") ? "; all scalars matched locked Rust oracle" : "")")
  }

  private static func compareEveryScalar(with executable: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let widths = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("Rust oracle exited \(process.terminationStatus)") }
    var offset = 0
    for value in UInt32(0)...0x10FFFF where !(0xD800...0xDFFF).contains(value) {
      guard offset < widths.count else { fatalError("Rust oracle ended at U+\(String(value, radix: 16))") }
      let scalar = Unicode.Scalar(value)!
      let actual = TerminalWidth.width(of: String(scalar))
      precondition(actual == Int(widths[offset]), "scalar mismatch at U+\(String(value, radix: 16).uppercased()): Swift \(actual), Rust \(widths[offset])")
      offset += 1
    }
    precondition(offset == widths.count, "Rust oracle emitted unexpected trailing data")
  }
}

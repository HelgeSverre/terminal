import CryptoKit
import Foundation

@main enum Unicode18CorpusTests {
  static func main() throws {
    let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
    let fixture = URL(fileURLWithPath: root).appendingPathComponent(
      "tools/unicode/GraphemeBreakTest-18.0.0.txt")
    let bytes = try Data(contentsOf: fixture)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    precondition(digest == "b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31",
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
          fatalError("bad fixture token \(token) on line \(lineNumber + 1)")
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
    // This executable reports exact parity state without turning expected work
    // into a misleading green test. It becomes a hard gate once generated
    // tables are present.
    if CommandLine.arguments.contains("--strict") { precondition(failures == 0) }
  }
}

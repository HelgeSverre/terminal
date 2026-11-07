import Foundation

@main enum SwiftUnicode18CorpusTests {
  static func main() throws {
    let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
    let fixture = URL(fileURLWithPath: root).appendingPathComponent(
      "crates/terminal-core/tests/fixtures/GraphemeBreakTest-18.0.0.txt")
    let data = try String(contentsOf: fixture, encoding: .utf8)
    var cases = 0, failures = 0
    var first: String?
    for (lineNumber, source) in data.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let line = source.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      var segmenter = SwiftUnicode.Segmenter()
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
    print("Unicode 18 corpus: \(cases) cases, \(failures) boundary failures\(first.map { "; first \($0)" } ?? "")")
    // This executable reports exact parity state without turning expected work
    // into a misleading green test. It becomes a hard gate once generated
    // tables are present.
    if SwiftUnicode18Tables.completeGeneratedRanges { precondition(failures == 0) }
  }
}

import Foundation
import CryptoKit

@main enum GenerateUnicode18 {
  static func main() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fixture = root.appendingPathComponent("crates/terminal-core/tests/fixtures/GraphemeBreakTest-18.0.0.txt")
    let vendored = root.appendingPathComponent("vendor/unicode-segmentation/src/tables.rs")
    let digest = SHA256.hash(data: try Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined()
    guard digest == SwiftUnicode18Tables.fixtureSHA256 else { fatalError("Unicode 18 fixture checksum changed: \(digest)") }
    guard FileManager.default.fileExists(atPath: vendored.path) else { fatalError("missing vendored Unicode 18 table source") }
    print("Unicode \(SwiftUnicode18Tables.unicodeVersion) fixture verified; vendored table source present.")
    print("Full Swift range emission is intentionally not generated yet; see docs/unicode18-generation.md.")
  }
}

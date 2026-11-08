import Foundation
import CryptoKit

@main enum GenerateUnicode18 {
  static func main() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fixture = root.appendingPathComponent("crates/terminal-core/tests/fixtures/GraphemeBreakTest-18.0.0.txt")
    let source = root.appendingPathComponent("vendor/unicode-segmentation/src/tables.rs")
    let output = root.appendingPathComponent("native/SwiftUnicode18Tables.swift")
    let digest = SHA256.hash(data: try Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined()
    guard digest == "b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31" else { fatalError("fixture checksum changed: \(digest)") }
    let rust = try String(contentsOf: source)
    guard let start = rust.range(of: "const grapheme_cat_table: &[(char, char, GraphemeCat)] = &[") else { fatalError("missing grapheme table") }
    let tail = rust[start.upperBound...]
    guard let end = tail.range(of: "    ];") else { fatalError("unterminated grapheme table") }
    let body = String(tail[..<end.lowerBound])
    let regex = try NSRegularExpression(pattern: #"\('\\u\{([0-9a-f]+)\}', '\\u\{([0-9a-f]+)\}', (GC_[A-Za-z_]+)\),"#)
    let ns = body as NSString
    let entries = regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { match -> String in
      let lo = ns.substring(with: match.range(at: 1)), hi = ns.substring(with: match.range(at: 2))
      let rawCategory = ns.substring(with: match.range(at: 3)).replacingOccurrences(of: "GC_", with: "")
      let category = rawCategory == "Any" ? "Other" : rawCategory
      return "    (0x\(lo), 0x\(hi), .\(category)),"
    }
    guard entries.count > 1_000 else { fatalError("incomplete parse: \(entries.count)") }
    let generated = """
    // Generated from vendor/unicode-segmentation/src/tables.rs (Unicode 18.0.0).
    // Do not edit: run `xcrun swift tools/GenerateUnicode18.swift`.
    enum SwiftUnicode18Tables {
      enum Category: UInt8 { case Other, CR, Control, Extend, Extended_Pictographic, InCB_Consonant, L, LF, LV, LVT, Prepend, Regional_Indicator, SpacingMark, T, V, ZWJ }
      static let unicodeVersion = "18.0.0"
      static let uaxRevision = 49
      static let fixtureSHA256 = "\(digest)"
      static let completeGeneratedRanges = true
      static let ranges: [(UInt32, UInt32, Category)] = [
    \(entries.joined(separator: "\n"))
      ]
      static func category(_ value: UInt32) -> Category {
        var low = 0, high = ranges.count
        while low < high { let mid = (low + high) / 2; if ranges[mid].1 < value { low = mid + 1 } else { high = mid } }
        guard ranges.indices.contains(low), ranges[low].0 <= value else { return .Other }
        return ranges[low].2
      }
      static func isIncbLinker(_ value: UInt32) -> Bool {
        switch value { case 0x094d, 0x09cd, 0x0acd, 0x0b4d, 0x0c4d, 0x0d4d, 0x1039, 0x17d2, 0x1a60, 0x1b44, 0x1bab, 0x1cf5...0x1cf6, 0xa9c0, 0xaaf6, 0x10a3f, 0x11133, 0x113d0, 0x1193e, 0x11a3a, 0x11a47, 0x11a99, 0x11f42: return true; default: return false }
      }
    }
    """
    try generated.write(to: output, atomically: true, encoding: .utf8)
    print("Generated \(entries.count) pinned Unicode 18 grapheme ranges")
  }
}

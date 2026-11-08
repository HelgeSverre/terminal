import Foundation
import CryptoKit

@main enum GenerateUnicode18 {
  static func main() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fixture = root.appendingPathComponent("tools/unicode/GraphemeBreakTest-18.0.0.txt")
    let source = root.appendingPathComponent("tools/unicode/grapheme-ranges-18.0.0.txt")
    let output = root.appendingPathComponent("native/SwiftUnicode18Tables.swift")
    let digest = SHA256.hash(data: try Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined()
    guard digest == "b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31" else { fatalError("fixture checksum changed: \(digest)") }
    let records = try Data(contentsOf: source)
    let recordsDigest = SHA256.hash(data: records).map { String(format: "%02x", $0) }.joined()
    guard recordsDigest == "df81b11f8af22806c3d5f0fecd8ca93537e129d4b8cd7a3270dfb3fc83babec5" else {
      fatalError("grapheme input checksum changed: \(recordsDigest)")
    }
    let entries = String(decoding: records, as: UTF8.self).split(separator: "\n").map { record -> String in
      let fields = record.split(separator: ";")
      guard fields.count == 3, UInt32(fields[0], radix: 16) != nil,
        UInt32(fields[1], radix: 16) != nil else { fatalError("malformed grapheme range") }
      return "    (0x\(fields[0]), 0x\(fields[1]), .\(fields[2])),"
    }
    guard entries.count == 1626 else { fatalError("incomplete grapheme ranges") }
    let generated = """
    // Generated from tools/unicode/grapheme-ranges-18.0.0.txt (Unicode 18.0.0).
    // Do not edit: regeneration commands are in tools/unicode/README.md.
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
        switch value {
        case 0x094d, 0x09cd, 0x0acd, 0x0b4d, 0x0c4d, 0x0d4d, 0x1039, 0x17d2, 0x1a60, 0x1b44,
             0x1bab, 0x1cf5...0x1cf6, 0xa9c0, 0xaaf6, 0x10a3f, 0x11133, 0x113d0, 0x1193e,
             0x11a3a, 0x11a47, 0x11a99, 0x11f42:
          return true
        default: return false
        }
      }
    }
    """
    try (generated + "\n").write(to: output, atomically: true, encoding: .utf8)
    print("Generated \(entries.count) pinned Unicode 18 grapheme ranges")
  }
}

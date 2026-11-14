import Foundation
import CryptoKit

@main enum GenerateUnicode18 {
  static func main() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fixture = root.appendingPathComponent("tools/unicode/GraphemeBreakTest-18.0.0.txt")
    let source = root.appendingPathComponent("tools/unicode/grapheme-ranges-18.0.0.txt")
    let output = root.appendingPathComponent("Sources/TerminalCore/Text/Unicode18GraphemeTables.swift")
    let digest = SHA256.hash(data: try Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined()
    guard digest == "b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31" else { fatalError("fixture checksum changed: \(digest)") }
    let records = try Data(contentsOf: source)
    let recordsDigest = SHA256.hash(data: records).map { String(format: "%02x", $0) }.joined()
    guard recordsDigest == "df81b11f8af22806c3d5f0fecd8ca93537e129d4b8cd7a3270dfb3fc83babec5" else {
      fatalError("grapheme input checksum changed: \(recordsDigest)")
    }
    let categories = ["Other", "CR", "Control", "Extend", "Extended_Pictographic", "InCB_Consonant",
                      "L", "LF", "LV", "LVT", "Prepend", "Regional_Indicator", "SpacingMark", "T", "V", "ZWJ"]
    precondition(categories.count <= 16, "grapheme categories require wider encoding")
    let categoryCodes = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, UInt8($0.offset)) })
    var dense = [UInt8](repeating: 0, count: 0x110000)
    let entries = String(decoding: records, as: UTF8.self).split(separator: "\n")
    guard entries.count == 1626 else { fatalError("incomplete grapheme ranges") }
    var previousUpper = -1
    for record in entries {
      let fields = record.split(separator: ";")
      guard fields.count == 3, let lower = Int(fields[0], radix: 16),
            let upper = Int(fields[1], radix: 16), let category = categoryCodes[String(fields[2])],
            lower > previousUpper, lower <= upper, upper < dense.count else {
        fatalError("malformed or overlapping grapheme range")
      }
      for scalar in lower...upper { dense[scalar] = category }
      previousUpper = upper
    }
    // Four bits encode the existing sixteen categories. Identical 256-scalar
    // pages share one leaf; all gaps retain the input's default Other value.
    var pageIndex: [UInt8] = []
    var leaves: [UInt8] = []
    var pageIDs: [[UInt8]: UInt8] = [:]
    for start in stride(from: 0, to: dense.count, by: 256) {
      let page = stride(from: start, to: start + 256, by: 2).map { dense[$0] | (dense[$0 + 1] << 4) }
      if let existing = pageIDs[page] {
        pageIndex.append(existing)
      } else {
        guard pageIDs.count < 256 else { fatalError("grapheme page index requires widening") }
        let index = UInt8(pageIDs.count)
        pageIDs[page] = index
        pageIndex.append(index)
        leaves.append(contentsOf: page)
      }
    }
    func literal(_ values: [UInt8]) -> String {
      stride(from: 0, to: values.count, by: 16).map { start in
        "    " + values[start..<min(start + 16, values.count)].map { String(format: "0x%02X", $0) }.joined(separator: ", ") + ","
      }.joined(separator: "\n")
    }
    let generated = """
    // Generated from tools/unicode/grapheme-ranges-18.0.0.txt (Unicode 18.0.0).
    // Do not edit: regeneration commands are in tools/unicode/README.md.
    enum Unicode18GraphemeTables {
      enum Category: UInt8 { case \(categories.joined(separator: ", ")) }
      static let unicodeVersion = "18.0.0"
      static let uaxRevision = 49
      static let fixtureSHA256 = "\(digest)"
      static let completeGeneratedRanges = true
      private static let pageIndex: [UInt8] = [
    \(literal(pageIndex))
      ]
      private static let leaves: [UInt8] = [
    \(literal(leaves))
      ]
      static func category(_ value: UInt32) -> Category {
        guard value <= 0x10FFFF else { return .Other }
        let page = Int(pageIndex[Int(value >> 8)])
        let packed = leaves[page * 128 + Int((value & 0xFF) >> 1)]
        let code = (packed >> UInt8((value & 1) * 4)) & 0x0F
        return Category(rawValue: code)!
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
    print("Generated \(entries.count) pinned Unicode 18 ranges as \(pageIDs.count) deduplicated pages (\(pageIndex.count + leaves.count) bytes)")
  }
}

import CryptoKit
import Foundation

@main enum GenerateUnicodeLowercase {
  static let recordsSHA256 = "35e8335ca053474f0baa2ac0525b062468b684253a99377e84563bc5033b9cd0"

  static func main() throws {
    let arguments = CommandLine.arguments.dropFirst()
    guard arguments.count == 2 else { fatalError("usage: GenerateUnicodeLowercase RECORDS OUTPUT") }
    let recordsURL = URL(fileURLWithPath: String(arguments[arguments.startIndex]))
    let recordsData = try Data(contentsOf: recordsURL)
    let digest = SHA256.hash(data: recordsData).map { String(format: "%02x", $0) }.joined()
    guard digest == recordsSHA256 else { fatalError("records checksum changed: \(digest)") }
    guard let records = String(data: recordsData, encoding: .utf8) else { fatalError("records are not UTF-8") }
    var mappings: [UInt64] = []
    var expansion: [UInt32]?
    for line in records.split(separator: "\n", omittingEmptySubsequences: true) {
      let fields = line.split(separator: ":", maxSplits: 1)
      guard fields.count == 2, let source = UInt32(fields[0], radix: 16) else { fatalError("malformed record: \(line)") }
      let targets = fields[1].split(separator: " ").compactMap { UInt32($0, radix: 16) }
      guard !targets.isEmpty else { fatalError("missing target: \(line)") }
      if source == 0x0130 {
        guard expansion == nil, targets == [0x0069, 0x0307] else { fatalError("unexpected U+0130 expansion") }
        expansion = targets
      } else {
        guard targets.count == 1 else { fatalError("unexpected expansion: \(line)") }
        mappings.append((UInt64(source) << 32) | UInt64(targets[0]))
      }
    }
    guard mappings.count == 1_487, mappings == mappings.sorted(), expansion == [0x0069, 0x0307] else { fatalError("incomplete Rust Unicode 17 mapping") }
    let output = """
    // Generated from the Rust standard-library Unicode 17.0.0 lowercase oracle.
    // Input SHA-256: \(recordsSHA256) (1,488 non-identity mappings).
    // Rust: rustc 1.99.0 (b940084d7 2026-09-28), char::UNICODE_VERSION=(17, 0, 0).
    // Do not edit; regenerate with tools/unicode/GenerateUnicodeLowercase.swift.
    enum UnicodeLowercase {
      private static let scalarMappings: [UInt64] = [
    \(format(mappings))
      ]

      static func lowercase(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        let value = scalar.value
        if value < 0x80 {
          if value >= 0x41, value <= 0x5A { return [Unicode.Scalar(value + 0x20)!] }
          return [scalar]
        }
        if value == 0x0130 { return [Unicode.Scalar(0x0069)!, Unicode.Scalar(0x0307)!] }
        let key = UInt64(value)
        var low = 0
        var high = scalarMappings.count
        while low < high {
          let middle = (low + high) / 2
          if scalarMappings[middle] >> 32 < key { low = middle + 1 } else { high = middle }
        }
        guard scalarMappings.indices.contains(low), scalarMappings[low] >> 32 == key else { return [scalar] }
        return [Unicode.Scalar(UInt32(truncatingIfNeeded: scalarMappings[low]))!]
      }
    }
    """
    try (output + "\n").write(toFile: String(arguments[arguments.index(after: arguments.startIndex)]), atomically: true, encoding: .utf8)
  }

  private static func format(_ mappings: [UInt64]) -> String {
    stride(from: 0, to: mappings.count, by: 4).map { offset in
      "        " + mappings[offset..<min(offset + 4, mappings.count)].map { String(format: "0x%016llX", $0) }.joined(separator: ", ") + ","
    }.joined(separator: "\n")
  }
}

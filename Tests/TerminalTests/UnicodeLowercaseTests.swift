import CryptoKit
import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

@Suite enum UnicodeLowercaseTests {
  private static let expectedUnicodeVersion = "17.0.0"
  private static let expectedRecordsSHA256 = "35e8335ca053474f0baa2ac0525b062468b684253a99377e84563bc5033b9cd0"

  /// Unicode 17.0.0: the pinned mappings, every scalar.
  @Test static func pinnedMappings() {
    var records = Data()
    var nonIdentity = 0
    for value in UInt32(0)...0x10FFFF {
      guard let scalar = Unicode.Scalar(value) else { continue }
      let mapped = UnicodeLowercase.lowercase(scalar)
      if mapped.count == 1, mapped[0] == scalar { continue }
      nonIdentity += 1
      let record = String(format: "%06X:", value) + mapped.map { String(format: "%06X", $0.value) }.joined(separator: " ") + "\n"
      records.append(contentsOf: record.utf8)
    }
    let digest = SHA256.hash(data: records).map { String(format: "%02x", $0) }.joined()
    #expect(nonIdentity == 1_488, "Unicode \(expectedUnicodeVersion)")
    #expect(digest == expectedRecordsSHA256)
    #expect(UnicodeLowercase.lowercase("\u{0130}").map(\.value) == [0x0069, 0x0307])
    #expect(UnicodeLowercase.lowercase("\u{A7CE}").map(\.value) == [0xA7CF])
    #expect(UnicodeLowercase.lowercase("\u{16EA0}").map(\.value) == [0x16EBB])
    #expect(UnicodeLowercase.lowercase("\u{16EB8}").map(\.value) == [0x16ED3])
  }
}

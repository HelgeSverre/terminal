import Foundation
import Testing
@testable import TerminalApp

@Suite enum StatisticsTests {
  /// Empty, finite and nonfinite distributions all serialize as JSON values.
  @Test static func distributionsSerializeAsJSON() throws {
    for values in [[Double](), [5], [9, 1, 7, 3, 5], [.infinity, .nan, 4]] {
      let report = TimingDistribution.report(values)
      #expect(JSONSerialization.isValidJSONObject(report))
      let data = try JSONSerialization.data(withJSONObject: report)
      #expect(!data.isEmpty)
    }
    let report = TimingDistribution.report([9, 1, 7, 3, 5])
    #expect(report["p50_ms"] as? Double == 5)
    #expect(report["max_ms"] as? Double == 9)
  }
}

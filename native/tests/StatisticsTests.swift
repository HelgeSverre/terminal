import Foundation

@main struct StatisticsTests {
  static func main() throws {
    for values in [[Double](), [5], [9, 1, 7, 3, 5], [.infinity, .nan, 4]] {
      let report = TimingDistribution.report(values)
      precondition(JSONSerialization.isValidJSONObject(report))
      let data = try JSONSerialization.data(withJSONObject: report)
      precondition(!data.isEmpty)
    }
    let report = TimingDistribution.report([9, 1, 7, 3, 5])
    precondition(report["p50_ms"] as? Double == 5)
    precondition(report["max_ms"] as? Double == 9)
    print("PASS statistics: empty/finite/nonfinite distributions serialize as JSON values")
  }
}

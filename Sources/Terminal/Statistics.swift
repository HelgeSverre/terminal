import Foundation

enum TimingDistribution {
  static func report(_ values: [Double]) -> [String: Any] {
    let sorted = values.filter { $0.isFinite }.sorted()
    func percentile(_ fraction: Double) -> Double {
      guard !sorted.isEmpty else { return 0 }
      return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    // Resolve Collection.last as a value before erasing the dictionary to Any;
    // otherwise Swift can select last(where:) as a function-valued member.
    let maximum: Double = sorted.last ?? 0
    return [
      "samples": sorted.count, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95),
      "p99_ms": percentile(0.99), "max_ms": maximum,
    ]
  }
}

import Foundation
import Testing
@testable import dev

@Suite struct CompareInputLatencyTests {
  @Test("input latency: percentiles pick the nearest sample") func percentilesPickTheNearestSample() throws {
    let values = [5.0, 1.0, 4.0, 2.0, 3.0]
    #expect(CompareInputLatency.percentile(values, 0.5) == 3.0, "median of five")
    #expect(CompareInputLatency.percentile(values, 0.95) == 5.0, "95th percentile of five")
    #expect(CompareInputLatency.percentile([], 0.5) == nil, "no samples, no percentile")
  }

  @Test("screen watch: only the marker's magenta counts as the marker") func onlyTheMarkersMagentaCounts() throws {
    #expect(ScreenWatch.isMarker(0x00ff_00ff), "pure magenta")
    #expect(ScreenWatch.isMarker(0x00f0_30e8), "magenta after colour conversion")
    #expect(!ScreenWatch.isMarker(0x00ff_ffff), "white")
    #expect(!ScreenWatch.isMarker(0x00ff_0000), "red")
    #expect(!ScreenWatch.isMarker(0x0010_1012), "a dark background")
  }
}

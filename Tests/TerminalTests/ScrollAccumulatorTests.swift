import AppKit
import Testing
@testable import TerminalApp
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

/// Trackpad deltas add up to whole lines; nothing is lost between events.
@Suite enum ScrollAccumulatorTests {
  static func scroll(_ deltas: [CGFloat], precise: Bool = true, lineHeight: CGFloat = 17,
                     accumulator: inout ScrollAccumulator) -> [Int] {
    deltas.map { accumulator.lines(delta: $0, precise: precise, lineHeight: lineHeight, startsGesture: false) }
  }

  @Test static func slowTrackpadSwipeStillScrolls() {
    // 1-point deltas used to scroll nothing: each was divided by 3 and truncated.
    var accumulator = ScrollAccumulator()
    let lines = scroll(Array(repeating: 1, count: 34), accumulator: &accumulator)
    #expect(lines.reduce(0, +) == 2, "34 points at 17 points a line is two lines")
    #expect(lines.allSatisfy { $0 == 0 || $0 == 1 })
  }

  @Test static func travelMatchesLineHeight() {
    var accumulator = ScrollAccumulator()
    let lines = scroll([5.5, 12, 40, 30.5, -0], accumulator: &accumulator)
    #expect(lines.reduce(0, +) == 5, "88 points is five lines of 17")
    #expect(abs(accumulator.pending - 3.0 / 17) < 0.0001)
  }

  @Test static func turningBackDropsTheRemainder() {
    var accumulator = ScrollAccumulator()
    #expect(scroll([16], accumulator: &accumulator) == [0])
    #expect(scroll([-17], accumulator: &accumulator) == [-1], "the 16 points up do not cancel the first line down")
  }

  @Test static func aNewGestureStartsAfresh() {
    var accumulator = ScrollAccumulator()
    _ = scroll([16], accumulator: &accumulator)
    #expect(accumulator.lines(delta: 2, precise: true, lineHeight: 17, startsGesture: true) == 0)
    #expect(abs(accumulator.pending - 2.0 / 17) < 0.0001)
  }

  @Test static func wheelNotchesScrollAtLeastOneLine() {
    var accumulator = ScrollAccumulator()
    #expect(scroll([0.1, -0.3, 3, 2.6], precise: false, accumulator: &accumulator) == [1, -1, 3, 2])
    #expect(accumulator.pending == 0)
  }

  @Test static func emptyAndHugeDeltas() {
    var accumulator = ScrollAccumulator()
    #expect(scroll([0, .nan, .infinity], accumulator: &accumulator) == [0, 0, 0],
      "an event with no vertical movement must not scroll, nor report a wheel-down")
    #expect(scroll([10_000], accumulator: &accumulator) == [ScrollAccumulator.maximumLines])
  }
}

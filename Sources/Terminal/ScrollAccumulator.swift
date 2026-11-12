import AppKit

/// Turns scroll-wheel and trackpad deltas into whole lines.
///
/// A trackpad reports small deltas in points, many per gesture; a mouse wheel
/// reports lines. Both are added up here, and only whole lines leave: the
/// fraction is kept for the next event, so a slow swipe still scrolls and a
/// fast one moves as far as the fingers did. A trackpad scrolls one line per
/// line height of finger travel; a wheel scrolls its reported lines, and at
/// least one for each notch.
struct ScrollAccumulator {
  /// Lines not yet scrolled. Positive is towards older output, as with
  /// `NSEvent.scrollingDeltaY`.
  private(set) var pending: CGFloat = 0

  /// The most lines one event may scroll, so a burst cannot flood a program
  /// with mouse reports.
  static let maximumLines = 50

  /// Whole lines to scroll for one event. `lineHeight` is in points.
  mutating func lines(delta: CGFloat, precise: Bool, lineHeight: CGFloat, startsGesture: Bool) -> Int {
    if startsGesture { pending = 0 }
    guard delta.isFinite, delta != 0 else { return 0 }
    let step = precise ? delta / max(1, lineHeight) : delta
    // Turning back starts afresh instead of first paying off the remainder.
    if pending != 0, (pending > 0) != (step > 0) { pending = 0 }
    pending += step
    var whole = pending.rounded(.towardZero)
    // Each notch of a wheel scrolls at least a line, as before.
    if !precise, whole == 0 { whole = step > 0 ? 1 : -1 }
    pending = precise ? pending - whole : 0
    return max(-Self.maximumLines, min(Self.maximumLines, Int(whole)))
  }

}

extension ScrollAccumulator {
  /// Lines for an AppKit scroll event.
  mutating func lines(for event: NSEvent, lineHeight: CGFloat) -> Int {
    lines(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, lineHeight: lineHeight,
      startsGesture: event.phase.contains(.began) || event.phase.contains(.mayBegin))
  }
}

import Foundation

/// Fractional history position uses the older enclosing row as its anchor.
/// The negative translation exposes the following guard row at the bottom.
package struct ViewportPresentation {
  package private(set) var position: CGFloat = 0
  package private(set) var anchor = 0

  /// The offset a requested scroll should publish, until a snapshot shows it.
  /// While it is set, published offsets do not overwrite the scroll position.
  package private(set) var pending: Int?
  private var pendingSince: TimeInterval = 0
  /// How long a request may stay unconfirmed before the published offset wins.
  package static let pendingLimit: TimeInterval = 0.25

  package var fraction: CGFloat { position - CGFloat(anchor) }

  /// Call after `scroll` returned lines that were sent to the session.
  package mutating func awaitScroll(now: TimeInterval) { pending = anchor; pendingSince = now }

  /// Takes a published offset. With a request outstanding it is accepted only
  /// when it is the requested one. Output under a pinned viewport moves that
  /// target by the rows history grew (`pinnedGrowth`); when history is full
  /// the growth cannot be seen, and the time limit ends the wait instead.
  package mutating func publish(offset: Int, pinnedGrowth: Int, now: TimeInterval) {
    guard let expected = pending else { reconcile(offset: offset); return }
    let growth = expected > 0 ? max(0, pinnedGrowth) : 0
    if expected + growth == offset || now - pendingSince > Self.pendingLimit {
      pending = nil
      reconcile(offset: offset)
    } else if growth > 0 {
      pending = expected + growth
      anchor += growth
      position += CGFloat(growth)
    }
  }

  package mutating func scroll(delta: CGFloat, lineHeight: CGFloat, maximum: Int) -> Int {
    guard delta.isFinite, lineHeight.isFinite, lineHeight > 0 else { return 0 }
    position = min(CGFloat(max(0, maximum)), max(0, position + delta / lineHeight))
    let previous = anchor
    anchor = Int(ceil(position))
    return anchor - previous
  }

  package mutating func reset(offset: Int) {
    pending = nil
    anchor = max(0, offset)
    position = CGFloat(anchor)
  }

  /// Output can advance a pinned viewport's integer offset without moving its
  /// retained row. Preserve only the sub-row part across that publication.
  package mutating func reconcile(offset: Int) {
    let remainder = fraction
    anchor = max(0, offset)
    position = max(0, CGFloat(anchor) + remainder)
  }
}

package struct ViewportGeometry {
  package let inset: CGFloat
  package let cellWidth: CGFloat
  package let cellHeight: CGFloat
  package let offset: CGFloat

  package func row(at y: CGFloat) -> Int { Int(floor((y - inset - offset) / max(1, cellHeight))) }
  package func column(at x: CGFloat) -> Int { Int(floor((x - inset) / max(1, cellWidth))) }
  package func rect(row: Int, column: Int, cells: Int = 1) -> CGRect {
    CGRect(x: inset + CGFloat(column) * cellWidth, y: inset + CGFloat(row) * cellHeight + offset,
      width: CGFloat(cells) * cellWidth, height: cellHeight)
  }
}

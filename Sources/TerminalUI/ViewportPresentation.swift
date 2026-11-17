import Foundation

/// Fractional history position uses the older enclosing row as its anchor.
/// The negative translation exposes the following guard row at the bottom.
package struct ViewportPresentation {
  package private(set) var position: CGFloat = 0
  package private(set) var anchor = 0

  package var fraction: CGFloat { position - CGFloat(anchor) }

  package mutating func scroll(delta: CGFloat, lineHeight: CGFloat, maximum: Int) -> Int {
    guard delta.isFinite, lineHeight.isFinite, lineHeight > 0 else { return 0 }
    position = min(CGFloat(max(0, maximum)), max(0, position + delta / lineHeight))
    let previous = anchor
    anchor = Int(ceil(position))
    return anchor - previous
  }

  package mutating func reset(offset: Int) {
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

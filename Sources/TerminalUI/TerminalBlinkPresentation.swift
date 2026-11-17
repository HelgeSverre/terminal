import Foundation

/// A phase and its next transition, rather than a repeating redraw timer.
/// Shape zero retains the terminal's default steady cursor appearance.
package struct TerminalBlinkPresentation: Equatable {
  package let cursorVisible: Bool
  package let textVisible: Bool
  package let nextDeadline: TimeInterval?

  package init(now: TimeInterval, cursorShape: Int, cursor: Bool, text: Bool, active: Bool) {
    let cursorBlinks = cursor && [1, 3, 5].contains(cursorShape)
    let phase = now.isFinite ? max(0, now) : 0
    let visible = Int(phase.truncatingRemainder(dividingBy: 1) * 2) == 0
    cursorVisible = !active || !cursorBlinks || visible
    textVisible = !active || !text || visible
    nextDeadline = active && (cursorBlinks || text) ? (floor(phase * 2) + 1) / 2 : nil
  }
}

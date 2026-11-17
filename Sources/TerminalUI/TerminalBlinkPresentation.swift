import Foundation
import TerminalEngine

/// A phase and its next transition, rather than a repeating redraw timer.
/// Shape zero retains the terminal's default steady cursor appearance.
package struct TerminalBlinkPresentation: Equatable {
  package let cursorVisible: Bool
  package let textVisible: Bool
  package let nextDeadline: TimeInterval?

  /// The cursor's phase starts at `cursorEpoch`, the last time it moved, so a
  /// cursor that has just moved is drawn. Blinking text keeps the shared clock.
  package init(now: TimeInterval, cursorEpoch: TimeInterval = 0, cursorShape: Int, cursor: Bool, text: Bool) {
    func phase(since epoch: TimeInterval) -> (visible: Bool, next: TimeInterval) {
      let epoch = epoch.isFinite ? epoch : 0
      let elapsed = now.isFinite ? max(0, now - epoch) : 0
      return (Int(elapsed.truncatingRemainder(dividingBy: 1) * 2) == 0, epoch + (floor(elapsed * 2) + 1) / 2)
    }
    let cursorBlinks = cursor && [1, 3, 5].contains(cursorShape)
    let cursorPhase = phase(since: cursorEpoch), textPhase = phase(since: 0)
    cursorVisible = !cursorBlinks || cursorPhase.visible
    textVisible = !text || textPhase.visible
    nextDeadline = [cursorBlinks ? cursorPhase.next : nil, text ? textPhase.next : nil].compactMap { $0 }.min()
  }
}

/// The one pending wake for the next blink transition. Asking again for the
/// deadline already scheduled keeps the timer; nil cancels it.
final class BlinkWake {
  private var work: DispatchWorkItem?
  private var deadline: TimeInterval?

  func schedule(_ next: TimeInterval?, now: TimeInterval, fire: @escaping () -> Void) {
    guard next != deadline else { return }
    work?.cancel()
    work = nil
    deadline = next
    guard let next else { return }
    let item = DispatchWorkItem { [weak self] in
      self?.work = nil
      self?.deadline = nil
      fire()
    }
    work = item
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, next - now), execute: item)
  }
  func cancel() { schedule(nil, now: 0) {} }
}

extension TerminalSnapshot {
  /// Whether any visible cell asks to blink.
  var hasBlinkingText: Bool {
    rows.contains { $0.cells.contains { $0.style.blink && !$0.style.conceal && !$0.text.isEmpty } }
  }
}

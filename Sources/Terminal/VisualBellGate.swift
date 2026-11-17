import Foundation

struct VisualBellGate {
  private var last: TimeInterval?
  mutating func admit(now: TimeInterval) -> Bool {
    guard now.isFinite, last.map({ now - $0 >= 0.75 }) ?? true else { return false }
    last = now
    return true
  }
}

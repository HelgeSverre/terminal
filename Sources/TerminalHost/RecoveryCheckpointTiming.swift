import Foundation

/// Monotonic scheduling state, independent of timers. A clean pane has no
/// deadline; output wakes the app once until a checkpoint takes that dirty set.
package struct RecoveryCheckpointTiming {
  private var first: UInt64?
  private var last: UInt64 = 0
  package mutating func output(at now: UInt64) -> Bool {
    let newlyDirty = first == nil
    if newlyDirty { first = now }
    last = now
    return newlyDirty
  }
  package func delay(at now: UInt64, force: Bool = false) -> Double? {
    guard let first else { return nil }
    let quiet = Double(now >= last ? now - last : 0) / 1_000_000_000
    let age = Double(now >= first ? now - first : 0) / 1_000_000_000
    return force ? 0 : max(0, min(2 - quiet, 60 - age))
  }
  package mutating func captured() { first = nil }
}

import Foundation
import TerminalEngine

// The handle is owner-queue confined. Publication returns owned Swift values;
// the C borrowed-cell/JSON endpoints remain separate compatibility oracles.
enum SnapshotBridge {
  struct Result {
    let snapshot: TerminalSnapshot?
    let error: String?
  }
  static func read(_ core: OpaquePointer?, scroll: Int, now: UInt64) -> Result {
    let result = swiftTerminalSnapshot(core, scroll: scroll, now: now)
    return Result(snapshot: result.snapshot, error: result.error)
  }
  static func readView(_ core: OpaquePointer?, now: UInt64) -> Result {
    let result = swiftTerminalSnapshot(core, scroll: nil, now: now)
    return Result(snapshot: result.snapshot, error: result.error)
  }
}

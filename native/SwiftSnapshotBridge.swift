import Foundation

// Owned JSON hand-off in the Swift-only build.  It intentionally replaces the
// C borrowed-row callback, keeping terminal mutation and snapshot construction
// behind one concurrency boundary.
enum SnapshotBridge {
  struct Result {
    let snapshot: TerminalSnapshot?
    let error: String?
  }
  static func read(_ core: OpaquePointer?, scroll: Int, now: UInt64) -> Result { decode(core) }
  static func readView(_ core: OpaquePointer?, now: UInt64) -> Result { decode(core) }
  private static func decode(_ core: OpaquePointer?) -> Result {
    guard let raw = terminal_snapshot(core, Int.max, 0) else {
      return Result(snapshot: nil, error: "Snapshot unavailable")
    }
    defer { terminal_string_free(raw) }
    do {
      return Result(
        snapshot: try JSONDecoder().decode(TerminalSnapshot.self, from: Data(String(cString: raw).utf8)),
        error: nil)
    } catch {
      return Result(snapshot: nil, error: "Snapshot decode failed: \(error)")
    }
  }
}

import Foundation

// The owner view API publishes authoritative metadata, while the legacy ABI
// selects rows by an explicit numeric offset. Combine those two existing
// outputs for tests without teaching production a test-only snapshot mode.
enum TerminalSnapshotTestSupport {
  private final class Metadata { var value = Data() }
  private static let collect: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
    UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int
  ) -> Void = { context, metadata, count, _, _, _, _ in
    guard let context, let metadata, count > 0 else { return }
    Unmanaged<Metadata>.fromOpaque(context).takeUnretainedValue().value = Data(bytes: metadata, count: count)
  }

  static func ownerSnapshot(_ terminal: OpaquePointer, now: UInt64 = 0) -> [String: Any]? {
    let capture = Metadata()
    guard terminal_view_snapshot_binary(
      terminal, now, Unmanaged.passUnretained(capture).toOpaque(), collect),
      let ownerObject = try? JSONSerialization.jsonObject(with: capture.value),
      var owner = ownerObject as? [String: Any],
      let offset = owner["scroll_offset"] as? Int,
      let raw = terminal_snapshot(terminal, offset, now)
    else { return nil }
    defer { terminal_string_free(raw) }
    guard let numericObject = try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)),
          let numeric = numericObject as? [String: Any],
          let rows = numeric["rows"] else { return nil }
    owner["rows"] = rows
    return owner
  }
}

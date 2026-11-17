import Foundation

/// A file received through OSC 1337. Receiving it never opens or writes a path.
/// The embedding application decides whether and where to save these bytes.
public struct TerminalDownload: Sendable {
  public let suggestedFilename: String
  public let data: Data
}

package struct TerminalPendingDownload: Sendable {
  package let id: UInt64
  package let suggestedFilename: String
  package let byteCount: Int
}

/// Completed files remain charged until the host takes or dismisses them.
/// Notifications contain metadata only, so a slow UI cannot bypass this cap.
final class TerminalDownloads {
  static let maximumPending = 4
  static let maximumBytes = 32 * 1024 * 1024
  private var nextID: UInt64 = 1
  private var files: [(id: UInt64, file: TerminalDownload)] = []
  private(set) var byteCount = 0

  @discardableResult func enqueue(name: String, data: Data) -> Bool {
    guard files.count < Self.maximumPending, data.count <= Self.maximumBytes - byteCount,
      nextID < UInt64.max else { return false }
    files.append((nextID, TerminalDownload(suggestedFilename: Self.filename(name), data: data)))
    nextID += 1; byteCount += data.count
    return true
  }
  var pending: [TerminalPendingDownload] {
    files.map { TerminalPendingDownload(id: $0.id, suggestedFilename: $0.file.suggestedFilename, byteCount: $0.file.data.count) }
  }
  func resolve(_ id: UInt64, take: Bool) -> TerminalDownload? {
    guard let index = files.firstIndex(where: { $0.id == id }) else { return nil }
    let file = files.remove(at: index).file
    byteCount -= file.data.count
    return take ? file : nil
  }
  func takeAll() -> [TerminalDownload] {
    defer { clear() }
    return files.map(\.file)
  }
  func clear() { files.removeAll(); byteCount = 0 }

  /// Both common path separators are recognized; controls and bidi formatting
  /// cannot disguise the suggested basename. This is a label, never a path.
  static func filename(_ original: String) -> String {
    let basename = original.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).last ?? ""
    var name = "", bytes = 0
    for scalar in basename.unicodeScalars {
      guard !CharacterSet.controlCharacters.contains(scalar), scalar.properties.generalCategory != .format,
        scalar.properties.generalCategory != .lineSeparator, scalar.properties.generalCategory != .paragraphSeparator else { continue }
      let next = scalar == ":" ? "_" : String(scalar)
      guard bytes + next.utf8.count <= 255 else { break }
      name += next; bytes += next.utf8.count
    }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name == "." || name == ".." ? "Unnamed file" : name
  }
}

import Foundation
import TerminalInterop

/// A terminal with no window and no process: bytes go in, and the screen's
/// text and the terminal's replies come out. It suits tests, recordings and
/// a host that has its own transport and its own drawing.
///
/// An instance is not thread-safe. Use it from one thread or queue at a time.
public final class HeadlessTerminal {
  /// What is on screen at one moment.
  public struct Screen: Sendable {
    /// One string per row, top to bottom, without trailing spaces.
    public let rows: [String]
    /// The cursor's row and column, counted from zero.
    public let cursorRow: Int
    public let cursorColumn: Int
    /// The title the program set, or an empty string.
    public let title: String
    /// Whether the program is using the alternate screen.
    public let isAlternateScreen: Bool
    /// The location the program last reported with OSC 7, as it sent it.
    public let workingDirectory: String?
    /// The rows joined by newlines.
    public var text: String { rows.joined(separator: "\n") }
  }

  private let core: OpaquePointer
  public private(set) var columns: Int
  public private(set) var rows: Int

  /// Fails for a grid outside 1 to 4,096 columns and rows, or of more than
  /// 1,048,576 cells.
  public init?(columns: Int = 80, rows: Int = 24) {
    guard columns > 0, rows > 0, columns <= 4096, rows <= 4096,
      let core = helge_terminal_create(UInt32(columns), UInt32(rows))
    else { return nil }
    self.core = core
    self.columns = columns
    self.rows = rows
  }
  deinit { helge_terminal_destroy(core) }

  /// Interprets bytes a program wrote to the terminal. Returns when all of
  /// them have taken effect.
  public func feed(_ bytes: Data) {
    bytes.withUnsafeBytes { raw in
      let base = raw.bindMemory(to: UInt8.self).baseAddress
      var offset = 0
      // The emulator works in bounded steps, so a long repeat is finished by
      // asking again with nothing new.
      while true {
        let repeating = helge_terminal_has_work(core)
        guard offset < raw.count || repeating else { break }
        let consumed = helge_terminal_feed(core, base.map { $0 + offset }, raw.count - offset, Self.now)
        offset += consumed
        // A step that only advanced a repeat consumes nothing and is progress.
        if consumed == 0, !repeating { break }
      }
    }
  }
  public func feed(_ text: String) { feed(Data(text.utf8)) }

  /// Changes the grid and reflows the text. Returns false for a size the
  /// terminal does not accept; the old size then stands.
  @discardableResult public func resize(columns: Int, rows: Int) -> Bool {
    guard columns > 0, rows > 0, columns <= 4096, rows <= 4096,
      helge_terminal_resize(core, UInt32(columns), UInt32(rows))
    else { return false }
    self.columns = columns
    self.rows = rows
    return true
  }

  /// What the terminal has to say back to the program since the last call:
  /// answers to status and attribute queries. A host with a transport writes
  /// these to it.
  public func takeReplies() -> Data {
    final class Box { var data = Data() }
    let box = Box()
    helge_terminal_replies(core, Unmanaged.passUnretained(box).toOpaque()) { context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
    }
    return box.data
  }

  /// The screen as it stands, or nil while the program holds the display
  /// back with synchronized output.
  public func screen() -> Screen? {
    guard let snapshot = swiftTerminalSnapshot(core, scroll: nil, now: Self.now).snapshot else { return nil }
    let lines = snapshot.rows.map { row -> String in
      // The second cell of a wide character holds nothing of its own.
      var line = row.cells.map { $0.kind == "Continuation" ? "" : ($0.text.isEmpty ? " " : $0.text) }.joined()
      while line.hasSuffix(" ") { line.removeLast() }
      return line
    }
    return Screen(
      rows: lines, cursorRow: snapshot.cursor.row, cursorColumn: snapshot.cursor.col, title: snapshot.title,
      isAlternateScreen: snapshot.alternate, workingDirectory: snapshot.cwd)
  }

  private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
}

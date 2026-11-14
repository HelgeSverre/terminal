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
    /// Every cell of every row, with its colors resolved. A wide character
    /// is followed by a cell with `isContinuation` set and no text.
    public let cells: [[Cell]]
    /// Rows that have scrolled off the top and are kept.
    public let historyRows: Int
    /// The rows joined by newlines.
    public var text: String { rows.joined(separator: "\n") }
  }

  /// One cell of the grid.
  public struct Cell: Equatable, Sendable {
    /// The character, which may be several code points; empty for a blank
    /// cell and for the second cell of a wide character.
    public let text: String
    public let isContinuation: Bool
    /// The colors the cell is drawn in, as 0xRRGGBB, after the palette,
    /// reverse video and faint are applied.
    public let foreground: UInt32
    public let background: UInt32
    public let bold: Bool
    public let italic: Bool
    public let underlined: Bool
    public let struckThrough: Bool
    public let concealed: Bool
    /// The target of an OSC 8 hyperlink.
    public let link: String?
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
  /// Sets the colors the terminal starts from and reports to programs
  /// that ask (OSC 4, 10 and 11).
  public func setColors(_ colors: TerminalColorScheme) {
    let ansi = colors.ansi.count == 16 ? colors.ansi : TerminalColorScheme.standardANSI
    ansi.withUnsafeBufferPointer {
      helge_terminal_set_colors(core, colors.foreground, colors.background, $0.baseAddress)
    }
  }
  /// The state mode 2027 starts in: grapheme clusters (true, the default)
  /// or one cell run per code point with a width (false).
  public func setGraphemeClustering(_ enabled: Bool) { helge_terminal_set_grapheme_clustering(core, enabled) }
  @discardableResult public func resize(columns: Int, rows: Int) -> Bool {
    guard columns > 0, rows > 0, columns <= 4096, rows <= 4096,
      helge_terminal_resize(core, UInt32(columns), UInt32(rows))
    else { return false }
    self.columns = columns
    self.rows = rows
    return true
  }

  /// The bytes `key` sends to the program in the terminal's current modes,
  /// for a host to write to its transport. Empty for a key the terminal
  /// does not know.
  public func encode(_ key: TerminalKey, modifiers: TerminalKeyModifiers = []) -> Data {
    guard let code = key.code else { return Data() }
    final class Box { var data = Data() }
    let box = Box()
    let character = key.character
    let shifted = modifiers.contains(.shift) ? character.uppercased() : ""
    let committed = modifiers.contains(.shift) ? shifted : character
    _ = helge_terminal_input_with_metadata(
      core, character, code, modifiers.rawValue, 0, committed, committed,
      shifted.unicodeScalars.count == 1 ? shifted.unicodeScalars.first!.value : 0,
      character.unicodeScalars.count == 1 ? character.unicodeScalars.first!.value : 0,
      Unmanaged.passUnretained(box).toOpaque()
    ) { context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
    }
    return box.data
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
  /// `scrolledBack` moves the window that many rows into the history.
  public func screen(scrolledBack: Int = 0) -> Screen? {
    guard let snapshot = swiftTerminalSnapshot(core, scroll: max(0, scrolledBack), now: Self.now).snapshot
    else { return nil }
    func rgb(_ color: TerminalColor, _ fallback: [Int]) -> UInt32 {
      let parts = color.rgb.flatMap { $0.count == 3 ? $0 : nil }
        ?? color.index.flatMap { snapshot.palette.indices.contains($0) ? snapshot.palette[$0] : nil }
        ?? fallback
      guard parts.count == 3 else { return 0 }
      return parts.reduce(0) { $0 << 8 | UInt32(min(255, max(0, $1))) }
    }
    let cells = snapshot.rows.map { row in
      row.cells.map { cell -> Cell in
        var foreground = rgb(cell.style.foreground, snapshot.default_fg)
        var background = rgb(cell.style.background, snapshot.default_bg)
        if cell.style.inverse != snapshot.modes.reverse_video { swap(&foreground, &background) }
        if cell.style.faint {
          // The view draws faint text at 65 % of its linear brightness;
          // this is the same on the encoded value, to the nearest step.
          foreground = [16, 8, 0].reduce(0) { $0 | UInt32(Double((foreground >> $1) & 255) * 0.82) << $1 }
        }
        return Cell(
          text: cell.kind == "Continuation" ? "" : cell.text, isContinuation: cell.kind == "Continuation",
          foreground: foreground, background: background, bold: cell.style.bold, italic: cell.style.italic,
          underlined: cell.style.underline != 0, struckThrough: cell.style.strike, concealed: cell.style.conceal,
          link: cell.link)
      }
    }
    let lines = snapshot.rows.map { row -> String in
      // The second cell of a wide character holds nothing of its own.
      var line = row.cells.map { $0.kind == "Continuation" ? "" : ($0.text.isEmpty ? " " : $0.text) }.joined()
      while line.hasSuffix(" ") { line.removeLast() }
      return line
    }
    return Screen(
      rows: lines, cursorRow: snapshot.cursor.row, cursorColumn: snapshot.cursor.col, title: snapshot.title,
      isAlternateScreen: snapshot.alternate, workingDirectory: snapshot.cwd,
      cells: cells, historyRows: snapshot.history_rows)
  }

  private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
}

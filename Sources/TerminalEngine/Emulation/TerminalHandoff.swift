import Foundation

/// A terminal's state in a form another process can restore: the rows as a
/// byte stream a fresh terminal of the same size paints itself from, and
/// everything a stream cannot say (cursor, modes, saved cursor, keyboard
/// stacks) as JSON. It carries a running program across an app relaunch, so
/// a newer build must be able to read what an older one wrote: `content` is
/// ordinary terminal output, and `state` tolerates unknown and missing keys.
/// Images, selection, search and command marks are not carried.
package struct TerminalHandoff: Sendable, Equatable {
  package var columns: Int
  package var rows: Int
  package var content: Data
  package var state: Data
  package init(columns: Int, rows: Int, content: Data, state: Data) {
    self.columns = columns; self.rows = rows; self.content = content; self.state = state
  }
}

struct TerminalHandoffState: Codable, Equatable {
  struct Style: Codable, Equatable {
    var foreground: UInt32 = 0, background: UInt32 = 0, underline: UInt32 = 0
    var flags: UInt16 = 0, underlineKind: UInt8 = 0
    init(_ style: TerminalStyle) {
      foreground = style.foreground; background = style.background; underline = style.underline
      flags = style.flags; underlineKind = style.underlineKind
    }
    var style: TerminalStyle {
      TerminalStyle(foreground: foreground, background: background, underline: underline,
                    flags: flags, underlineKind: underlineKind)
    }
  }
  struct Screen: Codable, Equatable {
    var cursorRow = 0, cursorColumn = 0, pendingWrap = false
    var savedRow = 0, savedColumn = 0, savedPendingWrap = false
    var savedOrigin = false, savedStyle = Style(TerminalStyle()), savedLink: String?
    var savedProtected = false, savedCharsetSpecial = [false, false], savedCharsetSlot = 0
    var keyboardFlags: UInt32 = 0, keyboardStack: [UInt32] = []
    var cursorVisible = true, cursorShape: UInt8 = 0
    var top = 0, bottom = 0, left = 0, right = 0
  }
  var version = 1
  var usingAlternate = false
  var primary = Screen()
  var alternate = Screen()
  var pen = Style(TerminalStyle())
  var penLink: String?
  var penProtected = false
  var charsetSpecial = [false, false]
  var charsetSlot = 0
  /// Named switches and small numbers. A key a build does not know is
  /// ignored, and one it misses keeps the terminal's default.
  var modes: [String: Int] = [:]
  var savedPrivateModes: [String: Bool] = [:]
  var tabs: [Bool] = []
  var tabsCleared = false
  var title = ""
  var iconTitle = ""
  var directory: String?
  /// OSC color commands, as (command, value) pairs, that restore overrides.
  var colors: [[String]] = []
}

/// Paints rows as terminal output. A fresh terminal of the same width that
/// reads it holds the same cells, styles, links and wrapping.
struct TerminalHandoffContent {
  private(set) var bytes = Data()
  private var style = TerminalStyle()
  private var link: String?
  private var protected = false

  /// History and the primary screen, oldest row first. The rows scroll into
  /// history as a program's output once did.
  mutating func paint(history: TerminalHistory, screen: [TerminalRow]) {
    let total = history.count + screen.count
    var continues = false
    for index in 0..<total {
      let row = index < history.count ? history[index] : screen[index - history.count]
      // A row that continues the one above is reached by wrapping onto it.
      // Text does that by being printed; a row that starts empty needs a
      // character put there and taken away again.
      if continues, row.count > 0, row.cell(0).kind == 0 {
        set(row.cell(0).style)
        append(" \u{8}\u{1b}[X")
      }
      continues = row.softWrapped && index + 1 < total
      paint(row, wraps: continues)
      if !row.softWrapped, index + 1 < total {
        // A line feed fills the row it scrolls in with the pen's background.
        set(TerminalStyle())
        append("\r\n")
      }
    }
  }

  /// The alternate screen, row by row at its own position.
  mutating func paint(alternate rows: [TerminalRow]) {
    finish()
    append("\u{1b}[?47h")
    for (index, row) in rows.enumerated() {
      append("\u{1b}[\(index + 1);1H")
      paint(row, wraps: false)
    }
  }

  mutating func finish() {
    set(TerminalStyle())
    setLink(nil)
    setProtected(false)
  }

  private mutating func paint(_ row: TerminalRow, wraps: Bool) {
    var end = row.count
    if !wraps {
      while end > 0 {
        let cell = row.cell(end - 1)
        if cell.kind != 0 || cell.style != TerminalStyle() { break }
        end -= 1
      }
    }
    var skipped = 0
    var column = 0
    while column < end {
      let cell = row.cell(column)
      switch cell.kind {
      case 3, 4: break
      case 0 where !wraps:
        // An empty cell stays empty: step over it, or erase it in its color.
        if cell.style == TerminalStyle() { skipped += 1; break }
        var run = 1
        while column + run < end, row.cell(column + run).kind == 0, row.cell(column + run).style == cell.style { run += 1 }
        flush(&skipped)
        set(cell.style)
        append("\u{1b}[\(run)X")
        skipped = run
        column += run - 1
      default:
        flush(&skipped)
        set(cell.style)
        setLink(cell.link)
        setProtected(cell.protected)
        let text = cell.kind == 0 ? " " : cell.text
        // Text another build may measure differently cannot shift the rest
        // of its row: every such cell names its own column.
        if column > 0, text.utf8.count > 1 { append("\u{1b}[\(column + 1)G") }
        append(text)
      }
      column += 1
    }
  }
  private mutating func flush(_ skipped: inout Int) {
    if skipped > 0 { append("\u{1b}[\(skipped)C") }
    skipped = 0
  }
  private mutating func set(_ next: TerminalStyle) {
    guard next != style else { return }
    style = next
    append("\u{1b}[\(TerminalQueries.sgr(next))m")
  }
  private mutating func setLink(_ next: String?) {
    guard next != link else { return }
    link = next
    append("\u{1b}]8;;\(next ?? "")\u{1b}\\")
  }
  private mutating func setProtected(_ next: Bool) {
    guard next != protected else { return }
    protected = next
    append("\u{1b}[\(next ? 1 : 0)\"q")
  }
  private mutating func append(_ text: String) { bytes.append(contentsOf: text.utf8) }
}

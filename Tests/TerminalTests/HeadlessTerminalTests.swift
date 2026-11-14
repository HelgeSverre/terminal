import Foundation
import Testing
import TerminalEngine

/// The public emulator, used the way another package would: no `@testable`.
@Suite struct HeadlessTerminalTests {
  @Test func bytesBecomeScreenText() throws {
    let terminal = try #require(HeadlessTerminal(columns: 20, rows: 4))
    terminal.feed("hello\r\n\u{1b}[31mred\u{1b}[0m 猫\u{1b}]2;a title\u{07}")
    let screen = try #require(terminal.screen())
    #expect(screen.rows == ["hello", "red 猫", "", ""])
    #expect(screen.text.hasPrefix("hello\nred 猫"))
    #expect(screen.cursorRow == 1)
    #expect(screen.cursorColumn == 6, "a wide character takes two columns")
    #expect(screen.title == "a title")
    #expect(!screen.isAlternateScreen)
  }

  @Test func queriesAreAnswered() throws {
    let terminal = try #require(HeadlessTerminal(columns: 20, rows: 4))
    terminal.feed("ab\u{1b}[6n")
    #expect(String(decoding: terminal.takeReplies(), as: UTF8.self) == "\u{1b}[1;3R")
    #expect(terminal.takeReplies().isEmpty, "replies are handed over once")
  }

  @Test func aLongRepeatFinishesWithinOneFeed() throws {
    let terminal = try #require(HeadlessTerminal(columns: 80, rows: 3))
    // REP runs in bounded steps inside the emulator.
    terminal.feed("x\u{1b}[9999b\r\ndone")
    let screen = try #require(terminal.screen())
    #expect(screen.rows.last == "done")
  }

  @Test func theHostsColorsAreWhatProgramsAreTold() throws {
    let terminal = try #require(HeadlessTerminal(columns: 20, rows: 4))
    func ask(_ query: String) -> String {
      terminal.feed("\u{1b}]\(query)\u{1b}\\")
      return String(decoding: terminal.takeReplies(), as: UTF8.self)
    }
    #expect(ask("11;?") == "\u{1b}]11;rgb:0a0a/0a0a/0b0b\u{1b}\\", "the standard background")
    var ansi = TerminalColorScheme.standardANSI
    ansi[1] = 0xaa0000
    terminal.setColors(TerminalColorScheme(foreground: 0x112233, background: 0xfdf6e3, ansi: ansi))
    #expect(ask("10;?") == "\u{1b}]10;rgb:1111/2222/3333\u{1b}\\")
    #expect(ask("11;?") == "\u{1b}]11;rgb:fdfd/f6f6/e3e3\u{1b}\\")
    #expect(ask("4;1;?") == "\u{1b}]4;1;rgb:aaaa/0000/0000\u{1b}\\")
    #expect(ask("4;196;?") == "\u{1b}]4;196;rgb:ffff/0000/0000\u{1b}\\", "the color cube is not the host's")

    // A color the program set for itself outlives a change of scheme, and
    // a reset returns to the scheme.
    _ = ask("11;#000001")
    terminal.setColors(TerminalColorScheme(foreground: 0x445566, background: 0xffffff))
    #expect(ask("11;?") == "\u{1b}]11;rgb:0000/0000/0101\u{1b}\\")
    #expect(ask("10;?") == "\u{1b}]10;rgb:4444/5555/6666\u{1b}\\")
    terminal.feed("\u{1b}c")
    #expect(ask("11;?") == "\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\")

    // Sixteen colors or none.
    terminal.setColors(TerminalColorScheme(ansi: [0xffffff]))
    #expect(ask("4;1;?") == "\u{1b}]4;1;rgb:efef/4444/4444\u{1b}\\")
  }

  @Test func cellsCarryTheirResolvedStyle() throws {
    let terminal = try #require(HeadlessTerminal(columns: 12, rows: 3))
    terminal.feed("a\u{1b}[1;3;4;31mb\u{1b}[0m\u{1b}[7mc\u{1b}[0m\u{1b}[38;2;1;2;3;48;5;196md\u{1b}[0m猫\u{1b}]8;;https://example.com\u{1b}\\L\u{1b}]8;;\u{1b}\\")
    let row = try #require(terminal.screen()).cells[0]
    #expect(row.count == 12)
    #expect(row[0].text == "a" && row[0].foreground == 0xe6e6e6 && row[0].background == 0x0a0a0b && !row[0].bold)
    #expect(row[1].bold && row[1].italic && row[1].underlined && row[1].foreground == 0xef4444)
    #expect(row[2].foreground == 0x0a0a0b && row[2].background == 0xe6e6e6, "reverse video swaps the colors")
    #expect(row[3].foreground == 0x010203 && row[3].background == 0xff0000)
    #expect(row[4].text == "猫" && !row[4].isContinuation)
    #expect(row[5].text.isEmpty && row[5].isContinuation)
    #expect(row[6].text == "L" && row[6].link == "https://example.com")
    #expect(row[7].link == nil)
  }

  @Test func historyIsReadByScrollingBack() throws {
    let terminal = try #require(HeadlessTerminal(columns: 10, rows: 3))
    terminal.feed((1...8).map { "line \($0)" }.joined(separator: "\r\n"))
    let tail = try #require(terminal.screen())
    #expect(tail.rows == ["line 6", "line 7", "line 8"])
    #expect(tail.historyRows == 5)
    #expect(try #require(terminal.screen(scrolledBack: 2)).rows == ["line 4", "line 5", "line 6"])
    #expect(try #require(terminal.screen(scrolledBack: 99)).rows == ["line 1", "line 2", "line 3"])
    #expect(try #require(terminal.screen()).rows == tail.rows, "reading history does not move the terminal")
  }

  /// zsh sums the width of each code point. With mode 2027 reset the
  /// terminal lays text out the same way, so the two agree on the cursor.
  @Test func textIsLaidOutByClusterOrByCodePoint() throws {
    let woman = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"   // woman, skin tone, joiner, laptop
    let flag = "\u{1F1F3}\u{1F1F4}"
    let cloud = "\u{2601}\u{FE0F}"
    func columns(_ text: String, clustering: Bool, by program: Bool = false) throws -> Int {
      let terminal = try #require(HeadlessTerminal(columns: 40, rows: 3))
      if program {
        terminal.feed(clustering ? "\u{1b}[?2027h" : "\u{1b}[?2027l")
      } else {
        terminal.setGraphemeClustering(clustering)
      }
      terminal.feed(text)
      return try #require(terminal.screen()).cursorColumn
    }
    #expect(try columns(woman, clustering: true) == 2)
    #expect(try columns(woman, clustering: false) == 6, "woman, skin tone and laptop, two columns each")
    #expect(try columns(woman, clustering: false, by: true) == 6)
    #expect(try columns(flag, clustering: true) == 2)
    #expect(try columns(cloud, clustering: true) == 2)
    #expect(try columns(cloud, clustering: false) == 1, "the variation selector has no width")
    #expect(try columns("e\u{301}x", clustering: false) == 2, "a combining mark joins the letter")
    #expect(try columns("a猫b", clustering: false) == 4)

    // The pieces are cells of their own, and the joiner stays with the cell before.
    let terminal = try #require(HeadlessTerminal(columns: 40, rows: 3))
    terminal.setGraphemeClustering(false)
    terminal.feed(woman + "!")
    let row = try #require(terminal.screen()).cells[0]
    #expect(row[0].text == "\u{1F469}" && row[1].isContinuation)
    #expect(row[2].text == "\u{1F3FD}\u{200D}")
    #expect(row[4].text == "\u{1F4BB}")
    #expect(row[6].text == "!")
    // The program turns clustering on; a reset returns to the host's choice.
    terminal.feed("\r\n\u{1b}[?2027h" + woman)
    #expect(try #require(terminal.screen()).cursorColumn == 2)
    terminal.feed("\u{1b}c" + woman)
    #expect(try #require(terminal.screen()).cursorColumn == 6)
  }

  @Test func resizeReflowsAndRejectsNonsense() throws {
    let terminal = try #require(HeadlessTerminal(columns: 10, rows: 4))
    terminal.feed("0123456789abcde")
    #expect(try #require(terminal.screen()).rows.prefix(2) == ["0123456789", "abcde"])
    #expect(terminal.resize(columns: 20, rows: 4))
    #expect(try #require(terminal.screen()).rows.first == "0123456789abcde")
    #expect(!terminal.resize(columns: 0, rows: 4))
    #expect(terminal.columns == 20)
    #expect(HeadlessTerminal(columns: 5000, rows: 4) == nil)
  }

  @Test func theAlternateScreenAndSynchronizedOutputAreVisible() throws {
    let terminal = try #require(HeadlessTerminal(columns: 20, rows: 3))
    terminal.feed("\u{1b}[?1049hfull screen")
    #expect(try #require(terminal.screen()).isAlternateScreen)
    terminal.feed("\u{1b}[?2026hheld")
    #expect(terminal.screen() == nil, "a program holding the display back publishes nothing")
    terminal.feed("\u{1b}[?2026l")
    #expect(try #require(terminal.screen()).rows.first == "full screenheld")
  }
}

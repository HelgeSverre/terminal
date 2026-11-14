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

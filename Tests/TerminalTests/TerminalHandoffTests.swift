import Foundation
import Testing
@testable import TerminalEngine
import TerminalInterop

/// A terminal captured for handoff and restored into a fresh one must be the
/// same terminal to the program writing to it.
@Suite struct TerminalHandoffTests {
  private func terminal(columns: Int = 20, rows: Int = 6) throws -> HeadlessTerminal {
    try #require(HeadlessTerminal(columns: columns, rows: rows))
  }
  private func handedOff(_ source: HeadlessTerminal, columns: Int = 20, rows: Int = 6) throws -> HeadlessTerminal {
    let copy = try terminal(columns: columns, rows: rows)
    #expect(TerminalHandoffBridge.restore(core: copy.core, TerminalHandoffBridge.capture(core: source.core), now: 0))
    return copy
  }
  private func ask(_ terminal: HeadlessTerminal, _ query: String) -> String {
    terminal.feed(query)
    return String(decoding: terminal.takeReplies(), as: UTF8.self)
  }
  private func picture(_ terminal: HeadlessTerminal, scrolledBack: Int = 0) -> String {
    guard let screen = terminal.screen(scrolledBack: scrolledBack) else { return "none" }
    return String(describing: screen.cells) + " cursor \(screen.cursorRow),\(screen.cursorColumn) alt \(screen.isAlternateScreen)"
      + " title \(screen.title) dir \(screen.workingDirectory ?? "") history \(screen.historyRows)"
  }
  /// Every question whose answer depends on state a program may rely on.
  private static let questions = [1, 6, 7, 25, 45, 66, 69, 1000, 1002, 1003, 1004, 1006, 1016, 1049, 2004, 2027, 2031]
    .map { "\u{1b}[?\($0)$p" }.joined()
    + "\u{1b}[4$p\u{1b}[20$p\u{1b}[?u\u{1b}[6n\u{1b}P$qm\u{1b}\\\u{1b}P$qr\u{1b}\\\u{1b}P$qs\u{1b}\\\u{1b}P$q q\u{1b}\\"
    + "\u{1b}]10;?\u{1b}\\\u{1b}]11;?\u{1b}\\\u{1b}]4;3;?\u{1b}\\"

  @Test func historyStylesWrappingAndLinksSurvive() throws {
    let source = try terminal()
    source.feed("\u{1b}]2;work\u{1b}\\\u{1b}]7;file://host/tmp\u{1b}\\")
    for line in 0..<15 { source.feed("\u{1b}[3\(line % 8)mline \(line)\u{1b}[0m\r\n") }
    source.feed("a long line that wraps over the right edge twice at least\r\n")
    source.feed("wide 猫猫 e\u{301} 👩‍👩‍👧 \u{1b}[1;4:3;58;2;1;2;3mcurly\u{1b}[0m\r\n")
    source.feed("\u{1b}[44m\u{1b}[K\u{1b}[5Cgap\u{1b}[0m \u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\\r\n")
    source.feed("\u{1b}[38;5;200mpen stays")
    let copy = try handedOff(source)
    #expect(picture(copy) == picture(source))
    for offset in [3, 9, 14] { #expect(picture(copy, scrolledBack: offset) == picture(source, scrolledBack: offset)) }
    #expect(ask(copy, Self.questions) == ask(source, Self.questions))
    // What the program prints next lands the same way in both.
    for target in [source, copy] { target.feed(" and continues\r\n\ttab\u{1b}[2Dx") }
    #expect(picture(copy) == picture(source))
    #expect(TerminalHandoffBridge.capture(core: copy.core) == TerminalHandoffBridge.capture(core: source.core))
  }

  /// zsh marks a missing final newline by filling the line, wrapping, and
  /// erasing what it wrapped onto: a wrapped row followed by an empty one.
  @Test func aWrappedRowFollowedByAnEmptyOneKeepsItsLineBreak() throws {
    let source = try terminal()
    source.feed("first\r\n" + String(repeating: "x", count: 20) + " \r\u{1b}[K\r\nafter\r\n")
    source.feed(String(repeating: "y", count: 20) + "\u{1b}[45m \r\u{1b}[K\u{1b}[0m\r\nlast")
    for _ in 0..<2 { source.feed("\r\n" + String(repeating: "z", count: 20) + " \r\u{1b}[K\r\nend") }
    let copy = try handedOff(source)
    #expect(picture(copy) == picture(source))
    for offset in [2, 5] { #expect(picture(copy, scrolledBack: offset) == picture(source, scrolledBack: offset)) }
    #expect(copy.screen()?.rows == source.screen()?.rows)
    #expect(TerminalHandoffBridge.capture(core: copy.core) == TerminalHandoffBridge.capture(core: source.core))
  }

  /// One mode at a time, so that a mode carried under another's name, or
  /// not at all, cannot hide behind the rest.
  @Test func eachModeSurvivesByItself() throws {
    let modes = [1, 5, 6, 7, 45, 66, 69, 1000, 1004, 1006, 2004, 2027, 2031].map { "?\($0)" } + ["4", "20"]
    for mode in modes {
      let question = "\u{1b}[\(mode)$p"
      let usual = ask(try terminal(), question)
      let source = try terminal()
      source.feed("\u{1b}[\(mode)h")
      if ask(source, question) == usual { source.feed("\u{1b}[\(mode)l") }
      let changed = ask(source, question)
      #expect(changed != usual, "mode \(mode) cannot be changed, so this proves nothing about it")
      #expect(ask(try handedOff(source), question) == changed, "mode \(mode)")
    }
  }

  @Test func alternateScreenModesAndSavedCursorSurvive() throws {
    let source = try terminal()
    source.feed("shell prompt\r\n$ vim\u{1b}7")
    source.feed("\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?25l\u{1b}[?1002;1006;1004;2004;2031h\u{1b}[>5u\u{1b}[>1u\u{1b}[3 q")
    source.feed("\u{1b}[2;5r\u{1b}[?6h\u{1b}[48;5;236m\u{1b}[2J\u{1b}[1;1Hstatus \u{1b}[7mbar\u{1b}[0m\u{1b}[3;4Htext\u{1b}(0qqq\u{1b}[4h")
    source.feed("\u{1b}]11;rgb:10/20/30\u{1b}\\\u{1b}]4;3;rgb:aa/bb/cc\u{1b}\\\u{1b}[5W\u{1b}[20h")
    let copy = try handedOff(source)
    #expect(picture(copy) == picture(source))
    #expect(ask(copy, Self.questions) == ask(source, Self.questions))
    // The program redraws incrementally, then leaves the alternate screen.
    for target in [source, copy] { target.feed("x\ty\u{1b}[1;1Hz\u{1b}M\u{1b}[<u") }
    #expect(picture(copy) == picture(source))
    #expect(ask(copy, Self.questions) == ask(source, Self.questions))
    for target in [source, copy] { target.feed("\u{1b}[?6l\u{1b}[r\u{1b}[4l\u{1b}(B\u{1b}[?1049l after") }
    #expect(picture(copy) == picture(source))
    #expect(ask(copy, Self.questions) == ask(source, Self.questions))
    #expect(copy.screen()?.rows.first == "shell prompt")
  }

  @Test func aSequenceReadInPartIsNotABoundary() throws {
    let source = try terminal()
    #expect(TerminalHandoffBridge.isAtBoundary(core: source.core))
    for partial in [Data("\u{1b}".utf8), Data("\u{1b}[3".utf8), Data("\u{1b}]2;ti".utf8), Data([0xe7, 0x8c])] {
      source.feed(partial)
      #expect(!TerminalHandoffBridge.isAtBoundary(core: source.core), "\(Array(partial))")
      source.feed("\u{18}\u{1b}\\")
      source.feed("ok")
      #expect(TerminalHandoffBridge.isAtBoundary(core: source.core))
    }
  }

  @Test func rowsSurviveStateThisBuildCannotRead() throws {
    let source = try terminal()
    source.feed("kept\r\n\u{1b}[?1049halt")
    var handoff = TerminalHandoffBridge.capture(core: source.core)
    handoff.state = Data("{\"version\": 99}".utf8)
    let copy = try terminal()
    #expect(!TerminalHandoffBridge.restore(core: copy.core, handoff, now: 0))
    #expect(copy.screen()?.rows.first == "kept" && copy.screen()?.isAlternateScreen == false)
    let other = try terminal(columns: 30, rows: 6)
    #expect(!TerminalHandoffBridge.restore(core: other.core, TerminalHandoffBridge.capture(core: source.core), now: 0))
    #expect(other.screen()?.rows.first == "")
  }
}

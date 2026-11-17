import Foundation
import Testing
@testable import TerminalEngine
import TerminalInterop

/// C05 regressions ported from the failing esctest cases, with additional
/// Unicode and resource-boundary cases that the ASCII checksum suite omits.
@Suite enum TerminalVTSemanticsTests {
  private typealias Oracle = TerminalSemanticRegressionTests
  private static func cursor(_ terminal: OpaquePointer) -> (Int, Int) {
    let value = Oracle.snapshot(terminal)["cursor"] as! [String: Any]
    return (value["row"] as! Int, value["col"] as! Int)
  }
  private static func lines(_ terminal: OpaquePointer, count: Int) -> [String] {
    let value = Oracle.snapshot(terminal)
    return (0..<count).map { Oracle.line(value, $0) }
  }
  private static func prepare(_ terminal: OpaquePointer, _ values: [String]) {
    for (row, text) in values.enumerated() { Oracle.feed(terminal, "\u{1b}[\(row + 1);1H\(text)") }
  }

  @Test static func relativeMovementStopsAtMarginsAndIndexOutsideDoesNotScroll() {
    let terminal = Oracle.make(8, 6); defer { helge_terminal_destroy(terminal) }
    Oracle.feed(terminal, "\u{1b}[?69h\u{1b}[2;6s\u{1b}[2;4r\u{1b}[3;4H\u{1b}[99D")
    #expect(cursor(terminal) == (2, 1))
    Oracle.feed(terminal, "\u{1b}[99C")
    #expect(cursor(terminal) == (2, 5))
    Oracle.feed(terminal, "\u{1b}[4;1H\n")
    #expect(cursor(terminal) == (3, 0))
    Oracle.feed(terminal, "\u{1b}[2;1H\u{1b}M")
    #expect(cursor(terminal) == (1, 0))
    Oracle.feed(terminal, "\u{1b}[3;7H\u{1b}[99C")
    #expect(cursor(terminal) == (2, 7))
  }

  @Test static func selectiveAndISOProtectionAreIndependent() {
    for erase in ["\u{1b}[?2K", "\u{1b}[?2J", "\u{1b}[1;1;1;8${"] {
      let terminal = Oracle.make(); defer { helge_terminal_destroy(terminal) }
      Oracle.feed(terminal, "a\u{1b}[1\"q猫\u{1b}[0\"q\u{1b}Vb\u{1b}W\r\(erase)")
      #expect(lines(terminal, count: 1) == [" 猫      "])
    }
    for erase in ["\u{1b}[2K", "\u{1b}[2J", "\u{1b}[8X"] {
      let terminal = Oracle.make(); defer { helge_terminal_destroy(terminal) }
      Oracle.feed(terminal, "a\u{1b}[1\"q猫\u{1b}[0\"q\u{1b}Vb\u{1b}W\r\(erase)")
      #expect(lines(terminal, count: 1) == ["   b    "])
    }
    // The direct ASCII writer, scalar writer and clustered writer must all
    // carry ISO protection through their independent fast paths.
    let terminal = Oracle.make(40, 2); defer { helge_terminal_destroy(terminal) }
    let protected = "abcdefghijklmnop猫e\u{301}"
    Oracle.feed(terminal, "\u{1b}V\(protected)\u{1b}W\r\u{1b}[2K")
    let value = Oracle.snapshot(terminal)
    #expect(Oracle.cell(value, 0, 16)["text"] as? String == "猫")
    #expect(Oracle.cell(value, 0, 18)["text"] as? String == "e\u{301}")
    #expect(lines(terminal, count: 1)[0].hasPrefix("abcdefghijklmnop"))
  }

  @Test static func eraseSavedLinesPreservesVisiblePage() {
    for erase in ["\u{1b}[3J", "\u{1b}[?3J"] {
      let terminal = Oracle.make(4, 2); defer { helge_terminal_destroy(terminal) }
      Oracle.feed(terminal, "one\r\ntwo\r\nlast")
      let before = lines(terminal, count: 2)
      #expect(Oracle.snapshot(terminal)["history_rows"] as? Int == 1)
      Oracle.feed(terminal, erase)
      #expect(lines(terminal, count: 2) == before)
      #expect(Oracle.snapshot(terminal)["history_rows"] as? Int == 0)
    }
  }

  @Test static func eraseSavedLinesPreservesPinnedViewportIntent() {
    let terminal = Oracle.make(4, 2); defer { helge_terminal_destroy(terminal) }
    Oracle.feed(terminal, "one\r\ntwo\r\nlast")
    helge_terminal_view_scroll(terminal, 1)
    let before = Oracle.snapshot(terminal)
    #expect(before["following_tail"] as? Bool == false)
    Oracle.feed(terminal, "\u{1b}[3J")
    let erased = Oracle.snapshot(terminal)
    #expect(erased["history_rows"] as? Int == 0)
    #expect(erased["following_tail"] as? Bool == false)
    #expect(erased["viewport_clamp_revision"] as? Int == (before["viewport_clamp_revision"] as! Int) + 1)
    #expect(lines(terminal, count: 2) == ["two ", "last"])
    Oracle.feed(terminal, "\r\nnext")
    let later = Oracle.snapshot(terminal)
    #expect(later["following_tail"] as? Bool == false)
    #expect(later["scroll_offset"] as? Int == 1)
    #expect(lines(terminal, count: 2) == ["two ", "last"])
  }

  @Test static func softResetPreservesLiveCursorAndResetsSavedCursor() {
    for (save, restore) in [("\u{1b}7", "\u{1b}8"), ("\u{1b}[s", "\u{1b}[u"), ("\u{1b}[?1048h", "\u{1b}[?1048l")] {
      let terminal = Oracle.make(); defer { helge_terminal_destroy(terminal) }
      Oracle.feed(terminal, "a\(save)\u{1b}[!pb\(restore)c")
      #expect(lines(terminal, count: 1)[0].hasPrefix("cb"))
    }
    let terminal = Oracle.make(); defer { helge_terminal_destroy(terminal) }
    Oracle.feed(terminal, "\u{1b}[1\"q\u{1b}(0\u{1b}7\u{1b}[0\"q\u{1b}(B\u{1b}8q\u{1b}[?2K")
    #expect(lines(terminal, count: 1)[0].hasPrefix("─"))
  }

  @Test static func alternateScreenModesRetainTheirDistinctContracts() {
    let terminal = Oracle.make(); defer { helge_terminal_destroy(terminal) }
    Oracle.feed(terminal, "abc\u{1b}[?47h")
    #expect(cursor(terminal) == (0, 3))
    Oracle.feed(terminal, "ALT\u{1b}[?47l")
    #expect(cursor(terminal) == (0, 6))
    #expect(lines(terminal, count: 1)[0].hasPrefix("abc"))
    Oracle.feed(terminal, "\u{1b}[?1047h")
    #expect(lines(terminal, count: 1)[0].contains("ALT"))
    Oracle.feed(terminal, "\u{1b}[?1047l\u{1b}[?47h")
    #expect(lines(terminal, count: 1) == ["        "])
    Oracle.feed(terminal, "\u{1b}[?47l\u{1b}[2;3H\u{1b}[?1049h\u{1b}[3;5H\u{1b}[?1049l")
    #expect(cursor(terminal) == (1, 2))
  }

  @Test static func rectanglesCopyOverlapsAndIgnoreMarginsUntilOriginMode() {
    let terminal = Oracle.make(8, 8); defer { helge_terminal_destroy(terminal) }
    prepare(terminal, ["abcdefgh", "ijklmnop", "qrstuvwx", "yz012345", "ABCDEFGH", "IJKLMNOP", "QRSTUVWX", "YZ6789!@"])
    Oracle.feed(terminal, "\u{1b}[2;2;4;4;1;3;3;1$v")
    #expect(lines(terminal, count: 5) == ["abcdefgh", "ijklmnop", "qrjklvwx", "yzrst345", "ABz01FGH"])
    Oracle.feed(terminal, "\u{1b}[?69h\u{1b}[3;6s\u{1b}[3;6r\u{1b}[2;4H\u{1b}[37;5;5;7;7$x")
    #expect(cursor(terminal) == (1, 3))
    #expect(lines(terminal, count: 7)[6] == "QRST%%%X")
    Oracle.feed(terminal, "\u{1b}[?6h\u{1b}[1;1;2;2$z\u{1b}[?6l")
    #expect(lines(terminal, count: 4)[2] == "qr  lvwx")
    #expect(lines(terminal, count: 4)[3] == "yz  t345")
  }

  @Test static func rectanglesClipAndRepairWidePairs() {
    let terminal = Oracle.make(4, 3); defer { helge_terminal_destroy(terminal) }
    prepare(terminal, ["猫ab", "c猫d", "efgh"])
    Oracle.feed(terminal, "\u{1b}[1;2;1;3;1;3;1;1$v")
    #expect(lines(terminal, count: 3)[2] == " agh")
    Oracle.feed(terminal, "\u{1b}[37;3;4;999;999$x")
    #expect(lines(terminal, count: 3)[2] == " ag%")
    let before = lines(terminal, count: 3)
    Oracle.feed(terminal, "\u{1b}[37;999;999;999;999$x\u{1b}[3;3;1;1$z")
    #expect(lines(terminal, count: 3) == before)
    Oracle.feed(terminal, "\u{1b}[$z")
    #expect(lines(terminal, count: 3) == Array(repeating: "    ", count: 3))
  }

  @Test static func columnEditsAndHorizontalIndexRespectRectangularMargins() {
    let terminal = Oracle.make(8, 4); defer { helge_terminal_destroy(terminal) }
    prepare(terminal, Array(repeating: "abcdefgh", count: 4))
    Oracle.feed(terminal, "\u{1b}[?69h\u{1b}[2;6s\u{1b}[2;3r\u{1b}[2;3H\u{1b}[2'}")
    #expect(lines(terminal, count: 4) == ["abcdefgh", "ab  cdgh", "ab  cdgh", "abcdefgh"])
    Oracle.feed(terminal, "\u{1b}[2'~")
    #expect(lines(terminal, count: 4) == ["abcdefgh", "abcd  gh", "abcd  gh", "abcdefgh"])
    Oracle.feed(terminal, "\u{1b}[2;2H\u{1b}6")
    #expect(lines(terminal, count: 4)[1] == "a bcd gh")
    Oracle.feed(terminal, "\u{1b}[2;6H\u{1b}9")
    #expect(lines(terminal, count: 4)[1] == "abcd  gh")
    Oracle.feed(terminal, "\u{1b}[2;1H\u{1b}[4294967295'}")
    #expect(lines(terminal, count: 4)[1] == "abcd  gh")
    Oracle.feed(terminal, "\u{1b}[2;2H\u{1b}[4294967295'}")
    #expect(lines(terminal, count: 4) == ["abcdefgh", "a     gh", "a     gh", "abcdefgh"])
  }

  @Test static func reverseWrapModesAndRepeatDefault() {
    let terminal = Oracle.make(8, 4); defer { helge_terminal_destroy(terminal) }
    Oracle.feed(terminal, "\u{1b}[?45habcdefghi\u{8}\u{8}")
    #expect(cursor(terminal) == (0, 7))
    Oracle.feed(terminal, "\u{1b}[1;8HZ\u{8}")
    #expect(cursor(terminal) == (0, 7), "BS consumes deferred wrap before moving")
    Oracle.feed(terminal, "\u{1b}[3;1H\u{8}")
    #expect(cursor(terminal) == (2, 0), "modern reverse wrap only traverses wrapped rows")
    Oracle.feed(terminal, "\u{1b}[?1045h\u{1b}[2;4r\u{1b}[2;1H\u{8}")
    #expect(cursor(terminal) == (3, 7))
    Oracle.feed(terminal, "\u{1b}[2;1H\u{1b}[4294967295D")
    #expect(cursor(terminal) == (2, 1), "huge reverse traversal reduces complete page cycles")
    Oracle.feed(terminal, "\u{1b}[?1045l\u{1b}[?45l\u{1b}[1;1HX\u{1b}[b\u{1b}[0b")
    #expect(lines(terminal, count: 1)[0].hasPrefix("XXX"))
  }

  @Test static func privateModeSaveRestoreAndBackwardTabsIgnoreLeftMargin() {
    let terminal = Oracle.make(24, 3); defer { helge_terminal_destroy(terminal) }
    Oracle.feed(terminal, "\u{1b}[?7l\u{1b}[?7s\u{1b}[?7h\u{1b}[?7r\u{1b}[1;24HXYZ")
    #expect(cursor(terminal) == (0, 23))
    Oracle.feed(terminal, "\u{1b}[?69h\u{1b}[5;10s\u{1b}[1;9H\u{1b}[Z")
    #expect(cursor(terminal) == (0, 0))
    Oracle.feed(terminal, "\u{1b}[2I")
    #expect(cursor(terminal) == (0, 9), "forward tabs stop at the right margin")
  }
}

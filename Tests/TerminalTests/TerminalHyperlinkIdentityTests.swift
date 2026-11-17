import Foundation
import Testing
@testable import TerminalEngine
@testable import TerminalHost
import TerminalInterop

@Suite(.serialized) @MainActor struct TerminalHyperlinkIdentityTests {
  private let uri = "https://example.test/unchanged"
  private func open(_ id: String?, uri: String? = nil) -> String {
    "\u{1b}]8;\(id.map { "id=" + $0 } ?? "");\(uri ?? self.uri)\u{1b}\\"
  }
  private var close: String { "\u{1b}]8;;\u{1b}\\" }

  @Test func adjacentDistinctIDsDoNotMergeAndDestinationStaysUnchanged() throws {
    let core = try #require(helge_terminal_create(12, 3))
    defer { helge_terminal_destroy(core) }
    PresentedContentTests.feed(core, open("first") + "ab" + open("second") + "cd" + close)
    let shown = try SnapshotBridgeTests.check(core)
    #expect(shown.rows[0].cells.prefix(4).map(\.linkID) == ["first", "first", "second", "second"])
    #expect(shown.rows[0].cells.prefix(4).allSatisfy { $0.link == uri })
    let projection = VisibleLinkProjection(snapshot: shown)
    #expect(projection.occurrences.count == 2)
    #expect(projection.occurrence(atGrid: 0)?.gridSegments == [0..<2])
    #expect(projection.occurrence(atGrid: 2)?.gridSegments == [2..<4])
    #expect(projection.occurrence(atGrid: 0)?.linkID == "first")
    #expect(projection.occurrence(atGrid: 2)?.activation?.linkID == "second")
    #expect(projection.occurrences.allSatisfy { $0.target.absoluteString == uri })
    let prior = try #require(projection.occurrence(atGrid: 0)?.activation)
    PresentedContentTests.accepted(core, prior.content, "original link proof")
    // An equal-URI/equal-text rewrite with a different id invalidates the
    // original hover/click target rather than reusing its row proof.
    PresentedContentTests.feed(core, "\u{1b}[1;1H" + open("replacement") + "ab" + close)
    PresentedContentTests.rejected(core, prior.content, .staleTarget, "id-only rewrite")
    let changed = try SnapshotBridgeTests.check(core)
    #expect(VisibleLinkProjection(snapshot: changed).occurrence(atGrid: 0)?.linkID == "replacement")
  }

  @Test func sameIDJoinsWrappedAndDisjointPiecesButDifferentURIsStaySeparate() throws {
    let core = try #require(helge_terminal_create(4, 5))
    defer { helge_terminal_destroy(core) }
    PresentedContentTests.feed(core, open("anchor") + "abcdef" + close + "\r\n--\r\n" + open("anchor") + "gh" + close)
    let shown = try SnapshotBridgeTests.check(core)
    let links = VisibleLinkProjection(snapshot: shown)
    let anchor = try #require(links.occurrence(atGrid: 0))
    #expect(anchor.linkID == "anchor")
    #expect(anchor.gridSegments == [0..<6, 12..<14])
    #expect(anchor.label == "abcdef gh")
    #expect(links.occurrence(atGrid: 12) == anchor)
    let activation = try #require(anchor.activation)
    PresentedContentTests.accepted(core, activation.content, "all pieces share a validated activation")
    PresentedContentTests.feed(core, "\u{1b}[5;1H" + open("anchor", uri: "https://different.test/") + "zz" + close)
    let different = VisibleLinkProjection(snapshot: try SnapshotBridgeTests.check(core))
    #expect(different.occurrences.count == 2)
    #expect(different.occurrence(atGrid: 16)?.target.absoluteString == "https://different.test/")
  }

  @Test func IDsSurviveWideClustersRepeatSaveAndReflowIntoHistory() throws {
    let terminal = try #require(HeadlessTerminal(columns: 6, rows: 2))
    terminal.feed(open("wide") + "猫e\u{301}" + open("other") + "\u{1b}[2b" + close)
    let cells = try #require(terminal.screen()).cells[0]
    #expect(cells.prefix(5).allSatisfy { $0.link == uri && $0.linkID == "wide" })
    #expect(cells[1].isContinuation)
    terminal.feed("\u{1b}c" + open("saved") + "\u{1b}7" + open("changed") + "X\u{1b}8Y" + close)
    #expect(terminal.screen()?.cells[0][0].linkID == "saved")
    terminal.feed("\u{1b}c" + open("history") + "abcdefghijklmnop" + close)
    #expect(terminal.resize(columns: 4, rows: 2))
    let history = try #require(terminal.screen(scrolledBack: 100))
    #expect(history.historyRows > 0)
    #expect(history.cells.flatMap { $0 }.filter { !$0.text.isEmpty }.allSatisfy { $0.linkID == "history" && $0.link == uri })
  }

  @Test func parserBoundsAndCloseDoNotLeakIdentity() throws {
    let terminal = try #require(HeadlessTerminal(columns: 12, rows: 2))
    terminal.feed("\u{1b}]8;ignored=value:id=valid:future=yes;\(uri)\u{1b}\\A" + close + "B")
    terminal.feed(open(String(repeating: "x", count: 257)) + "C" + open("") + "D" + close)
    terminal.feed(open("bad\u{1}id") + "E" + close)
    let cells = try #require(terminal.screen()).cells[0]
    #expect(cells[0].linkID == "valid" && cells[0].link == uri)
    #expect(cells[1].linkID == nil && cells[1].link == nil)
    #expect(cells[2...4].allSatisfy { $0.linkID == nil && $0.link == uri })
  }

  @Test func softResetClearsSavedIdentityAlongWithSavedURI() throws {
    let terminal = try #require(HeadlessTerminal(columns: 12, rows: 2))
    terminal.feed(open("saved") + "\u{1b}7\u{1b}[!p\u{1b}8e\u{301}")
    let cell = try #require(terminal.screen()).cells[0][0]
    #expect(cell.text == "e\u{301}" && cell.link == nil && cell.linkID == nil)
  }

  @Test func promptClearPreservesSavedIdentityProtectionAndCharset() throws {
    let core = try #require(helge_terminal_create(8, 3))
    defer { helge_terminal_destroy(core) }
    PresentedContentTests.feed(core, "\u{1b}(0\u{1b}[1\"q" + open("saved") + "\u{1b}7\u{1b}(B\u{1b}[0\"q" + close + "\u{1b}]133;A\u{1b}\\")
    #expect(helge_terminal_clear_display(core) == 2)
    PresentedContentTests.feed(core, "\u{1b}8q")
    let cell = try SnapshotBridgeTests.check(core).rows[0].cells[0]
    #expect(cell.text == "─", "DECSC's G0 charset survives prompt clearing")
    #expect(cell.flags & 2 != 0, "DECSC's DEC protection survives prompt clearing")
    #expect(cell.link == uri && cell.linkID == "saved")
  }

  @Test func isoProtectionAndIdentitySurviveRepeatAndReflowTogether() throws {
    let core = try #require(helge_terminal_create(8, 3))
    defer { helge_terminal_destroy(core) }
    PresentedContentTests.feed(core, "\u{1b}V" + open("iso") + "X" + close + "\u{1b}W\u{1b}[2b")
    #expect(helge_terminal_resize(core, 4, 3))
    let cells = try SnapshotBridgeTests.check(core).rows[0].cells
    #expect(cells.prefix(3).allSatisfy { $0.flags & 8 != 0 && $0.link == uri && $0.linkID == "iso" })
    PresentedContentTests.feed(core, "\u{1b}[H\u{1b}[2J")
    #expect(try SnapshotBridgeTests.check(core).rows[0].cells.prefix(3).allSatisfy { $0.text == "X" && $0.linkID == "iso" })
  }

  @Test func sparseIdentityBytesAreChargedAndPreservedOnRowCopy() {
    var row = TerminalRow(columns: 4)
    row.setCell(TerminalCell(text: "X", kind: 1, link: uri), at: 0)
    let withoutID = row.retainedStorageCost
    row.setCell(TerminalCell(text: "X", kind: 1, link: uri, linkID: "identity"), at: 0)
    #expect(row.retainedStorageCost == withoutID + 8)
    #expect(row.reflowCellStorage(at: 0).linkBytes == UInt64(uri.utf8.count + 8))
    let original = row
    row.setCell(TerminalCell(text: "X", kind: 1, link: uri, linkID: "replacement"), at: 0)
    #expect(original.cell(0).linkID == "identity" && row.cell(0).linkID == "replacement")
  }
}

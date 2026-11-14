import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalEngine
import TerminalInterop
@testable import TerminalHost
@testable import TerminalUI

/// Owner selection against the core. Serialized: tests pause and drain the process-wide
/// selection retirement queue and word-job worker.
@Suite(.serialized) enum TerminalSelectionTests {
  static func feed(_ core: OpaquePointer, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = helge_terminal_feed(core, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
        #expect(count > 0, "fixture feed progress"); if count <= 0 { return }
        offset += count
      }
    }
  }
  static func snapshot(_ core: OpaquePointer) -> TerminalSnapshot { swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot! }
  static func hit(_ snapshot: TerminalSnapshot, row: Int, column: Int) -> TerminalSelectionHit {
    snapshot.selectionPresentation!.hit(row: row, boundary: column, affinity: .before)!
  }
  static func perform(_ core: OpaquePointer, _ action: TerminalSelectionAction) -> TerminalSelectionProgress {
    finish(core, TerminalSelectionBridge.begin(core: core, action: action))
  }
  static func finish(_ core: OpaquePointer, _ initial: TerminalSelectionProgress) -> TerminalSelectionProgress {
    var result = initial
    var turns = 0
    while case .pending = result {
      turns += 1; #expect(turns < 100_000, "selection made no progress"); if turns >= 100_000 { break }
      // Owner turns cannot bound completion of the asynchronous word worker.
      #expect(TerminalSelection.drainWordJobsForTesting(), "word worker did not finish")
      result = TerminalSelectionBridge.advance(core: core)
    }
    return result
  }
  static func select(_ core: OpaquePointer, _ shown: TerminalSnapshot, _ start: (Int, Int), _ end: (Int, Int), mode: TerminalSelectionMode = .linear) {
    let result = perform(core, .range(start: hit(shown, row: start.0, column: start.1), end: hit(shown, row: end.0, column: end.1), mode: mode))
    guard case .completed = result else { Issue.record("selection rejected: \(result)"); return }
  }
  static func copy(_ core: OpaquePointer) -> String? {
    let revision = snapshot(core).selection.revision
    guard case .completed(let result) = perform(core, .copy(expectedSelectionRevision: revision)) else { return nil }
    return result
  }
  @Test static func emptyGesture() {
    let core = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "a界")
    for column in [0, 5] {
      _ = perform(core, .begin(hit(snapshot(core), row: 0, column: column), granularity: .character))
      _ = perform(core, .commit)
      #expect(snapshot(core).selection.phase == .none, "plain click must leave no committed selection")
    }
    _ = perform(core, .begin(hit(snapshot(core), row: 0, column: 2), granularity: .character))
    _ = perform(core, .commit)
    #expect(copy(core) == "界", "wide continuation click selects its whole cluster")
    select(core, snapshot(core), (0, 4), (0, 4))
    #expect(snapshot(core).selection.phase == .none, "explicit zero-width range is no selection")
    select(core, snapshot(core), (0, 4), (2, 4), mode: .rectangular)
    #expect(snapshot(core).selection.phase == .none, "zero-width rectangle is no selection")
    select(core, snapshot(core), (0, 4), (0, 8))
    #expect(snapshot(core).selection.phase == .committed && copy(core) == "", "nonempty implicit-blank range remains a successful empty copy")
  }
  @Test static func selectedHardRowBoundaries() {
    let core = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "first\r\nnext")
    select(core, snapshot(core), (0, 0), (1, 0))
    #expect(copy(core) == "first\n", "selected trailing hard newline is copied")
    #expect(snapshot(core).selection.segments == [.init(row: 0, start: 0, end: 8), .init(row: 1, start: 0, end: 0)],
      "linear projection retains trailing empty boundary for AX")
    select(core, snapshot(core), (0, 8), (1, 4))
    #expect(copy(core) == "\nnext", "selected leading hard newline is copied")
    #expect(snapshot(core).selection.segments == [.init(row: 0, start: 8, end: 8), .init(row: 1, start: 0, end: 4)],
      "linear projection retains leading empty boundary for AX")
    select(core, snapshot(core), (0, 8), (1, 0))
    #expect(snapshot(core).selection.phase == .committed && copy(core) == "\n", "hard newline alone is nonempty selected content")
    #expect(snapshot(core).selection.segments == [.init(row: 0, start: 8, end: 8), .init(row: 1, start: 0, end: 0)],
      "newline-only projection retains both boundary markers")
    feed(core, "\u{1b}cabcdefghX")
    select(core, snapshot(core), (0, 8), (1, 0))
    #expect(snapshot(core).selection.phase == .none, "soft-wrap boundary alone contains no selected cells or hard separator")
  }
  @Test static func inclusivePointerGesture() {
    let core = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "abcde\r\nABCDE")
    func drag(_ start: (Int, Int), _ end: (Int, Int), _ granularity: TerminalSelectionGranularity = .character) {
      // This fixture checks pointer ranges, not retirement backpressure
      // (which has a dedicated paused-queue control below).
      TerminalSelection.drainRetirementForTesting()
      let begin = perform(core, .begin(hit(snapshot(core), row: start.0, column: start.1), granularity: granularity))
      guard case .completed = begin else { Issue.record("pointer begin: \(begin)"); return }
      let extend = perform(core, .extend(hit(snapshot(core), row: end.0, column: end.1)))
      guard case .completed = extend else { Issue.record("pointer extend: \(extend)"); return }
      let commit = perform(core, .commit)
      guard case .completed = commit else { Issue.record("pointer commit: \(commit)"); return }
    }
    drag((0, 1), (0, 4)); #expect(copy(core) == "bcde", "forward drag includes head cell")
    drag((0, 4), (0, 1)); #expect(copy(core) == "bcde", "reverse drag includes origin cell")
    drag((0, 2), (0, 2)); #expect(copy(core) == "c", "same-cell drag selects one cell")
    drag((0, 0), (1, 4), .rectangular); #expect(copy(core) == "abcde\nABCDE", "rectangle includes upper endpoint column")
    drag((1, 4), (0, 0), .rectangular); #expect(copy(core) == "abcde\nABCDE", "reverse rectangle includes upper endpoint column")
    feed(core, "\u{1b}ca界b")
    drag((0, 0), (0, 2)); #expect(copy(core) == "a界", "forward wide continuation includes whole cluster")
    drag((0, 2), (0, 0)); #expect(copy(core) == "a界", "reverse wide continuation includes whole origin cluster")
    select(core, snapshot(core), (0, 0), (0, 1))
    #expect(copy(core) == "a", "AX range remains exclusive")
  }
  @Test static func historyCaptureAndRetirement() {
    let core = helge_terminal_create(4, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "x")
    let original = snapshot(core)
    _ = perform(core, .begin(hit(original, row: 0, column: 0), granularity: .character))
    feed(core, String(repeating: "\r\nx", count: 49_999))
    let charged = helge_terminal_history_bytes(core)
    let shown = snapshot(core)
    var progress = TerminalSelectionBridge.begin(core: core, action: .extend(hit(shown, row: 2, column: 0)))
    var turns = 0
    while case .pending = progress {
      turns += 1; #expect(turns < 10_000, "large history capture progress"); if turns >= 10_000 { break }
      progress = TerminalSelectionBridge.advance(core: core)
    }
    if case .completed = progress {} else { Issue.record("immutable unseen history interior admitted"); return }
    #expect(turns >= 195, "50k rows captured in bounded owner turns")
    #expect(copy(core) == String(repeating: "x\n", count: 49_999) + "x", "50k history copy is exact")
    #expect(helge_terminal_history_bytes(core) == charged && original.rows[0].cells[0].text == "x", "selection does not alter history accounting or retained snapshot")
    helge_terminal_set_history_limit(core, 0)
    #expect(copy(core) == nil, "selection does not pin 50k rows against eviction")

    TerminalSelection.drainRetirementForTesting()
    TerminalSelection.withRetirementPausedForTesting {
      for _ in 0..<4 { select(core, snapshot(core), (2, 0), (2, 1)) }
      let result = perform(core, .range(start: hit(snapshot(core), row: 2, column: 0), end: hit(snapshot(core), row: 2, column: 1), mode: .linear))
      if case .rejected(.busy) = result {} else { Issue.record("retiring proof storage retains its admission slot"); return }
      #expect(snapshot(core).selection.phase == .committed, "resource rejection preserves the current selection")
    }
    TerminalSelection.drainRetirementForTesting()
    select(core, snapshot(core), (2, 0), (2, 1))
    #expect(copy(core) == "x", "retirement releases admission only after resources are dropped")
  }
  @Test static func alternateCrop() {
    let core = helge_terminal_create(4, 4)!
    defer { helge_terminal_destroy(core) }
    feed(core, "\u{1b}[?47habcdefghij")
    select(core, snapshot(core), (0, 0), (2, 2))
    #expect(copy(core) == "abcdefghij", "alternate soft-chain selection")
    #expect(helge_terminal_resize(core, 4, 2), "alternate height crop")
    #expect(copy(core) == nil, "cropped selected successor invalidates soft-chain selection")
    select(core, snapshot(core), (0, 0), (0, 4))
    #expect(helge_terminal_resize(core, 4, 1), "alternate last-row soft edge crop")
    #expect(copy(core) == "abcd", "edge after final selected row is irrelevant to copy")
  }
  @Test static func oversizedCopyRejectsAtomically() {
    let core = helge_terminal_create(512, 256)!
    defer { helge_terminal_destroy(core) }
    // One admitted cluster reaches the real 64-scalar cap. REP shares its
    // immutable payload; no giant fixture input bypasses parser admission.
    let cluster = "a" + String(repeating: "\u{1ab0}", count: 63)
    #expect(cluster.unicodeScalars.count == 64 && cluster.utf8.count == 190, "capped cluster fixture")
    feed(core, cluster + "\u{1b}[131071b")
    var feedTurns = 0
    while helge_terminal_has_work(core) {
      feedTurns += 1; #expect(feedTurns < 10_000, "resumable REP fixture progress"); if feedTurns >= 10_000 { break }
      _ = helge_terminal_feed(core, nil, 0, 0)
    }
    let filled = snapshot(core)
    #expect(filled.rows[0].cells[0].text == cluster && filled.rows[255].cells[511].text == cluster,
      "REP fills both ends with the capped cluster")
    #expect(512 * 256 * cluster.utf8.count > TerminalSelection.maximumCopyBytes, "fixture exceeds real copy-byte ceiling")
    select(core, filled, (0, 0), (255, 512))
    let selected = snapshot(core)
    var progress = TerminalSelectionBridge.begin(core: core, action: .copy(expectedSelectionRevision: selected.selection.revision))
    var turns = 0
    while case .pending = progress {
      turns += 1; #expect(turns < 10_000, "oversized copy makes bounded progress"); if turns >= 10_000 { break }
      progress = TerminalSelectionBridge.advance(core: core)
    }
    if case .rejected(.limitExceeded) = progress {} else { Issue.record("oversized copy rejects without exposing a partial String"); return }
    #expect(turns >= 44, "copy-byte rejection is reached through bounded cell quanta")
    let rejected = snapshot(core)
    #expect(rejected.selection.phase == .committed && rejected.selection.segments == selected.selection.segments,
      "copy-byte rejection preserves valid selection geometry")
    #expect(rejected.selection.issue == .limitExceeded && rejected.selection.revision > selected.selection.revision,
      "copy-byte rejection publishes its issue")
    TerminalSelection.drainRetirementForTesting()
    TerminalSelection.withRetirementPausedForTesting {
      if case .rejected(.limitExceeded) = perform(core, .copy(expectedSelectionRevision: snapshot(core).selection.revision)) {}
      else { Issue.record("repeated oversized copy reaches byte cap"); return }
      let admission = TerminalSelectionBridge.begin(core: core, action: .copy(expectedSelectionRevision: snapshot(core).selection.revision))
      if case .rejected(.busy) = admission {} else {
        Issue.record("retired copy buffer must retain admission credit until its storage is released"); return
      }
    }
    TerminalSelection.drainRetirementForTesting()
    select(core, rejected, (0, 0), (0, 1))
    #expect(copy(core) == cluster && snapshot(core).selection.issue == nil,
      "rejected copy retires its buffer and releases pending work for recovery")
    TerminalSelection.withRetirementPausedForTesting {
      let first = copy(core), second = copy(core)
      #expect(first == cluster && second == cluster,
        "successful immutable transfer admits sequential copies without waiting for utility retirement")
    }
  }
  @Test static func exactWriteEvidence() {
    let core = helge_terminal_create(12, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "hello world")
    select(core, snapshot(core), (0, 0), (0, 5))
    feed(core, "\u{1b}[1;10HX")
    #expect(copy(core) == "hello", "unrelated same-row write must preserve selected content")
    feed(core, "\u{1b}[1;3Hl")
    #expect(copy(core) == nil, "equal-byte selected overwrite must invalidate")
    select(core, snapshot(core), (0, 0), (0, 2))
    feed(core, "\u{1b}[1;1H\u{1b}[@")
    #expect(copy(core) == nil, "insert/delete shifting selected content must invalidate")
  }
  @Test static func presentedInteriorProof() {
    let core = helge_terminal_create(8, 4)!
    defer { helge_terminal_destroy(core) }
    feed(core, "one\r\ntwo\r\nthree")
    let shown = snapshot(core)
    feed(core, "\u{1b}[2;1HX")
    let result = perform(core, .range(start: hit(shown, row: 0, column: 0), end: hit(shown, row: 2, column: 5), mode: .linear))
    if case .rejected(.staleTarget) = result {} else { Issue.record("stale interior row must not be captured"); return }
    let old = snapshot(core)
    feed(core, "\u{1b}c")
    let stale = perform(core, .begin(hit(old, row: 0, column: 0), granularity: .character))
    if case .rejected(.staleTarget) = stale {} else { Issue.record("RIS row ID reuse must reject old hit"); return }
  }
  @Test static func copyPolicy() {
    let core = helge_terminal_create(6, 4)!
    defer { helge_terminal_destroy(core) }
    feed(core, "ab  \r\nc界d\r\n\u{1b}[8msecret")
    select(core, snapshot(core), (0, 0), (1, 6))
    #expect(copy(core) == "ab  \nc界d", "printed spaces preserved; absent tail trimmed; wide continuation skipped")
    select(core, snapshot(core), (2, 0), (2, 6))
    #expect(copy(core) == "secret", "concealed text remains copyable")
    select(core, snapshot(core), (0, 1), (1, 5), mode: .rectangular)
    #expect(copy(core) == "b   \n界d ", "rectangle padding and whole wide cluster")
    feed(core, "\u{1b}cABCDEFGH")
    select(core, snapshot(core), (0, 0), (1, 2))
    #expect(copy(core) == "ABCDEFGH", "confirmed soft wrap joins without newline")
  }
  @Test static func stableRowsAndScreens() {
    let core = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "selected\r\nnext")
    select(core, snapshot(core), (0, 0), (0, 8))
    feed(core, "\r\nmore\r\nlast")
    #expect(copy(core) == "selected", "selected whole row follows identity into history")
    feed(core, "\u{1b}[?1049hALT")
    #expect(copy(core) == nil, "primary selection hidden on alternate")
    select(core, snapshot(core), (0, 0), (0, 3))
    #expect(copy(core) == "ALT", "alternate owns separate selection")
    feed(core, "\u{1b}[?1049l")
    #expect(copy(core) == "selected", "primary selection returns")
    helge_terminal_set_history_limit(core, 0)
    #expect(copy(core) == nil, "eviction clears endpoint without pinning history")
  }
  @Test static func acceptedCopyAndCancellation() {
    let core = helge_terminal_create(80, 80)!
    defer { helge_terminal_destroy(core) }
    feed(core, String(repeating: "x", count: 79))
    select(core, snapshot(core), (0, 0), (0, 79))
    guard case .completed(let result) = perform(core, .copy(expectedSelectionRevision: snapshot(core).selection.revision)) else {
      Issue.record("accepted copy"); return
    }
    feed(core, "\u{1b}[1;1HY")
    #expect(result == String(repeating: "x", count: 79), "later mutation must not change accepted copy")
    let shown = snapshot(core)
    _ = TerminalSelectionBridge.begin(core: core, action: .range(start: hit(shown, row: 0, column: 0), end: hit(shown, row: 79, column: 80), mode: .linear))
    TerminalSelectionBridge.cancel(core: core)
    if case .rejected(.noSelection) = TerminalSelectionBridge.advance(core: core) {} else { Issue.record("cancel ends pending operation"); return }
  }
  @Test static func reflowSelection() {
    let core = helge_terminal_create(8, 4)!
    defer { helge_terminal_destroy(core) }
    feed(core, "abcdefghijklmnop\r\nend")
    select(core, snapshot(core), (0, 1), (1, 7))
    let original = copy(core)
    #expect(helge_terminal_resize(core, 5, 6), "selection reflow commits")
    #expect(copy(core) == original, "linear selected content survives width reflow")
    #expect(helge_terminal_resize(core, 8, 4), "selection roundtrip commits")
    #expect(copy(core) == original, "linear selected content survives width roundtrip")
    feed(core, "\u{1b}cabcdefghABCDEFGH")
    select(core, snapshot(core), (0, 2), (1, 5), mode: .rectangular)
    #expect(copy(core) == "cde\nCDE", "rectangle before reflow")
    #expect(helge_terminal_resize(core, 16, 4), "rectangle reflow")
    #expect(copy(core) == "cde\nCDE", "rectangle groups survive two disjoint intervals in one output row")
    feed(core, "\u{1b}[1;7Hx")
    #expect(copy(core) == "cde\nCDE", "write between rectangle slices preserves selection")
    feed(core, "\u{1b}[1;12HD")
    #expect(copy(core) == nil, "same-byte overwrite inside second rectangle slice invalidates")
  }
  @Test static func delayedWordWorker() {
    let core = helge_terminal_create(8, 4)!
    defer { helge_terminal_destroy(core) }
    feed(core, "élève/path next")
    var result = TerminalSelectionProgress.pending
    TerminalSelection.withWordJobsPausedForTesting {
      result = TerminalSelectionBridge.begin(core: core,
        action: .begin(hit(snapshot(core), row: 0, column: 2), granularity: .word))
      for _ in 0..<100_000 {
        guard case .pending = result else { Issue.record("word selection completed before worker ran"); return }
        result = TerminalSelectionBridge.advance(core: core)
      }
      guard case .pending = result else { Issue.record("paused word worker must remain pending"); return }
    }
    result = finish(core, result)
    guard case .completed = result else { Issue.record("released word worker must complete selection"); return }
    #expect(copy(core) == "élève/path", "delayed worker preserves Unicode word and soft-wrap boundaries")
  }
  @Test static func wordSelection() {
    let core = helge_terminal_create(8, 4)!
    defer { helge_terminal_destroy(core) }
    feed(core, "élève/path next")
    let shown = snapshot(core)
    guard case .completed = perform(core, .begin(hit(shown, row: 0, column: 2), granularity: .word)) else {
      Issue.record("Unicode word selection"); return
    }
    #expect(copy(core) == "élève/path", "Unicode word boundary + terminal punctuation joins soft wrap")
    feed(core, "\u{1b}cfoo bar")
    guard case .completed = perform(core, .begin(hit(snapshot(core), row: 0, column: 5), granularity: .word)) else {
      Issue.record("word after delimiter"); return
    }
    #expect(copy(core) == "bar", "word delimiter separates tokens")
  }
  @Test static func profileAndPresentedScreen() {
    #expect(TerminalSelectionWordProfile(punctuation: "__--") == TerminalSelectionWordProfile(punctuation: "-_"), "profile canonical set")
    #expect(TerminalSelectionWordProfile(punctuation: "a b") == nil, "profile rejects whitespace")
    #expect(TerminalSelectionWordProfile(punctuation: "\u{7}") == nil, "profile rejects controls")
    #expect(TerminalSelectionWordProfile(punctuation: String(repeating: "x", count: 65)) == nil, "profile scalar bound")
    #expect((try? JSONDecoder().decode(TerminalSelectionWordProfile.self, from: Data("\"a b\"".utf8))) == nil, "decoded profile validated")
    let core = helge_terminal_create(16, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "foo/bar next")
    _ = perform(core, .begin(hit(snapshot(core), row: 0, column: 1), granularity: .word))
    #expect(copy(core) == "foo/bar", "default punctuation profile")
    _ = perform(core, .wordProfile(TerminalSelectionWordProfile(punctuation: "")!))
    _ = perform(core, .extend(hit(snapshot(core), row: 0, column: 1)))
    #expect(copy(core) == "foo/bar", "profile immutable during drag")
    _ = perform(core, .begin(hit(snapshot(core), row: 0, column: 1), granularity: .word))
    #expect(copy(core) == "foo", "new gesture uses configured Unicode boundaries")
    let oldRevision = snapshot(core).selection.revision
    feed(core, "\u{1b}[?47hALT")
    if case .rejected = perform(core, .copy(expectedSelectionRevision: oldRevision)) {} else { Issue.record("delayed copy cannot retarget alternate screen"); return }
  }
  @Test static func resizeCancellationAndWideAffinity() {
    let core = helge_terminal_create(1, 4)!
    defer { helge_terminal_destroy(core) }
    feed(core, "界")
    select(core, snapshot(core), (0, 0), (0, 1))
    _ = TerminalResizeBridge.begin(core: core, columns: 2, rows: 4, cellWidth: 8, cellHeight: 16)
    TerminalResizeBridge.cancel(core: core)
    #expect(copy(core) == "界", "resize cancellation preserves selection watch generation")
    #expect(helge_terminal_resize(core, 2, 4), "clipped-wide selection resize")
    #expect(copy(core) == "界", "clipped-wide selection restored intact")
    let value = snapshot(core)
    #expect(value.cursor.row == 0 && value.cursor.col == 1 && value.cursor.pending_wrap,
      "selection before-affinity must not move pending-wrap cursor after-affinity")
  }
  @Test static func pendingRollbackAndEmptyCopy() {
    let core = helge_terminal_create(16, 512)!
    defer { helge_terminal_destroy(core) }
    feed(core, "saved")
    select(core, snapshot(core), (0, 0), (0, 5))
    let shown = snapshot(core)
    _ = TerminalSelectionBridge.begin(core: core, action: .range(start: hit(shown, row: 0, column: 0), end: hit(shown, row: 511, column: 16), mode: .linear))
    if case .pending = TerminalSelectionBridge.advance(core: core) {} else { Issue.record("capture must yield before all 512 rows"); return }
    #expect(snapshot(core).selection.phase == .committed, "pending capture retains previous published selection")
    TerminalSelectionBridge.cancel(core: core)
    feed(core, "\u{1b}[1;12HX")
    #expect(copy(core) == "saved", "cancel restores original precise observation")
    feed(core, "\u{1b}[1;2Ha")
    #expect(copy(core) == nil, "restored observation still catches equal-byte selected write")

    let blank = helge_terminal_create(1024, 128)!
    defer { helge_terminal_destroy(blank) }
    select(blank, snapshot(blank), (0, 0), (127, 1024))
    var progress = TerminalSelectionBridge.begin(core: blank, action: .copy(expectedSelectionRevision: snapshot(blank).selection.revision))
    var turns = 0
    while case .pending = progress { turns += 1; #expect(turns < 1000, "empty copy progress"); if turns >= 1000 { break }; progress = TerminalSelectionBridge.advance(core: blank) }
    #expect(turns >= 64, "blank trimming and row boundaries must consume bounded work")
    if case .completed(let text) = progress { #expect(text == String(repeating: "\n", count: 127), "empty ordinary rows trim tails but preserve hard boundaries") }
    else { Issue.record("empty copy completion"); return }
  }
}

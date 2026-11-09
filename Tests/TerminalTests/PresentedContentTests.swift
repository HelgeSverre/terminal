import Foundation

@main enum PresentedContentTests {
  static func check(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message)\n".utf8)); exit(1)
    }
  }
  static func feed(_ core: OpaquePointer, _ text: String) {
    Array(text.utf8).withUnsafeBufferPointer { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = terminal_feed(core, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        check(count > 0 || terminal_has_work(core), "feed progress")
        offset += count
      }
    }
    while terminal_has_work(core) { _ = terminal_feed(core, nil, 0, 0) }
  }
  static func snapshot(_ core: OpaquePointer) -> TerminalSnapshot { swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot! }
  static func content(_ snapshot: TerminalSnapshot, _ rows: [(Int, Range<Int>)]) -> TerminalPresentedContent {
    TerminalPresentedContent(presentation: snapshot.selectionPresentation!, rows: rows.map { .init(row: $0.0, columns: $0.1) })
  }
  static func perform(_ core: OpaquePointer, _ content: TerminalPresentedContent) -> TerminalPresentedContentProgress {
    var result = TerminalPresentedContentBridge.begin(core: core, content: content)
    var turns = 0
    while case .pending = result {
      turns += 1; check(turns < 1000, "validation progress")
      result = TerminalPresentedContentBridge.advance(core: core)
    }
    return result
  }
  static func accepted(_ core: OpaquePointer, _ content: TerminalPresentedContent, _ message: String) {
    let result = perform(core, content)
    if case .accepted = result {} else { check(false, "\(message): \(result)") }
  }
  static func rejected(_ core: OpaquePointer, _ content: TerminalPresentedContent,
                       _ expected: TerminalSelectionFailure, _ message: String) {
    let result = perform(core, content)
    if case .rejected(let error) = result { check(error == expected, "\(message): \(error)") }
    else { check(false, "\(message): \(result)") }
  }
  static func withID(_ original: TerminalSelectionPresentation, _ id: UInt64) -> TerminalSelectionPresentation {
    .init(snapshotID: id, documentGeneration: original.documentGeneration, screen: original.screen,
      geometryEpoch: original.geometryEpoch, columns: original.columns, rows: original.rows)
  }
  static func main() {
    stableIdentityAndNoSelectionMutation()
    staleRowsAndInteriors()
    geometryResetAndScreens()
    malformedAndZeroProofs()
    boundedCancellationAndAdmission()
    print("PASS presented content: issued identities, row proofs/order/boundaries, stable history, bounded validation and cancellation")
  }
  static func stableIdentityAndNoSelectionMutation() {
    let core = terminal_create(8, 3)!
    defer { terminal_destroy(core) }
    feed(core, "link\r\nother")
    let shown = snapshot(core)
    let hit = shown.selectionHit(row: 0, boundary: 0)!, end = shown.selectionHit(row: 0, boundary: 4)!
    var selection = TerminalSelectionBridge.begin(core: core, action: .range(start: hit, end: end, mode: .linear))
    while case .pending = selection { selection = TerminalSelectionBridge.advance(core: core) }
    guard case .completed = selection else { check(false, "selection setup"); return }
    let before = snapshot(core)
    accepted(core, content(shown, [(0, 0..<4)]), "old issued snapshot remains valid")
    let after = snapshot(core)
    check(after.selection == before.selection && after.revision == before.revision,
      "read-only validation changes neither selection nor publication revision")
    feed(core, "\r\nmore\r\nlast")
    terminal_view_scroll(core, 1)
    accepted(core, content(shown, [(0, 0..<4)]), "unchanged row follows identity into history despite new output and view scroll")
    terminal_view_follow_tail(core)
    accepted(core, content(shown, [(0, 0..<4)]), "follow-tail change does not stale content")
    terminal_set_history_limit(core, 0)
    rejected(core, content(shown, [(0, 0..<4)]), .evicted, "evicted row cannot activate")
  }
  static func staleRowsAndInteriors() {
    let core = terminal_create(8, 4)!
    defer { terminal_destroy(core) }
    feed(core, "first\r\nmiddle\r\nlast")
    let shown = snapshot(core)
    feed(core, "\u{1b}[4;1HX")
    accepted(core, content(shown, [(0, 0..<5)]), "unrelated output row preserves target")
    feed(core, "\u{1b}[2;1Hm")
    rejected(core, content(shown, [(0, 0..<5), (2, 0..<4)]), .staleTarget,
      "even omitted middle range contributes a presented interior row proof")
    feed(core, "\u{1b}[1;1Hf")
    rejected(core, content(shown, [(0, 0..<5)]), .staleTarget, "equal-byte rewrite invalidates target")
    let ordered = snapshot(core)
    feed(core, "\u{1b}[1;1H\u{1b}[M")
    rejected(core, content(ordered, [(0, 0..<5), (2, 0..<4)]), .evicted, "deleted row identity cannot be rebound")
  }
  static func geometryResetAndScreens() {
    let core = terminal_create(8, 3)!
    defer { terminal_destroy(core) }
    feed(core, "target")
    let shown = snapshot(core)
    feed(core, "\u{1b}[?47hALT")
    rejected(core, content(shown, [(0, 0..<6)]), .staleTarget, "wrong selected screen")
    feed(core, "\u{1b}[?47l")
    accepted(core, content(shown, [(0, 0..<6)]), "unchanged primary identity survives alternate return")
    check(terminal_resize(core, 10, 3), "resize fixture")
    rejected(core, content(shown, [(0, 0..<6)]), .staleTarget, "geometry changed")
    let beforeReset = snapshot(core)
    feed(core, "\u{1b}ctarget")
    rejected(core, content(beforeReset, [(0, 0..<6)]), .staleTarget, "RIS resets identity namespace")
  }
  static func malformedAndZeroProofs() {
    let core = terminal_create(8, 3)!
    defer { terminal_destroy(core) }
    feed(core, "界x")
    let shown = snapshot(core), proof = shown.selectionPresentation!
    check(proof.snapshotID > 0, "issued identity is positive")
    let zero = withID(proof, 0)
    check(zero.hit(row: 0, boundary: 0) == nil, "zero identity is nonactionable at shared factory")
    rejected(core, .init(presentation: zero, rows: [.init(row: 0, columns: 0..<2)]), .staleTarget, "zero identity owner rejection")
    let rawHit = TerminalSelectionHit(presentation: zero, row: 0, boundary: 0, affinity: .before)
    if case .rejected(.staleTarget) = TerminalSelectionBridge.begin(core: core, action: .begin(rawHit, granularity: .character)) {}
    else { check(false, "selection uses the same strict positive identity resolver") }
    rejected(core, .init(presentation: withID(proof, UInt64.max), rows: [.init(row: 0, columns: 0..<2)]), .staleTarget, "unissued future identity")
    accepted(core, content(shown, [(0, 0..<2)]), "whole wide cluster")
    for columns in [(-1)..<2, 0..<9, 0..<0, 1..<2, 0..<1] {
      rejected(core, content(shown, [(0, columns)]), .staleTarget, "invalid or half-wide boundaries")
    }
    rejected(core, content(shown, [(0, 0..<2), (0, 0..<2)]), .staleTarget, "duplicate row ranges")
    rejected(core, content(shown, [(2, 0..<1), (0, 0..<2)]), .staleTarget, "unordered ranges")
    var rows = proof.rows
    rows[0] = .init(id: 0, revision: rows[0].revision)
    let zeroRow = TerminalSelectionPresentation(snapshotID: proof.snapshotID, documentGeneration: proof.documentGeneration,
      screen: proof.screen, geometryEpoch: proof.geometryEpoch, columns: proof.columns, rows: rows)
    rejected(core, .init(presentation: zeroRow, rows: [.init(row: 0, columns: 0..<2)]), .staleTarget, "zero row identity")
    var oversized: [TerminalPresentedContent.RowRange] = []
    oversized.reserveCapacity(30_000); oversized.append(.init(row: 0, columns: 0..<2))
    rejected(core, .init(presentation: proof, rows: oversized), .limitExceeded, "actual retained capacity is bounded even with one row")
    rejected(core, .init(presentation: proof, rows: Array(repeating: .init(row: 0, columns: 0..<2), count: 4097)),
      .limitExceeded, "row proof count bound")
  }
  static func boundedCancellationAndAdmission() {
    let core = terminal_create(4, 512)!
    defer { terminal_destroy(core) }
    let shown = snapshot(core)
    let target = content(shown, [(0, 0..<1), (511, 0..<1)])
    let before = shown.selection
    if case .pending = TerminalPresentedContentBridge.begin(core: core, content: target) {} else { check(false, "bounded begin") }
    for _ in 0..<3 {
      if case .pending = TerminalPresentedContentBridge.advance(core: core) {} else { check(false, "screen index and proofs obey row quantum") }
    }
    if case .rejected(.busy) = TerminalPresentedContentBridge.begin(core: core, content: target) {} else { check(false, "one pending validation") }
    let hit = shown.selectionHit(row: 0, boundary: 0)!
    if case .rejected(.busy) = TerminalSelectionBridge.begin(core: core, action: .begin(hit, granularity: .character)) {} else { check(false, "pending validation cannot overlap a selection operation") }
    TerminalPresentedContentBridge.cancel(core: core)
    if case .rejected(.cancelled) = TerminalPresentedContentBridge.advance(core: core) {} else { check(false, "cancel discards pending work") }
    check(snapshot(core).selection == before, "cancel/busy path leaves selection untouched")
    accepted(core, target, "cancellation releases admission")
    _ = TerminalPresentedContentBridge.begin(core: core, content: target)
    for _ in 0..<3 { _ = TerminalPresentedContentBridge.advance(core: core) }
    feed(core, "X")
    if case .rejected(.staleTarget) = TerminalPresentedContentBridge.advance(core: core) {} else { check(false, "mutation after an earlier proof was checked cannot slip through") }
    let fresh = content(snapshot(core), [(0, 0..<1), (511, 0..<1)])
    _ = TerminalPresentedContentBridge.begin(core: core, content: fresh)
    terminal_set_history_limit(core, 0)
    if case .rejected(.staleTarget) = TerminalPresentedContentBridge.advance(core: core) {} else { check(false, "history configuration mutation also stales stepped validation") }
    let abandoned = terminal_create(4, 512)!
    _ = TerminalPresentedContentBridge.begin(core: abandoned, content: content(snapshot(abandoned), [(0, 0..<1), (511, 0..<1)]))
    terminal_destroy(abandoned) // no worker or row lease may outlive this owner
  }
}

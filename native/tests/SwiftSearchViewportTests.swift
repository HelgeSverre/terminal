import Foundation

@main enum SwiftSearchViewportTests {
  static let stamp = SwiftSearchStamp(document: 1, history: 1, geometry: 1, screen: 1, alternate: false)
  static func row(_ id: UInt64, _ text: String, soft: Bool = false, revision: UInt64 = 0) -> SwiftSearchRow {
    SwiftSearchRow(id: id, revision: revision, cells: text.map { SwiftSearchCell(String($0), .lead1) }, softWrapsToNext: soft)
  }
  static func run(_ task: inout SwiftSearchTask, _ document: SwiftSearchDocument) {
    for _ in 0..<10_000 {
      switch task.fill(from: document.source) {
      case .working: _ = task.step()
      case .needsPage: continue
      case .complete: return
      default: return
      }
    }
    preconditionFailure("search did not finish")
  }
  static func main() throws {
    let joined = SwiftSearchDocument(stamp: stamp, rows: [row(1, "abcd", soft: true), row(2, "EFGH"), row(3, "next")])
    var task = try SwiftSearchTask(query: "dEf", source: joined.source)
    run(&task, joined)
    precondition(task.accept(in: joined.source) == .found(
      anchor: 0,
      spans: [
        SwiftSearchResolvedSpan(row: 0, span: SwiftSearchSpan(proof: SwiftSearchProof(joined.rows[0], softNextID: 2), start: 3, end: 4)),
        SwiftSearchResolvedSpan(row: 1, span: SwiftSearchSpan(proof: SwiftSearchProof(joined.rows[1]), start: 0, end: 2)),
      ]))
    var hard = try SwiftSearchTask(query: "GHnext", source: joined.source)
    run(&hard, joined)
    precondition(hard.accept(in: joined.source) == .missing)
    var newline = try SwiftSearchTask(query: "GH\nnext", source: joined.source)
    run(&newline, joined)
    precondition(newline.found)
    var bareNewline = try SwiftSearchTask(query: "\n", source: joined.source)
    run(&bareNewline, joined)
    precondition(bareNewline.accept(in: joined.source) == .found(
      anchor: 1,
      spans: [SwiftSearchResolvedSpan(row: 1, span: SwiftSearchSpan(
        proof: SwiftSearchProof(joined.rows[1]), start: 4, end: 4))]))

    // Unicode 17 mappings are pinned rather than delegated to Foundation,
    // whose macOS 15 tables do not yet include these scalars.
    let unicode17 = SwiftSearchDocument(stamp: stamp, rows: [row(4, "\u{A7CE}\u{16EA0}")])
    var unicode17Task = try SwiftSearchTask(query: "\u{A7CF}\u{16EBB}", source: unicode17.source)
    run(&unicode17Task, unicode17)
    precondition(unicode17Task.found)

    // A cross-row match has to retain adjacency, not merely prove each row by
    // ID somewhere in the document. An inserted physical row breaks it.
    let across = SwiftSearchDocument(stamp: stamp, rows: [row(10, "A"), row(11, "B")])
    var disconnected = try SwiftSearchTask(query: "A\nB", source: across.source)
    run(&disconnected, across)
    let inserted = SwiftSearchDocument(stamp: stamp, rows: [row(10, "A"), row(12, ""), row(11, "B")])
    precondition(disconnected.accept(in: inserted.source) == .changed)

    // The successor is part of a soft-wrap proof even if the query happens to
    // fit entirely in the first row.
    let softProof = SwiftSearchDocument(stamp: stamp, rows: [row(20, "keep", soft: true), row(21, "next")])
    var relinked = try SwiftSearchTask(query: "keep", source: softProof.source)
    run(&relinked, softProof)
    let newSuccessor = SwiftSearchDocument(stamp: stamp, rows: [row(20, "keep", soft: true), row(22, "next")])
    precondition(relinked.accept(in: newSuccessor.source) == .changed)

    var cancellation = try SwiftSearchTask(query: "abc", source: joined.source)
    cancellation.cancel()
    precondition(cancellation.accept(in: joined.source) == .cancelled)

    var stale = try SwiftSearchTask(query: "abcd", source: joined.source)
    precondition(stale.fill(from: joined.source) == .working)
    _ = stale.step()
    run(&stale, joined)
    let changed = SwiftSearchDocument(
      stamp: stamp,
      rows: [row(1, "abcd", soft: true, revision: 1), row(2, "EFGH"), row(3, "next")])
    precondition(stale.accept(in: changed.source) == .changed)

    let oversized = SwiftSearchDocument(
      stamp: stamp,
      rows: [SwiftSearchRow(id: 9, cells: [SwiftSearchCell(String(repeating: "x", count: 16 * 1024 * 1024), .lead1)])])
    var limited = try SwiftSearchTask(query: "x", source: oversized.source)
    precondition(limited.fill(from: oversized.source) == .resourceLimit)
    print("PASS Swift search: immutable pages, soft/hard rows, cancellation, staleness, limits")
  }
}

import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

@Suite enum HistorySearchTests {
  static let stamp = TerminalSearchStamp(document: 1, history: 1, geometry: 1, screen: 1, alternate: false)
  static func row(_ id: UInt64, _ text: String, soft: Bool = false, revision: UInt64 = 0) -> TerminalSearchRow {
    TerminalSearchRow(id: id, revision: revision, cells: text.map { TerminalSearchCell(String($0), .lead1) }, softWrapsToNext: soft)
  }
  static func run(_ task: inout TerminalSearchTask, _ document: TerminalSearchDocument) {
    for _ in 0..<10_000 {
      switch task.fill(from: document.source) {
      case .working: _ = task.step()
      case .needsPage: continue
      case .complete: return
      default: return
      }
    }
    Issue.record("search did not finish")
  }
  static let joined = TerminalSearchDocument(stamp: stamp, rows: [row(1, "abcd", soft: true), row(2, "EFGH"), row(3, "next")])

  @Test static func softAndHardRows() throws {
    var task = try TerminalSearchTask(query: "dEf", source: joined.source)
    run(&task, joined)
    #expect(task.accept(in: joined.source) == .found(
      matches: [TerminalSearchMatch(anchor: 0, spans: [
        TerminalSearchResolvedSpan(row: 0, span: TerminalSearchSpan(proof: TerminalSearchProof(joined.rows[0], softNextID: 2), start: 3, end: 4)),
        TerminalSearchResolvedSpan(row: 1, span: TerminalSearchSpan(proof: TerminalSearchProof(joined.rows[1]), start: 0, end: 2)),
      ])], capped: false))
    var hard = try TerminalSearchTask(query: "GHnext", source: joined.source)
    run(&hard, joined)
    #expect(hard.accept(in: joined.source) == .missing)
    var newline = try TerminalSearchTask(query: "GH\nnext", source: joined.source)
    run(&newline, joined)
    #expect(newline.found)
    var bareNewline = try TerminalSearchTask(query: "\n", source: joined.source)
    run(&bareNewline, joined)
    #expect(bareNewline.accept(in: joined.source) == .found(
      matches: [TerminalSearchMatch(anchor: 1, spans: [TerminalSearchResolvedSpan(row: 1, span: TerminalSearchSpan(
        proof: TerminalSearchProof(joined.rows[1]), start: 4, end: 4))])], capped: false))
  }

  @Test static func unicode17Mappings() throws {
    // Unicode 17 mappings are pinned rather than delegated to Foundation,
    // whose macOS 15 tables do not yet include these scalars.
    let unicode17 = TerminalSearchDocument(stamp: stamp, rows: [row(4, "\u{A7CE}\u{16EA0}")])
    var unicode17Task = try TerminalSearchTask(query: "\u{A7CF}\u{16EBB}", source: unicode17.source)
    run(&unicode17Task, unicode17)
    #expect(unicode17Task.found)
  }

  @Test static func crossRowAdjacency() throws {
    // A cross-row match has to retain adjacency, not merely prove each row by
    // ID somewhere in the document. An inserted physical row breaks it.
    let across = TerminalSearchDocument(stamp: stamp, rows: [row(10, "A"), row(11, "B")])
    var disconnected = try TerminalSearchTask(query: "A\nB", source: across.source)
    run(&disconnected, across)
    let inserted = TerminalSearchDocument(stamp: stamp, rows: [row(10, "A"), row(12, ""), row(11, "B")])
    #expect(disconnected.accept(in: inserted.source) == .changed)
  }

  @Test static func softWrapSuccessorProof() throws {
    // The successor is part of a soft-wrap proof even if the query happens to
    // fit entirely in the first row.
    let softProof = TerminalSearchDocument(stamp: stamp, rows: [row(20, "keep", soft: true), row(21, "next")])
    var relinked = try TerminalSearchTask(query: "keep", source: softProof.source)
    run(&relinked, softProof)
    let newSuccessor = TerminalSearchDocument(stamp: stamp, rows: [row(20, "keep", soft: true), row(22, "next")])
    #expect(relinked.accept(in: newSuccessor.source) == .changed)
  }

  @Test static func cancellationAndStaleness() throws {
    var cancellation = try TerminalSearchTask(query: "abc", source: joined.source)
    cancellation.cancel()
    #expect(cancellation.accept(in: joined.source) == .cancelled)

    var stale = try TerminalSearchTask(query: "abcd", source: joined.source)
    #expect(stale.fill(from: joined.source) == .working)
    _ = stale.step()
    run(&stale, joined)
    let changed = TerminalSearchDocument(
      stamp: stamp,
      rows: [row(1, "abcd", soft: true, revision: 1), row(2, "EFGH"), row(3, "next")])
    #expect(stale.accept(in: changed.source) == .changed)
  }

  @Test static func resourceLimit() throws {
    let oversized = TerminalSearchDocument(
      stamp: stamp,
      rows: [TerminalSearchRow(id: 9, cells: [TerminalSearchCell(String(repeating: "x", count: 16 * 1024 * 1024), .lead1)])])
    var limited = try TerminalSearchTask(query: "x", source: oversized.source)
    #expect(limited.fill(from: oversized.source) == .resourceLimit)
  }

  @Test static func allMatchesInDocumentOrder() throws {
    // Every match is retained in document order, including several on one row
    // and matches that end inside the same 64-cell step.
    func columns(_ acceptance: TerminalSearchAcceptance) -> [[Int]] {
      guard case .found(let matches, _) = acceptance else { return [] }
      return matches.map { [$0.anchor, $0.spans[0].span.start, $0.spans[0].span.end] }
    }
    let several = TerminalSearchDocument(stamp: stamp, rows: [row(30, "ab ab"), row(31, "none"), row(32, "xAB")])
    var all = try TerminalSearchTask(query: "ab", source: several.source)
    run(&all, several)
    #expect(columns(all.accept(in: several.source)) == [[0, 0, 2], [0, 3, 5], [2, 1, 3]])

    // Matches never overlap, so each is a distinct navigation stop.
    let repeated = TerminalSearchDocument(stamp: stamp, rows: [row(40, "aaaaa")])
    var disjoint = try TerminalSearchTask(query: "aa", source: repeated.source)
    run(&disjoint, repeated)
    #expect(columns(disjoint.accept(in: repeated.source)) == [[0, 0, 2], [0, 2, 4]])

    // A rewritten or evicted row costs only its own matches. Surviving
    // anchors follow the rows to their new positions.
    let partlyStale = TerminalSearchDocument(
      stamp: stamp, rows: [row(31, "none"), row(32, "xAB"), row(33, "ab", revision: 0)])
    #expect(columns(all.accept(in: partlyStale.source)) == [[1, 1, 3]])
    let rewritten = TerminalSearchDocument(
      stamp: stamp, rows: [row(30, "ab ab", revision: 1), row(31, "none"), row(32, "xAB")])
    #expect(columns(all.accept(in: rewritten.source)) == [[2, 1, 3]])
  }

  @Test static func boundedRetention() throws {
    // Retention is bounded: the newest matches survive and the cap is reported.
    let wide = String(repeating: "x", count: 100)
    let floodRows = (0..<250).map { row(UInt64(1_000 + $0), wide) }
    let flood = TerminalSearchDocument(stamp: stamp, rows: floodRows)
    var bounded = try TerminalSearchTask(query: "x", source: flood.source)
    for _ in 0..<100_000 {
      let status = bounded.fill(from: flood.source)
      if status == .working { _ = bounded.step() } else if status != .needsPage { break }
    }
    guard case .found(let retained, let capped) = bounded.accept(in: flood.source) else {
      Issue.record("bounded search found nothing")
      return
    }
    #expect(capped && retained.count == TerminalSearchTask.maxMatches)
    #expect(retained.last?.anchor == 249 && retained.last?.spans[0].span.start == 99)
    #expect(retained.first?.anchor == 150 && retained.first?.spans[0].span.start == 0)
  }
}

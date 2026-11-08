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
    precondition(task.accept(in: joined.source) == .found([
      SwiftSearchHighlight(row: 0, start: 3, end: 4), SwiftSearchHighlight(row: 1, start: 0, end: 2),
    ]))
    var hard = try SwiftSearchTask(query: "GHnext", source: joined.source)
    run(&hard, joined)
    precondition(hard.accept(in: joined.source) == .missing)
    var newline = try SwiftSearchTask(query: "GH\nnext", source: joined.source)
    run(&newline, joined)
    precondition(newline.found)

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

import Foundation

@main enum SwiftSearchViewportTests {
  static let stamp = SwiftSearchStamp(document: 1, history: 1, geometry: 1, screen: 1, alternate: false)
  static func row(_ id: UInt64, _ text: String, soft: Bool = false, revision: UInt64 = 0) -> SwiftSearchRow {
    SwiftSearchRow(id: id, revision: revision, cells: text.map { SwiftSearchCell(String($0), .lead1) }, softWrapsToNext: soft)
  }
  static func run(_ task: inout SwiftSearchTask, _ document: SwiftSearchDocument) {
    for _ in 0..<10_000 {
      switch task.fill(from: document) {
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
    var task = try SwiftSearchTask(query: "dEf", document: joined)
    run(&task, joined)
    precondition(task.accept(in: joined) == .found([
      SwiftSearchHighlight(row: 0, start: 3, end: 4), SwiftSearchHighlight(row: 1, start: 0, end: 2),
    ]))
    var hard = try SwiftSearchTask(query: "GHnext", document: joined)
    run(&hard, joined)
    precondition(hard.accept(in: joined) == .missing)
    var newline = try SwiftSearchTask(query: "GH\nnext", document: joined)
    run(&newline, joined)
    precondition(newline.found)

    var cancellation = try SwiftSearchTask(query: "abc", document: joined)
    cancellation.cancel()
    precondition(cancellation.accept(in: joined) == .cancelled)

    var stale = try SwiftSearchTask(query: "abcd", document: joined)
    precondition(stale.fill(from: joined) == .working)
    _ = stale.step()
    let changed = SwiftSearchDocument(
      stamp: SwiftSearchStamp(document: 2, history: 1, geometry: 1, screen: 1, alternate: false), rows: joined.rows)
    precondition(stale.accept(in: changed) == .changed)

    let oversized = SwiftSearchDocument(
      stamp: stamp,
      rows: [SwiftSearchRow(id: 9, cells: [SwiftSearchCell(String(repeating: "x", count: 16 * 1024 * 1024), .lead1)])])
    var limited = try SwiftSearchTask(query: "x", document: oversized)
    precondition(limited.fill(from: oversized) == .resourceLimit)
    print("PASS Swift search: immutable pages, soft/hard rows, cancellation, staleness, limits")
  }
}

import Foundation
import Testing
@testable import TerminalEngine

@Suite struct SearchOptionsTests {
  private let stamp = TerminalSearchStamp(document: 1, history: 1, geometry: 1, screen: 1, alternate: false)
  private func document(_ rows: [String]) -> TerminalSearchDocument {
    TerminalSearchDocument(stamp: stamp, rows: rows.enumerated().map { index, text in
      TerminalSearchRow(id: UInt64(index + 1), cells: text.map { TerminalSearchCell(String($0), .lead1) })
    })
  }
  private func matches(_ query: String, in document: TerminalSearchDocument,
                       options: TerminalSearchOptions = .init()) throws -> [TerminalSearchMatch] {
    var task = try TerminalSearchTask(query: query, source: document.source, options: options)
    HistorySearchTests.run(&task, document)
    switch task.accept(in: document.source) {
    case .found(let matches, _): return matches
    case .missing: return []
    default: Issue.record("Unexpected search outcome: \(task.accept(in: document.source))"); return []
    }
  }

  @Test func caseAndUnicodeWordBoundaries() throws {
    let rows = document(["Cat cat cat2 _cat 猫cat cat猫 cat! cat"])
    #expect(try matches("cat", in: rows).count == 8)
    #expect(try matches("cat", in: rows, options: .init(caseSensitive: true)).count == 7)
    #expect(try matches("cat", in: rows, options: .init(wholeWord: true)).count == 4)
    #expect(try matches("cat", in: rows, options: .init(caseSensitive: true, wholeWord: true)).count == 3)
  }

  @Test func boundedRegexSyntaxAndShortestNonemptySemantics() throws {
    let rows = document(["abc abbbc ac axc a9c", "ABC", "next"])
    let regex = TerminalSearchOptions(regularExpression: true)
    #expect(try matches("ab*c", in: rows, options: regex).count == 4)
    #expect(try matches("a[b-x]?c", in: rows, options: regex).count == 4)
    #expect(try matches("^abc$", in: rows, options: regex).count == 1)
    #expect(try matches("^abc$", in: rows, options: .init(caseSensitive: true, regularExpression: true)).isEmpty)
    #expect(try matches("a[^0-9]*c", in: rows, options: regex).count == 5)
    #expect(try matches("a+", in: document(["aaa"]), options: regex).count == 3)
    #expect(try matches("a*", in: document(["bbb"]), options: regex).isEmpty, "zero-width matches are not navigation stops")
    #expect(try matches("abc\\nnext", in: document(["ABC", "next"]), options: regex).count == 1)
    #expect(try matches("abc.next", in: document(["ABC", "next"]), options: regex).isEmpty, "dot excludes hard newline")
    for query in ["(", "(a+)+$", "a|b", "a{2}", "[", "[z-a]", "\\w", "a**", String(repeating: "a", count: 257)] {
      #expect(throws: TerminalSearchAdmissionError.query) {
        _ = try TerminalSearchTask(query: query, source: rows.source, options: regex)
      }
    }
  }

  @Test func regexCrossesSoftWrapsWithoutInventingNewlines() throws {
    let rows = TerminalSearchDocument(stamp: stamp, rows: [
      TerminalSearchRow(id: 1, cells: [TerminalSearchCell("a", .lead1)], softWrapsToNext: true),
      TerminalSearchRow(id: 2, cells: [TerminalSearchCell("b", .lead1), TerminalSearchCell("c", .lead1)]),
    ])
    #expect(try matches("^a.c$", in: rows, options: .init(regularExpression: true)).count == 1)
    #expect(try matches("^bc", in: rows, options: .init(regularExpression: true)).isEmpty)
  }

  @Test func wholeWordBoundaryProofRejectsEditsOutsideTheMatch() throws {
    let rows = TerminalSearchDocument(stamp: stamp, rows: [
      TerminalSearchRow(id: 1, cells: [TerminalSearchCell("cat", .lead1)], softWrapsToNext: true),
      TerminalSearchRow(id: 2, cells: [TerminalSearchCell("!", .lead1)]),
    ])
    var task = try TerminalSearchTask(query: "cat", source: rows.source, options: .init(wholeWord: true))
    HistorySearchTests.run(&task, rows)
    #expect(task.found)
    let changed = TerminalSearchDocument(stamp: stamp, rows: [rows.rows[0],
      TerminalSearchRow(id: 2, revision: 1, cells: [TerminalSearchCell("s", .lead1)]),
    ])
    #expect(task.accept(in: changed.source) == .changed)
  }

  @Test func regexMatchWindowAndSingleCellLimitsAreExplicit() throws {
    let rows = document([String(repeating: "a", count: 4097) + "b"])
    var task = try TerminalSearchTask(query: "a+b", source: rows.source, options: .init(regularExpression: true))
    HistorySearchTests.run(&task, rows)
    #expect(task.accept(in: rows.source) == .resourceLimit)
    let cell = TerminalSearchDocument(stamp: stamp, rows: [TerminalSearchRow(id: 1, cells: [TerminalSearchCell(String(repeating: "a", count: 4097), .lead1)])])
    var cellTask = try TerminalSearchTask(query: "a", source: cell.source)
    HistorySearchTests.run(&cellTask, cell)
    #expect(cellTask.accept(in: cell.source) == .resourceLimit)
  }

  @Test func aLongCellCanBeCancelledBetweenScalarSteps() throws {
    let rows = TerminalSearchDocument(stamp: stamp, rows: [TerminalSearchRow(id: 1, cells: [TerminalSearchCell(String(repeating: "a", count: 4096), .lead1)])])
    var task = try TerminalSearchTask(query: "z", source: rows.source, options: .init(regularExpression: true))
    #expect(task.fill(from: rows.source) == .working)
    #expect(task.step() == .working)
    task.cancel()
    #expect(task.step() == .cancelled)
    #expect(task.accept(in: rows.source) == .cancelled)
  }
}

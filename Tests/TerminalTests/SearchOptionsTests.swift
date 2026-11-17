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

  @Test func boundedRegexSyntaxAndLeftmostLongestSemantics() throws {
    let rows = document(["abc abbbc ac axc a9c", "ABC", "next"])
    let regex = TerminalSearchOptions(regularExpression: true)
    #expect(try matches("ab*c", in: rows, options: regex).count == 4)
    #expect(try matches("a[b-x]?c", in: rows, options: regex).count == 4)
    #expect(try matches("^abc$", in: rows, options: regex).count == 1)
    #expect(try matches("^abc$", in: rows, options: .init(caseSensitive: true, regularExpression: true)).isEmpty)
    #expect(try matches("a[^0-9]*c", in: rows, options: regex).count == 2)
    #expect(try matches("a+", in: document(["aaa"]), options: regex).count == 1)
    #expect(try matches("a*", in: document(["bbb"]), options: regex).isEmpty, "zero-width matches are not navigation stops")
    #expect(try matches("abc\\nnext", in: document(["ABC", "next"]), options: regex).count == 1)
    #expect(try matches("abc.next", in: document(["ABC", "next"]), options: regex).isEmpty, "dot excludes hard newline")
    let greedy = try matches("a.*b", in: document(["a1b a2b"]), options: regex)
    #expect(greedy.count == 1)
    #expect(greedy.first?.spans.first?.span.start == 0)
    #expect(greedy.first?.spans.first?.span.end == 7)
    let choice = try matches("(a|ab)+", in: document(["abab"]), options: regex)
    #expect(choice.count == 1)
    #expect(choice.first?.spans.first?.span.end == 4)
    #expect(try matches("(a|b)c", in: document(["ac bc cc"]), options: regex).count == 2)
    #expect(try matches("a.*b|c", in: document(["axxxc"]), options: regex).count == 1,
      "a later hit survives lookahead from an earlier failing start")
    #expect(try matches("a.*b|c", in: document(["acc"]), options: regex).count == 2,
      "lookahead after the first hit is replayed to find the second")
    #expect(try matches("ab|a", in: document(["aba"]), options: regex).count == 2)
    #expect(try matches("a+", in: document(["aaa"]), options: .init(wholeWord: true, regularExpression: true)).count == 1)
    #expect(try matches("(a+)+$", in: document([String(repeating: "a", count: 512) + "!"]), options: regex).isEmpty,
      "nested repetition executes as a finite-state machine")
    for query in ["(", "a|", "()", "a{", "a{,2}", "a{3,2}", "a{0}", "a{2", "^{2}", "a{257}", "[", "[z-a]", "\\q", "[\\d]",
                  "a**", String(repeating: "a", count: 257)] {
      #expect(throws: TerminalSearchAdmissionError.query) {
        _ = try TerminalSearchTask(query: query, source: rows.source, options: regex)
      }
    }
  }

  @Test func literalWholeWordFindsAnOccurrenceOverlappingARejectedOne() throws {
    let whole = TerminalSearchOptions(wholeWord: true)
    let found = try matches("1.1", in: document(["v1.1.1"]), options: whole)
    #expect(found.count == 1)
    #expect(found.first?.spans.first?.span.start == 3 && found.first?.spans.first?.span.end == 6)
    #expect(try matches("1\\.1", in: document(["v1.1.1"]), options: .init(wholeWord: true, regularExpression: true)).count == 1,
      "literal and regex modes agree")
    #expect(try matches("aa", in: document(["aaaa"])).count == 2, "plain matches stay nonoverlapping")
  }

  @Test func wholeWordRegexChecksBothBoundaries() throws {
    let options = TerminalSearchOptions(wholeWord: true, regularExpression: true)
    #expect(try matches("a+", in: document(["baaa"]), options: options).isEmpty)
    #expect(try matches("a+", in: document(["aaab"]), options: options).isEmpty)
    #expect(try matches("a+", in: document(["b aaa b"]), options: options).count == 1)
    let animals = try matches("cat|dog", in: document(["cat cats dog"]), options: options)
    #expect(animals.map { $0.spans.first?.span.start } == [0, 9])
  }

  @Test func caseInsensitiveClassesFoldMembersNotEndpoints() throws {
    let regex = TerminalSearchOptions(regularExpression: true)
    #expect(try matches("[@-Z]", in: document(["@ M m _ ` ["]), options: regex).map { $0.spans.first?.span.start } == [0, 2, 4])
    #expect(try matches("[A-C]+", in: document(["xAbCx"]), options: regex).first?.spans.first?.span.end == 4)
    #expect(try matches("[Z-a]", in: document(["Z ^ a z"]), options: regex).count == 4, "Z, ^, a and the lowercase of Z")
    let sensitive = TerminalSearchOptions(caseSensitive: true, regularExpression: true)
    #expect(try matches("[A-C]+", in: document(["xAbCx"]), options: sensitive).count == 2)
  }

  @Test func shorthandClassesAndCountedRepetition() throws {
    let regex = TerminalSearchOptions(regularExpression: true)
    let rows = document(["id 42 x_1 7777 é!", "a  b"])
    #expect(try matches("\\d+", in: rows, options: regex).map { $0.spans.first?.span.start } == [3, 8, 10])
    #expect(try matches("\\w+", in: rows, options: regex).count == 7)
    #expect(try matches("\\s{2}", in: rows, options: regex).count == 1)
    #expect(try matches("\\S+\\W\\D", in: document(["ab !x"]), options: regex).count == 1)
    #expect(try matches("\\d{4}", in: rows, options: regex).count == 1)
    #expect(try matches("\\d{2,3}", in: rows, options: regex).map { $0.spans.first?.span.end } == [5, 13])
    #expect(try matches("\\d{3,}", in: rows, options: regex).first?.spans.first?.span.end == 14)
    #expect(try matches("(ab){2}", in: document(["ababab"]), options: regex).first?.spans.first?.span.end == 4)
    #expect(try matches("a{0,2}b", in: document(["aaab b"]), options: regex).map { $0.spans.first?.span.start } == [1, 5])
    #expect(try matches("x{1}", in: document(["xx"]), options: regex).count == 2)
    #expect(try matches("a\\{2\\}", in: document(["a{2}"]), options: regex).count == 1, "an escaped brace is literal")
  }

  @Test func regexReplaysLookaheadAcrossRows() throws {
    let regex = TerminalSearchOptions(regularExpression: true)
    let found = try matches("a[^b]*b|c", in: document(["ac", "cc"]), options: regex)
    #expect(found.count == 3)
    #expect(found.map { $0.spans.first { !$0.span.isBoundaryOnly }?.span.proof.id } == [1, 2, 2])
  }

  @Test func historyLengthDoesNotExhaustTheWorkBudget() throws {
    var regex = try BoundedSearchRegex("(error|warn|fatal)", caseSensitive: true)
    let line = Array("2026-11-17 12:00:00 info request served in 12 ms; nothing to warn about here\n".unicodeScalars)
    var position = 0, hits = 0, previousWord = false
    // More scalars than the base allowance alone could pay for.
    while position < 8_000_000 {
      for scalar in line {
        if regex.push(scalar, position: position, previousWord: previousWord, lineStart: false, wholeWord: false) != nil {
          hits += 1; regex.reset()
        }
        previousWord = scalar.isSearchWord
        position += 1
      }
    }
    #expect(!regex.exceeded && !regex.truncated)
    #expect(hits == 8_000_000 / line.count + (8_000_000 % line.count == 0 ? 0 : 1))
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
    // A path longer than the window is dropped and reported as an incomplete
    // result; it does not void the matches that fit.
    let rows = document([String(repeating: "a", count: 4097) + "b c"])
    var task = try TerminalSearchTask(query: "a+b|c", source: rows.source, options: .init(regularExpression: true))
    HistorySearchTests.run(&task, rows)
    guard case .found(let found, let capped) = task.accept(in: rows.source) else {
      Issue.record("expected an incomplete result"); return
    }
    #expect(capped && found.count == 2)
    #expect(found.first?.spans.first?.span.end == 4098 && found.last?.spans.first?.span.start == 4099)
    let unbalanced = document(["say \"" + String(repeating: "x", count: 5000) + " \"ok\""])
    var quoted = try TerminalSearchTask(query: "\"[^\"]*\"", source: unbalanced.source, options: .init(regularExpression: true))
    HistorySearchTests.run(&quoted, unbalanced)
    guard case .found(let strings, true) = quoted.accept(in: unbalanced.source) else {
      Issue.record("an over-long first candidate must not void the search"); return
    }
    #expect(strings.count == 1)
    let cell = TerminalSearchDocument(stamp: stamp, rows: [TerminalSearchRow(id: 1, cells: [TerminalSearchCell(String(repeating: "a", count: 4097), .lead1)])])
    var cellTask = try TerminalSearchTask(query: "a", source: cell.source)
    HistorySearchTests.run(&cellTask, cell)
    #expect(cellTask.accept(in: cell.source) == .resourceLimit)
  }

  @Test func aLongCellCanBeCancelledBetweenScalarSteps() throws {
    let rows = TerminalSearchDocument(stamp: stamp, rows: [TerminalSearchRow(id: 1, cells: [TerminalSearchCell(String(repeating: "a", count: 4096), .lead1)])])
    var task = try TerminalSearchTask(query: "(a+)+$", source: rows.source, options: .init(regularExpression: true))
    #expect(task.fill(from: rows.source) == .working)
    #expect(task.step() == .working)
    task.cancel()
    #expect(task.step() == .cancelled)
    #expect(task.accept(in: rows.source) == .cancelled)
  }
}

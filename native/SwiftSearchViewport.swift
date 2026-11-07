import Foundation

// Immutable owner/worker search seam. The owner supplies a document only to
// `fill`; `step` retains a single value row and may therefore run without the
// terminal or document. Callers cannot tune its memory or work budgets.

enum SwiftSearchCellKind: Equatable {
  case empty, lead1, lead2, continuation, wrapSpacer
}

struct SwiftSearchCell: Equatable {
  var text: String
  var kind: SwiftSearchCellKind
  init(_ text: String = "", _ kind: SwiftSearchCellKind = .empty) {
    self.text = text
    self.kind = kind
  }
  var columnWidth: Int { kind == .lead2 ? 2 : 1 }
  var participates: Bool { kind == .empty || kind == .lead1 || kind == .lead2 }
}

struct SwiftSearchRow: Equatable {
  let id: UInt64
  let revision: UInt64
  let cells: [SwiftSearchCell]
  /// A soft continuation joins the next row without an implicit newline.
  let softWrapsToNext: Bool
  init(id: UInt64, revision: UInt64 = 0, cells: [SwiftSearchCell], softWrapsToNext: Bool = false) {
    self.id = id
    self.revision = revision
    self.cells = cells
    self.softWrapsToNext = softWrapsToNext
  }
  var retainedBytes: Int {
    cells.reduce(0) { $0 + $1.text.utf8.count + MemoryLayout<SwiftSearchCell>.stride }
  }
}

struct SwiftSearchStamp: Equatable {
  let document: UInt64
  let history: UInt64
  let geometry: UInt64
  let screen: UInt64
  let alternate: Bool
  init(document: UInt64, history: UInt64, geometry: UInt64, screen: UInt64, alternate: Bool) {
    self.document = document
    self.history = history
    self.geometry = geometry
    self.screen = screen
    self.alternate = alternate
  }
}

struct SwiftSearchDocument {
  let stamp: SwiftSearchStamp
  let rows: [SwiftSearchRow]
  init(stamp: SwiftSearchStamp, rows: [SwiftSearchRow]) {
    self.stamp = stamp
    self.rows = rows
  }
}

struct SwiftSearchHighlight: Equatable {
  let row: Int
  let start: Int
  let end: Int
}

enum SwiftSearchStatus: Equatable {
  case working, needsPage, complete, changed, resourceLimit, cancelled
}

enum SwiftSearchAdmissionError: Error, Equatable { case query }

enum SwiftSearchAcceptance: Equatable {
  case found([SwiftSearchHighlight])
  case missing
  case changed
  case resourceLimit
  case cancelled
}

private struct SwiftSearchProof: Equatable {
  let id: UInt64
  let revision: UInt64
  let softWrapsToNext: Bool
  init(_ row: SwiftSearchRow) {
    id = row.id
    revision = row.revision
    softWrapsToNext = row.softWrapsToNext
  }
}

private struct SwiftSearchSpan: Equatable {
  let proof: SwiftSearchProof
  var start: Int
  var end: Int
}

private struct SwiftSearchPage {
  let row: SwiftSearchRow
  var column: Int
  let end: Int
  let hardBreak: Bool
}

/// A bounded KMP literal task. It returns only the latest hit, matching the
/// renderer's single-decoration policy while retaining O(query) state.
struct SwiftSearchTask {
  private static let maxQueryBytes = 4_096
  private static let maxRowBytes = 16 * 1024 * 1024
  private static let cellsPerStep = 64

  private let stamp: SwiftSearchStamp
  private let pattern: [Character]
  private let failure: [Int]
  private let stopIndex: Int
  private var nextIndex = 0
  private var page: SwiftSearchPage?
  private var matched = 0
  private var recent: [SwiftSearchSpan] = []
  private var latest: [SwiftSearchSpan]?
  private(set) var status: SwiftSearchStatus = .needsPage

  init(query: String, document: SwiftSearchDocument) throws {
    guard !query.isEmpty, query.utf8.count <= Self.maxQueryBytes else {
      throw SwiftSearchAdmissionError.query
    }
    let folded = Array(query.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")))
    guard !folded.isEmpty else { throw SwiftSearchAdmissionError.query }
    var table = Array(repeating: 0, count: folded.count)
    if folded.count > 1 {
      for index in 1..<folded.count {
        var prefix = table[index - 1]
        while prefix > 0 && folded[index] != folded[prefix] { prefix = table[prefix - 1] }
        if folded[index] == folded[prefix] { prefix += 1 }
        table[index] = prefix
      }
    }
    stamp = document.stamp
    pattern = folded
    failure = table
    stopIndex = document.rows.count - 1
    if document.rows.isEmpty { status = .complete }
  }

  var found: Bool { latest != nil }

  /// Owner-only. It validates all epochs before lending exactly one immutable
  /// row to the worker. New output is never followed past `stopIndex`.
  mutating func fill(from document: SwiftSearchDocument) -> SwiftSearchStatus {
    guard status == .needsPage else { return status }
    guard document.stamp == stamp, nextIndex <= stopIndex, document.rows.indices.contains(nextIndex) else {
      status = .changed
      return status
    }
    let row = document.rows[nextIndex]
    guard row.retainedBytes <= Self.maxRowBytes else {
      status = .resourceLimit
      return status
    }
    let hasNext = nextIndex < stopIndex
    let soft = hasNext && row.softWrapsToNext
    let end: Int
    if soft {
      end = row.cells.count
    } else {
      end = (row.cells.lastIndex { $0.participates && (!$0.text.isEmpty || $0.kind == .empty) }.map { $0 + 1 }) ?? 0
    }
    page = SwiftSearchPage(row: row, column: 0, end: end, hardBreak: hasNext && !soft)
    nextIndex += 1
    status = .working
    return status
  }

  /// Worker-only. It touches no mutable terminal/document state and advances at
  /// most 64 physical cells. The task is safe to continue after owner teardown.
  mutating func step() -> SwiftSearchStatus {
    guard status == .working, var page else { return status }
    let stop = min(page.end, page.column + Self.cellsPerStep)
    var matchEnd: Int?
    while page.column < stop {
      let column = page.column
      let cell = page.row.cells[column]
      page.column += 1
      let span = SwiftSearchSpan(
        proof: SwiftSearchProof(page.row), start: column, end: column + cell.columnWidth)
      if cell.kind == .empty {
        push(" ", span: span, matchEnd: &matchEnd)
      } else if cell.kind == .lead1 || cell.kind == .lead2 {
        for character in fold(cell.text) { push(character, span: span, matchEnd: &matchEnd) }
      }
    }
    if page.column == page.end {
      if page.hardBreak {
        let point = SwiftSearchSpan(proof: SwiftSearchProof(page.row), start: page.end, end: page.end)
        push("\n", span: point, matchEnd: &matchEnd)
      }
      self.page = nil
      status = nextIndex <= stopIndex ? .needsPage : .complete
    } else {
      self.page = page
    }
    if let matchEnd {
      let start = matchEnd - pattern.count
      var spans: [SwiftSearchSpan] = []
      for span in recent[start..<matchEnd] {
        if let index = spans.indices.last, spans[index].proof == span.proof {
          spans[index].start = min(spans[index].start, span.start)
          spans[index].end = max(spans[index].end, span.end)
        } else {
          spans.append(span)
        }
      }
      latest = spans
    }
    if recent.count > pattern.count { recent.removeFirst(recent.count - pattern.count) }
    return status
  }

  mutating func cancel() { status = .cancelled; page = nil; latest = nil; recent.removeAll() }

  /// Owner-only acceptance. It rechecks epochs and per-row proofs, so a stale
  /// worker result can never navigate/highlight unrelated output.
  func accept(in document: SwiftSearchDocument) -> SwiftSearchAcceptance {
    switch status {
    case .changed: return .changed
    case .resourceLimit: return .resourceLimit
    case .cancelled: return .cancelled
    case .working, .needsPage: return .changed
    case .complete: break
    }
    guard document.stamp == stamp else { return .changed }
    guard let latest else { return .missing }
    var highlights: [SwiftSearchHighlight] = []
    for span in latest {
      guard let index = document.rows.firstIndex(where: {
        SwiftSearchProof($0) == span.proof
      }) else { return .changed }
      if span.start < span.end {
        highlights.append(SwiftSearchHighlight(row: index, start: span.start, end: span.end))
      }
    }
    return .found(highlights)
  }

  private func fold(_ text: String) -> [Character] {
    Array(text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")))
  }
  private mutating func push(_ character: Character, span: SwiftSearchSpan, matchEnd: inout Int?) {
    recent.append(span)
    var candidate = matched
    while candidate > 0 && character != pattern[candidate] { candidate = failure[candidate - 1] }
    if character == pattern[candidate] { candidate += 1 }
    if candidate == pattern.count {
      matchEnd = recent.count
      candidate = failure[candidate - 1]
    }
    matched = candidate
  }
}

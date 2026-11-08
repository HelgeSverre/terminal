import Foundation

// Immutable owner/worker search seam. The owner supplies a document only to
// `fill`; `step` retains a single value row and may therefore run without the
// terminal or document. Callers cannot tune its memory or work budgets.

enum TerminalSearchCellKind: Equatable {
  case empty, lead1, lead2, continuation, wrapSpacer
}

struct TerminalSearchCell: Equatable {
  var text: String
  var kind: TerminalSearchCellKind
  /// Only non-default BCE background makes an otherwise blank hard-row cell
  /// searchable. This mirrors the terminal model's trimming contract.
  var hasBackground: Bool
  init(_ text: String = "", _ kind: TerminalSearchCellKind = .empty, hasBackground: Bool = false) {
    self.text = text
    self.kind = kind
    self.hasBackground = hasBackground
  }
  var columnWidth: Int { kind == .lead2 ? 2 : 1 }
  var participates: Bool { kind == .empty || kind == .lead1 || kind == .lead2 }
  var endsHardRow: Bool { kind == .lead1 || kind == .lead2 || hasBackground }
}

struct TerminalSearchRow: Equatable {
  let id: UInt64
  let revision: UInt64
  let cells: [TerminalSearchCell]
  /// A soft continuation joins the next row without an implicit newline.
  let softWrapsToNext: Bool
  init(id: UInt64, revision: UInt64 = 0, cells: [TerminalSearchCell], softWrapsToNext: Bool = false) {
    self.id = id
    self.revision = revision
    self.cells = cells
    self.softWrapsToNext = softWrapsToNext
  }
  var retainedBytes: Int {
    cells.reduce(0) { $0 + $1.text.utf8.count + MemoryLayout<TerminalSearchCell>.stride }
  }
}

struct TerminalSearchStamp: Equatable {
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

struct TerminalSearchDocument {
  let stamp: TerminalSearchStamp
  let rows: [TerminalSearchRow]
  init(stamp: TerminalSearchStamp, rows: [TerminalSearchRow]) {
    self.stamp = stamp
    self.rows = rows
  }
  var source: TerminalSearchSource {
    TerminalSearchSource(
      stamp: stamp, rowCount: rows.count,
      rowAt: { rows.indices.contains($0) ? rows[$0] : nil },
      rowIDAt: { rows.indices.contains($0) ? rows[$0].id : nil },
      proofAt: { index in
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        let successor = row.softWrapsToNext && rows.indices.contains(index + 1) ? rows[index + 1].id : nil
        return TerminalSearchProof(row, softNextID: successor)
      },
      softNextIDAt: { index in
        guard rows.indices.contains(index), rows[index].softWrapsToNext,
              rows.indices.contains(index + 1) else { return nil }
        return rows[index + 1].id
      },
      retainedBytesAt: { rows.indices.contains($0) ? rows[$0].retainedBytes : nil })
  }
}

/// Owner-only access to the live document. The closures must never escape a
/// fill/accept call. A task retains only one converted row page, not this
/// source nor a copy of scrollback.
struct TerminalSearchSource {
  let stamp: TerminalSearchStamp
  let rowCount: Int
  let rowAt: (Int) -> TerminalSearchRow?
  let rowIDAt: (Int) -> UInt64?
  /// Cheap structural proof lookup. Publication and acceptance use this
  /// rather than projecting rich cells for every retained search span.
  let proofAt: (Int) -> TerminalSearchProof?
  /// Physical successor identity for an active soft wrap. This is part of a
  /// search proof: a row that keeps its text but is relinked must not retain a
  /// cross-row match.
  let softNextIDAt: (Int) -> UInt64?
  /// Budget admission runs before a row's rich cell projection is built.
  let retainedBytesAt: (Int) -> Int?
}

struct TerminalSearchHighlight: Equatable {
  let row: Int
  let start: Int
  let end: Int
}

enum TerminalSearchStatus: Equatable {
  case working, needsPage, complete, changed, resourceLimit, cancelled
}

enum TerminalSearchAdmissionError: Error, Equatable { case query }

enum TerminalSearchAcceptance: Equatable {
  /// `anchor` is the first physical source row, including zero-width newline
  /// spans that intentionally have no drawable highlight.
  case found(anchor: Int, spans: [TerminalSearchResolvedSpan])
  case missing
  case working
  case needsPage
  case changed
  case resourceLimit
  case cancelled
}

struct TerminalSearchProof: Equatable {
  let id: UInt64
  let revision: UInt64
  let softNextID: UInt64?
  init(id: UInt64, revision: UInt64, softNextID: UInt64?) {
    self.id = id
    self.revision = revision
    self.softNextID = softNextID
  }
  init(_ row: TerminalSearchRow, softNextID: UInt64? = nil) {
    self.init(id: row.id, revision: row.revision, softNextID: softNextID)
  }
}

struct TerminalSearchSpan: Equatable {
  let proof: TerminalSearchProof
  var start: Int
  var end: Int
}

struct TerminalSearchResolvedSpan: Equatable {
  let row: Int
  let span: TerminalSearchSpan
}

private struct TerminalSearchPage {
  let row: TerminalSearchRow
  let softNextID: UInt64?
  var column: Int
  let end: Int
  let hardBreak: Bool
}

/// A bounded KMP literal task. It returns only the latest hit, matching the
/// renderer's single-decoration policy while retaining O(query) state.
struct TerminalSearchTask {
  private static let maxQueryBytes = 4_096
  private static let maxRowBytes = 16 * 1024 * 1024
  private static let cellsPerStep = 64

  private let stamp: TerminalSearchStamp
  private let pattern: [Unicode.Scalar]
  private let failure: [Int]
  private let stop: UInt64?
  private var next: UInt64?
  private var hint = 0
  private var page: TerminalSearchPage?
  private var matched = 0
  private var recent: [TerminalSearchSpan] = []
  private var latest: [TerminalSearchSpan]?
  private(set) var status: TerminalSearchStatus = .needsPage

  init(query: String, source: TerminalSearchSource) throws {
    guard !query.isEmpty, query.utf8.count <= Self.maxQueryBytes else {
      throw TerminalSearchAdmissionError.query
    }
    let folded = query.unicodeScalars.flatMap(Self.lowercase)
    guard !folded.isEmpty else { throw TerminalSearchAdmissionError.query }
    var table = Array(repeating: 0, count: folded.count)
    if folded.count > 1 {
      for index in 1..<folded.count {
        var prefix = table[index - 1]
        while prefix > 0 && folded[index] != folded[prefix] { prefix = table[prefix - 1] }
        if folded[index] == folded[prefix] { prefix += 1 }
        table[index] = prefix
      }
    }
    stamp = source.stamp
    pattern = folded
    failure = table
    next = source.rowIDAt(0)
    stop = source.rowIDAt(source.rowCount - 1)
    if source.rowCount == 0 { status = .complete }
  }

  var found: Bool { latest != nil }

  /// Owner-only. It validates all epochs before lending exactly one immutable
  /// row to the worker. New output is never followed past `stopIndex`.
  mutating func fill(from source: TerminalSearchSource) -> TerminalSearchStatus {
    guard source.stamp == stamp else {
      status = .changed
      return status
    }
    guard status == .needsPage else { return status }
    guard let next,
          let index = searchIndex(of: next, hint: hint, source: source)
    else {
      status = .changed
      return status
    }
    guard let retainedBytes = source.retainedBytesAt(index) else {
      status = .changed
      return status
    }
    guard retainedBytes <= Self.maxRowBytes else {
      status = .resourceLimit
      return status
    }
    guard let row = source.rowAt(index) else {
      status = .changed
      return status
    }
    let nextID = row.id == stop ? nil : source.rowIDAt(index + 1)
    guard nextID != nil || row.id == stop else {
      status = .changed
      return status
    }
    let hasNext = nextID != nil
    // The task's scan boundary and the row's structural proof are distinct.
    // Output appended after creation may turn the captured final row into a
    // soft predecessor; retain that identity for acceptance but never chase it.
    let actualSoftNext = source.softNextIDAt(index)
    let soft = hasNext && actualSoftNext == nextID
    let end: Int
    if soft {
      end = row.cells.count
    } else {
      end = (row.cells.lastIndex { $0.endsHardRow }.map { $0 + 1 }) ?? 0
    }
    page = TerminalSearchPage(row: row, softNextID: actualSoftNext,
                           column: 0, end: end, hardBreak: hasNext && !soft)
    self.next = nextID
    hint = index + 1
    status = .working
    return status
  }

  /// Worker-only. It touches no mutable terminal/document state and advances at
  /// most 64 physical cells. The task is safe to continue after owner teardown.
  mutating func step() -> TerminalSearchStatus {
    guard status == .working, var page else { return status }
    let stop = min(page.end, page.column + Self.cellsPerStep)
    var matchEnd: Int?
    while page.column < stop {
      let column = page.column
      let cell = page.row.cells[column]
      page.column += 1
      let span = TerminalSearchSpan(
        proof: TerminalSearchProof(page.row, softNextID: page.softNextID), start: column, end: column + cell.columnWidth)
      if cell.kind == .empty {
        push(Unicode.Scalar(0x20)!, span: span, matchEnd: &matchEnd)
      } else if cell.kind == .lead1 || cell.kind == .lead2 {
        for scalar in cell.text.unicodeScalars.flatMap(Self.lowercase) { push(scalar, span: span, matchEnd: &matchEnd) }
      }
    }
    if page.column == page.end {
      if page.hardBreak {
        let point = TerminalSearchSpan(proof: TerminalSearchProof(page.row, softNextID: page.softNextID), start: page.end, end: page.end)
        push(Unicode.Scalar(0x0a)!, span: point, matchEnd: &matchEnd)
      }
      self.page = nil
      status = next == nil ? .complete : .needsPage
    } else {
      self.page = page
    }
    if let matchEnd {
      let start = matchEnd - pattern.count
      var spans: [TerminalSearchSpan] = []
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
  func accept(in source: TerminalSearchSource) -> TerminalSearchAcceptance {
    guard source.stamp == stamp else { return .changed }
    switch status {
    case .changed: return .changed
    case .resourceLimit: return .resourceLimit
    case .cancelled: return .cancelled
    case .working: return .working
    case .needsPage: return .needsPage
    case .complete: break
    }
    guard let latest else { return .missing }
    guard let first = latest.first,
          let firstIndex = searchIndex(of: first.proof.id, hint: 0, source: source)
    else { return .changed }
    var spans: [TerminalSearchResolvedSpan] = []
    for (offset, span) in latest.enumerated() {
      let index = firstIndex + offset
      guard source.rowIDAt(index) == span.proof.id,
            source.proofAt(index) == span.proof
      else { return .changed }
      spans.append(TerminalSearchResolvedSpan(row: index, span: span))
    }
    return .found(anchor: firstIndex, spans: spans)
  }

  private static func lowercase(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
    UnicodeLowercase.lowercase(scalar)
  }
  private func searchIndex(of id: UInt64, hint: Int, source: TerminalSearchSource) -> Int? {
    if source.rowIDAt(hint) == id { return hint }
    for index in 0..<source.rowCount where source.rowIDAt(index) == id { return index }
    return nil
  }
  private mutating func push(_ scalar: Unicode.Scalar, span: TerminalSearchSpan, matchEnd: inout Int?) {
    recent.append(span)
    var candidate = matched
    while candidate > 0 && scalar != pattern[candidate] { candidate = failure[candidate - 1] }
    if scalar == pattern[candidate] { candidate += 1 }
    if candidate == pattern.count {
      matchEnd = recent.count
      candidate = failure[candidate - 1]
    }
    matched = candidate
  }
}

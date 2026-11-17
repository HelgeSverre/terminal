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

/// One accepted match. `anchor` is the first physical source row, including
/// zero-width newline spans that intentionally have no drawable highlight.
struct TerminalSearchMatch: Equatable {
  var anchor: Int
  let spans: [TerminalSearchResolvedSpan]
}

enum TerminalSearchAcceptance: Equatable {
  /// Matches in document order, oldest first. `capped` reports that older
  /// matches beyond the retention bound were discarded.
  case found(matches: [TerminalSearchMatch], capped: Bool)
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
  var scalarOffset: Int
  let end: Int
  let hardBreak: Bool
}

/// Bounded literal KMP or finite-state regex. Retains one row, bounded match
/// proofs, and O(query + maximum regex match length) scan state.
struct TerminalSearchTask {
  static let maxMatches = 10_000
  private static let maxQueryBytes = 4_096
  private static let maxRowBytes = 16 * 1024 * 1024
  private static let cellsPerStep = 64

  private let stamp: TerminalSearchStamp
  private let pattern: [Unicode.Scalar]
  private let failure: [Int]
  private let options: TerminalSearchOptions
  private var regex: BoundedSearchRegex?
  private let stop: UInt64?
  private var next: UInt64?
  private var hint = 0
  private var page: TerminalSearchPage?
  private var matched = 0
  private var position = 0
  private var recentBase = 0
  private var previousWord = false
  private var lineStart = true
  private var candidate: (spans: [TerminalSearchSpan], endAnchored: Bool)?
  private var wordBeforeRecent: [Bool] = []
  private var recent: [TerminalSearchSpan] = []
  private var matches: [[TerminalSearchSpan]] = []
  private var retainedSpanCount = 0
  private var dropped = false
  private(set) var status: TerminalSearchStatus = .needsPage

  init(query: String, source: TerminalSearchSource, options: TerminalSearchOptions = .init()) throws {
    guard !query.isEmpty, query.utf8.count <= Self.maxQueryBytes else {
      throw TerminalSearchAdmissionError.query
    }
    self.options = options
    if options.regularExpression { regex = try BoundedSearchRegex(query, caseSensitive: options.caseSensitive) }
    else { regex = nil }
    let folded = options.caseSensitive ? Array(query.unicodeScalars) : query.unicodeScalars.flatMap(Self.lowercase)
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

  var found: Bool { !matches.isEmpty }

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
                           column: 0, scalarOffset: 0, end: end, hardBreak: hasNext && !soft)
    self.next = nextID
    hint = index + 1
    status = .working
    return status
  }

  /// Worker-only: at most 64 scalars or non-text cells, independent of the
  /// size of a grapheme. No mutable terminal/document access.
  mutating func step() -> TerminalSearchStatus {
    guard status == .working, var page else { return status }
    var budget = Self.cellsPerStep
    while page.column < page.end && budget > 0 {
      let column = page.column
      let cell = page.row.cells[column]
      let span = TerminalSearchSpan(
        proof: TerminalSearchProof(page.row, softNextID: page.softNextID), start: column, end: column + cell.columnWidth)
      guard cell.text.utf8.count <= 4096 else { status = .resourceLimit; self.page = nil; return status }
      let scalars: [Unicode.Scalar]
      if cell.kind == .empty { scalars = [Unicode.Scalar(0x20)!] }
      else if cell.kind == .lead1 || cell.kind == .lead2 {
        scalars = options.caseSensitive ? Array(cell.text.unicodeScalars) : cell.text.unicodeScalars.flatMap(Self.lowercase)
      } else { scalars = [] }
      if scalars.isEmpty { budget -= 1 }
      while page.scalarOffset < scalars.count && budget > 0 {
        push(scalars[page.scalarOffset], span: span)
        page.scalarOffset += 1
        budget -= 1
        if status == .resourceLimit { self.page = nil; return status }
      }
      if page.scalarOffset == scalars.count { page.column += 1; page.scalarOffset = 0 }
    }
    if page.column == page.end && (!page.hardBreak || budget > 0) {
      if page.hardBreak {
        let point = TerminalSearchSpan(proof: TerminalSearchProof(page.row, softNextID: page.softNextID), start: page.end, end: page.end)
        push(Unicode.Scalar(0x0a)!, span: point)
      }
      self.page = nil
      if status != .resourceLimit {
        status = next == nil ? .complete : .needsPage
        if status == .complete { finishCandidate(next: nil) }
      }
    } else { self.page = page }
    if matches.count >= 2 * Self.maxMatches {
      let remove = matches.count - Self.maxMatches
      retainedSpanCount -= matches.prefix(remove).reduce(0) { $0 + $1.count }
      matches.removeFirst(remove)
      dropped = true
    }
    return status
  }

  mutating func cancel() {
    status = .cancelled; page = nil; matches.removeAll(); recent.removeAll()
    wordBeforeRecent.removeAll(); candidate = nil; regex?.reset()
  }

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
    guard !matches.isEmpty else { return .missing }
    let kept = matches.suffix(Self.maxMatches)
    // One pass over the source resolves every retained first row. A match
    // whose rows were evicted, relinked or rewritten since its page was lent
    // is dropped on its own; the remaining matches stay navigable.
    var anchors = Dictionary(kept.map { ($0[0].proof.id, -1) }, uniquingKeysWith: { first, _ in first })
    var unresolved = anchors.count
    var index = 0
    while unresolved > 0 && index < source.rowCount {
      if let id = source.rowIDAt(index), anchors[id] == -1 {
        anchors[id] = index
        unresolved -= 1
      }
      index += 1
    }
    var accepted: [TerminalSearchMatch] = []
    accepted.reserveCapacity(kept.count)
    for match in kept {
      guard let first = anchors[match[0].proof.id], first >= 0 else { continue }
      var spans: [TerminalSearchResolvedSpan] = []
      for (offset, span) in match.enumerated() {
        let row = first + offset
        guard source.rowIDAt(row) == span.proof.id, source.proofAt(row) == span.proof else { break }
        spans.append(TerminalSearchResolvedSpan(row: row, span: span))
      }
      if spans.count == match.count { accepted.append(TerminalSearchMatch(anchor: first, spans: spans)) }
    }
    guard !accepted.isEmpty else { return .changed }
    return .found(matches: accepted, capped: dropped || matches.count > kept.count)
  }

  private static func lowercase(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
    UnicodeLowercase.lowercase(scalar)
  }
  private func searchIndex(of id: UInt64, hint: Int, source: TerminalSearchSource) -> Int? {
    if source.rowIDAt(hint) == id { return hint }
    for index in 0..<source.rowCount where source.rowIDAt(index) == id { return index }
    return nil
  }
  private mutating func storeMatch(_ spans: [TerminalSearchSpan]) {
    // Match count alone does not bound multi-row proof storage.
    guard retainedSpanCount + spans.count <= 65_536 else { status = .resourceLimit; return }
    matches.append(spans)
    retainedSpanCount += spans.count
  }

  private static func word(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
      || scalar.properties.generalCategory == .nonspacingMark
      || scalar.properties.generalCategory == .spacingMark
      || scalar.properties.generalCategory == .enclosingMark
  }

  private mutating func finishCandidate(next: Unicode.Scalar?, span: TerminalSearchSpan? = nil) {
    guard let candidate else { return }
    self.candidate = nil
    if options.wholeWord, let next, Self.word(next) { return }
    if candidate.endAnchored, let next, next != "\n" { return }
    var spans = candidate.spans
    if let span, spans.last?.proof != span.proof {
      spans.append(TerminalSearchSpan(proof: span.proof, start: span.start, end: span.start))
    }
    storeMatch(spans)
    matched = 0
    regex?.reset()
  }

  private mutating func push(_ scalar: Unicode.Scalar, span: TerminalSearchSpan) {
    finishCandidate(next: scalar, span: span)
    if status == .resourceLimit { return }
    wordBeforeRecent.append(previousWord)
    recent.append(span)
    let range: Range<Int>?
    let endAnchored: Bool
    if regex != nil {
      range = regex!.push(scalar, position: position, canStart: !options.wholeWord || !previousWord, lineStart: lineStart)
      endAnchored = regex!.endAnchored
      if regex!.exceeded { status = .resourceLimit; return }
    } else {
      var count = matched
      while count > 0 && scalar != pattern[count] { count = failure[count - 1] }
      if scalar == pattern[count] { count += 1 }
      if count == pattern.count {
        range = (position + 1 - pattern.count)..<(position + 1)
        count = 0
      } else { range = nil }
      matched = count
      endAnchored = false
    }
    if let range {
      let start = range.lowerBound - recentBase
      if start >= 0, (!options.wholeWord || !wordBeforeRecent[start]) {
        var spans: [TerminalSearchSpan] = []
        if (options.wholeWord || regex?.startAnchored == true), start > 0,
           recent[start - 1].proof != recent[start].proof {
          let before = recent[start - 1]
          spans.append(TerminalSearchSpan(proof: before.proof, start: before.end, end: before.end))
        }
        for span in recent[start...] {
          if let index = spans.indices.last, spans[index].proof == span.proof {
            spans[index].start = min(spans[index].start, span.start)
            spans[index].end = max(spans[index].end, span.end)
          } else { spans.append(span) }
        }
        if options.wholeWord || endAnchored { candidate = (spans, endAnchored) }
        else { storeMatch(spans); regex?.reset() }
      }
    }
    previousWord = Self.word(scalar)
    lineStart = scalar == "\n"
    position += 1
    let limit = (regex == nil ? pattern.count : BoundedSearchRegex.maxMatchScalars) + 1
    if recent.count > 2 * limit {
      let remove = recent.count - limit
      recent.removeFirst(remove)
      wordBeforeRecent.removeFirst(remove)
      recentBase += remove
    }
  }
}

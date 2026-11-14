import Foundation

// Selection is owner-lane state. The host sends a hit from the displayed
// snapshot, never an index to reinterpret against the current viewport.
package enum TerminalSelectionAction {
  case begin(TerminalSelectionHit, granularity: TerminalSelectionGranularity)
  case extend(TerminalSelectionHit)
  case commit
  case clear
  case range(start: TerminalSelectionHit, end: TerminalSelectionHit, mode: TerminalSelectionMode)
  case copy(expectedSelectionRevision: UInt64)
  case wordProfile(TerminalSelectionWordProfile)
}
package enum TerminalSelectionProgress {
  case pending
  // nil means no copy was requested. An empty string is a successful copy.
  case completed(copiedText: String?)
  case rejected(TerminalSelectionFailure)
}

extension TerminalDocument {
  mutating func observeSelection(at index: Int, screen: TerminalSelectionScreen, observation: TerminalRow.SelectionObservation?) {
    if screen == .alternate { alternate.rows[index].selectionObservation = observation }
    else if index >= history.count { primary.rows[index - history.count].selectionObservation = observation }
  }
}

final class TerminalSelection {
  // Explicit resource admission, not silent truncation. No selected row/cell
  // references remain pinned after an owner turn.
  static let maximumRows = 65_536
  static let maximumCopyBytes = 16 * 1024 * 1024
  // At most two published screen states, one replacement and one retiring
  // generation may own proof containers. A fast stream of replaced gestures
  // cannot outrun off-owner destruction and build an unbounded retire queue.
  private final class ProofSlots {
    let semaphore = DispatchSemaphore(value: 4)
    func acquire() -> ProofSlot? { semaphore.wait(timeout: .now()) == .success ? ProofSlot(self) : nil }
  }
  private final class ProofSlot {
    let owner: ProofSlots
    init(_ owner: ProofSlots) { self.owner = owner }
    deinit { owner.semaphore.signal() }
  }
  // A failed or cancelled copy may still own its buffer on the retirement
  // queue. Hold admission through that release, not merely through completion.
  private final class CopyBufferLease {
    private let credit: DispatchSemaphore
    init?(_ credit: DispatchSemaphore) {
      guard credit.wait(timeout: .now()) == .success else { return nil }
      self.credit = credit
    }
    deinit { credit.signal() }
  }
  private static let retirement = DispatchQueue(label: "terminal.selection.retirement", qos: .utility)
  // Owner-side test synchronization only; production word work remains asynchronous.
  static func drainWordJobsForTesting() -> Bool { TerminalWordCapture.drainJobsForTesting() }
  static func withWordJobsPausedForTesting(_ body: () -> Void) { TerminalWordCapture.withJobsPausedForTesting(body) }
  static func drainRetirementForTesting() { retirement.sync {} }
  static func withRetirementPausedForTesting(_ body: () -> Void) {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    retirement.async { entered.signal(); resume.wait() }
    entered.wait(); defer { resume.signal() }
    body()
  }
  private let proofSlots = ProofSlots()
  private let copyBufferCredit = DispatchSemaphore(value: 1)
  private final class State {
    var proofSlot: ProofSlot?
    let generation: UInt64
    let screen: TerminalSelectionScreen
    var origin: TerminalSelectionHit
    var head: TerminalSelectionHit
    let granularity: TerminalSelectionGranularity
    let mode: TerminalSelectionMode
    let wordProfile: TerminalSelectionWordProfile
    var phase: TerminalSelectionSnapshot.Phase
    var hasSelectedContent = false
    var content = TerminalSelectionContent()
    init(generation: UInt64, origin: TerminalSelectionHit, head: TerminalSelectionHit,
         granularity: TerminalSelectionGranularity, mode: TerminalSelectionMode,
         phase: TerminalSelectionSnapshot.Phase, proofSlot: ProofSlot, wordProfile: TerminalSelectionWordProfile) {
      self.proofSlot = proofSlot
      self.generation = generation; screen = origin.screen; self.origin = origin; self.head = head
      self.granularity = granularity; self.mode = mode; self.phase = phase
      self.wordProfile = wordProfile
    }
    func releaseResources() {
      content = TerminalSelectionContent()
      let presentation = TerminalSelectionPresentation(snapshotID: 0, documentGeneration: UUID(),
        screen: screen, geometryEpoch: 0, columns: 1, rows: [])
      let empty = TerminalSelectionHit(presentation: presentation, row: 0, boundary: 0, affinity: .before)
      origin = empty; head = empty
      proofSlot = nil
    }
  }
  private final class Pending {
    enum Work { case capture, copy }
    let work: Work
    let state: State
    var first: Int
    var last: Int
    var lowerColumn: Int
    var upperColumn: Int
    let presented: [UInt64: TerminalSelectionPresentation.Row]
    let presentedPositions: [Int: UInt64]
    let previous: State?
    var next: Int
    var copyIndex = 0
    var copyColumn = 0
    var copyEnd: Int?
    var text = ""
    var copyBufferLease: CopyBufferLease?
    var wordFirst: TerminalWordCapture?
    var wordLast: TerminalWordCapture?
    var expandedFirst: ClosedRange<Int>?
    var expandedLast: ClosedRange<Int>?
    var rollbackRows: [(UInt64, TerminalRow.SelectionObservation?)] = []
    init(state: State, first: Int, last: Int, lower: Int, upper: Int, presented: [UInt64: TerminalSelectionPresentation.Row], positions: [Int: UInt64], previous: State?) {
      work = .capture; self.state = state; self.first = first; self.last = last
      lowerColumn = lower; upperColumn = upper; next = first
      self.presented = presented; self.presentedPositions = positions; self.previous = previous
    }
    init(copy state: State, lease: CopyBufferLease) {
      work = .copy; self.state = state; first = 0; last = 0; lowerColumn = 0; upperColumn = 0; next = 0; presented = [:]; presentedPositions = [:]; previous = nil
      copyBufferLease = lease
    }
  }
  private var primary: State?
  private var alternate: State?
  private var pending: Pending?
  private var generation: UInt64 = 0
  private(set) var revision: UInt64 = 0
  private var presentedScreen: TerminalSelectionScreen?
  private var issue: TerminalSelectionFailure?
  // Terminal-oriented punctuation extends Unicode word runs. The profile is
  // value configuration owned here, never a predicate supplied per gesture.
  private var wordProfile = TerminalSelectionWordProfile.standard

  private func state(_ screen: TerminalSelectionScreen) -> State? { screen == .primary ? primary : alternate }
  private func assign(_ value: State?, screen: TerminalSelectionScreen) {
    if screen == .primary { primary = value } else { alternate = value }
  }
  private func retire(_ state: State?) {
    guard let state else { return }
    Self.retirement.async { state.releaseResources() }
  }
  private func retirePending(_ work: Pending, discarded: Bool = false, retirePrevious: Bool = true) {
    work.wordFirst?.cancel(); work.wordLast?.cancel()
    Self.retirement.async {
      work.wordFirst?.releaseResources(); work.wordLast?.releaseResources()
      work.wordFirst = nil; work.wordLast = nil; work.text = ""
      work.copyBufferLease = nil
      work.rollbackRows.removeAll()
      if work.work == .capture {
        if retirePrevious { work.previous?.releaseResources() }
        if discarded { work.state.releaseResources() }
      }
    }
  }
  func reset() {
    if let work = pending {
      pending = nil; retirePending(work, discarded: true, retirePrevious: false)
    }
    retire(primary); retire(alternate); primary = nil; alternate = nil
    revision &+= 1; issue = .staleTarget
  }
  func cancel(in document: inout TerminalDocument, preservePrevious: Bool = true) {
    guard let work = pending else { return }
    pending = nil
    if work.work == .capture {
      if preservePrevious {
        let lookup = TerminalSelectionLookup(document)
        for (id, observation) in work.rollbackRows {
          if let index = lookup.index(id, screen: work.state.screen, in: document) {
            document.observeSelection(at: index, screen: work.state.screen, observation: observation)
          }
        }
      } else { assign(nil, screen: work.state.screen); revision &+= 1; issue = .staleTarget }
    }
    retirePending(work, discarded: true, retirePrevious: !preservePrevious)
  }
  deinit { reset() }
  private func clear(_ screen: TerminalSelectionScreen, reason: TerminalSelectionFailure? = nil) {
    retire(state(screen))
    assign(nil, screen: screen); revision &+= 1; issue = reason
  }
  func snapshot(screen: TerminalSelectionScreen, rows: [TerminalRow]) -> TerminalSelectionSnapshot {
    if presentedScreen != screen { presentedScreen = screen; revision &+= 1 }
    guard let selected = state(screen) else { return TerminalSelectionSnapshot(revision: revision, issue: issue) }
    var result = TerminalSelectionSnapshot(revision: revision, phase: selected.phase, mode: selected.mode, issue: issue)
    for (rowIndex, row) in rows.enumerated() {
      if let index = selected.content.byRow[row.id] {
        // Empty linear endpoint spans carry a selected hard newline into
        // the bounded AX projection; they do not paint any renderer cells.
        for span in selected.content.spans[index] where selected.mode == .linear || !span.columns.isEmpty {
          if let last = result.segments.last, last.row == rowIndex, last.end >= span.columns.lowerBound {
            result.segments[result.segments.count - 1] = .init(row: rowIndex, start: last.start, end: max(last.end, span.columns.upperBound))
          } else {
            result.segments.append(.init(row: rowIndex, start: span.columns.lowerBound, end: span.columns.upperBound))
          }
        }
      }
    }
    return result
  }
  func report(_ failure: TerminalSelectionFailure) { issue = failure; revision &+= 1 }
  // All mutable-at-capture rows are bounded by the active grid. Historical
  // rows cannot be edited; FIFO eviction is proven by the first/last IDs and
  // span count. Deletion/reordering inside active rows is checked separately.
  @discardableResult func validate(in document: TerminalDocument, lookup: TerminalSelectionLookup) -> Bool {
    var valid = true
    for screen in [TerminalSelectionScreen.primary, .alternate] {
      guard let selected = state(screen), let first = selected.content.spans.first, let last = selected.content.spans.last else { continue }
      guard let start = lookup.index(first.rowID, screen: screen, in: document),
            let end = lookup.index(last.rowID, screen: screen, in: document),
            end - start == last.sourceOrdinal - first.sourceOrdinal else {
        clear(screen, reason: .evicted); valid = false; continue
      }
      for (rowID, ordinal) in selected.content.mutableRows {
        guard let index = lookup.index(rowID, screen: screen, in: document), index == start + ordinal - first.sourceOrdinal else {
          clear(screen, reason: .changedContent); valid = false; break
        }
        let row = document.selectionRow(at: index, screen: screen)
        guard let observation = row.selectionObservation, observation.generation == selected.generation,
              !observation.overwritten else {
          clear(screen, reason: .changedContent); valid = false; break
        }
        if selected.mode == .linear && ordinal < last.sourceOrdinal {
          if observation.changedSoftEdge { clear(screen, reason: .changedContent); valid = false; break }
          let nextID = document.selectionRow(at: index + 1, screen: screen).id
          let span = selected.content.spans[selected.content.byRow[rowID]!.upperBound - 1]
          if (row.softWrapped ? nextID : nil) != span.softNextID {
            clear(screen, reason: .changedContent); valid = false; break
          }
        }
      }
    }
    return valid
  }
  func begin(_ action: TerminalSelectionAction, in document: inout TerminalDocument,
             screen: TerminalSelectionScreen, documentGeneration: UUID, geometryEpoch: UInt64,
             snapshotID: UInt64) -> TerminalSelectionFailure? {
    guard pending == nil else { return .busy }
    let lookup = TerminalSelectionLookup(document)
    validate(in: document, lookup: lookup)
    issue = nil
    switch action {
    case .wordProfile(let profile): wordProfile = profile; return nil
    case .clear: clear(screen); return nil
    case .commit:
      guard let selected = state(screen) else { return .noSelection }
      guard selected.hasSelectedContent else { clear(screen); return nil }
      selected.phase = .committed; revision &+= 1; return nil
    case .copy(let expected):
      guard presentedScreen == screen, expected == revision, let selected = state(screen), !selected.content.spans.isEmpty else { return .noSelection }
      guard let lease = CopyBufferLease(copyBufferCredit) else { return .busy }
      pending = Pending(copy: selected, lease: lease); return nil
    default: break
    }
    let previous = state(screen)
    let origin: TerminalSelectionHit, head: TerminalSelectionHit
    let granularity: TerminalSelectionGranularity, mode: TerminalSelectionMode
    let phase: TerminalSelectionSnapshot.Phase
    switch action {
    case .begin(let hit, let g): origin = hit; head = hit; granularity = g; mode = g == .rectangular ? .rectangular : .linear; phase = .dragging
    case .extend(let hit):
      guard let old = state(screen) else { return .noSelection }
      origin = old.origin; head = hit; granularity = old.granularity; mode = old.mode; phase = .dragging
    case .range(let start, let end, let m): origin = start; head = end; granularity = .character; mode = m; phase = .committed
    default: return nil
    }
    let context = TerminalPresentationContext(documentGeneration: documentGeneration, screen: screen,
      geometryEpoch: geometryEpoch, snapshotID: snapshotID, columns: document.columns)
    // The stored drag origin has already been observed precisely; unrelated
    // later writes on its row do not make that origin stale.
    let extending: Bool = { if case .extend = action { return true }; return false }()
    let resolvedOrigin = extending
      ? lookup.acceptedBoundary(.init(rowID: origin.rowID, column: origin.boundary, after: origin.affinity == .after), screen: screen, in: document)
      : lookup.presentedHit(origin, context: context, in: document)
    guard let originIndex = resolvedOrigin,
      let headIndex = lookup.presentedHit(head, context: context, in: document) else { return .staleTarget }
    var presented: [UInt64: TerminalSelectionPresentation.Row] = [:]
    if !extending { for row in origin.presentation.rows { presented[row.id] = row } }
    for row in head.presentation.rows { presented[row.id] = row }
    var positions: [Int: UInt64] = [:]
    for (offset, row) in head.presentation.rows.enumerated() { positions[headIndex + offset - head.row] = row.id }
    if !extending {
      for (offset, row) in origin.presentation.rows.enumerated() { positions[originIndex + offset - origin.row] = row.id }
    }
    let forwards = originIndex < headIndex || (originIndex == headIndex && origin.boundary <= head.boundary)
    let first = min(originIndex, headIndex), last = max(originIndex, headIndex)
    guard last - first < Self.maximumRows else { return .limitExceeded }
    var lower = forwards ? origin.boundary : head.boundary
    var upper = forwards ? head.boundary : origin.boundary
    if mode == .rectangular { lower = min(origin.boundary, head.boundary); upper = max(origin.boundary, head.boundary) }
    // Pointer hits name cells. A drag includes both endpoint cells; explicit
    // ranges (AX, programmatic selection) retain exclusive boundary semantics.
    if extending && (granularity == .character || granularity == .rectangular) {
      upper = min(document.columns, upper + 1)
    }
    if granularity == .line { lower = 0; upper = document.columns }
    func normalized(_ hit: TerminalSelectionHit, index: Int, upper: Bool) -> TerminalSelectionHit {
      let row = document.selectionRow(at: index, screen: screen)
      var column = hit.boundary
      if column < row.count && row.kind(at: column) == 3 { column += upper ? 1 : -1 }
      return TerminalSelectionHit(presentation: hit.presentation, row: hit.row, boundary: column, affinity: hit.affinity)
    }
    generation &+= 1
    guard let proofSlot = proofSlots.acquire() else { return .busy }
    let selected = State(generation: generation,
      origin: mode == .rectangular ? origin : normalized(origin, index: originIndex, upper: !forwards),
      head: mode == .rectangular ? head : normalized(head, index: headIndex, upper: forwards),
      granularity: granularity, mode: mode, phase: phase, proofSlot: proofSlot,
      wordProfile: extending ? (previous?.wordProfile ?? wordProfile) : wordProfile)
    // Keep the previous selection until the candidate is complete. Its
    // active-row observations are restored if this capture is cancelled.
    pending = Pending(state: selected, first: first, last: last, lower: lower, upper: upper, presented: presented, positions: positions, previous: previous)
    if granularity == .word {
      pending!.wordFirst = TerminalWordCapture(row: first, column: lower, punctuation: selected.wordProfile.punctuation)
      pending!.wordLast = TerminalWordCapture(row: last, column: upper, punctuation: selected.wordProfile.punctuation)
    }
    return nil
  }
  var hasSelection: Bool { primary != nil || alternate != nil }
  var hasPendingWork: Bool { pending != nil }
  func reflowInput(_ screen: TerminalSelectionScreen) -> TerminalSelectionReflowInput? {
    guard let selected = state(screen) else { return nil }
    return TerminalSelectionReflowInput(generation: selected.generation,
      rectangular: selected.mode == .rectangular, content: selected.content,
      origin: .init(rowID: selected.origin.rowID, column: selected.origin.boundary, after: selected.origin.affinity == .after),
      head: .init(rowID: selected.head.rowID, column: selected.head.boundary, after: selected.head.affinity == .after))
  }
  func applyReflow(_ result: TerminalSelectionReflowResult, document: TerminalDocument,
                   documentGeneration: UUID, geometryEpoch: UInt64, snapshotID: UInt64) {
    let lookup = TerminalSelectionLookup(document)
    for screen in [TerminalSelectionScreen.primary, .alternate] {
      guard let selected = state(screen) else { continue }
      let lost = screen == .primary ? result.primaryLost : result.alternateLost
      let content = screen == .primary ? result.primary : result.alternate
      let origin = screen == .primary ? result.primaryOrigin : result.alternateOrigin
      let head = screen == .primary ? result.primaryHead : result.alternateHead
      func hit(_ boundary: TerminalSelectionBoundary?) -> TerminalSelectionHit? {
        guard let boundary, let index = lookup.index(boundary.rowID, screen: screen, in: document) else { return nil }
        let row = document.selectionRow(at: index, screen: screen)
        let presented = TerminalSelectionPresentation(snapshotID: snapshotID, documentGeneration: documentGeneration,
          screen: screen, geometryEpoch: geometryEpoch, columns: document.columns,
          rows: [.init(id: row.id, revision: row.revision, softWrapped: row.softWrapped)])
        return presented.hit(row: 0, boundary: boundary.column, affinity: boundary.after ? .after : .before)
      }
      guard !lost, let content, let origin = hit(origin), let head = hit(head) else {
        clear(screen, reason: .evicted); continue
      }
      selected.content = content; selected.origin = origin; selected.head = head; revision &+= 1
    }
  }
  // Nil text means capture completed; .some("") remains a successful empty copy.
  func advance(in document: inout TerminalDocument) -> Result<String?, TerminalSelectionFailure>? {
    guard let work = pending else { return .success(nil) }
    if let capture = work.wordFirst {
      guard let result = capture.advance(document: document, screen: work.state.screen) else { return nil }
      switch result {
      case .failure(let error): cancel(in: &document); return .failure(error)
      case .success(let bounds):
        work.expandedFirst = bounds.0.row...work.first
        work.first = bounds.0.row; work.lowerColumn = bounds.0.column; work.next = work.first
        work.wordFirst = nil
        Self.retirement.async { capture.releaseResources() }
      }
      return nil
    }
    if let capture = work.wordLast {
      guard let result = capture.advance(document: document, screen: work.state.screen) else { return nil }
      switch result {
      case .failure(let error): cancel(in: &document); return .failure(error)
      case .success(let bounds):
        work.expandedLast = work.last...bounds.1.row
        work.last = bounds.1.row; work.upperColumn = bounds.1.column
        guard work.last - work.first < Self.maximumRows else { cancel(in: &document); return .failure(.limitExceeded) }
        work.wordLast = nil
        Self.retirement.async { capture.releaseResources() }
      }
      return nil
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000
    var units = 0
    switch work.work {
    case .capture:
      while work.next <= work.last {
        let index = work.next, selected = work.state
        let row = document.selectionRow(at: index, screen: selected.screen)
        var lower = selected.mode == .rectangular || index == work.first ? work.lowerColumn : 0
        var upper = selected.mode == .rectangular || index == work.last ? work.upperColumn : document.columns
        lower = min(document.columns, max(0, lower)); upper = min(document.columns, max(lower, upper))
        if lower < row.count && row.kind(at: lower) == 3 { lower -= 1 }
        if upper > 0 && upper < row.count && row.kind(at: upper) == 3 { upper += 1 }
        let alreadySelected = work.previous.map { previous in
          guard let indices = previous.content.byRow[row.id] else { return false }
          return previous.content.spans[indices].contains { $0.columns.lowerBound <= lower && $0.columns.upperBound >= upper }
        } ?? false
        let expandedWord = work.expandedFirst?.contains(index) == true || work.expandedLast?.contains(index) == true
        let unseenHistory = selected.screen == .primary && index < document.history.count && work.presented[row.id] == nil
        let proven: Bool
        if let presented = work.presented[row.id] {
          proven = work.presentedPositions[index] == row.id && TerminalSelectionLookup.matches(row, proof: presented)
        } else { proven = alreadySelected || expandedWord || unseenHistory }
        guard proven else {
          cancel(in: &document); return .failure(.staleTarget)
        }
        let mutable = selected.screen == .alternate || index >= document.history.count
        let softNext = index < work.last && row.softWrapped ? document.selectionRow(at: index + 1, screen: selected.screen).id : nil
        let ordinal = selected.content.spans.count
        selected.hasSelectedContent = selected.hasSelectedContent || lower < upper
          || (selected.mode == .linear && index < work.last && !row.softWrapped)
        selected.content.append(TerminalSelectedSpan(rowID: row.id, columns: lower..<upper, softNextID: softNext,
          sourceOrdinal: ordinal, mutableAtCapture: mutable, group: selected.mode == .rectangular ? ordinal : 0))
        if mutable {
          work.rollbackRows.append((row.id, row.selectionObservation))
          document.observeSelection(at: index, screen: selected.screen,
            observation: TerminalRow.SelectionObservation(generation: selected.generation, columns: lower..<upper,
                                                       observesSoftEdge: index < work.last))
        }
        work.next += 1; units += 1
        if units >= 256 || DispatchTime.now().uptimeNanoseconds >= deadline { return nil }
      }
      let empty = work.state.phase == .committed && !work.state.hasSelectedContent
      assign(empty ? nil : work.state, screen: work.state.screen); revision &+= 1; pending = nil
      retirePending(work, discarded: empty)
      return .success(nil)
    case .copy:
      let lookup = TerminalSelectionLookup(document)
      while work.copyIndex < work.state.content.spans.count {
        let span = work.state.content.spans[work.copyIndex]
        guard let index = lookup.index(span.rowID, screen: work.state.screen, in: document) else { cancel(in: &document); return .failure(.evicted) }
        let row = document.selectionRow(at: index, screen: work.state.screen)
        if work.copyEnd == nil {
          var end = span.columns.upperBound
          if work.state.mode == .linear && end == row.count && span.softNextID == nil {
            while end > span.columns.lowerBound && row.kind(at: end - 1) == 0 && row.style(at: end - 1).background == 0 { end -= 1; units += 1 }
          }
          work.copyEnd = end
          if units >= 2048 || DispatchTime.now().uptimeNanoseconds >= deadline { return nil }
        }
        let end = work.copyEnd!
        var column = max(span.columns.lowerBound, work.copyColumn)
        while column < end {
          let cell = row.cell(column)
          let text = cell.kind == 0 ? " " : (cell.kind == 1 || cell.kind == 2 ? cell.text : "")
          guard work.text.utf8.count <= Self.maximumCopyBytes - text.utf8.count else { cancel(in: &document); return .failure(.limitExceeded) }
          work.text += text; column += 1; units += 1; work.copyColumn = column
          if units >= 2048 || (units.isMultiple(of: 64) && DispatchTime.now().uptimeNanoseconds >= deadline) { return nil }
        }
        let next = work.copyIndex + 1 < work.state.content.spans.count ? work.state.content.spans[work.copyIndex + 1] : nil
        let newline = next.map { work.state.mode == .rectangular ? $0.group != span.group : ($0.rowID != span.rowID && span.softNextID == nil) } ?? false
        if newline {
          guard work.text.utf8.count < Self.maximumCopyBytes else { cancel(in: &document); return .failure(.limitExceeded) }
          work.text += "\n"
        }
        work.copyIndex += 1; work.copyColumn = 0; work.copyEnd = nil; units += 1
        if units >= 2048 || DispatchTime.now().uptimeNanoseconds >= deadline { return nil }
      }
      // Success transfers immutable storage to the caller (Session separately
      // bounds undelivered results). Clearing this alias cannot free that
      // buffer, and a legitimate next copy need not wait for utility cleanup.
      let result = work.text
      work.text = ""; work.copyBufferLease = nil
      pending = nil; return .success(result)
    }
  }
}

// Word segmentation uses Foundation's Unicode word boundaries on an immutable
// bounded string. The owner captures that string in small turns; linguistic
// work runs off-owner and returns only two cell boundaries. No document or
// row storage crosses this worker seam.
private final class TerminalWordCapture {
  struct Boundary { let row: Int; let column: Int }
  private struct Cell { let offset: Int; let length: Int; let row: Int; let column: Int; let width: Int }
  private enum Phase { case backward, forward, cells, waiting }
  private static let maximumCells = 65_536
  private static let maximumBytes = 4 * 1024 * 1024
  private let seed: Boundary
  private let punctuation: String
  private var phase = Phase.backward
  private var first: Int
  private var last: Int
  private var row: Int
  private var column = 0
  private var offset = 0
  private var targetOffset = 0
  private var text = ""
  private var cells: [Cell] = []
  private var job: WordJob?
  init(row: Int, column: Int, punctuation: String) {
    seed = Boundary(row: row, column: column); first = row; last = row; self.row = row; self.punctuation = punctuation
  }
  func cancel() { job?.cancel() }
  func releaseResources() { cancel(); cells.removeAll(); text = ""; job = nil }
  func advance(document: TerminalDocument, screen: TerminalSelectionScreen) -> Result<(Boundary, Boundary), TerminalSelectionFailure>? {
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000
    var units = 0
    while units < 512 {
      units += 1
      if units.isMultiple(of: 32) && DispatchTime.now().uptimeNanoseconds >= deadline { return nil }
      switch phase {
      case .backward:
        if first > 0 && document.selectionRow(at: first - 1, screen: screen).softWrapped {
          first -= 1
          if seed.row - first >= Self.maximumCells / document.columns { return .failure(.limitExceeded) }
        } else { phase = .forward }
      case .forward:
        let count = screen == .alternate ? document.alternate.rows.count : document.history.count + document.primary.rows.count
        if last + 1 < count && document.selectionRow(at: last, screen: screen).softWrapped {
          last += 1
          if last - first >= Self.maximumCells / document.columns { return .failure(.limitExceeded) }
        } else { row = first; phase = .cells }
      case .cells:
        if row > last {
          guard let admitted = WordJob(text: text, target: targetOffset, punctuation: punctuation) else { return .failure(.limitExceeded) }
          job = admitted
          phase = .waiting; return nil
        }
        let source = document.selectionRow(at: row, screen: screen)
        if column >= source.count { row += 1; column = 0; continue }
        let sourceColumn = column
        let cell = source.cell(column)
        let width = cell.kind == 2 ? 2 : 1
        column += width
        if cell.kind == 3 || cell.kind == 4 { continue }
        let value = cell.kind == 0 ? " " : cell.text
        let length = value.utf16.count
        guard cells.count < Self.maximumCells, text.utf8.count <= Self.maximumBytes - value.utf8.count else { return .failure(.limitExceeded) }
        if row == seed.row && (sourceColumn..<(sourceColumn + width)).contains(min(source.count - 1, seed.column)) { targetOffset = offset }
        cells.append(Cell(offset: offset, length: length, row: row, column: sourceColumn, width: width))
        text += value; offset += length
      case .waiting:
        guard let result = job?.result else { return nil }
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let range):
          func index(containing offset: Int) -> Int {
            var lower = 0, upper = cells.count
            while lower < upper {
              let middle = lower + (upper - lower) / 2
              if cells[middle].offset + cells[middle].length <= offset { lower = middle + 1 }
              else { upper = middle }
            }
            return min(cells.count - 1, lower)
          }
          guard !cells.isEmpty else { return .failure(.noSelection) }
          let first = cells[index(containing: range.location)]
          let last = cells[index(containing: NSMaxRange(range) - 1)]
          return .success((Boundary(row: first.row, column: first.column), Boundary(row: last.row, column: last.column + last.width)))
        }
      }
    }
    return nil
  }
  static func drainJobsForTesting() -> Bool { WordJob.drainForTesting() }
  static func withJobsPausedForTesting(_ body: () -> Void) { WordJob.withPausedForTesting(body) }
  private final class WordJob {
    static func drainForTesting() -> Bool {
      let finished = DispatchSemaphore(value: 0)
      queue.async { finished.signal() }
      return finished.wait(timeout: .now() + .seconds(5)) == .success
    }
    static func withPausedForTesting(_ body: () -> Void) {
      let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
      queue.async { entered.signal(); resume.wait() }
      entered.wait(); defer { resume.signal() }
      body()
    }
    private static let queue = DispatchQueue(label: "terminal.selection.words", qos: .userInitiated)
    private static let slots = DispatchSemaphore(value: 4)
    private let lock = NSLock()
    private var cancelled = false
    private var admitted = false
    private var value: Result<NSRange, TerminalSelectionFailure>?
    var result: Result<NSRange, TerminalSelectionFailure>? { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    init?(text: String, target: Int, punctuation: String) {
      guard Self.slots.wait(timeout: .now()) == .success else { return nil }
      admitted = true
      Self.queue.async { [self] in
        let result = segment(text, target: target, punctuation: punctuation)
        lock.lock(); value = cancelled ? .failure(.cancelled) : result; lock.unlock()
      }
    }
    deinit { if admitted { Self.slots.signal() } }
    private func segment(_ text: String, target: Int, punctuation: String) -> Result<NSRange, TerminalSelectionFailure> {
      struct Token { var range: NSRange; var lastConnector: Bool; var wordOrConnector: Bool; var whitespace: Bool }
      let source = text as NSString
      var words: [NSRange] = []
      var failed = false
      text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
        if self.isCancelled || words.count >= TerminalWordCapture.maximumCells { failed = true; stop = true; return }
        words.append(NSRange(range, in: text))
      }
      if failed { return .failure(isCancelled ? .cancelled : .limitExceeded) }
      var tokens: [Token] = []
      var offset = 0, word = 0
      while offset < source.length {
        if tokens.count >= TerminalWordCapture.maximumCells || isCancelled { return .failure(isCancelled ? .cancelled : .limitExceeded) }
        let range: NSRange, isWord: Bool
        if word < words.count && words[word].location == offset { range = words[word]; word += 1; isWord = true }
        else { range = source.rangeOfComposedCharacterSequence(at: offset); isWord = false }
        let value = source.substring(with: range)
        let connector = !isWord && value.unicodeScalars.allSatisfy { punctuation.unicodeScalars.contains($0) }
        let whitespace = value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        if let last = tokens.last,
           (last.whitespace && whitespace) || (last.wordOrConnector && connector) || (last.lastConnector && isWord) {
          tokens[tokens.count - 1].range.length = NSMaxRange(range) - last.range.location
          tokens[tokens.count - 1].lastConnector = connector
          tokens[tokens.count - 1].wordOrConnector = last.wordOrConnector || isWord || connector
        } else { tokens.append(Token(range: range, lastConnector: connector, wordOrConnector: isWord || connector, whitespace: whitespace)) }
        offset = NSMaxRange(range)
      }
      guard let token = tokens.first(where: { NSLocationInRange(target, $0.range) }) else { return .failure(.noSelection) }
      return .success(token.range)
    }
  }
}

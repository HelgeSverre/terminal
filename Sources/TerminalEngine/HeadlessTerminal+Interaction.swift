import Foundation
import TerminalInterop

extension HeadlessTerminal {
  /// A position from a specific published screen. The terminal validates its
  /// row identity and revision before selecting it; stale points are rejected.
  public struct SelectionPoint {
    let hit: TerminalSelectionHit
  }

  public enum SelectionFailure: String, Error, Equatable, Sendable {
    case staleTarget, changedContent, evicted, noSelection, busy, limitExceeded, cancelled
  }
  public enum SelectionProgress: Equatable, Sendable {
    case pending
    /// Nil means a selection operation completed without copying. Empty text
    /// is a successful copy of an empty selection.
    case completed(text: String?)
    case rejected(SelectionFailure)
  }

  public struct Selection: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
      public let row: Int
      public let columns: Range<Int>
    }
    public let revision: UInt64
    public let segments: [Segment]
    public let isCommitted: Bool
    public let isRectangular: Bool
    public let issue: SelectionFailure?
    init(_ snapshot: TerminalSelectionSnapshot) {
      revision = snapshot.revision
      segments = snapshot.segments.map { Segment(row: $0.row, columns: $0.start..<$0.end) }
      isCommitted = snapshot.phase == .committed
      isRectangular = snapshot.mode == .rectangular
      issue = snapshot.issue.flatMap { SelectionFailure(rawValue: $0.rawValue) }
    }
  }

  /// Selects the half-open range between two snapshot points. Work is bounded
  /// per call: repeat `advanceSelection` while the result is `.pending`.
  /// Feeding or resizing cancels pending selection work before changing cells.
  public func select(from start: SelectionPoint, to end: SelectionPoint, rectangular: Bool = false) -> SelectionProgress {
    guard !selectionPending else { return .rejected(.busy) }
    return selectionResult(TerminalSelectionBridge.begin(core: core, action:
      .range(start: start.hit, end: end.hit, mode: rectangular ? .rectangular : .linear)))
  }

  public func advanceSelection() -> SelectionProgress {
    guard selectionPending else { return .rejected(.noSelection) }
    return selectionResult(TerminalSelectionBridge.advance(core: core))
  }

  /// Copies exactly the selection revision seen in `screen.selection`, using
  /// the engine's 16 MiB copy limit. Stale revisions fail rather than copying
  /// a later selection. Repeat `advanceSelection` while pending.
  public func copySelection(_ selection: Selection) -> SelectionProgress {
    guard !selectionPending else { return .rejected(.busy) }
    return selectionResult(TerminalSelectionBridge.begin(core: core, action: .copy(expectedSelectionRevision: selection.revision)))
  }

  public func clearSelection() {
    cancelPendingSelection()
    _ = selectionResult(TerminalSelectionBridge.begin(core: core, action: .clear))
  }

  func cancelPendingSelection() {
    if selectionPending { TerminalSelectionBridge.cancel(core: core); selectionPending = false }
  }

  private func selectionResult(_ progress: TerminalSelectionProgress) -> SelectionProgress {
    switch progress {
    case .pending: selectionPending = true; return .pending
    case .completed(let text): selectionPending = false; return .completed(text: text)
    case .rejected(let failure):
      selectionPending = false
      return .rejected(SelectionFailure(rawValue: failure.rawValue)!)
    }
  }

  public struct SearchSegment: Equatable, Sendable {
    public let row: Int
    public let columns: Range<Int>
  }

  public struct SearchPosition: Equatable, Sendable {
    /// One-based, counted from the newest retained match.
    public let index: Int
    public let total: Int
    /// The oldest matches were dropped at the 10,000 match retention limit.
    public let capped: Bool
  }
  public enum SearchResult: Equatable, Sendable {
    case working
    case found(SearchPosition)
    case missing, changed, invalidQuery, resourceLimit, cancelled
  }

  /// Starts an incremental history search. Every advance lends at most one
  /// row and scans at most 64 scalars/cells; the host controls cancellation and
  /// scheduling. No history snapshot is retained. See docs/search.md for the
  /// supported regex syntax and explicit memory/match-length limits.
  public func beginSearch(_ query: String, options: TerminalSearchOptions = .init()) -> SearchResult {
    cancelSearch()
    helge_terminal_search_clear(core)
    let bytes = Array(query.utf8.prefix(4097))
    guard !bytes.isEmpty, bytes.count <= 4096 else { searchResult = .invalidQuery; return searchResult }
    searchHandle = bytes.withUnsafeBufferPointer {
      helge_terminal_search_create_options(core, $0.baseAddress, $0.count, options.flags)
    }
    searchResult = searchHandle == nil ? .invalidQuery : .working
    return searchResult
  }

  @discardableResult public func advanceSearch() -> SearchResult {
    guard let handle = searchHandle else { return searchResult }
    var status = helge_terminal_search_fill(core, handle)
    if status == 0 { status = helge_terminal_search_step(handle) }
    switch status {
    case 0, 1: return .working
    case 2:
      let accepted = helge_terminal_search_accept(core, handle)
      switch accepted {
      case 5: searchResult = searchPosition.map(SearchResult.found) ?? .changed
      case 2: searchResult = .missing
      case 4: searchResult = .resourceLimit
      default: searchResult = .changed
      }
    case 4: searchResult = .resourceLimit
    default: searchResult = .changed
    }
    helge_terminal_search_destroy(handle)
    searchHandle = nil
    return searchResult
  }

  public func cancelSearch() {
    if let handle = searchHandle { helge_terminal_search_destroy(handle); searchHandle = nil }
    searchResult = .cancelled
  }
  public func clearSearch() { cancelSearch(); helge_terminal_search_clear(core) }

  public var searchPosition: SearchPosition? {
    var index: UInt32 = 0, total: UInt32 = 0
    var capped = false
    guard helge_terminal_search_position(core, &index, &total, &capped) else { return nil }
    return SearchPosition(index: Int(index), total: Int(total), capped: capped)
  }
  public func navigateSearch(older: Bool) -> SearchPosition? {
    var index: UInt32 = 0, total: UInt32 = 0
    var capped = false
    guard helge_terminal_search_navigate(core, older, &index, &total, &capped) else { return nil }
    return SearchPosition(index: Int(index), total: Int(total), capped: capped)
  }
}

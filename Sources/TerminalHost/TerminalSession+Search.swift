import Foundation
import TerminalEngine
import TerminalInterop

/// How a search of the screen and its history ended.
public enum HistorySearchOutcome: Equatable, Sendable {
  /// `found`: the newest match is selected and scrolled into view.
  /// `missing`: nothing matches. `changed`: output kept arriving while the
  /// search ran; ask again. `cancelled`: a newer search or a close replaced
  /// it. `invalidQuery`: empty, longer than 4096 UTF-8 bytes, or unsupported regex syntax.
  /// `resourceLimit`: a row, cell, proof set or regex match exceeds a bound.
  case found, missing, changed, cancelled, invalidQuery, resourceLimit
  public var message: String {
    switch self {
    case .found: return "Match found"
    case .missing: return "No match"
    case .changed: return "Output changed during search; try again"
    case .cancelled: return "Search cancelled"
    case .invalidQuery: return "Invalid search expression (1–4096 UTF-8 bytes)"
    case .resourceLimit: return "Search exceeds a memory or match-length limit"
    }
  }
}

/// One-based position counted from the newest match. `capped` reports that
/// matches older than the retention bound are not included in `total`.
public struct HistorySearchPosition: Equatable, Sendable {
  public let index: Int
  public let total: Int
  public let capped: Bool
}

extension TerminalSession {
  public typealias SearchCompletion = @MainActor (HistorySearchOutcome, HistorySearchPosition?) -> Void

  // This module owns worker scheduling, latest-query replacement, bounded work,
  // retries, lifetime and source validation. Canvas only submits a query and
  // receives an outcome; it never reconstructs history positions or epochs.
  final class HistorySearch: @unchecked Sendable {
    private static let worker = DispatchQueue(label: "no.helgesverre.terminal.search", qos: .utility)
    private final class Job: @unchecked Sendable {
      let handle: OpaquePointer
      let generation: UInt64
      init(_ handle: OpaquePointer, generation: UInt64) {
        self.handle = handle
        self.generation = generation
      }
      deinit { helge_terminal_search_destroy(handle) }
    }
    private struct Request {
      let query: String
      let options: TerminalSearchOptions
      let completion: SearchCompletion
      var retries = 0
    }
    private weak var session: TerminalSession?
    private var generation: UInt64 = 0
    private var request: Request?
    private var job: Job?
    private var working = false
    private var scheduled = false
    init(session: TerminalSession) { self.session = session }
    func start(_ query: String, options: TerminalSearchOptions, completion: @escaping SearchCompletion) {
      cancel()
      request = Request(query: query, options: options, completion: completion)
      schedule()
    }
    func cancel() {
      generation &+= 1
      if let request { DispatchQueue.main.async { request.completion(.cancelled, nil) } }
      request = nil
      job = nil
    }
    private func schedule() {
      guard !working, !scheduled, request != nil, let session, !session.closed else { return }
      scheduled = true
      session.enqueue(.searchAdvance)
    }
    func advance() {
      scheduled = false
      guard !working, let request, let session, !session.closed, let core = session.core else { return }
      if job == nil {
        guard !request.query.isEmpty, request.query.utf8.count <= 4096 else {
          finish(.invalidQuery)
          return
        }
        let bytes = Array(request.query.utf8)
        let handle = bytes.withUnsafeBufferPointer {
          helge_terminal_search_create_options(core, $0.baseAddress, $0.count, request.options.flags)
        }
        guard let handle else { finish(.invalidQuery); return }
        job = Job(handle, generation: generation)
      }
      guard let job else { return }
      let status = helge_terminal_search_fill(core, job.handle)
      if status == 0 {
        working = true
        let owner = session.readBroker!
        Self.worker.async { [weak self, job] in
          _ = helge_terminal_search_step(job.handle)
          owner.submit { [weak self, job] in
            guard let self else { return }
            self.working = false
            if job.generation != self.generation { self.job = nil }
            self.schedule()
          }
        }
      } else if status == 2 {
        let accepted = helge_terminal_search_accept(core, job.handle)
        if accepted == 3 { retryOrFinish() }
        else { finish(accepted == 5 ? .found : .missing) }
      } else if status == 3 { retryOrFinish() }
      else { finish(.resourceLimit) }
    }
    private func retryOrFinish() {
      guard var current = request else { return }
      guard current.retries < 2 else { finish(.changed); return }
      current.retries += 1
      request = current
      job = nil
      schedule()
    }
    private func finish(_ outcome: HistorySearchOutcome) {
      guard let request else { return }
      self.request = nil
      job = nil
      let position = outcome == .found ? session?.searchPosition() : nil
      DispatchQueue.main.async { request.completion(outcome, position) }
    }
  }

  private func searchPosition() -> HistorySearchPosition? {
    var index: UInt32 = 0
    var total: UInt32 = 0
    var capped = false
    guard let core, helge_terminal_search_position(core, &index, &total, &capped) else { return nil }
    return HistorySearchPosition(index: Int(index), total: Int(total), capped: capped)
  }

  package func find(_ query: String, completion: @escaping @MainActor (HistorySearchOutcome) -> Void) {
    search(query) { outcome, _ in completion(outcome) }
  }

  /// Searches the screen and its history with bounded scalar matching.
  /// Replaces any search in flight. A hit selects the newest match,
  /// marks the others and reports its position among all retained matches.
  public func search(_ query: String, options: TerminalSearchOptions = .init(), completion: @escaping SearchCompletion) {
    readBroker.submit { [self] in
      guard !closed else {
        DispatchQueue.main.async { completion(.cancelled, nil) }
        return
      }
      enqueue(.find(query, options, completion))
    }
  }

  /// Moves to the adjacent match of the accepted search, wrapping at the ends.
  /// Nil means no accepted match is still valid; the caller searches again.
  public func searchNavigate(older: Bool, completion: @escaping @MainActor (HistorySearchPosition?) -> Void) {
    readBroker.submit { [self] in
      guard !closed else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      enqueue(.searchNavigate(older, completion))
    }
  }

  /// Cancels any search in flight and removes the match decorations.
  public func searchClear() {
    readBroker.submit { [self] in
      guard !closed else { return }
      enqueue(.searchClear)
    }
  }
}

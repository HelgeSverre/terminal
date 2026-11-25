import Foundation

/// Schedules debounced layout saves, serialized per-pane scrollback
/// checkpoints, sleep flushes, and normal-quit cancellation without depending
/// on AppKit windows.
final class RecoveryCoordinator {
  struct ScheduledTask {
    let cancel: () -> Void
  }

  typealias Clock = () -> TimeInterval
  typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask
  typealias CaptureCompletion = (_ text: String?, _ rows: Int, _ retryDelay: TimeInterval?) -> Void

  private let layoutDebounce: TimeInterval
  private let layoutMaxAge: TimeInterval
  private let checkpointDelay: TimeInterval
  private let now: Clock
  private let schedule: Scheduler
  private let isPaneAlive: (String) -> Bool
  private let saveLayout: () -> Void
  private let captureCheckpoint: (_ paneID: String, _ force: Bool, _ completion: @escaping CaptureCompletion) -> Void
  private let saveScrollback: (_ paneID: String, _ text: String, _ rows: Int) -> Void
  private let cleanExit: (_ completion: @escaping @Sendable () -> Void) -> Void

  private(set) var layoutRevision: UInt64 = 0
  private(set) var isStopped = false

  private var layoutTimer: ScheduledTask?
  private var layoutPendingSince: TimeInterval?
  private var checkpointTimer: ScheduledTask?
  private var pendingCheckpoints: [String: TimeInterval] = [:]
  private var captureInFlight = false
  private var captureToken: UInt64 = 0
  private var sleepFlush = false
  private var readyPanes: Set<String> = []

  init(
    layoutDebounce: TimeInterval = 1,
    layoutMaxAge: TimeInterval = 5,
    checkpointDelay: TimeInterval = 2,
    now: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
    schedule: @escaping Scheduler = RecoveryCoordinator.mainQueueScheduler,
    isPaneAlive: @escaping (String) -> Bool,
    saveLayout: @escaping () -> Void,
    captureCheckpoint: @escaping (_ paneID: String, _ force: Bool, _ completion: @escaping CaptureCompletion) -> Void,
    saveScrollback: @escaping (_ paneID: String, _ text: String, _ rows: Int) -> Void,
    cleanExit: @escaping (_ completion: @escaping @Sendable () -> Void) -> Void = { $0() }
  ) {
    self.layoutDebounce = layoutDebounce
    self.layoutMaxAge = layoutMaxAge
    self.checkpointDelay = checkpointDelay
    self.now = now
    self.schedule = schedule
    self.isPaneAlive = isPaneAlive
    self.saveLayout = saveLayout
    self.captureCheckpoint = captureCheckpoint
    self.saveScrollback = saveScrollback
    self.cleanExit = cleanExit
  }

  deinit {
    layoutTimer?.cancel()
    checkpointTimer?.cancel()
  }

  static func mainQueueScheduler(delay: TimeInterval, action: @escaping () -> Void) -> ScheduledTask {
    let work = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    return ScheduledTask(cancel: { work.cancel() })
  }

  func layoutChanged() {
    guard !isStopped else { return }
    layoutRevision &+= 1
    layoutTimer?.cancel()
    // Wait `layoutDebounce` after the last change, and never more than
    // `layoutMaxAge` after the first: steady changes must not postpone the
    // save indefinitely.
    let current = now()
    let first = layoutPendingSince ?? current
    layoutPendingSince = first
    let deadline = min(current + layoutDebounce, first + layoutMaxAge)
    let delay = max(0, deadline - current)
    layoutTimer = schedule(delay) { [weak self] in
      self?.performLayoutSave()
    }
  }

  func paneReady(_ id: String) {
    guard !isStopped else { return }
    readyPanes.insert(id)
    layoutChanged()
  }

  func allPanesReady<S: Sequence>(_ ids: S) -> Bool where S.Element == String {
    ids.allSatisfy { readyPanes.contains($0) }
  }

  func output(paneID: String) {
    guard !isStopped else { return }
    pendingCheckpoints[paneID] = now() + checkpointDelay
    scheduleCheckpoint()
  }

  func flush() {
    guard !isStopped else { return }
    layoutTimer?.cancel()
    performLayoutSave()
    guard !isStopped else { return }
    sleepFlush = true
    for paneID in pendingCheckpoints.keys {
      pendingCheckpoints[paneID] = -.greatestFiniteMagnitude
    }
    captureNext(force: true)
  }

  func cancelForNormalQuit(completion: @escaping @Sendable () -> Void = {}) {
    guard !isStopped else { completion(); return }
    isStopped = true
    layoutTimer?.cancel()
    layoutTimer = nil
    layoutPendingSince = nil
    checkpointTimer?.cancel()
    checkpointTimer = nil
    pendingCheckpoints.removeAll()
    sleepFlush = false
    cleanExit(completion)
  }

  private func performLayoutSave() {
    layoutTimer = nil
    layoutPendingSince = nil
    guard !isStopped else { return }
    saveLayout()
  }

  private func scheduleCheckpoint() {
    checkpointTimer?.cancel()
    checkpointTimer = nil
    if pendingCheckpoints.isEmpty && !captureInFlight { sleepFlush = false }
    guard !isStopped, !captureInFlight, let nextDue = pendingCheckpoints.values.min() else { return }
    let delay = max(0, nextDue - now())
    checkpointTimer = schedule(delay) { [weak self] in
      self?.captureNext()
    }
  }

  private func nextPendingCheckpoint() -> (key: String, due: TimeInterval)? {
    pendingCheckpoints.min { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value < rhs.value }
      return lhs.key < rhs.key
    }.map { (key: $0.key, due: $0.value) }
  }

  private func captureNext(force: Bool = false) {
    checkpointTimer = nil
    guard !isStopped, !captureInFlight else { return }
    while let entry = nextPendingCheckpoint() {
      pendingCheckpoints[entry.key] = nil
      guard isPaneAlive(entry.key) else { continue }
      captureInFlight = true
      captureToken &+= 1
      let token = captureToken
      let paneID = entry.key
      let forced = force || sleepFlush
      captureCheckpoint(paneID, forced) { [weak self] text, rows, retryDelay in
        guard let self, self.captureInFlight, self.captureToken == token else { return }
        self.captureInFlight = false
        if !self.isStopped, self.isPaneAlive(paneID) {
          if let text {
            self.saveScrollback(paneID, text, rows)
            self.layoutChanged()
          } else if let retryDelay {
            self.pendingCheckpoints[paneID] = self.now() + retryDelay
          }
        }
        self.scheduleCheckpoint()
      }
      return
    }
    scheduleCheckpoint()
  }
}

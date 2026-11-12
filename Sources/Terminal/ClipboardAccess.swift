import AppKit

enum ClipboardAccessDecision {
  case allow, deny
}

// The only native owner of OSC 52 policy and pasteboard writes. Programs may
// write the clipboard without asking: this is a personal terminal, and a
// prompt per write (or per pane) only got in the way. `decide` stays as a
// seam so tests can hold or deny a request.
final class ClipboardAccess {
  typealias DecisionHandler = (
    ClipboardWriteRequest, NSWindow?, @escaping (ClipboardAccessDecision) -> Void
  ) -> (() -> Void)?
  private final class Pending {
    let request: ClipboardWriteRequest
    weak var window: NSWindow?
    var cancelled = false
    var dismiss: (() -> Void)?
    var writePermit: UInt64?
    var pasteboardChangeCount: Int?
    init(_ request: ClipboardWriteRequest, window: NSWindow?) {
      self.request = request
      self.window = window
    }
  }
  static let maximumPending = 4
  private let pasteboard: NSPasteboard
  private let decide: DecisionHandler
  private var queued: [Pending] = []
  private var active: Pending?
  private var deniedSessions = Set<UUID>()
  /// Every accepted writer receives a monotonically newer permit. This is the
  /// single ordering point for OSC 52 decisions and explicit user copies.
  private var latestWritePermit: UInt64 = 0

  init(
    pasteboard: NSPasteboard = .general, decide: @escaping DecisionHandler = ClipboardAccess.allow
  ) {
    precondition(Thread.isMainThread)
    self.pasteboard = pasteboard
    self.decide = decide
  }

  func request(_ request: ClipboardWriteRequest, from window: NSWindow?) {
    precondition(Thread.isMainThread)
    guard request.isLive, !deniedSessions.contains(request.sessionID) else {
      request.resolve(false) { _ in }
      return
    }
    guard String(data: request.data, encoding: .utf8) != nil else {
      request.resolve(false) { _ in }
      return
    }
    let pendingCount = queued.count + (active == nil ? 0 : 1)
    guard pendingCount < Self.maximumPending else {
      request.resolve(false) { _ in }
      return
    }
    queued.append(Pending(request, window: window))
    presentNext()
  }

  /// Explicit copy is a local user action, so it never prompts. The terminal
  /// owner produces immutable text asynchronously; this bridge alone decides
  /// whether that completion may still change the host pasteboard.
  func copy(from session: Session, selectionRevision: UInt64) {
    precondition(Thread.isMainThread)
    // `Session.selection` rejects synchronously before it schedules any main
    // completion. Do not supersede an already allowed OSC 52 write unless the
    // explicit copy was actually admitted to the owner queue.
    var permit: UInt64?
    var observedChangeCount: Int?
    let admitted = session.selection(.copy(expectedSelectionRevision: selectionRevision)) { [weak self] result in
      guard let self, let permit, let observedChangeCount,
        self.latestWritePermit == permit,
        case .success(let copiedText) = result, let copiedText
      else { return }
      self.write(Data(copiedText.utf8), permit: permit, expectedChangeCount: observedChangeCount)
    }
    guard admitted else { return }
    permit = issueWritePermit()
    observedChangeCount = pasteboard.changeCount
  }

  func cancel(sessionID: UUID) {
    precondition(Thread.isMainThread)
    queued.removeAll { pending in
      guard pending.request.sessionID == sessionID else { return false }
      pending.cancelled = true
      pending.request.resolve(false) { _ in }
      return true
    }
    if let active, active.request.sessionID == sessionID {
      active.cancelled = true
      self.active = nil
      active.dismiss?()
      active.request.resolve(false) { _ in }
      presentNext()
    }
    deniedSessions.remove(sessionID)
  }

  private func presentNext() {
    guard active == nil else { return }
    while !queued.isEmpty {
      let pending = queued.removeFirst()
      guard !pending.cancelled, pending.request.isLive,
        !deniedSessions.contains(pending.request.sessionID)
      else {
        pending.request.resolve(false) { _ in }
        continue
      }
      active = pending
      pending.dismiss = decide(pending.request, pending.window) { [weak self, weak pending] decision in
        guard let self, let pending, self.active === pending else { return }
        let allowed = decision == .allow && !pending.cancelled && pending.request.isLive
        if decision == .deny { self.deniedSessions.insert(pending.request.sessionID) }
        if allowed {
          pending.writePermit = self.issueWritePermit()
          pending.pasteboardChangeCount = self.pasteboard.changeCount
        }
        pending.request.resolve(allowed) { [weak self, weak pending] accepted in
          guard let self, let pending, self.active === pending else { return }
          if accepted, !pending.cancelled, pending.request.isLive,
            let permit = pending.writePermit, let changeCount = pending.pasteboardChangeCount
          {
            self.write(pending.request.data, permit: permit, expectedChangeCount: changeCount)
          }
          self.active = nil
          self.presentNext()
        }
      }
      return
    }
  }

  private func issueWritePermit() -> UInt64 {
    latestWritePermit &+= 1
    return latestWritePermit
  }

  /// The only pasteboard mutation path. A delayed owner completion cannot
  /// overwrite either a newer accepted request or an external clipboard edit.
  private func write(_ data: Data, permit: UInt64, expectedChangeCount: Int) {
    guard permit == latestWritePermit, pasteboard.changeCount == expectedChangeCount else { return }
    pasteboard.clearContents()
    _ = pasteboard.setData(data, forType: .string)
  }

  /// The default decision: every write is allowed, at once and without a prompt.
  static func allow(
    request: ClipboardWriteRequest, window: NSWindow?, completion: @escaping (ClipboardAccessDecision) -> Void
  ) -> (() -> Void)? {
    completion(.allow)
    return nil
  }
}

import AppKit

enum ClipboardAccessDecision {
  case allow, deny
}

// This is deliberately the only native owner of OSC 52 policy, prompting and
// pasteboard writes. It does not persist a grant or expose a general-purpose
// permission system.
final class ClipboardAccess {
  typealias DecisionHandler = (
    ClipboardWriteRequest, NSWindow?, @escaping (ClipboardAccessDecision) -> Void
  ) -> Void
  private final class Pending {
    let request: ClipboardWriteRequest
    weak var window: NSWindow?
    var cancelled = false
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

  init(pasteboard: NSPasteboard = .general, decide: @escaping DecisionHandler = ClipboardAccess.prompt) {
    precondition(Thread.isMainThread)
    self.pasteboard = pasteboard
    self.decide = decide
  }

  func request(_ request: ClipboardWriteRequest, from window: NSWindow?) {
    precondition(Thread.isMainThread)
    let pendingCount = queued.count + (active == nil ? 0 : 1)
    guard pendingCount < Self.maximumPending else {
      request.resolve(false) { _ in }
      return
    }
    queued.append(Pending(request, window: window))
    presentNext()
  }

  func cancel(sessionID: UUID) {
    precondition(Thread.isMainThread)
    queued.removeAll { pending in
      guard pending.request.sessionID == sessionID else { return false }
      pending.cancelled = true
      pending.request.resolve(false) { _ in }
      return true
    }
    guard let active, active.request.sessionID == sessionID else { return }
    active.cancelled = true
  }

  private func presentNext() {
    guard active == nil, !queued.isEmpty else { return }
    let pending = queued.removeFirst()
    active = pending
    decide(pending.request, pending.window) { [weak self, weak pending] decision in
      guard let self, let pending, self.active === pending else { return }
      let allowed = decision == .allow && !pending.cancelled && pending.request.isLive
      pending.request.resolve(allowed) { [weak self, weak pending] accepted in
        guard let self, let pending, self.active === pending else { return }
        if accepted && !pending.cancelled && pending.request.isLive {
          self.pasteboard.clearContents()
          _ = self.pasteboard.setData(pending.request.data, forType: .string)
        }
        self.active = nil
        self.presentNext()
      }
    }
  }

  private static func prompt(
    request: ClipboardWriteRequest, window: NSWindow?, completion: @escaping (ClipboardAccessDecision) -> Void
  ) {
    guard let window else {
      completion(.deny)
      return
    }
    let alert = NSAlert()
    alert.messageText = "Allow terminal clipboard write?"
    alert.informativeText = "A program in this terminal wants to write \(request.data.count) bytes to the clipboard."
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Deny")
    alert.beginSheetModal(for: window) { response in
      completion(response == .alertFirstButtonReturn ? .allow : .deny)
    }
  }
}

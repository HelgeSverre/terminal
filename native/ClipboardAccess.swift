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
  ) -> (() -> Void)?
  private final class Pending {
    let request: ClipboardWriteRequest
    weak var window: NSWindow?
    var cancelled = false
    var dismiss: (() -> Void)?
    init(_ request: ClipboardWriteRequest, window: NSWindow?) {
      self.request = request
      self.window = window
    }
  }
  static let maximumPending = 4
  private static let promptInterval: TimeInterval = 1
  private let pasteboard: NSPasteboard
  private let decide: DecisionHandler
  private let clock: () -> TimeInterval
  private var queued: [Pending] = []
  private var active: Pending?
  private var lastPromptAt: [UUID: TimeInterval] = [:]
  private var deniedSessions = Set<UUID>()

  init(
    pasteboard: NSPasteboard = .general, decide: @escaping DecisionHandler = ClipboardAccess.prompt,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    precondition(Thread.isMainThread)
    self.pasteboard = pasteboard
    self.decide = decide
    self.clock = clock
  }

  func request(_ request: ClipboardWriteRequest, from window: NSWindow?) {
    precondition(Thread.isMainThread)
    let now = clock()
    guard request.isLive, !deniedSessions.contains(request.sessionID),
      lastPromptAt[request.sessionID].map({ now - $0 >= Self.promptInterval }) ?? true
    else {
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
    lastPromptAt[request.sessionID] = now
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
    if let active, active.request.sessionID == sessionID {
      active.cancelled = true
      self.active = nil
      active.dismiss?()
      active.request.resolve(false) { _ in }
      presentNext()
    }
    lastPromptAt[sessionID] = nil
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
      return
    }
  }

  private static func prompt(
    request: ClipboardWriteRequest, window: NSWindow?, completion: @escaping (ClipboardAccessDecision) -> Void
  ) -> (() -> Void)? {
    guard let window else {
      completion(.deny)
      return nil
    }
    let alert = NSAlert()
    alert.messageText = "Allow terminal clipboard write?"
    alert.informativeText = "A program in this terminal wants to write \(request.data.count) bytes to the clipboard."
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Deny")
    alert.beginSheetModal(for: window) { response in
      completion(response == .alertFirstButtonReturn ? .allow : .deny)
    }
    return {
      if let parent = alert.window.sheetParent {
        parent.endSheet(alert.window, returnCode: .cancel)
      }
    }
  }
}

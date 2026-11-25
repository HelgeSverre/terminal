import Foundation
import TerminalEngine

extension TerminalSession {
  typealias SelectionCompletion = @MainActor (Result<String?, TerminalSelectionFailure>) -> Void
  package typealias LinkCompletion = @MainActor (Result<URL, TerminalSelectionFailure>) -> Void

  final class SelectionDelivery: @unchecked Sendable {
    let completion: SelectionCompletion
    let cost: Int
    let retainsCopyResult: Bool
    private let lock = NSLock()
    private var result: Result<String?, TerminalSelectionFailure>
    private var delivering = false
    init(completion: @escaping SelectionCompletion, cost: Int, retainsCopyResult: Bool,
         result: Result<String?, TerminalSelectionFailure>) {
      self.completion = completion; self.cost = cost; self.retainsCopyResult = retainsCopyResult
      self.result = result
    }
    func cancel() {
      lock.lock()
      if !delivering { result = .failure(.cancelled) }
      lock.unlock()
    }
    func takeForDelivery() -> Result<String?, TerminalSelectionFailure> {
      lock.lock()
      delivering = true
      let resolved = result
      lock.unlock()
      return resolved
    }
  }

  final class LinkDelivery: @unchecked Sendable {
    let completion: LinkCompletion
    let cost: Int
    private let lock = NSLock()
    private var result: Result<URL, TerminalSelectionFailure>
    private var delivering = false
    init(completion: @escaping LinkCompletion, cost: Int,
         result: Result<URL, TerminalSelectionFailure>) {
      self.completion = completion; self.cost = cost; self.result = result
    }
    func cancel() {
      lock.lock()
      if !delivering { result = .failure(.cancelled) }
      lock.unlock()
    }
    func takeForDelivery() -> Result<URL, TerminalSelectionFailure> {
      lock.lock()
      delivering = true
      let resolved = result
      lock.unlock()
      return resolved
    }
  }

  private static let selectionBaseCost = 256
  private static let selectionPresentationCost = 128
  private static let selectionProofRowCost = MemoryLayout<TerminalSelectionPresentation.Row>.stride
  private static let linkBaseCost = 256

  private static func selectionCost(_ action: TerminalSelectionAction) -> Int? {
    func hitCost(_ hit: TerminalSelectionHit) -> Int? {
      let (proofBytes, proofOverflow) = hit.presentation.rows.count.multipliedReportingOverflow(
        by: selectionProofRowCost)
      guard !proofOverflow else { return nil }
      let (presentationBytes, presentationOverflow) = proofBytes.addingReportingOverflow(
        selectionPresentationCost)
      return presentationOverflow ? nil : presentationBytes
    }
    let hits: [TerminalSelectionHit]
    switch action {
    case .begin(let hit, _), .extend(let hit): hits = [hit]
    case .range(let start, let end, _): hits = [start, end]
    case .commit, .clear, .copy, .wordProfile: hits = []
    }
    var cost = selectionBaseCost
    for hit in hits {
      guard let costForHit = hitCost(hit) else { return nil }
      let (next, overflow) = cost.addingReportingOverflow(costForHit)
      guard !overflow else { return nil }
      cost = next
    }
    return cost
  }

  private static func linkCost(content: TerminalPresentedContent, target: URL) -> Int? {
    guard let proofBytes = content.retainedByteCount else { return nil }
    let (withProof, proofOverflow) = linkBaseCost.addingReportingOverflow(proofBytes)
    let (cost, urlOverflow) = withProof.addingReportingOverflow(target.absoluteString.utf8.count)
    return proofOverflow || urlOverflow ? nil : cost
  }

  private static func selectionIsControl(_ action: TerminalSelectionAction) -> Bool {
    if case .clear = action { return true }
    if case .commit = action { return true }
    if case .wordProfile = action { return true }
    return false
  }

  private func reserveSelection(_ cost: Int, control: Bool, retainsCopyResult: Bool) -> Admission {
    admission.lock()
    defer { admission.unlock() }
    let limit = 2 * 1024 * 1024 - (control ? 0 : 65_536)
    guard !interactionClosed else { return .closed }
    guard !retainsCopyResult || outstandingSelectionCopyCompletions == 0 else { return .busy }
    guard cost <= limit, admittedBytes + cost <= limit else { return .busy }
    admittedBytes += cost
    if retainsCopyResult { outstandingSelectionCopyCompletions += 1 }
    return .accepted
  }

  func finishSelection(cost: Int, completion: SelectionCompletion?, retainsCopyResult: Bool,
                       result: Result<String?, TerminalSelectionFailure>) {
    selectionPending = false
    guard let completion else {
      precondition(!retainsCopyResult)
      release(cost)
      return
    }
    let delivery = SelectionDelivery(completion: completion, cost: cost,
                                     retainsCopyResult: retainsCopyResult, result: result)
    selectionDeliveries.append(delivery)
    DispatchQueue.main.async { [self, delivery] in
      admission.lock()
      let cancelled = interactionClosed
      admission.unlock()
      if cancelled { delivery.cancel() }
      delivery.completion(delivery.takeForDelivery())
      release(delivery.cost)
      if delivery.retainsCopyResult {
        admission.lock()
        outstandingSelectionCopyCompletions -= 1
        admission.unlock()
      }
      readBroker.submit { [self, delivery] in
        removeSelectionDelivery(delivery)
      }
    }
  }

  private func removeSelectionDelivery(_ delivery: SelectionDelivery) {
    selectionDeliveries.removeAll { $0 === delivery }
  }

  func finishLink(cost: Int, completion: @escaping LinkCompletion,
                  result: Result<URL, TerminalSelectionFailure>) {
    linkPending = false
    let delivery = LinkDelivery(completion: completion, cost: cost, result: result)
    linkDeliveries.append(delivery)
    DispatchQueue.main.async { [self, delivery] in
      admission.lock()
      let cancelled = interactionClosed
      admission.unlock()
      if cancelled { delivery.cancel() }
      delivery.completion(delivery.takeForDelivery())
      release(delivery.cost)
      readBroker.submit { [self, delivery] in
        removeLinkDelivery(delivery)
      }
    }
  }

  private func removeLinkDelivery(_ delivery: LinkDelivery) {
    linkDeliveries.removeAll { $0 === delivery }
  }

  func clearSelectionForAcceptedInput(_ core: OpaquePointer) {
    // Input has reached the core only after every earlier selection event has
    // settled. Clear is an immediate owner-side action; it must never begin a
    // second resumable operation without a matching FIFO event to advance it.
    if case .completed = TerminalSelectionBridge.begin(core: core, action: .clear) {}
  }

  /// Submits an immutable, presentation-proven selection gesture. The host
  /// never reads cells or derives copied text; success carries the core-built
  /// copy (where `nil` means a non-copy selection action).
  @discardableResult package func selection(
    _ action: TerminalSelectionAction,
    completion: (@MainActor (Result<String?, TerminalSelectionFailure>) -> Void)? = nil
  ) -> Bool {
    guard let cost = Self.selectionCost(action) else {
      report("Selection request exceeds queue limit")
      return false
    }
    let retainsCopyResult: Bool = {
      if case .copy = action { return completion != nil }
      return false
    }()
    let admission = reserveSelection(cost, control: Self.selectionIsControl(action),
                                     retainsCopyResult: retainsCopyResult)
    guard admission == .accepted else {
      report(admission.message)
      return false
    }
    readBroker.submit { [self] in
      guard !closed else {
        finishSelection(cost: cost, completion: completion, retainsCopyResult: retainsCopyResult,
                        result: .failure(.cancelled))
        return
      }
      enqueue(.selection(action, completion, cost, false, retainsCopyResult))
    }
    return true
  }

  /// Validates a recognized URL against the immutable rows that were actually
  /// presented to the user. URL parsing and policy stay in the projection;
  /// this boundary only proves that those rows still describe the same content
  /// before returning the exact captured URL to Canvas.
  @discardableResult package func activateLink(
    _ activation: VisibleLinkProjection.Activation,
    completion: @escaping LinkCompletion
  ) -> Bool {
    guard let cost = Self.linkCost(content: activation.content, target: activation.target) else {
      report("Link activation exceeds queue limit")
      return false
    }
    let admission = reserveInteraction(cost)
    guard admission == .accepted else {
      report(admission.message)
      return false
    }
    readBroker.submit { [self] in
      guard !closed else {
        finishLink(cost: cost, completion: completion, result: .failure(.cancelled))
        return
      }
      enqueue(.link(activation.content, activation.target, completion, cost, false))
    }
    return true
  }
}

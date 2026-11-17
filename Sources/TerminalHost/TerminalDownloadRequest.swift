import Foundation
import TerminalEngine

/// A completed file offered by terminal output. The payload remains bounded
/// inside the engine until the application explicitly takes or dismisses it.
/// Present a save destination only after the user chooses to save this offer.
public final class TerminalDownloadRequest: @unchecked Sendable {
  public let id = UUID()
  public let suggestedFilename: String
  public let byteCount: Int
  private enum State: Equatable { case pending, requested, finished, cancelled }
  private let lock = NSLock()
  private var state = State.pending
  private let generation: TerminalDownloadGeneration?
  private let live: () -> Bool
  private let resolve: (Bool, @escaping @MainActor (Data?) -> Void) -> Void

  init(suggestedFilename: String, byteCount: Int, generation: TerminalDownloadGeneration? = nil, live: @escaping () -> Bool,
       resolve: @escaping (Bool, @escaping @MainActor (Data?) -> Void) -> Void) {
    self.suggestedFilename = suggestedFilename; self.byteCount = byteCount
    self.generation = generation
    self.live = live; self.resolve = resolve
  }
  public var isAvailable: Bool {
    lock.lock(); let pending = state == .pending; lock.unlock()
    return pending && (generation?.isLive ?? true) && live()
  }
  /// Takes the payload once, on the session's owner queue. Completion always
  /// runs on the main actor. Close, reset, dismissal or a repeated take returns
  /// nil. The application now owns the returned data and any explicit save.
  public func takeData(_ completion: @escaping @MainActor (Data?) -> Void) {
    lock.lock()
    guard state == .pending else { lock.unlock(); DispatchQueue.main.async { completion(nil) }; return }
    state = .requested; lock.unlock()
    resolve(true) { [self] data in
      lock.lock()
      let accepted = state == .requested
      state = .finished; lock.unlock()
      completion(accepted && (generation?.isLive ?? true) && live() ? data : nil)
    }
  }
  /// Dismisses an offer without opening a file or writing its bytes. This also
  /// cancels a queued take whose completion has not been delivered yet.
  public func dismiss() {
    lock.lock()
    let release = state == .pending
    if state == .pending || state == .requested { state = .cancelled }
    lock.unlock()
    if release { resolve(false) { _ in } }
  }
  func invalidate() { lock.lock(); state = .cancelled; lock.unlock() }
}

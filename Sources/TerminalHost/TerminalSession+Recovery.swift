import Foundation
import TerminalEngine

extension TerminalSession {
  /// Returns a checkpoint, or the delay until a dirty pane is eligible. Only
  /// one capture is admitted per session; the app schedules panes serially.
  package func recoveryCheckpoint(force: Bool = false,
    completion: @escaping @MainActor (String?, Int, Double?) -> Void) {
    readBroker.submit { [self] in
      guard !closed else { DispatchQueue.main.async { completion(nil, 0, nil) }; return }
      enqueue(.recoveryCheckpoint(force, completion))
    }
  }

  /// Read-only primary history capture, independent of checkpoint dirtiness.
  /// One bounded capture is admitted; the caller receives nil when busy/closed.
  package func recoveryHistory(maximumBytes: Int,
    completion: @escaping @MainActor (String?) -> Void) {
    readBroker.submit { [self] in
      guard !closed else { DispatchQueue.main.async { completion(nil) }; return }
      enqueue(.recoveryRead(min(16 * 1024 * 1024, max(0, maximumBytes)), completion))
    }
  }

  func recoveryDidChange(at now: UInt64) {
    if onRecoveryActivity != nil, recoveryTiming.output(at: now) {
      DispatchQueue.main.async { [weak self] in self?.onRecoveryActivity?() }
    }
  }

  func beginRecoveryCheckpoint(force: Bool,
    completion: @escaping @MainActor (String?, Int, Double?) -> Void) {
    guard !closed, let core,
      let delay = recoveryTiming.delay(at: DispatchTime.now().uptimeNanoseconds, force: force) else {
      DispatchQueue.main.async { completion(nil, 0, nil) }; return
    }
    guard !recoveryCapturing else {
      // A read-only automation capture must not consume the app's one dirty
      // wakeup. Keep its checkpoint pending until the capture slot is free.
      DispatchQueue.main.async { completion(nil, 0, 0.05) }; return
    }
    guard delay == 0 else { DispatchQueue.main.async { completion(nil, 0, delay) }; return }
    recoveryCapturing = true
    recoveryTiming.captured()
    let capture = TerminalRecoveryBridge.capture(core: core)
    advanceRecovery(capture, completion: completion)
  }

  func advanceRecovery(_ capture: TerminalRecoveryCapture,
    completion: @escaping @MainActor (String?, Int, Double?) -> Void) {
    guard !closed else {
      recoveryCapturing = false
      DispatchQueue.main.async { completion(nil, 0, nil) }; return
    }
    if let text = capture.advance() {
      recoveryCapturing = false
      let rows = capture.capturedRows
      DispatchQueue.main.async { completion(text, rows, nil) }
    } else {
      // Re-enter behind admitted input/output instead of holding the FIFO
      // head while capturing up to the existing 16 MiB copy limit.
      queue.async { [self] in
        readBroker.submit { [self] in advanceRecovery(capture, completion: completion) }
      }
    }
  }
}

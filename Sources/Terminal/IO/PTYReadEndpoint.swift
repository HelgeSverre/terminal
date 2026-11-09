import Foundation

/// Read-source state belongs exclusively to one shared serial IO lane. Owner
/// notifications are coalesced; descriptor operations use generation leases.
final class PTYReadEndpoint: @unchecked Sendable {
  private static let lane = DispatchQueue(label: "no.helgesverre.terminal.shared-io", qos: .userInteractive)
  private let lock = NSLock()
  private let broker: PTYReadBroker
  private let lifetime: PTYDescriptorLifetime
  private let eofObserved: () -> Void
  private let source: DispatchSourceRead
  #if SESSION_IO_TESTING
  var willPauseForCredit: (() -> Void)?
  var didPauseForCredit: (() -> Void)?
  #endif
  private var notificationPending = false
  private var stopped = false
  private var writeBlocked = false
  private var paused = false
  // IO lane only, including initial activation.
  private var suspended = false
  private var cancelled = false

  init(fd: Int32, broker: PTYReadBroker, lifetime: PTYDescriptorLifetime,
       eofObserved: @escaping () -> Void) {
    self.broker = broker; self.lifetime = lifetime; self.eofObserved = eofObserved
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.lane)
    source.setEventHandler { [weak self] in self?.readAvailable() }
    source.setCancelHandler { lifetime.sourceCancelled(0) }
    source.resume()
  }
  func update(writeBytes: Int) {
    lock.lock()
    let previous = writeBlocked
    if writeBytes >= 3 * 1024 * 1024 { writeBlocked = true }
    else if writeBytes < 1536 * 1024 { writeBlocked = false }
    if !stopped && !notificationPending && (paused || previous != writeBlocked) {
      notificationPending = true
      Self.lane.async { [self] in refresh() }
    }
    lock.unlock()
  }
  func close() {
    broker.stopReading()
    lifetime.beginClose()
    lock.lock()
    stopped = true
    if !notificationPending {
      notificationPending = true
      Self.lane.async { [self] in refresh() }
    }
    lock.unlock()
  }
  private func refresh() {
    lock.lock(); notificationPending = false
    let stop = stopped, blocked = writeBlocked
    lock.unlock()
    if stop { cancelSource(); return }
    let credit = broker.credit
    if blocked || credit.bytes == 0 || credit.nodes == 0 {
      pauseSource(); return
    }
    if suspended && broker.mayResumeReading {
      source.resume(); suspended = false
      broker.noteReadInterest(suspended: false)
      lock.lock(); paused = false; lock.unlock()
      readAvailable()
    }
  }
  private func pauseSource(recheckCredit: Bool = false) {
    if !suspended && !cancelled {
      source.suspend(); suspended = true; broker.noteReadInterest(suspended: true)
    }
    lock.lock(); paused = true
    // Consumption can race between a failed read-credit check and publishing
    // paused. Recheck once after publication so that credit cannot be stranded
    // when the owner's earlier notification observed the source still active.
    if recheckCredit && !notificationPending {
      notificationPending = true
      Self.lane.async { [self] in refresh() }
    }
    lock.unlock()
  }
  private func cancelSource() {
    guard !cancelled else { return }
    cancelled = true
    if suspended { source.resume(); suspended = false; broker.noteReadInterest(suspended: false) }
    source.cancel()
  }
  private func readAvailable() {
    let started = broker.beginReadTurn()
    defer { broker.endReadTurn(started) }
    var total = 0
    while total < PTYReadBroker.readQuantum {
      lock.lock(); let stop = stopped, blocked = writeBlocked; lock.unlock()
      if stop { cancelSource(); return }
      if blocked { pauseSource(); return }
      let result = broker.readOnce { buffer in
        lifetime.withLease { fd in
          let count = Darwin.read(fd, buffer.baseAddress!, buffer.count)
          return (count, count < 0 ? errno : 0)
        } ?? (-1, EBADF)
      }
      switch result {
      case .bytes(let count): total += count
      case .wouldBlock: return
      case .interrupted: continue
      case .creditExhausted:
        #if SESSION_IO_TESTING
        willPauseForCredit?()
        #endif
        pauseSource(recheckCredit: true)
        #if SESSION_IO_TESTING
        didPauseForCredit?()
        #endif
        return
      case .ended:
        eofObserved()
        lifetime.beginClose()
        lock.lock(); stopped = true; lock.unlock()
        cancelSource(); return
      }
    }
  }
}

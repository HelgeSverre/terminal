import Foundation

/// The descriptor cannot be reused until every source cancellation and every
/// in-flight read/write/ioctl lease has retired. Closing is idempotent and does
/// not execute the supplied close operation while holding the state lock.
final class PTYDescriptorLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private let descriptor: Int32
  private let closeDescriptor: (Int32) -> Void
  private var pendingSources: Set<Int>
  private var activeLeases = 0
  private var stopping = false
  private var retired = false

  init(descriptor: Int32, sources: Int, close: @escaping (Int32) -> Void = { _ = Darwin.close($0) }) {
    precondition(descriptor >= 0 && sources > 0)
    self.descriptor = descriptor; pendingSources = Set(0..<sources); closeDescriptor = close
  }
  func withLease<Result>(_ body: (Int32) throws -> Result) rethrows -> Result? {
    lock.lock()
    guard !stopping && !retired else { lock.unlock(); return nil }
    activeLeases += 1
    lock.unlock()
    defer { releaseLease() }
    return try body(descriptor)
  }
  func beginClose() {
    lock.lock(); stopping = true
    let close = retireIfReady()
    lock.unlock()
    if close { closeDescriptor(descriptor) }
  }
  func sourceCancelled(_ source: Int) {
    lock.lock()
    pendingSources.remove(source)
    let close = retireIfReady()
    lock.unlock()
    if close { closeDescriptor(descriptor) }
  }
  private func releaseLease() {
    lock.lock(); precondition(activeLeases > 0); activeLeases -= 1
    let close = retireIfReady()
    lock.unlock()
    if close { closeDescriptor(descriptor) }
  }
  private func retireIfReady() -> Bool {
    if stopping && pendingSources.isEmpty && activeLeases == 0 && !retired {
      retired = true
      return true
    }
    return false
  }
}

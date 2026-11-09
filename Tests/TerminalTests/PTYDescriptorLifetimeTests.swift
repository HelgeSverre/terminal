import Foundation

@main enum PTYDescriptorLifetimeTests {
  final class Observations: @unchecked Sendable {
    let lock = NSLock()
    private var count = 0
    func closed(_ fd: Int32) { precondition(fd == 42); lock.lock(); count += 1; lock.unlock() }
    var closes: Int { lock.lock(); defer { lock.unlock() }; return count }
  }
  static func main() {
    for cancelFirst in [false, true] {
      let observations = Observations()
      let endpoint = PTYDescriptorLifetime(descriptor: 42, sources: 2, close: observations.closed)
      let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        let result = endpoint.withLease { fd in
          precondition(fd == 42); entered.signal(); release.wait(); return 7
        }
        precondition(result == 7); finished.signal()
      }
      entered.wait()
      if cancelFirst { endpoint.sourceCancelled(0); endpoint.sourceCancelled(1) }
      endpoint.beginClose()
      if !cancelFirst { endpoint.sourceCancelled(1); endpoint.sourceCancelled(0) }
      endpoint.sourceCancelled(0)
      precondition(endpoint.withLease { _ in 1 } == nil && observations.closes == 0)
      release.signal(); finished.wait()
      precondition(observations.closes == 1)
      endpoint.beginClose(); endpoint.sourceCancelled(1)
      precondition(observations.closes == 1)
      // Numeric reuse belongs to a new lifetime. The old object is permanently
      // closed, so even a late callback cannot obtain the replacement fd.
      let reused = PTYDescriptorLifetime(descriptor: 42, sources: 1, close: observations.closed)
      precondition(endpoint.withLease { _ in 1 } == nil)
      precondition(reused.withLease { $0 } == 42)
      reused.beginClose(); reused.sourceCancelled(0)
      precondition(observations.closes == 2)
    }
    print("PASS descriptor lifetime: cancellation orders, held leases, close once, duplicate acknowledgments, fd reuse")
  }
}

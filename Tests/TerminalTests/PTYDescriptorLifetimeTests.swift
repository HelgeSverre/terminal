import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

@Suite struct PTYDescriptorLifetimeTests {
  final class Observations: @unchecked Sendable {
    let lock = NSLock()
    private var count = 0
    private var wrong = false
    func closed(_ fd: Int32) { lock.lock(); if fd != 42 { wrong = true }; count += 1; lock.unlock() }
    var closes: Int { lock.lock(); defer { lock.unlock() }; return count }
    var closedWrongDescriptor: Bool { lock.lock(); defer { lock.unlock() }; return wrong }
  }

  /// Cancellation orders, held leases, close once, duplicate acknowledgments, fd reuse.
  @Test(arguments: [false, true]) static func lifetime(cancelFirst: Bool) {
    let observations = Observations()
    let endpoint = PTYDescriptorLifetime(descriptor: 42, sources: 2, close: observations.closed)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let result = endpoint.withLease { fd in
        #expect(fd == 42); entered.signal(); release.wait(); return 7
      }
      #expect(result == 7); finished.signal()
    }
    entered.wait()
    if cancelFirst { endpoint.sourceCancelled(0); endpoint.sourceCancelled(1) }
    endpoint.beginClose()
    if !cancelFirst { endpoint.sourceCancelled(1); endpoint.sourceCancelled(0) }
    endpoint.sourceCancelled(0)
    #expect(endpoint.withLease { _ in 1 } == nil && observations.closes == 0)
    release.signal(); finished.wait()
    #expect(observations.closes == 1)
    endpoint.beginClose(); endpoint.sourceCancelled(1)
    #expect(observations.closes == 1)
    // Numeric reuse belongs to a new lifetime. The old object is permanently
    // closed, so even a late callback cannot obtain the replacement fd.
    let reused = PTYDescriptorLifetime(descriptor: 42, sources: 1, close: observations.closed)
    #expect(endpoint.withLease { _ in 1 } == nil)
    #expect(reused.withLease { $0 } == 42)
    reused.beginClose(); reused.sourceCancelled(0)
    #expect(observations.closes == 2)
    #expect(!observations.closedWrongDescriptor)
  }
}

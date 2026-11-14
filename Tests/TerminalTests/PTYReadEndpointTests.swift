import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession

@Suite struct PTYReadEndpointTests {
  final class Fixture: @unchecked Sendable {
    let owner = DispatchQueue(label: "endpoint-test-owner")
    let ownerEntered = DispatchSemaphore(value: 0), releaseOwner = DispatchSemaphore(value: 0)
    let drainedInitial = DispatchSemaphore(value: 0), drainedFinal = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    var broker: PTYReadBroker!
    var endpoint: PTYReadEndpoint!
    var delivered = 0 // owner-only
    var pausedOnce = false // IO lane-only
    func run() {
      var fds: [Int32] = [0, 0]
      #expect(pipe(&fds) == 0)
      #expect(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0)
      owner.async { self.ownerEntered.signal(); self.releaseOwner.wait() }
      ownerEntered.wait()
      let lifetime = PTYDescriptorLifetime(descriptor: fds[0], sources: 1) { fd in
        Darwin.close(fd); self.closed.signal()
      }
      broker = PTYReadBroker(owner: owner, byteLimit: 8, nodeLimit: 2, slabSize: 4,
        deliver: { [self] data in
          delivered += data.count
          broker.consumed(data.count, completedNode: true)
          endpoint.update(writeBytes: 0)
          if delivered == 8 { drainedInitial.signal() }
          if delivered == 9 { drainedFinal.signal() }
        }, ended: { _ in })
      endpoint = PTYReadEndpoint(fd: fds[0], broker: broker, lifetime: lifetime,
        eofObserved: {})
      endpoint.willPauseForCredit = { [self] in
          guard !pausedOnce else { return }; pausedOnce = true
          // Return every credit before paused becomes visible. The owner sees
          // an active source, so only the post-publication recheck can resume.
          releaseOwner.signal(); drainedInitial.wait()
        }
      let bytes = Array("123456789".utf8)
      #expect(bytes.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress!, $0.count) } == 9)
      #expect(drainedFinal.wait(timeout: .now() + 5) == .success)
      endpoint.close()
      #expect(closed.wait(timeout: .now() + 5) == .success)
      Darwin.close(fds[1])
      owner.sync { #expect(delivered == 9) }
    }
  }

  /// Credit returned before pause publication resumes without another owner
  /// notification; cancellation retires the source.
  @Test static func creditReturnedBeforePause() {
    Fixture().run()
  }

  @Test static func suspendedCloseWithLease() {
    var fds: [Int32] = [0, 0]; #expect(pipe(&fds) == 0)
    #expect(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0)
    let owner = DispatchQueue(label: "suspended-close-owner")
    let ownerHeld = DispatchSemaphore(value: 0), releaseOwner = DispatchSemaphore(value: 0)
    owner.async { ownerHeld.signal(); releaseOwner.wait() }; ownerHeld.wait()
    let paused = DispatchSemaphore(value: 0), releasePause = DispatchSemaphore(value: 0)
    let leaseHeld = DispatchSemaphore(value: 0), releaseLease = DispatchSemaphore(value: 0)
    let leaseDone = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
    let lifetime = PTYDescriptorLifetime(descriptor: fds[0], sources: 2) { fd in Darwin.close(fd); closed.signal() }
    DispatchQueue.global().async {
      _ = lifetime.withLease { _ in leaseHeld.signal(); releaseLease.wait() }
      leaseDone.signal()
    }
    leaseHeld.wait()
    let broker = PTYReadBroker(owner: owner, byteLimit: 8, nodeLimit: 2, slabSize: 4, deliver: { _ in }, ended: { _ in })
    let endpoint = PTYReadEndpoint(fd: fds[0], broker: broker, lifetime: lifetime, eofObserved: {})
    endpoint.didPauseForCredit = { paused.signal(); releasePause.wait() }
    let bytes = Array("123456789".utf8)
    #expect(bytes.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress!, $0.count) } == 9)
    #expect(paused.wait(timeout: .now() + 5) == .success)
    endpoint.close(); lifetime.sourceCancelled(1)
    #expect(lifetime.withLease { _ in 1 } == nil)
    #expect(closed.wait(timeout: .now()) == .timedOut)
    releasePause.signal(); releaseLease.signal(); leaseDone.wait()
    #expect(closed.wait(timeout: .now() + 5) == .success)
    endpoint.close(); lifetime.sourceCancelled(1)
    #expect(closed.wait(timeout: .now()) == .timedOut)
    releaseOwner.signal(); owner.sync {}; Darwin.close(fds[1])
  }
}

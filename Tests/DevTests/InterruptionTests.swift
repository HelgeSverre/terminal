import Foundation
import Testing
@testable import dev

/// Serialized: the test installs and restores this process's SIGINT and SIGTERM handling.
@Suite(.serialized) struct InterruptionTests {
  @Test("interruption: an observing runner is told once, and the default is restored") func anObservingRunnerIsToldOnce() throws {
    Interruption.observe()
    defer { Interruption.endRun() }
    try Interruption.check()
    kill(getpid(), SIGTERM)
    let deadline = Clock.now + 2_000_000_000
    while !Interruption.requested, Clock.now < deadline { usleep(5_000) }
    #expect(Interruption.requested, "the signal is recorded as a request")
    let checkFailure = try #require(throws: Failure.self) { try Interruption.check() }
    #expect(checkFailure.message == "interrupted", "check fails")
    let tree = try ProcessTree(["/bin/sleep", "30"])
    defer { tree.cleanup() }
    let waitFailure = try #require(throws: Failure.self) { _ = try tree.waitInterruptibly(seconds: 5) }
    #expect(waitFailure.message == "interrupted", "a wait ends early")
    Interruption.endRun()
    #expect(!Interruption.requested, "a new run starts without a request")
  }
}

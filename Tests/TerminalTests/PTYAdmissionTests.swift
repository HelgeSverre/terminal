import Foundation
import Testing
@testable import TerminalApp

@Suite struct PTYAdmissionTests {
  final class State: @unchecked Sendable {
    var bytes = 0
    var atControl = -1
    var log: [String] = []
    var broker: PTYReadBroker!
  }

  /// Exact bounded queued-ahead bytes and the control barrier.
  @Test(arguments: [true, false]) static func boundedQueuedAhead(useDefault: Bool) {
    let cap = useDefault ? 65_536 : 8192
    let owner = DispatchQueue(label: "ahead-test")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    owner.async { entered.signal(); release.wait() }; entered.wait()
    let state = State()
    let deliver: (Data) -> Void = { data in
      state.bytes += data.count; state.broker.consumed(data.count, completedNode: true)
    }
    if useDefault {
      state.broker = PTYReadBroker(owner: owner, deliver: deliver, ended: { _ in })
    } else {
      state.broker = PTYReadBroker(owner: owner, byteLimit: cap, deliver: deliver, ended: { _ in })
    }
    var admitted = 0
    while true {
      let result = state.broker.readOnce { buffer in buffer.initializeMemory(as: UInt8.self, repeating: 65); return (buffer.count, 0) }
      if case .creditExhausted = result { break }
      guard case .bytes(let count) = result else { Issue.record("expected bytes or creditExhausted"); release.signal(); return }
      admitted += count
      #expect(admitted <= cap, "Production default must bound queued predecessor work to one read quantum")
      if admitted > cap { release.signal(); return }
    }
    state.broker.submit { state.atControl = state.bytes }
    var readAgain = false
    if case .creditExhausted = state.broker.readOnce({ _ in readAgain = true; return (0, 0) }) {} else { Issue.record("expected creditExhausted after control") }
    #expect(!readAgain)
    release.signal(); owner.sync {}
    #expect(state.atControl == cap && state.bytes == cap)
    #expect(state.broker.credit.bytes == cap)
  }

  /// Input is admitted before peer EOF but its owner event runs afterwards.
  /// EOF prevents the pending transport write while preserving data order.
  @Test static func eofVersusAcceptedInput() {
    let owner = DispatchQueue(label: "eof-input-test")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    owner.async { entered.signal(); release.wait() }; entered.wait()
    let lifetime = PTYDescriptorLifetime(descriptor: 42, sources: 2, close: { _ in })
    let state = State()
    state.broker = PTYReadBroker(owner: owner, deliver: { data in
      state.log.append("data"); state.broker.consumed(data.count, completedNode: true)
    }, ended: { _ in state.log.append("EOF") })
    _ = state.broker.readOnce { buffer in buffer[0] = 65; return (1, 0) }
    state.broker.submit {
      state.log.append("input-admitted")
      owner.async {
        #expect(lifetime.withLease { _ in true } == nil)
        state.log.append("input-released-without-write")
      }
    }
    _ = state.broker.readOnce { _ in lifetime.withLease { _ in (0, Int32(0)) }! }
    lifetime.beginClose(); lifetime.sourceCancelled(0); lifetime.sourceCancelled(1)
    release.signal(); owner.sync {}; owner.sync {}
    #expect(state.log == ["data", "input-admitted", "EOF", "input-released-without-write"])
  }
}

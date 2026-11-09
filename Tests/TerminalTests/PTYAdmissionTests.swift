import Foundation

@main enum PTYAdmissionTests {
  final class State: @unchecked Sendable {
    var bytes = 0
    var atControl = -1
    var log: [String] = []
    var broker: PTYReadBroker!
  }
  static func main() {
    for useDefault in [true, false] {
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
        guard case .bytes(let count) = result else { preconditionFailure() }
        admitted += count
        precondition(admitted <= cap, "Production default must bound queued predecessor work to one read quantum")
      }
      state.broker.submit { state.atControl = state.bytes }
      if case .creditExhausted = state.broker.readOnce({ _ in preconditionFailure() }) {} else { preconditionFailure() }
      release.signal(); owner.sync {}
      precondition(state.atControl == cap && state.bytes == cap)
      precondition(state.broker.credit.bytes == cap)
    }
    // Input is admitted before peer EOF but its owner event runs afterwards.
    // EOF prevents the pending transport write while preserving data order.
    let owner = DispatchQueue(label: "eof-input-test")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    owner.async { entered.signal(); release.wait() }; entered.wait()
    let lifetime = PTYDescriptorLifetime(descriptor: 42, sources: 2, close: { precondition($0 == 42) })
    let state = State()
    state.broker = PTYReadBroker(owner: owner, deliver: { data in
      state.log.append("data"); state.broker.consumed(data.count, completedNode: true)
    }, ended: { _ in state.log.append("EOF") })
    _ = state.broker.readOnce { buffer in buffer[0] = 65; return (1, 0) }
    state.broker.submit {
      state.log.append("input-admitted")
      owner.async {
        precondition(lifetime.withLease { _ in true } == nil)
        state.log.append("input-released-without-write")
      }
    }
    _ = state.broker.readOnce { _ in lifetime.withLease { _ in (0, Int32(0)) }! }
    lifetime.beginClose(); lifetime.sourceCancelled(0); lifetime.sourceCancelled(1)
    release.signal(); owner.sync {}; owner.sync {}
    precondition(state.log == ["data", "input-admitted", "EOF", "input-released-without-write"])
    print("PASS admission: exact bounded queued-ahead bytes, control barrier, EOF versus accepted input and descriptor write rejection")
  }
}

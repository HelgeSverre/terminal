import Foundation

/// Orders read deliveries and semantic submissions onto the terminal owner.
/// The Event queue and terminal mutation remain confined to that owner.
/// All semantic queue submissions must use submit, including submissions made
/// from the owner itself. Owner callbacks never run under the admission lock.
final class PTYReadBroker: @unchecked Sendable {
  static let readQuantum = 65_536
  private final class Batch {
    var data = Data()
    var sealed = false
  }
  private let lock = NSLock()
  private let owner: DispatchQueue
  private let deliver: (Data) -> Void
  private let ended: (Int32) -> Void
  private let byteLimit: Int
  private let nodeLimit: Int
  private let slabSize: Int
  private var slab: [UInt8]
  private var tail: Batch?
  private var bytes = 0
  private var nodes = 0
  private var stopped = false
  struct Statistics {
    var bytesRead: UInt64 = 0
    var firstReadNs: UInt64 = 0
    var readCallbacks: UInt64 = 0
    var readCalls: UInt64 = 0
    var readNanoseconds: UInt64 = 0
    var suspends = 0, resumes = 0, queuedBytesHighWater = 0
  }
  private let diagnostics: Bool
  private var statistics = Statistics()

  init(owner: DispatchQueue, byteLimit: Int = PTYReadBroker.readQuantum,
       nodeLimit: Int = 256, slabSize: Int = 16_384, diagnostics: Bool = false,
       deliver: @escaping (Data) -> Void, ended: @escaping (Int32) -> Void) {
    precondition(byteLimit > 0 && nodeLimit > 0 && slabSize > 0)
    self.owner = owner; self.byteLimit = byteLimit; self.nodeLimit = nodeLimit
    self.slabSize = slabSize; slab = Array(repeating: 0, count: slabSize)
    self.deliver = deliver; self.ended = ended
    self.diagnostics = diagnostics
  }
  func submit(_ operation: @escaping () -> Void) {
    lock.lock()
    tail?.sealed = true; tail = nil
    owner.async(execute: operation)
    lock.unlock()
  }
  enum ReadResult { case bytes(Int), wouldBlock, interrupted, creditExhausted, ended }
  /// Nonblocking syscall only. A callback must neither wait nor reenter.
  func readOnce(_ read: (UnsafeMutableRawBufferPointer) -> (Int, Int32)) -> ReadResult {
    lock.lock(); defer { lock.unlock() }
    guard !stopped else { return .ended }
    let existingRoom = tail.map { $0.sealed ? 0 : slabSize - $0.data.count } ?? 0
    let room = existingRoom > 0 ? existingRoom : (nodes < nodeLimit ? slabSize : 0)
    let amount = min(room, byteLimit - bytes)
    guard amount > 0 else { return .creditExhausted }
    if diagnostics { statistics.readCalls += 1 }
    let (count, error) = slab.withUnsafeMutableBytes {
      read(UnsafeMutableRawBufferPointer(rebasing: $0[..<amount]))
    }
    precondition(count <= amount)
    if count > 0 {
      let batch: Batch
      if let existing = tail, !existing.sealed && existing.data.count < slabSize {
        batch = existing
      } else {
        batch = Batch(); tail = batch; nodes += 1
        owner.async { [self, batch] in
          lock.lock()
          batch.sealed = true
          if tail === batch { tail = nil }
          let data = batch.data
          lock.unlock()
          deliver(data)
        }
      }
      slab.withUnsafeBytes { batch.data.append($0.bindMemory(to: UInt8.self).baseAddress!, count: count) }
      bytes += count
      if diagnostics { statistics.queuedBytesHighWater = max(statistics.queuedBytesHighWater, bytes) }
      statistics.bytesRead += UInt64(count)
      if statistics.firstReadNs == 0 { statistics.firstReadNs = DispatchTime.now().uptimeNanoseconds }
      return .bytes(count)
    }
    if count < 0 && error == EINTR { return .interrupted }
    if count < 0 && (error == EAGAIN || error == EWOULDBLOCK) { return .wouldBlock }
    stopped = true; tail?.sealed = true; tail = nil
    owner.async { [ended] in ended(count == 0 ? 0 : error) }
    return .ended
  }
  /// Charge survives delivery to the owner. Each delivered slab must occupy
  /// one output event (no second-stage coalescing). Release its node only when
  /// the parser has no remaining resumable work for that event.
  func consumed(_ count: Int, completedNode: Bool) {
    lock.lock(); defer { lock.unlock() }
    precondition(count >= 0 && count <= bytes)
    bytes -= count
    if completedNode { precondition(nodes > 0); nodes -= 1 }
  }
  func stopReading() {
    lock.lock(); stopped = true; tail?.sealed = true; tail = nil; lock.unlock()
  }
  var credit: (bytes: Int, nodes: Int) {
    lock.lock(); defer { lock.unlock() }
    return (byteLimit - bytes, nodeLimit - nodes)
  }
  var mayResumeReading: Bool {
    lock.lock(); defer { lock.unlock() }
    return byteLimit - bytes >= max(1, byteLimit / 2)
      && nodeLimit - nodes >= max(1, nodeLimit / 2)
  }
  func beginReadTurn() -> UInt64 {
    guard diagnostics else { return 0 }
    lock.lock(); statistics.readCallbacks += 1; lock.unlock()
    return DispatchTime.now().uptimeNanoseconds
  }
  func endReadTurn(_ started: UInt64) {
    guard diagnostics else { return }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    lock.lock(); statistics.readNanoseconds += elapsed; lock.unlock()
  }
  var snapshot: Statistics {
    lock.lock(); defer { lock.unlock() }; return statistics
  }
  func noteReadInterest(suspended: Bool) {
    guard diagnostics else { return }
    lock.lock(); defer { lock.unlock() }
    if suspended { statistics.suspends += 1 } else { statistics.resumes += 1 }
  }
}

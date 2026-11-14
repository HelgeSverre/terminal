import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

@Suite struct PTYReadBrokerTests {
  final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ value: String) { lock.lock(); entries.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
  }
  static func read(_ broker: PTYReadBroker, _ text: String) -> PTYReadBroker.ReadResult {
    broker.readOnce { buffer in
      let bytes = Array(text.utf8); #expect(bytes.count <= buffer.count)
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
      return (bytes.count, 0)
    }
  }

  /// Output/control/output FIFO, bounded coalescing, credit retained through
  /// delivery and REP, ordered EOF, idempotent stop.
  @Test static func fifoCreditAndEOF() {
    let owner = DispatchQueue(label: "broker-test-owner")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    owner.async { entered.signal(); release.wait() }; entered.wait()
    let log = Log()
    let broker = PTYReadBroker(owner: owner, byteLimit: 8, nodeLimit: 2, slabSize: 4,
      deliver: { log.add(String(decoding: $0, as: UTF8.self)) }, ended: { log.add("EOF:\($0)") })
    _ = read(broker, "A"); _ = read(broker, "B")
    broker.submit { log.add("resize") }
    _ = read(broker, "CD")
    #expect(broker.credit.bytes == 4 && broker.credit.nodes == 0)
    release.signal(); owner.sync {}
    #expect(log.values == ["AB", "resize", "CD"])
    // Delivery has not returned credit. In particular zero-byte parser work
    // can still retain a completely consumed output head's node.
    #expect(broker.credit.bytes == 4 && broker.credit.nodes == 0)
    if case .creditExhausted = read(broker, "") {} else { Issue.record("expected creditExhausted") }
    broker.consumed(2, completedNode: false)
    #expect(broker.credit.bytes == 6 && broker.credit.nodes == 0)
    broker.consumed(0, completedNode: true)
    broker.consumed(2, completedNode: true)
    #expect(broker.credit.bytes == 8 && broker.credit.nodes == 2)
    _ = read(broker, "E"); _ = read(broker, "")
    owner.sync {}
    #expect(log.values == ["AB", "resize", "CD", "E", "EOF:0"])
    broker.consumed(1, completedNode: true)
    if case .ended = read(broker, "late") {} else { Issue.record("expected ended after EOF") }
    broker.stopReading(); broker.stopReading()
    #expect(broker.credit.bytes == 8 && broker.credit.nodes == 2)
  }

  /// Close can arrive while a read owns the admission boundary. It waits for
  /// that one nonblocking operation, preserves its accepted bytes, and never
  /// admits a later read. A held owner queue covers the delivery-pending phase.
  @Test static func closeDuringRead() {
    let owner2 = DispatchQueue(label: "broker-close-owner")
    let ownerHeld = DispatchSemaphore(value: 0), releaseOwner = DispatchSemaphore(value: 0)
    owner2.async { ownerHeld.signal(); releaseOwner.wait() }; ownerHeld.wait()
    let log2 = Log()
    let broker2 = PTYReadBroker(owner: owner2, byteLimit: 8, nodeLimit: 2, slabSize: 4,
      deliver: { log2.add(String(decoding: $0, as: UTF8.self)) }, ended: { _ in log2.add("unexpectedEOF") })
    let readEntered = DispatchSemaphore(value: 0), releaseRead = DispatchSemaphore(value: 0)
    let readDone = DispatchSemaphore(value: 0), closeStarted = DispatchSemaphore(value: 0), closeDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = broker2.readOnce { buffer in
        readEntered.signal(); releaseRead.wait(); buffer[0] = 90; return (1, 0)
      }; readDone.signal()
    }
    readEntered.wait()
    DispatchQueue.global().async { closeStarted.signal(); broker2.stopReading(); closeDone.signal() }
    closeStarted.wait(); releaseRead.signal(); readDone.wait(); closeDone.wait()
    if case .ended = read(broker2, "late") {} else { Issue.record("expected ended after close") }
    #expect(broker2.credit.bytes == 7 && broker2.credit.nodes == 1)
    releaseOwner.signal(); owner2.sync {}
    #expect(log2.values == ["Z"])
    broker2.consumed(1, completedNode: true)
    let unopened = PTYReadBroker(owner: owner2, deliver: { _ in Issue.record("unexpected delivery") }, ended: { _ in Issue.record("unexpected EOF") })
    unopened.stopReading()
    if case .ended = read(unopened, "late") {} else { Issue.record("expected ended on an unopened broker") }
  }
}

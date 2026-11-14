import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession

@Suite struct SessionIngressTests {
  enum Event: Equatable { case input(Int), resize(Int), eof, cancelled }

  /// Owner queue: delivery identity, partial and zero-byte lease, barriers,
  /// replacement, cancellation, drain.
  @Test static func ownerQueue() {
    var queue = SessionEventQueue<Event>()
    let first = Data([1, 2, 3]), second = Data([4, 5])
    queue.appendOutput(first); queue.appendOutput(second); queue.append(.resize(80))
    #expect(queue.count == 3 && queue.outputBytes == 5)
    guard case .output(let held, 0)? = queue.leaseHead() else { Issue.record("expected output lease at offset 0"); return }
    queue.consumeOutput(2)
    queue.appendOutput(Data([6]))
    #expect(held == first && queue.outputBytes == 4)
    queue.consumeOutput(1); queue.consumeOutput(0)
    guard case .output(_, 3)? = queue.leaseHead() else { Issue.record("expected output lease at offset 3"); return }
    queue.completeHead()
    guard case .output(let data, 0)? = queue.leaseHead() else { Issue.record("expected second output lease"); return }
    #expect(data == second); queue.consumeOutput(2); queue.completeHead()
    guard case .event(.resize(80))? = queue.leaseHead() else { Issue.record("expected resize(80)"); return }
    queue.replaceHead(with: .resize(100))
    guard case .event(.resize(100))? = queue.leaseHead() else { Issue.record("expected resize(100)"); return }
    queue.completeHead()
    queue.append(.input(1)); queue.transformEvents { _ in .cancelled }
    let abandoned = queue.drain()
    #expect(abandoned.count == 2 && queue.isEmpty && queue.outputBytes == 0)
  }

  /// Real deliveries retain identity even without a semantic separator.
  /// Every partition preserves its bytes and exact control position; a sliced
  /// Data's startIndex must not influence the parser-relative consumed offset.
  @Test static func slicedDataPartitions() {
    for split in 0...19 {
      var q = SessionEventQueue<Event>()
      let bytes = Data((0..<19).map(UInt8.init))
      if split > 0 { q.appendOutput(bytes.prefix(split)) }
      q.append(.input(split))
      if split < 19 { q.appendOutput(bytes.dropFirst(split)) }
      q.append(.eof)
      var observed = Data(), boundary = -1, outputs = 0
      while let record = q.leaseHead() {
        switch record {
        case .output(let bytes, let offset):
          outputs += 1; observed.append(bytes.dropFirst(offset)); q.consumeOutput(bytes.count - offset)
        case .event(.input): boundary = observed.count
        case .event(.eof): #expect(observed == bytes)
        default: Issue.record("unexpected record at split \(split)"); return
        }
        q.completeHead()
      }
      #expect(observed == bytes && boundary == split && outputs == (split == 0 || split == 19 ? 1 : 2))
    }
  }
}

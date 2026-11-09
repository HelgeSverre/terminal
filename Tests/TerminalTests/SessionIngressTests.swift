import Foundation

@main enum SessionIngressTests {
  enum Event: Equatable { case input(Int), resize(Int), eof, cancelled }
  static func main() {
    var queue = SessionEventQueue<Event>()
    let first = Data([1, 2, 3]), second = Data([4, 5])
    queue.appendOutput(first); queue.appendOutput(second); queue.append(.resize(80))
    precondition(queue.count == 3 && queue.outputBytes == 5)
    guard case .output(let held, 0)? = queue.leaseHead() else { preconditionFailure() }
    queue.consumeOutput(2)
    queue.appendOutput(Data([6]))
    precondition(held == first && queue.outputBytes == 4)
    queue.consumeOutput(1); queue.consumeOutput(0)
    guard case .output(_, 3)? = queue.leaseHead() else { preconditionFailure() }
    queue.completeHead()
    guard case .output(let data, 0)? = queue.leaseHead() else { preconditionFailure() }
    precondition(data == second); queue.consumeOutput(2); queue.completeHead()
    guard case .event(.resize(80))? = queue.leaseHead() else { preconditionFailure() }
    queue.replaceHead(with: .resize(100))
    guard case .event(.resize(100))? = queue.leaseHead() else { preconditionFailure() }
    queue.completeHead()
    queue.append(.input(1)); queue.transformEvents { _ in .cancelled }
    let abandoned = queue.drain()
    precondition(abandoned.count == 2 && queue.isEmpty && queue.outputBytes == 0)
    // Real deliveries retain identity even without a semantic separator.
    // Every partition preserves its bytes and exact control position; a sliced
    // Data's startIndex must not influence the parser-relative consumed offset.
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
        case .event(.eof): precondition(observed == bytes)
        default: preconditionFailure()
        }
        q.completeHead()
      }
      precondition(observed == bytes && boundary == split && outputs == (split == 0 || split == 19 ? 1 : 2))
    }
    print("PASS owner queue: delivery identity, partial and zero-byte lease, barriers, replacement, cancellation, drain, sliced Data")
  }
}

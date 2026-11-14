import Foundation

/// Owner-confined ordered ingress. An output head is leased until explicitly
/// completed, including zero-byte resumable parser work. Broker deliveries retain
/// their identity; events never move relative to admitted bytes.
struct SessionEventQueue<Event> {
  enum Record {
    case vacant
    case output(Data, offset: Int)
    case event(Event)
  }
  private var records: [Record] = []
  private var head = 0
  private var leased = false
  private(set) var outputBytes = 0
  var count: Int { records.count - head }
  var isEmpty: Bool { count == 0 }

  mutating func append(_ event: Event) { records.append(.event(event)) }

  /// One immutable delivery already admitted and bounded by PTYReadBroker.
  /// The owner queue does not split, merge, or admit output a second time.
  mutating func appendOutput(_ data: Data) {
    precondition(!data.isEmpty)
    records.append(.output(data, offset: 0))
    outputBytes += data.count
  }
  mutating func leaseHead() -> Record? {
    guard !isEmpty else { return nil }
    leased = true
    return records[head]
  }
  mutating func consumeOutput(_ amount: Int) {
    precondition(leased && !isEmpty)
    guard case .output(let data, let offset) = records[head] else {
      preconditionFailure("Only an output lease has byte credit")
    }
    precondition(amount >= 0 && amount <= data.count - offset)
    records[head] = .output(data, offset: offset + amount)
    outputBytes -= amount
  }
  mutating func replaceHead(with event: Event) {
    precondition(leased && !isEmpty)
    guard case .event = records[head] else { preconditionFailure("Cannot replace output lease with event") }
    records[head] = .event(event)
  }
  mutating func completeHead() {
    precondition(leased && !isEmpty)
    if case .output(let data, let offset) = records[head] {
      precondition(offset == data.count)
    }
    records[head] = .vacant
    head += 1; leased = false
    if head == records.count {
      records.removeAll(keepingCapacity: true); head = 0
    } else if head >= 32 {
      records.removeFirst(head); head = 0
    }
  }
  mutating func transformEvents(_ transform: (Event) -> Event) {
    for index in head..<records.count {
      if case .event(let event) = records[index] { records[index] = .event(transform(event)) }
    }
  }
  mutating func drain() -> [Record] {
    let pending = Array(records[head...])
    records.removeAll(); head = 0; leased = false; outputBytes = 0
    return pending
  }
}

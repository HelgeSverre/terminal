struct TerminalHistory: RandomAccessCollection, Equatable {
  struct RetainedRow: Equatable {
    let row: TerminalRow
    let chargedBytes: UInt64
    init(_ row: TerminalRow) { self.row = row; chargedBytes = row.retainedStorageCost }
    var allocationBytes: UInt64 { row.reflowAllocationBytes }
  }
  private static let maximumRetiredRowBytes: UInt64 = 256 * 1024
  private var entries: [RetainedRow?] = []
  // Entries retain their absolute slot while the history's front is trimmed.
  // A pinned viewport or selection looks a row up by identity; identity zero
  // is the unassigned placeholder and never anchors.
  //
  // Rows normally scroll into history in ascending identity order. While they
  // do, a binary search over `entries` answers a lookup and appending a row
  // costs nothing here. The dictionary exists only once a row has arrived out
  // of order or unassigned, and is then authoritative until history empties.
  private var absoluteIndexByRowID: [UInt64: Int]?
  // The dictionary's key count and capacity had it been maintained throughout.
  // Reflow admission charges that capacity, so the ascending case reports the
  // same figure (Dictionary keeps three keys per four power-of-two buckets).
  private var modelIndexCount = 0
  private var modelIndexCapacity = 0
  private var rowIndexCapacity: Int { absoluteIndexByRowID?.capacity ?? modelIndexCapacity }
  static func dictionaryCapacity(holding count: Int) -> Int {
    guard count > 0 else { return 0 }
    var buckets = 2
    while buckets * 3 / 4 < count { buckets *= 2 }
    return buckets * 3 / 4
  }
  /// Records the row just appended at `absoluteIndex`.
  private mutating func indexAppended(_ id: UInt64, at absoluteIndex: Int) {
    if absoluteIndexByRowID == nil {
      if id != 0, absoluteIndex == head || entries[absoluteIndex - 1]!.row.id < id {
        if modelIndexCount == modelIndexCapacity {
          modelIndexCapacity = Self.dictionaryCapacity(holding: modelIndexCount + 1)
        }
        modelIndexCount += 1
        return
      }
      var map = [UInt64: Int](minimumCapacity: modelIndexCapacity)
      for index in head..<absoluteIndex { map[entries[index]!.row.id] = index }
      absoluteIndexByRowID = map
    }
    if id != 0 { absoluteIndexByRowID![id] = absoluteIndex }
  }
  /// Records that the row at `absoluteIndex` is leaving the front.
  private mutating func indexRemoved(_ id: UInt64, at absoluteIndex: Int) {
    guard absoluteIndexByRowID != nil else { modelIndexCount -= 1; return }
    if id != 0, absoluteIndexByRowID![id] == absoluteIndex { absoluteIndexByRowID!.removeValue(forKey: id) }
  }
  private mutating func indexCleared() {
    absoluteIndexByRowID = nil
    modelIndexCount = 0
    modelIndexCapacity = 0
  }
  private var head = 0
  // One genuinely evicted row of at most 256 KiB charged storage may supply
  // the next document replacement. Large text/link payloads are not cached.
  // It is outside the retained history/accounting contract, holds no queue
  // alias after transfer, and still obeys row COW when a snapshot retains it.
  private var retiredRow: TerminalRow?
  private(set) var byteCount: UInt64 = 0
  private(set) var allocationBytes: UInt64 = 0
  var reflowAllocationBytes: UInt64 {
    allocationBytes + UInt64(entries.capacity * MemoryLayout<RetainedRow?>.stride)
      + UInt64(rowIndexCapacity) * 32 + (retiredRow?.reflowAllocationBytes ?? 0) + 128
  }
  var hasEmptyReflowStorage: Bool {
    isEmpty && (entries.capacity > 0 || rowIndexCapacity > 0 || retiredRow != nil)
  }
  var count: Int { entries.count - head }
  var startIndex: Int { 0 }
  var endIndex: Int { count }
  var isEmpty: Bool { count == 0 }
  subscript(_ index: Int) -> TerminalRow { entries[head + index]!.row }
  func retainedRow(at index: Int) -> RetainedRow { entries[head + index]! }
  var rows: [TerminalRow] { Array(self) }
  mutating func reserveReflowRows(_ count: Int) {
    entries.reserveCapacity(count)
    if absoluteIndexByRowID != nil {
      absoluteIndexByRowID!.reserveCapacity(count)
    } else {
      modelIndexCapacity = Swift.max(modelIndexCapacity, Self.dictionaryCapacity(holding: count))
    }
  }
  mutating func append(_ row: TerminalRow) {
    appendRetained(RetainedRow(row))
  }
  mutating func appendRetained(_ entry: RetainedRow) {
    let absoluteIndex = entries.count
    entries.append(entry)
    indexAppended(entry.row.id, at: absoluteIndex)
    byteCount &+= entry.chargedBytes
    allocationBytes &+= entry.allocationBytes
  }
  mutating func append(contentsOf values: [TerminalRow]) { for row in values { append(row) } }
  // Reflow pressure runs only after its captured generation has retired.
  // Advance the FIFO without a whole-array compaction; the returned immutable
  // row is transferred to off-owner retirement before another batch is taken.
  mutating func takeOldestForReflow() -> RetainedRow? {
    guard head < entries.count else { return nil }
    let entry = entries[head]!
    indexRemoved(entry.row.id, at: head)
    entries[head] = nil; head += 1
    byteCount -= entry.chargedBytes; allocationBytes -= entry.allocationBytes
    return entry
  }
  mutating func removeAll() { entries.removeAll(); indexCleared(); retiredRow = nil; head = 0; byteCount = 0; allocationBytes = 0 }
  mutating func replace(_ values: [TerminalRow]) { removeAll(); append(contentsOf: values) }
  func index(ofRowID rowID: UInt64) -> Int? {
    guard rowID != 0 else { return nil }
    guard let map = absoluteIndexByRowID else {
      // Retained identities ascend with their slots.
      var lower = head, upper = entries.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        let id = entries[middle]!.row.id
        if id == rowID { return middle - head }
        if id < rowID { lower = middle + 1 } else { upper = middle }
      }
      return nil
    }
    guard let absoluteIndex = map[rowID],
          absoluteIndex >= head, absoluteIndex < entries.count, entries[absoluteIndex] != nil else { return nil }
    return absoluteIndex - head
  }
  mutating func takeRetiredRow() -> TerminalRow? {
    defer { retiredRow = nil }
    return retiredRow
  }
  mutating func trim(rows limit: Int, bytes: Int) -> Int {
    var remove = 0; let cap = UInt64(Swift.max(0, bytes)); var total = byteCount
    let rowLimit = Swift.max(0, limit)
    while count - remove > rowLimit || (total > cap && remove < count) {
      total &-= entries[head + remove]!.chargedBytes; remove += 1
    }
    if remove > 0 {
      let last = entries[head + remove - 1]!
      retiredRow = last.chargedBytes <= Self.maximumRetiredRowBytes ? last.row : nil
      for index in head..<(head + remove) {
        allocationBytes -= entries[index]!.allocationBytes
        indexRemoved(entries[index]!.row.id, at: index)
        entries[index] = nil
      }
      head += remove; byteCount = total
      if head == entries.count { entries.removeAll(); indexCleared(); head = 0 }
      else if head >= count && head >= 256 {
        entries.removeFirst(head); head = 0
        if absoluteIndexByRowID != nil {
          absoluteIndexByRowID!.removeAll(keepingCapacity: true)
          for (index, entry) in entries.enumerated() {
            guard let entry, entry.row.id != 0 else { continue }
            absoluteIndexByRowID![entry.row.id] = index
          }
        }
      }
    }
    return remove
  }
  static func == (lhs: TerminalHistory, rhs: TerminalHistory) -> Bool {
    lhs.count == rhs.count && lhs.byteCount == rhs.byteCount && lhs.elementsEqual(rhs)
  }
}

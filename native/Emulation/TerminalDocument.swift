import Foundation

// `TerminalCell` is the public/read projection of a terminal cell.  Rows do
// not retain one of these for every column: a String (and its ARC traffic) is
// far too expensive for the overwhelmingly scalar, blank grid.
struct TerminalStyle: Equatable {
  var foreground: UInt32 = 0; var background: UInt32 = 0; var underline: UInt32 = 0
  var flags: UInt16 = 0; var underlineKind: UInt8 = 0
  func erased() -> TerminalStyle { TerminalStyle(background: background) }
}
struct TerminalCell: Equatable {
  // 0 empty, 1 single-width lead, 2 double-width lead, 3 continuation,
  // 4 a single-column spacer left by a wide glyph that wrapped.
  var text = ""; var kind: UInt8 = 0; var style = TerminalStyle(); var link: String?
  var flags: UInt8 = 0; var protected = false
  static func erased(_ style: TerminalStyle = TerminalStyle()) -> TerminalCell {
    TerminalCell(text: "", kind: 0, style: style.erased())
  }
}

// The hot row representation.  Keep this deliberately reference-free: text
// is either the single Unicode scalar here, or an exceptional payload in the
// row dictionary below. `hasScalar` distinguishes a real U+0000 from empty.
private struct TerminalRowSlot: Equatable {
  var scalar: UInt32 = 0
  var style = TerminalStyle()
  var hasScalar = false
  var kind: UInt8 = 0
  var flags: UInt8 = 0
  var protected = false
}

private struct TerminalRowPayload: Equatable {
  var text: String?
  var link: String?
  var utf8Bytes: UInt64 { UInt64(text?.utf8.count ?? 0) + UInt64(link?.utf8.count ?? 0) }
}

// The sparse payload owner keeps its resource charge with its COW dictionary.
// Every replacement/removal updates both atomically; scalar-only rows never
// enter this path. Reflow can therefore reserve an input generation without
// scanning every cell or retaining an uncharged history generation first.
private struct TerminalRowPayloads: Equatable, Sequence {
  private var entries: [Int: TerminalRowPayload] = [:]
  private(set) var utf8Bytes: UInt64 = 0
  var count: Int { entries.count }
  var capacity: Int { entries.capacity }
  var isEmpty: Bool { entries.isEmpty }
  var values: Dictionary<Int, TerminalRowPayload>.Values { entries.values }
  subscript(_ index: Int) -> TerminalRowPayload? {
    get { entries[index] }
    set {
      utf8Bytes = utf8Bytes - (entries[index]?.utf8Bytes ?? 0) + (newValue?.utf8Bytes ?? 0)
      entries[index] = newValue
    }
  }
  @discardableResult mutating func removeValue(forKey key: Int) -> TerminalRowPayload? {
    let old = entries.removeValue(forKey: key)
    utf8Bytes -= old?.utf8Bytes ?? 0
    return old
  }
  mutating func removeAll(keepingCapacity: Bool = false) {
    entries.removeAll(keepingCapacity: keepingCapacity); utf8Bytes = 0
  }
  func makeIterator() -> Dictionary<Int, TerminalRowPayload>.Iterator { entries.makeIterator() }
}

// Matches the old TerminalCell ABI stride without retaining a String, link,
// or style. It is used only to reproduce Array's old capacity rounding for
// the public history-byte budget; it is never row storage.
private struct TerminalLegacyCapacityCell {
  var a: UInt64 = 0; var b: UInt64 = 0; var c: UInt64 = 0; var d: UInt64 = 0
  var e: UInt64 = 0; var f: UInt64 = 0; var g: UInt64 = 0; var h: UInt64 = 0
}
private final class TerminalRowStorage {
  var slots: [TerminalRowSlot]
  var payloads = TerminalRowPayloads()
  var logicalCapacity: Int
  var detachCapacity: Int
  init(slots: [TerminalRowSlot], payloads: TerminalRowPayloads = TerminalRowPayloads(), logicalCapacity: Int, detachCapacity: Int) {
    self.slots = slots; self.payloads = payloads
    self.logicalCapacity = logicalCapacity; self.detachCapacity = detachCapacity
  }
}

struct TerminalRow: Equatable {
  // Value-only observation: private reflow copies cannot invalidate live
  // selection, and no row retains a selection object or page generation.
  struct SelectionObservation {
    let generation: UInt64
    var columns: Range<Int>
    let observesSoftEdge: Bool
    var additionalColumns: [Range<Int>]? = nil
    var overwritten = false
    var changedSoftEdge = false
    mutating func write(_ range: Range<Int>) {
      guard !overwritten else { return }
      if columns.overlaps(range) { overwritten = true; return }
      guard let intervals = additionalColumns else { return }
      var lower = 0, upper = intervals.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if intervals[middle].upperBound <= range.lowerBound { lower = middle + 1 }
        else { upper = middle }
      }
      if lower < intervals.count && intervals[lower].overlaps(range) { overwritten = true }
    }
    mutating func softEdgeChanged() { if observesSoftEdge { changedSoftEdge = true } }
    // Reflow supplies monotonically ordered intervals. Keep the common
    // single interval allocation-free; coalesce adjacent selected runs.
    mutating func include(_ range: Range<Int>) {
      if additionalColumns == nil && range.lowerBound <= columns.upperBound {
        columns = columns.lowerBound..<max(columns.upperBound, range.upperBound)
      } else if let last = additionalColumns?.last, range.lowerBound <= last.upperBound {
        additionalColumns![additionalColumns!.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        if additionalColumns == nil { additionalColumns = [] }
        additionalColumns!.append(range)
      }
    }
    var allocationBytes: UInt64 { UInt64(additionalColumns?.capacity ?? 0) * UInt64(MemoryLayout<Range<Int>>.stride) }
  }
  var id: UInt64; var revision: UInt64
  var softWrapped = false {
    didSet { if oldValue != softWrapped { selectionObservation?.softEdgeChanged() } }
  }
  var selectionObservation: SelectionObservation?
  private mutating func observeSelectionWrite(_ range: Range<Int>) { selectionObservation?.write(range) }
  private var storage: TerminalRowStorage
  // `slots.capacity` is deliberately not the history contract: Swift rounds
  // Array capacity by element stride. Preserve the former 64-byte rich-cell
  // capacity independently without retaining a parallel rich-cell grid.

  init(id: UInt64 = 0, revision: UInt64 = 0, cells: [TerminalCell]) {
    self.id = id; self.revision = revision
    var slots: [TerminalRowSlot] = []
    // Keep the old array-capacity budget observable to history admission when
    // a caller supplies a deliberately over-reserved rich fixture.
    slots.reserveCapacity(cells.capacity)
    slots.append(contentsOf: repeatElement(TerminalRowSlot(), count: cells.count))
    self.storage = TerminalRowStorage(slots: slots, logicalCapacity: cells.capacity, detachCapacity: Self.blankLogicalCapacity(columns: cells.count))
    for (index, cell) in cells.enumerated() { setCell(cell, at: index) }
  }
  private init(id: UInt64, storage: TerminalRowStorage) {
    self.id = id; self.revision = 0; self.softWrapped = false; self.storage = storage
  }
  init(columns: Int, logicalCellCapacity: Int? = nil) {
    id = 0; revision = 0
    let capacity = logicalCellCapacity ?? Self.blankLogicalCapacity(columns: columns)
    // Fresh blank rows are already calibrated by their document geometry;
    // reuse that shape for a later COW detach rather than calibrating again.
    storage = TerminalRowStorage(slots: Array(repeating: TerminalRowSlot(), count: columns), logicalCapacity: capacity, detachCapacity: capacity)
  }
  static func erased(columns: Int, logicalCellCapacity: Int, style: TerminalStyle, id: UInt64 = 0) -> TerminalRow {
    let slots = Array(repeating: TerminalRowSlot(style: style.erased()), count: columns)
    return TerminalRow(id: id, storage: TerminalRowStorage(slots: slots,
                       logicalCapacity: logicalCellCapacity, detachCapacity: logicalCellCapacity))
  }
  mutating func resetForReuse(columns: Int, logicalCellCapacity: Int,
                              style: TerminalStyle, id: UInt64) {
    selectionObservation = nil
    if storage.slots.count != columns || !isKnownUniquelyReferenced(&storage) {
      storage = TerminalRowStorage(slots: Array(repeating: TerminalRowSlot(style: style.erased()), count: columns),
                                   logicalCapacity: logicalCellCapacity, detachCapacity: logicalCellCapacity)
      self.id = id; revision = 0; softWrapped = false
      return
    }
    let slot = TerminalRowSlot(style: style.erased())
    storage.slots.withUnsafeMutableBufferPointer { slots in
      for index in slots.indices { slots[index] = slot }
    }
    storage.payloads.removeAll(keepingCapacity: true)
    storage.logicalCapacity = logicalCellCapacity
    storage.detachCapacity = logicalCellCapacity
    self.id = id; revision = 0; softWrapped = false
  }

  // Read-only rich projection for publication, search, and compatibility at
  // the Core boundary. It retains value/COW snapshots of the two stores and
  // constructs a cell only for the requested subscript; editing must use the
  // narrow operations below and never retain this projection across mutation.
  struct Cells: RandomAccessCollection {
    typealias Index = Int
    typealias Element = TerminalCell
    private let storage: TerminalRowStorage
    fileprivate init(storage: TerminalRowStorage) {
      self.storage = storage
    }
    var startIndex: Int { storage.slots.startIndex }
    var endIndex: Int { storage.slots.endIndex }
    subscript(position: Int) -> TerminalCell {
      TerminalRow.project(storage.slots[position], storage.payloads[position])
    }
  }
  var cells: Cells { Cells(storage: storage) }
  var count: Int { storage.slots.count }
  var payloadCount: Int { storage.payloads.count }
  var retainedCellCapacity: Int { storage.logicalCapacity }

  func cell(_ index: Int) -> TerminalCell {
    Self.project(storage.slots[index], storage.payloads[index])
  }
  private static func project(_ slot: TerminalRowSlot, _ payload: TerminalRowPayload?) -> TerminalCell {
    let text: String
    if let payloadText = payload?.text { text = payloadText }
    else if slot.hasScalar, let scalar = Unicode.Scalar(slot.scalar) { text = String(scalar) }
    else { text = "" }
    return TerminalCell(text: text, kind: slot.kind, style: slot.style,
                        link: payload?.link, flags: slot.flags, protected: slot.protected)
  }
  private mutating func ensureUniqueForCellEdit() {
    if !isKnownUniquelyReferenced(&storage) {
      storage = TerminalRowStorage(slots: storage.slots, payloads: storage.payloads,
                                   logicalCapacity: storage.detachCapacity,
                                   detachCapacity: storage.detachCapacity)
    }
  }

  mutating func setCell(_ cell: TerminalCell, at index: Int) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    var slot = TerminalRowSlot(scalar: 0, style: cell.style, hasScalar: false,
                               kind: cell.kind, flags: cell.flags, protected: cell.protected)
    var payload = TerminalRowPayload(text: nil, link: cell.link)
    let scalars = cell.text.unicodeScalars
    if scalars.count == 1, let scalar = scalars.first {
      slot.scalar = scalar.value
      slot.hasScalar = true
    } else if !cell.text.isEmpty {
      payload.text = cell.text
    }
    storage.slots[index] = slot
    if payload.text != nil || payload.link != nil { storage.payloads[index] = payload }
    else if !storage.payloads.isEmpty { storage.payloads.removeValue(forKey: index) }
  }

  mutating func setScalar(_ scalar: Unicode.Scalar, at index: Int, kind: UInt8,
                          style: TerminalStyle, link: String?, flags: UInt8, protected: Bool) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    storage.slots[index] = TerminalRowSlot(scalar: scalar.value, style: style, hasScalar: true,
                                   kind: kind, flags: flags, protected: protected)
    if let link { storage.payloads[index] = TerminalRowPayload(text: nil, link: link) }
    else if !storage.payloads.isEmpty { storage.payloads.removeValue(forKey: index) }
  }

  mutating func erase(at index: Int, style: TerminalStyle = TerminalStyle()) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit(); storage.slots[index] = TerminalRowSlot(style: style.erased())
    if !storage.payloads.isEmpty { storage.payloads.removeValue(forKey: index) }
  }
  mutating func copyCell(from source: TerminalRow, at sourceIndex: Int, to index: Int) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit(); storage.slots[index] = source.storage.slots[sourceIndex]
    if let payload = source.storage.payloads[sourceIndex] { storage.payloads[index] = payload }
    else if !storage.payloads.isEmpty { storage.payloads.removeValue(forKey: index) }
  }
  // Width-one stored cells can move together without Unicode reclassification
  // or changing any style/link/protection metadata. Wide and clipped atoms
  // deliberately stop the run and remain with the reflow atom owner.
  func unchangedReflowRun(from start: Int, until limit: Int) -> Range<Int> {
    let slots = storage.slots
    var end = start
    while end < min(limit, slots.count), slots[end].kind == 1, slots[end].flags & 1 == 0 { end += 1 }
    return start..<end
  }
  mutating func copyCells(from source: TerminalRow, range: Range<Int>, to destination: Int) {
    guard !range.isEmpty else { return }
    ensureUniqueForCellEdit()
    let target = destination..<(destination + range.count)
    observeSelectionWrite(target)
    storage.slots.replaceSubrange(target, with: source.storage.slots[range])
    if !storage.payloads.isEmpty {
      for index in target { storage.payloads.removeValue(forKey: index) }
    }
    if !source.storage.payloads.isEmpty {
      for index in range {
        if let payload = source.storage.payloads[index] { storage.payloads[destination + index - range.lowerBound] = payload }
      }
    }
  }
  mutating func setKind(_ kind: UInt8, at index: Int) { observeSelectionWrite(index..<(index + 1)); ensureUniqueForCellEdit(); storage.slots[index].kind = kind }
  mutating func setFlags(_ flags: UInt8, at index: Int) { observeSelectionWrite(index..<(index + 1)); ensureUniqueForCellEdit(); storage.slots[index].flags = flags }
  mutating func addFlags(_ flags: UInt8, at index: Int) { observeSelectionWrite(index..<(index + 1)); ensureUniqueForCellEdit(); storage.slots[index].flags |= flags }
  mutating func clearText(at index: Int) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit(); storage.slots[index].scalar = 0
    storage.slots[index].hasScalar = false
    if var payload = storage.payloads[index] {
      payload.text = nil
      if payload.link != nil { storage.payloads[index] = payload }
      else { storage.payloads.removeValue(forKey: index) }
    }
  }
  func kind(at index: Int) -> UInt8 { storage.slots[index].kind }
  func flags(at index: Int) -> UInt8 { storage.slots[index].flags }
  func style(at index: Int) -> TerminalStyle { storage.slots[index].style }
  func isProtected(at index: Int) -> Bool { storage.slots[index].protected }
  func scalarCount(at index: Int) -> Int {
    storage.payloads[index]?.text?.unicodeScalars.count ?? (storage.slots[index].hasScalar ? 1 : 0)
  }
  mutating func appendScalar(_ scalar: Unicode.Scalar, at index: Int) {
    var cell = cell(index)
    cell.text.unicodeScalars.append(scalar)
    setCell(cell, at: index)
  }
  mutating func truncate(to newCount: Int) {
    if newCount < count { observeSelectionWrite(newCount..<count) }
    let next = Self.legacyCapacity(existingCount: storage.slots.count, capacity: storage.logicalCapacity, truncatingTo: newCount)
    if !isKnownUniquelyReferenced(&storage) { storage = TerminalRowStorage(slots: storage.slots, payloads: storage.payloads, logicalCapacity: storage.logicalCapacity, detachCapacity: storage.detachCapacity) }
    storage.logicalCapacity = next; storage.detachCapacity = Self.blankLogicalCapacity(columns: newCount)
    storage.slots = Array(storage.slots.prefix(newCount))
    storage.payloads = storage.payloads.reduce(into: TerminalRowPayloads()) { result, entry in
      if entry.key < newCount { result[entry.key] = entry.value }
    }
  }
  mutating func appendBlanks(_ count: Int) {
    guard count > 0 else { return }
    let next = Self.legacyCapacity(existingCount: storage.slots.count, capacity: storage.logicalCapacity, appending: count)
    if !isKnownUniquelyReferenced(&storage) { storage = TerminalRowStorage(slots: storage.slots, payloads: storage.payloads, logicalCapacity: storage.logicalCapacity, detachCapacity: storage.detachCapacity) }
    storage.logicalCapacity = next; storage.detachCapacity = Self.blankLogicalCapacity(columns: storage.slots.count + count)
    storage.slots.append(contentsOf: repeatElement(TerminalRowSlot(), count: count))
  }
  mutating func copyRange(from source: TerminalRow, _ range: ClosedRange<Int>) {
    for index in range { copyCell(from: source, at: index, to: index) }
  }
  mutating func shiftCells(column: Int, right: Int, amount: Int, inserting: Bool) {
    observeSelectionWrite(column..<(right + 1))
    ensureUniqueForCellEdit()
    if inserting {
      for destination in stride(from: right, through: column + amount, by: -1) {
        storage.slots[destination] = storage.slots[destination - amount]
        if let payload = storage.payloads[destination - amount] { storage.payloads[destination] = payload }
        else { storage.payloads.removeValue(forKey: destination) }
      }
    } else {
      for destination in column...(right - amount) {
        storage.slots[destination] = storage.slots[destination + amount]
        if let payload = storage.payloads[destination + amount] { storage.payloads[destination] = payload }
        else { storage.payloads.removeValue(forKey: destination) }
      }
    }
  }
  mutating func replaceASCII<C: Collection>(at column: Int, scalars: C, style: TerminalStyle,
                                             link: String?, protected: Bool) where C.Element == Unicode.Scalar {
    let count = scalars.count
    guard count > 0, column >= 0, column + count <= storage.slots.count else { return }
    ensureUniqueForCellEdit()
    let range = column..<(column + count)
    observeSelectionWrite(range)
    if let link {
      for index in range { storage.payloads[index] = TerminalRowPayload(text: nil, link: link) }
    } else if !storage.payloads.isEmpty {
      for index in range { storage.payloads.removeValue(forKey: index) }
    }
    storage.slots.withUnsafeMutableBufferPointer { slots in
      var index = column
      for scalar in scalars {
        slots[index] = TerminalRowSlot(scalar: scalar.value, style: style, hasScalar: true,
                                       kind: 1, flags: protected ? 2 : 0, protected: protected)
        index += 1
      }
    }
  }

  // Preserve the published history-byte contract across this physical storage
  // optimization. These are the old ABI strides (row 32, rich cell 64), not
  // an allocator or RSS estimate; payload bytes retain their old per-cell
  // ownership semantics.
  private static let logicalRowCharge: UInt64 = 32
  private static let logicalCellCharge: UInt64 = 64
  var retainedBaseCost: UInt64 { Self.logicalRowCharge + UInt64(storage.logicalCapacity) * Self.logicalCellCharge }
  // Temporary-operation admission follows the packed allocation, while the
  // public history budget deliberately retains its legacy 64-byte formula.
  var allocationBaseCost: UInt64 {
    allocationSlotCost
      + UInt64(storage.payloads.capacity) * 80 + UInt64(storage.payloads.count) * 64
  }
  var allocationSlotCost: UInt64 { 64 + UInt64(storage.slots.capacity * MemoryLayout<TerminalRowSlot>.stride) }
  var reflowAllocationBytes: UInt64 { allocationBaseCost + 2 * storage.payloads.utf8Bytes + (selectionObservation?.allocationBytes ?? 0) }
  func reflowCellStorage(at index: Int) -> (textBytes: UInt64, linkBytes: UInt64, sparse: Bool, hasLink: Bool) {
    let slot = storage.slots[index]
    let payload = storage.payloads[index]
    return (slot.hasScalar ? UInt64(Self.utf8Length(of: slot.scalar)) : UInt64(payload?.text?.utf8.count ?? 0),
            UInt64(payload?.link?.utf8.count ?? 0), payload != nil, payload?.link != nil)
  }
  var retainedStorageCost: UInt64 {
    var bytes = Self.logicalRowCharge + UInt64(storage.logicalCapacity) * Self.logicalCellCharge
    for slot in storage.slots where slot.hasScalar { bytes += UInt64(Self.utf8Length(of: slot.scalar)) }
    for payload in storage.payloads.values {
      if let text = payload.text { bytes += UInt64(text.utf8.count) }
      if let link = payload.link { bytes += UInt64(link.utf8.count) }
    }
    return bytes
  }
  @inline(__always) private static func utf8Length(of scalar: UInt32) -> Int {
    scalar <= 0x7f ? 1 : scalar <= 0x7ff ? 2 : scalar <= 0xffff ? 3 : 4
  }

  // Called once per document geometry (or by a direct test fixture), never by
  // normal blank-row allocation. That keeps the row hot path reference-free
  // and avoids a temporary 64-byte-per-column calibration array per scroll.
  static func blankLogicalCapacity(columns count: Int) -> Int {
    Array(repeating: TerminalLegacyCapacityCell(), count: count).capacity
  }
  private static func legacySeed(count: Int, capacity: Int) -> [TerminalLegacyCapacityCell] {
    var cells: [TerminalLegacyCapacityCell] = []
    cells.reserveCapacity(capacity)
    cells.append(contentsOf: repeatElement(TerminalLegacyCapacityCell(), count: count))
    return cells
  }
  private static func legacyCapacity(existingCount: Int, capacity: Int, truncatingTo count: Int) -> Int {
    Array(legacySeed(count: existingCount, capacity: capacity).prefix(count)).capacity
  }
  private static func legacyCapacity(existingCount: Int, capacity: Int, appending count: Int) -> Int {
    var cells = legacySeed(count: existingCount, capacity: capacity)
    cells.append(contentsOf: repeatElement(TerminalLegacyCapacityCell(), count: count))
    return cells.capacity
  }

  static func == (lhs: TerminalRow, rhs: TerminalRow) -> Bool {
    guard lhs.id == rhs.id, lhs.revision == rhs.revision,
          lhs.softWrapped == rhs.softWrapped, lhs.storage.slots.count == rhs.storage.slots.count else { return false }
    // Most comparisons preserve representation, so avoid projecting strings.
    if lhs.storage.slots == rhs.storage.slots && lhs.storage.payloads == rhs.storage.payloads { return true }
    // String equality is canonically equivalent; a scalar slot and an
    // exceptional multi-scalar payload can therefore be semantically equal.
    for index in lhs.storage.slots.indices where lhs.cell(index) != rhs.cell(index) { return false }
    return true
  }
}
struct PromptAnchor: Equatable {
  var row: UInt64
  var column: Int
  var pendingWrap: Bool
}
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
  // The map makes a pinned viewport's row lookup independent of scrollback
  // length; row identity zero is the unassigned placeholder and never anchors.
  private var absoluteIndexByRowID: [UInt64: Int] = [:]
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
      + UInt64(absoluteIndexByRowID.capacity) * 32 + (retiredRow?.reflowAllocationBytes ?? 0) + 128
  }
  var hasEmptyReflowStorage: Bool {
    isEmpty && (entries.capacity > 0 || absoluteIndexByRowID.capacity > 0 || retiredRow != nil)
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
    absoluteIndexByRowID.reserveCapacity(count)
  }
  mutating func append(_ row: TerminalRow) {
    appendRetained(RetainedRow(row))
  }
  mutating func appendRetained(_ entry: RetainedRow) {
    let absoluteIndex = entries.count
    entries.append(entry)
    if entry.row.id != 0 { absoluteIndexByRowID[entry.row.id] = absoluteIndex }
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
    if entry.row.id != 0, absoluteIndexByRowID[entry.row.id] == head {
      absoluteIndexByRowID.removeValue(forKey: entry.row.id)
    }
    entries[head] = nil; head += 1
    byteCount -= entry.chargedBytes; allocationBytes -= entry.allocationBytes
    return entry
  }
  mutating func removeAll() { entries.removeAll(); absoluteIndexByRowID.removeAll(); retiredRow = nil; head = 0; byteCount = 0; allocationBytes = 0 }
  mutating func replace(_ values: [TerminalRow]) { removeAll(); append(contentsOf: values) }
  func index(ofRowID rowID: UInt64) -> Int? {
    guard rowID != 0, let absoluteIndex = absoluteIndexByRowID[rowID],
          absoluteIndex >= head, absoluteIndex < entries.count, entries[absoluteIndex] != nil else { return nil }
    return absoluteIndex - head
  }
  fileprivate mutating func takeRetiredRow() -> TerminalRow? {
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
        if let entry = entries[index], entry.row.id != 0,
           absoluteIndexByRowID[entry.row.id] == index {
          absoluteIndexByRowID.removeValue(forKey: entry.row.id)
        }
        entries[index] = nil
      }
      head += remove; byteCount = total
      if head == entries.count { entries.removeAll(); absoluteIndexByRowID.removeAll(); head = 0 }
      else if head >= count && head >= 256 {
        entries.removeFirst(head); head = 0
        absoluteIndexByRowID.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() {
          guard let entry, entry.row.id != 0 else { continue }
          absoluteIndexByRowID[entry.row.id] = index
        }
      }
    }
    return remove
  }
  static func == (lhs: TerminalHistory, rhs: TerminalHistory) -> Bool {
    lhs.count == rhs.count && lhs.byteCount == rhs.byteCount && lhs.elementsEqual(rhs)
  }
}
struct TerminalScreen: Equatable {
  enum PromptPhase { case none, drawing, inputReady }
  var rows: [TerminalRow]; var cursorRow = 0; var cursorColumn = 0; var pendingWrap = false
  var savedRow = 0; var savedColumn = 0; var savedPendingWrap = false; var savedOrigin = false
  var savedStyle = TerminalStyle(); var savedLink: String?
  var keyboardFlags: UInt32 = 0
  var keyboardStack: [UInt32] = []
  // DEC cursor appearance belongs to a screen, just like the keyboard stack.
  // Alternate-screen selection must restore the cursor that screen owns.
  var cursorVisible = true
  var cursorShape: UInt8 = 0
  // OSC 133 prompt identity is screen-local and survives resize by row ID.
  var promptPhase = PromptPhase.none
  var atPrompt: Bool { promptPhase != .none }
  var inputReady: Bool { promptPhase == .inputReady }
  var promptRedraw = false
  var promptAnchor: PromptAnchor?
  // A geometry-dependent row address can expire while the shell is still
  // editing the same command. Only OSC 133 changes that semantic phase.
  mutating func retirePromptAnchor() { promptAnchor = nil; promptRedraw = false }
  var topMargin: Int; var bottomMargin: Int; var leftMargin: Int; var rightMargin: Int
  init(rows: [TerminalRow], columns: Int) {
    self.rows = rows; topMargin = 0; bottomMargin = max(0, rows.count - 1)
    leftMargin = 0; rightMargin = max(0, columns - 1)
  }
  init(columns: Int, rows count: Int) {
    let capacity = TerminalRow.blankLogicalCapacity(columns: columns)
    self.init(rows: Array(repeating: TerminalRow(columns: columns, logicalCellCapacity: capacity), count: count), columns: columns)
  }
}
struct TerminalDocument {
  struct PrintAttributes {
    var style: TerminalStyle
    var link: String?
    var protected: Bool
  }
  struct PrintEffect {
    var appendedHistoryCount: Int
    var lastPrinted: String?
    var repeatAttributes: PrintAttributes?
  }
  struct PrintBatchEffect {
    var effect: PrintEffect
    var consumedScalarCount: Int
    var mutationCount: Int
  }
  // All state needed to continue a grapheme across decoder batches lives in
  // one value.  Keeping it disjoint from the selected screen lets the batch
  // writer hold that screen exactly once without accidentally extending an
  // inout row borrow across a wrap or scroll.
  private struct PrintState {
    var segmenter = TerminalText.Segmenter()
    var openCluster: (row: Int, column: Int)?
    var retainedScalars = 0
    var capped = false

    mutating func reset() {
      segmenter = TerminalText.Segmenter()
      openCluster = nil
      retainedScalars = 0
      capped = false
    }
  }
  private(set) var columns: Int; private(set) var rowCount: Int
  private var blankCellCapacity: Int
  var history = TerminalHistory()
  var primary: TerminalScreen; var alternate: TerminalScreen
  mutating func clearHistory() { history.removeAll() }
  mutating func trimHistory(rowLimit: Int, byteLimit: Int) -> Int { history.trim(rows: rowLimit, bytes: byteLimit) }
  fileprivate var nextRowID: UInt64 = 1
  // Print/segmentation state belongs beside the cells it identifies. This
  // keeps the scalar transaction self-contained across cursor/edit resets.
  private var printState = PrintState()
  init(columns: Int, rows: Int) {
    self.columns = columns; rowCount = rows
    blankCellCapacity = TerminalRow.blankLogicalCapacity(columns: columns)
    primary = TerminalScreen(rows: [], columns: columns); alternate = TerminalScreen(rows: [], columns: columns)
    primary.rows = makeRows(rows); alternate.rows = makeRows(rows)
    primary.bottomMargin = rows - 1; alternate.bottomMargin = rows - 1
  }
  mutating func blankRow() -> TerminalRow {
    var row = TerminalRow(columns: columns, logicalCellCapacity: blankCellCapacity); row.id = reserveRowIdentity(); return row
  }
  mutating func reserveRowIdentity() -> UInt64 { defer { nextRowID &+= 1 }; return nextRowID }
  mutating func eraseRow(_ style: TerminalStyle) -> TerminalRow {
    defer { nextRowID &+= 1 }
    return Self.erasedRow(columns: columns, logicalCellCapacity: blankCellCapacity,
                          style: style, id: nextRowID, history: &history)
  }
  private static func erasedRow(columns: Int, logicalCellCapacity: Int, style: TerminalStyle,
                                id: UInt64, history: inout TerminalHistory) -> TerminalRow {
    if var row = history.takeRetiredRow() {
      row.resetForReuse(columns: columns, logicalCellCapacity: logicalCellCapacity, style: style, id: id)
      return row
    }
    return TerminalRow.erased(columns: columns, logicalCellCapacity: logicalCellCapacity, style: style, id: id)
  }
  mutating func setSize(columns: Int, rows: Int) {
    if self.columns != columns { blankCellCapacity = TerminalRow.blankLogicalCapacity(columns: columns) }
    self.columns = columns; rowCount = rows
  }

  mutating func resetPrintCluster() {
    printState.reset()
  }

  // CR selects and mutates its screen here so Core need not materialize a
  // whole screen value merely to update the cursor.
  mutating func carriageReturn(usingAlternate: Bool, leftRightMargins: Bool) {
    resetPrintCluster()
    if usingAlternate {
      Self.carriageReturn(&alternate, leftRightMargins: leftRightMargins)
    } else {
      Self.carriageReturn(&primary, leftRightMargins: leftRightMargins)
    }
  }

  private static func carriageReturn(_ screen: inout TerminalScreen, leftRightMargins: Bool) {
    let left = leftRightMargins ? screen.leftMargin : 0
    screen.cursorColumn = screen.cursorColumn >= left ? left : 0
    screen.pendingWrap = false
  }

  // LF/IND/RI select and mutate their screen here so callers do not need to
  // materialize a whole screen value merely to alter its cursor or rows.
  // The result reports history admission; retained rows never leave this owner.
  mutating func index(usingAlternate: Bool, reverse: Bool,
                      leftRightMargins: Bool, eraseStyle: TerminalStyle) -> Int {
    if usingAlternate {
      _ = Self.index(&alternate, columns: columns, blankCellCapacity: blankCellCapacity, recycleDiscarded: true, reverse: reverse,
                     leftRightMargins: leftRightMargins, eraseStyle: eraseStyle,
                     history: &history, nextRowID: &nextRowID)
      return 0
    }
    guard let removed = Self.index(&primary, columns: columns, blankCellCapacity: blankCellCapacity, recycleDiscarded: false, reverse: reverse,
                                   leftRightMargins: leftRightMargins, eraseStyle: eraseStyle,
                                   history: &history, nextRowID: &nextRowID) else { return 0 }
    history.append(removed)
    return 1
  }

  private static func index(_ screen: inout TerminalScreen, columns: Int, blankCellCapacity: Int, recycleDiscarded: Bool,
                            reverse: Bool, leftRightMargins: Bool,
                            eraseStyle: TerminalStyle, history: inout TerminalHistory, nextRowID: inout UInt64) -> TerminalRow? {
    let horizontal = leftRightMargins ? (screen.leftMargin, screen.rightMargin) : (0, columns - 1)
    let inside = (horizontal.0...horizontal.1).contains(screen.cursorColumn)
    screen.pendingWrap = false
    if reverse {
      if screen.cursorRow == screen.topMargin && inside {
        _ = scrollForIndex(&screen, columns: columns, blankCellCapacity: blankCellCapacity, recycleDiscarded: recycleDiscarded, top: screen.topMargin, bottom: screen.bottomMargin,
                           left: horizontal.0, right: horizontal.1, up: false, eraseStyle: eraseStyle,
                           history: &history, nextRowID: &nextRowID)
      } else {
        screen.cursorRow = max(0, screen.cursorRow - 1)
      }
    } else if screen.cursorRow == screen.bottomMargin && inside {
      return scrollForIndex(&screen, columns: columns, blankCellCapacity: blankCellCapacity, recycleDiscarded: recycleDiscarded, top: screen.topMargin, bottom: screen.bottomMargin,
                            left: horizontal.0, right: horizontal.1, up: true, eraseStyle: eraseStyle,
                            history: &history, nextRowID: &nextRowID)
    } else {
      screen.cursorRow = min(screen.rows.count - 1, screen.cursorRow + 1)
    }
    return nil
  }

  private static func scrollForIndex(_ screen: inout TerminalScreen, columns: Int, blankCellCapacity: Int, recycleDiscarded: Bool,
                                     top: Int, bottom: Int, left: Int, right: Int, up: Bool,
                                     eraseStyle: TerminalStyle, history: inout TerminalHistory, nextRowID: inout UInt64) -> TerminalRow? {
    guard top >= 0, bottom < screen.rows.count, top <= bottom else { return nil }
    if left != 0 || right != columns - 1 {
      scrollRectangleInPlace(&screen, columns: columns, top: top, bottom: bottom,
                             left: left, right: right, count: 1, up: up, eraseStyle: eraseStyle)
      return nil
    }
    var removed = screen.rows.remove(at: up ? top : bottom)
    if recycleDiscarded {
      removed.resetForReuse(columns: columns, logicalCellCapacity: blankCellCapacity,
                            style: eraseStyle, id: nextRowID)
      nextRowID &+= 1
      screen.rows.insert(removed, at: up ? bottom : top)
      return nil
    }
    let replacement = erasedRow(columns: columns, logicalCellCapacity: blankCellCapacity,
                                style: eraseStyle, id: nextRowID, history: &history)
    nextRowID &+= 1
    screen.rows.insert(replacement, at: up ? bottom : top)
    return up && top == 0 && bottom == screen.rows.count - 1 ? removed : nil
  }

  // This is the document's scalar-print transaction. It is intentionally a
  // terminal operation rather than a generic mutable-grid callback: callers
  // provide parser/mode facts, while this module owns segmentation, cells,
  // continuation repair, cursor/wrap, history rows, identities and retention.
  mutating func print(_ scalar: Unicode.Scalar,
                      usingAlternate: Bool, leftRightMargins: Bool,
                      autoWrap: Bool, insertMode: Bool,
                      attributes: PrintAttributes) -> PrintEffect? {
    let batch = print(CollectionOfOne(scalar), usingAlternate: usingAlternate,
                      leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                      insertMode: insertMode, attributes: attributes)
    return batch.mutationCount == 0 ? nil : batch.effect
  }

  // Bounded text transaction for the ordinary decoder path. Rows and their
  // replacement IDs stay document-owned. A history append yields its count so
  // the caller can enforce budgets and viewport clamps before more printing.
  mutating func print<C: Collection>(_ scalars: C, usingAlternate: Bool,
                      leftRightMargins: Bool, autoWrap: Bool, insertMode: Bool,
                      attributes: borrowing PrintAttributes) -> PrintBatchEffect where C.Element == Unicode.Scalar {
    if usingAlternate {
      return Self.printBatch(scalars, in: &alternate, columns: columns, blankCellCapacity: blankCellCapacity,
                             leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                             insertMode: insertMode, attributes: attributes, history: &history,
                             retainHistory: false, state: &printState, nextRowID: &nextRowID)
    }
    return Self.printBatch(scalars, in: &primary, columns: columns, blankCellCapacity: blankCellCapacity,
                           leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                           insertMode: insertMode, attributes: attributes, history: &history,
                           retainHistory: true, state: &printState, nextRowID: &nextRowID)
  }

  private static func category(for scalar: Unicode.Scalar) -> TerminalText.Category {
    switch scalar.value {
    case 0x000d: return .cr
    case 0x000a: return .lf
    case 0x0000...0x001f, 0x007f: return .control
    case 0x0000...0x007f: return .other
    default: return TerminalText.category(of: scalar)
    }
  }

  private static func printBatch<C: Collection>(_ scalars: C, in screen: inout TerminalScreen,
                                                columns: Int, blankCellCapacity: Int, leftRightMargins: Bool,
                                                autoWrap: Bool, insertMode: Bool,
                                                attributes: borrowing PrintAttributes,
                                                history: inout TerminalHistory, retainHistory: Bool,
                                                state: inout PrintState,
                                                nextRowID: inout UInt64) -> PrintBatchEffect
  where C.Element == Unicode.Scalar {
    var effect = PrintEffect(appendedHistoryCount: 0, lastPrinted: nil, repeatAttributes: nil)
    var consumed = 0, mutations = 0
    var index = scalars.startIndex
    while index != scalars.endIndex {
      let scalar = scalars[index]
      index = scalars.index(after: index)
      consumed += 1
      let category = category(for: scalar)
      switch category { case .control, .cr, .lf: continue; default: break }
      let startsCluster = state.segmenter.push(scalar, category: category)
      if TerminalText.isDefaultIgnorable(scalar) {
        if startsCluster || !hasExtendablePrintOwner(state.openCluster, in: screen) {
          state.reset()
          continue
        }
      }
      Self.print(scalar, category: category, startsCluster: startsCluster, in: &screen, columns: columns, blankCellCapacity: blankCellCapacity,
                 leftRightMargins: leftRightMargins, autoWrap: autoWrap, insertMode: insertMode,
                 attributes: attributes, history: &history, nextRowID: &nextRowID,
                 retainHistory: retainHistory, state: &state, effect: &effect)
      mutations += 1
      // Only a primary-history append yields: Core must enforce budgets and
      // viewport clamps before another scalar can scroll the document.
      if effect.appendedHistoryCount > 0 {
        return PrintBatchEffect(effect: effect, consumedScalarCount: consumed, mutationCount: mutations)
      }

      // Admission remains deliberately narrow: the first scalar has already
      // established grapheme ownership through the ordinary transaction.
      // Subsequent printable ASCII scalars each begin a fresh cluster, so a
      // bounded same-row run can share one row replacement without altering
      // wrapping, insert, history or identity boundaries.
      guard category == .other, scalar.value >= 0x20, scalar.value <= 0x7e,
            startsCluster, !insertMode, !screen.pendingWrap,
            screen.rows.indices.contains(screen.cursorRow),
            screen.rows[screen.cursorRow].count > screen.cursorColumn else { continue }
      let horizontal = leftRightMargins
        ? (screen.leftMargin, screen.rightMargin) : (0, columns - 1)
      let bounds = screen.cursorColumn <= horizontal.1 ? horizontal : (0, columns - 1)
      let capacity = autoWrap ? bounds.1 - screen.cursorColumn + 1
                              : bounds.1 - screen.cursorColumn
      guard capacity > 0, index != scalars.endIndex else { continue }

      var end = index
      var count = 0
      var last: Unicode.Scalar?
      while end != scalars.endIndex, count < capacity {
        let candidate = scalars[end]
        guard candidate.value >= 0x20, candidate.value <= 0x7e else { break }
        last = candidate
        count += 1
        end = scalars.index(after: end)
      }
      guard count > 0, let last else { continue }

      // Segmenter state after a run of plain ASCII depends only on its final
      // scalar. Work on a copy so an unexpected continuation retains the
      // ordinary scalar path rather than changing state prematurely.
      var finalSegmenter = state.segmenter
      guard finalSegmenter.push(last, category: .other) else { continue }
      Self.replacePrintedASCII(in: &screen.rows[screen.cursorRow], at: screen.cursorColumn,
                               scalars: scalars[index..<end], count: count,
                               attributes: attributes)
      state.segmenter = finalSegmenter
      let firstColumn = screen.cursorColumn
      state.openCluster = (screen.cursorRow, firstColumn + count - 1)
      state.retainedScalars = 1
      state.capped = false
      effect.lastPrinted = String(last)
      effect.repeatAttributes = PrintAttributes(style: attributes.style, link: attributes.link,
                                                protected: attributes.protected)
      screen.cursorColumn = min(bounds.1, firstColumn + count)
      screen.pendingWrap = firstColumn + count > bounds.1 && autoWrap
      consumed += count
      mutations += count
      index = end
    }
    return PrintBatchEffect(effect: effect, consumedScalarCount: consumed, mutationCount: mutations)
  }

  private static func hasExtendablePrintOwner(_ owner: (row: Int, column: Int)?,
                                                in screen: borrowing TerminalScreen) -> Bool {
    guard let owner else { return false }
    return owner.row == screen.cursorRow && screen.rows.indices.contains(owner.row) &&
      screen.rows[owner.row].count > owner.column
  }

  private static func print(_ scalar: Unicode.Scalar, category: TerminalText.Category, startsCluster: Bool,
                            in screen: inout TerminalScreen, columns: Int, blankCellCapacity: Int,
                            leftRightMargins: Bool, autoWrap: Bool, insertMode: Bool,
                            attributes: borrowing PrintAttributes, history: inout TerminalHistory,
                            nextRowID: inout UInt64, retainHistory: Bool,
                            state: inout PrintState,
                            effect: inout PrintEffect) {
    let horizontal = leftRightMargins ? (screen.leftMargin, screen.rightMargin) : (0, columns - 1)
    func writeBounds(_ column: Int) -> (left: Int, right: Int) {
      return column <= horizontal.1 ? (horizontal.0, horizontal.1) : (0, columns - 1)
    }
    func erase(_ row: Int, _ range: Range<Int>, _ eraseStyle: TerminalStyle) {
      let lower = max(0, range.lowerBound), upper = min(columns, range.upperBound)
      guard screen.rows.indices.contains(row), lower < upper else { return }
      for column in lower..<upper { screen.rows[row].erase(at: column, style: eraseStyle) }
      Self.repairWidePairsInPlace(&screen.rows[row], around: lower..<upper, eraseStyle: eraseStyle)
      screen.rows[row].revision &+= 1
    }
    func shift(_ row: Int, _ column: Int, _ right: Int, _ amount: Int, _ eraseStyle: TerminalStyle) {
      guard screen.rows.indices.contains(row), column <= right else { return }
      let count = min(amount, right - column + 1)
      guard count > 0 else { return }
      if column + count <= right {
        screen.rows[row].shiftCells(column: column, right: right, amount: count, inserting: true)
      }
      for index in column..<(column + count) { screen.rows[row].erase(at: index, style: eraseStyle) }
      Self.repairWidePairsInPlace(&screen.rows[row], around: column..<(right + 1), eraseStyle: eraseStyle)
      screen.rows[row].revision &+= 1
    }
    func scrollUpFullWidth() {
      var removed = screen.rows.remove(at: screen.topMargin)
      if retainHistory {
        screen.rows.insert(Self.erasedRow(columns: columns, logicalCellCapacity: blankCellCapacity,
                                         style: attributes.style, id: nextRowID, history: &history), at: screen.bottomMargin)
      } else {
        removed.resetForReuse(columns: columns, logicalCellCapacity: blankCellCapacity,
                              style: attributes.style, id: nextRowID)
        screen.rows.insert(removed, at: screen.bottomMargin)
      }
      nextRowID &+= 1
      if retainHistory && screen.topMargin == 0 && screen.bottomMargin == screen.rows.count - 1 {
        history.append(removed)
        effect.appendedHistoryCount += 1
      }
    }
    func wrap() {
      let old = screen.cursorRow
      screen.rows[old].softWrapped = horizontal.0 == 0 && horizontal.1 == columns - 1
      let inside = (horizontal.0...horizontal.1).contains(screen.cursorColumn)
      if screen.cursorRow == screen.bottomMargin && inside {
        if horizontal.0 == 0 && horizontal.1 == columns - 1 {
          scrollUpFullWidth()
        } else {
          Self.scrollRectangleInPlace(&screen, columns: columns, top: screen.topMargin, bottom: screen.bottomMargin,
                                      left: horizontal.0, right: horizontal.1, count: 1,
                               up: true, eraseStyle: attributes.style)
        }
      } else {
        screen.cursorRow = min(screen.rows.count - 1, screen.cursorRow + 1)
      }
      screen.cursorColumn = writeBounds(screen.cursorColumn).left
      screen.pendingWrap = false
    }

    if !startsCluster, let owner = state.openCluster, owner.row == screen.cursorRow,
       screen.rows[owner.row].count > owner.column {
      let cell = screen.rows[owner.row].cell(owner.column)
      if state.capped || state.retainedScalars + 1 > 64 {
        state.capped = true
        screen.rows[owner.row].addFlags(4, at: owner.column)
        return
      }
      state.retainedScalars += 1
      var combined = cell.text
      combined.unicodeScalars.append(scalar)
      let nominal = min(2, max(1, TerminalText.cellWidth(of: combined)))
      let oldWidth = cell.kind == 2 ? 2 : 1
      let right = writeBounds(owner.column).right
      if nominal > oldWidth && owner.column + nominal > right + 1 && autoWrap {
        erase(owner.row, owner.column..<(owner.column + oldWidth), cell.style.erased())
        if writeBounds(owner.column).left == 0 && right == columns - 1 { screen.rows[owner.row].setKind(4, at: owner.column) }
        screen.cursorRow = owner.row; screen.cursorColumn = owner.column; screen.pendingWrap = true
        wrap()
        let row = screen.cursorRow, column = screen.cursorColumn
        let newRight = writeBounds(column).right
        let occupied = min(nominal, newRight + 1 - column)
        let lead = TerminalCell(text: combined, kind: nominal == 2 && occupied == 2 ? 2 : 1,
                                style: cell.style, link: cell.link,
                                flags: cell.flags | (nominal > occupied ? 1 : 0),
                                protected: cell.protected)
        Self.replacePrintedLead(in: &screen.rows[row], at: column, with: lead)
        state.openCluster = (row, column)
        screen.cursorColumn = min(newRight, column + occupied); screen.pendingWrap = column + occupied > newRight && autoWrap
      } else {
        let occupied = min(nominal, right + 1 - owner.column)
        if occupied > oldWidth && insertMode && (horizontal.0...horizontal.1).contains(owner.column) {
          shift(owner.row, owner.column + oldWidth, horizontal.1, occupied - oldWidth, cell.style.erased())
        }
        let lead = TerminalCell(text: combined, kind: nominal == 2 && occupied == 2 ? 2 : 1,
                                style: cell.style, link: cell.link,
                                flags: cell.flags | (nominal > occupied ? 1 : 0),
                                protected: cell.protected)
        Self.replacePrintedLead(in: &screen.rows[owner.row], at: owner.column, with: lead)
        screen.cursorRow = owner.row; screen.cursorColumn = min(right, owner.column + occupied); screen.pendingWrap = owner.column + occupied > right && autoWrap
      }
      effect.lastPrinted = combined
      effect.repeatAttributes = PrintAttributes(style: cell.style, link: cell.link, protected: cell.protected)
      return
    }
    state.openCluster = nil; state.retainedScalars = 0
    let measuredWidth: Int
    let richText: String?
    if scalar.value < 0x80 && category == .other {
      measuredWidth = 1
      richText = nil
    } else {
      let text = String(scalar)
      measuredWidth = TerminalText.cellWidth(of: text)
      richText = text
    }
    if measuredWidth == 0 {
      if TerminalText.isDefaultIgnorable(scalar) {
        return
      }
      if !startsCluster, screen.cursorColumn > 0 {
        var attachment = screen.pendingWrap ? screen.cursorColumn : screen.cursorColumn - 1
        if !screen.pendingWrap, screen.rows[screen.cursorRow].kind(at: attachment) == 0, screen.cursorColumn < columns { attachment = screen.cursorColumn }
        let owner = Self.repairedCellOwner(in: screen.rows[screen.cursorRow], at: attachment)
        let count = screen.rows[screen.cursorRow].scalarCount(at: owner)
        if count + 1 > 64 { screen.rows[screen.cursorRow].addFlags(4, at: owner) }
        else { screen.rows[screen.cursorRow].appendScalar(scalar, at: owner) }
      }
      if !startsCluster { return }
    }
    let width = min(2, max(1, measuredWidth))
    state.capped = false
    // A pending wrap lands at the left edge. A width <= 2 then fits, except
    // in a one-column region where it clips; the overflow branch below cannot
    // wrap that scalar twice. Cluster extension above also wraps at most once
    // before returning. The effect counts actual appends rather than assuming
    // one, and the batch yields immediately after this scalar's transaction.
    if screen.pendingWrap && autoWrap { wrap() }
    guard screen.rows.indices.contains(screen.cursorRow),
          (0..<columns).contains(screen.cursorColumn) else { return }
    let bounds = writeBounds(screen.cursorColumn)
    if width == 2 && screen.cursorColumn + 2 > bounds.right + 1 && bounds.right > bounds.left && autoWrap {
      erase(screen.cursorRow, screen.cursorColumn..<(screen.cursorColumn + 1), attributes.style.erased())
      if bounds.left == 0 && bounds.right == columns - 1 { screen.rows[screen.cursorRow].setKind(4, at: screen.cursorColumn) }
      wrap()
    }
    let right = writeBounds(screen.cursorColumn).right
    let occupied = min(width, right + 1 - screen.cursorColumn)
    guard occupied > 0 else { return }
    if insertMode, (horizontal.0...horizontal.1).contains(screen.cursorColumn) {
      shift(screen.cursorRow, screen.cursorColumn, horizontal.1, occupied, attributes.style.erased())
    }
    let row = screen.cursorRow, column = screen.cursorColumn
    let truncated = width == 2 && occupied < width
    let kind: UInt8 = width == 2 && occupied == 2 ? 2 : 1
    let flags: UInt8 = (attributes.protected ? 2 : 0) | (truncated ? 1 : 0)
    if let richText {
      Self.replacePrintedLead(in: &screen.rows[row], at: column,
                              with: TerminalCell(text: richText, kind: kind, style: attributes.style,
                                                 link: attributes.link, flags: flags,
                                                 protected: attributes.protected))
    } else {
      Self.replacePrintedScalar(in: &screen.rows[row], at: column, scalar: scalar, kind: kind,
                                style: attributes.style, link: attributes.link, flags: flags,
                                protected: attributes.protected)
    }
    state.openCluster = (row, column); state.retainedScalars = 1
    effect.lastPrinted = richText ?? String(scalar)
    effect.repeatAttributes = PrintAttributes(style: attributes.style, link: attributes.link,
                                              protected: attributes.protected)
    screen.cursorColumn = min(right, column + occupied)
    screen.pendingWrap = column + occupied > right && autoWrap
  }

  // Printing replaces a single physical lead and, when needed, its adjacent
  // continuation.  Unlike erase/edit operations, the overwritten cells are
  // not observable mid-transaction, so install the rich lead directly and
  // clear only pair halves that survive beyond its new physical span.
  private static func replacePrintedLead(in row: inout TerminalRow, at column: Int,
                                         with lead: TerminalCell) {
    guard column >= 0, column < row.count else { return }
    let width = lead.kind == 2 ? 2 : 1
    guard column + width <= row.count else { return }
    guard preparePrintedReplacement(in: &row, at: column, count: width, like: lead) else { return }

    row.setCell(lead, at: column)
    if width == 2 {
      row.setCell(TerminalCell(text: "", kind: 3, style: lead.style,
                                link: lead.link, flags: lead.flags & ~UInt8(1),
                                protected: lead.protected), at: column + 1)
    }
    row.revision &+= 1
  }

  private static func replacePrintedScalar(in row: inout TerminalRow, at column: Int,
                                           scalar: Unicode.Scalar, kind: UInt8, style: TerminalStyle,
                                           link: String?, flags: UInt8, protected: Bool) {
    guard column >= 0, column < row.count else { return }
    let width = kind == 2 ? 2 : 1
    guard column + width <= row.count else { return }
    let prototype = TerminalCell(text: "", kind: kind, style: style, link: link,
                                 flags: flags, protected: protected)
    guard preparePrintedReplacement(in: &row, at: column, count: width, like: prototype) else { return }
    row.setScalar(scalar, at: column, kind: kind, style: style, link: link, flags: flags,
                  protected: protected)
    if width == 2 {
      row.setCell(TerminalCell(text: "", kind: 3, style: style, link: link,
                                flags: flags & ~UInt8(1), protected: protected), at: column + 1)
    }
    row.revision &+= 1
  }

  private static func replacePrintedASCII<C: Collection>(in row: inout TerminalRow, at column: Int,
                                                          scalars: C, count: Int,
                                                          attributes: borrowing PrintAttributes)
  where C.Element == Unicode.Scalar {
    guard count > 0, column >= 0, column < row.count, column + count <= row.count else { return }
    let prototype = TerminalCell(text: "", kind: 1, style: attributes.style, link: attributes.link,
                                 flags: attributes.protected ? 2 : 0, protected: attributes.protected)
    guard preparePrintedReplacement(in: &row, at: column, count: count, like: prototype) else { return }
    row.replaceASCII(at: column, scalars: scalars, style: attributes.style,
                     link: attributes.link, protected: attributes.protected)
    row.revision &+= UInt64(count)
  }

  // All print-time replacements share this boundary owner. It clears only
  // pair halves that survive outside the newly owned span; the caller writes
  // every cell inside that span directly.
  private static func preparePrintedReplacement(in row: inout TerminalRow, at column: Int,
                                                count: Int, like lead: borrowing TerminalCell) -> Bool {
    guard count > 0, column >= 0, column < row.count, column + count <= row.count else { return false }
    let end = column + count
    let eraseStyle = lead.style.erased()
    let clearsLeft = column > 0 && row.kind(at: column) == 3 && row.kind(at: column - 1) == 2
    let clearsRight = end < row.count && row.kind(at: end - 1) == 2 && row.kind(at: end) == 3
    if clearsLeft { row.erase(at: column - 1, style: eraseStyle) }
    if clearsRight { row.erase(at: end, style: eraseStyle) }
    return true
  }

  func hasValidInvariants(_ screen: TerminalScreen) -> Bool {
    guard columns > 0, rowCount > 0, screen.rows.count == rowCount,
          (0..<rowCount).contains(screen.cursorRow), (0..<columns).contains(screen.cursorColumn),
          screen.topMargin >= 0, screen.topMargin <= screen.bottomMargin, screen.bottomMargin < rowCount,
          screen.leftMargin >= 0, screen.leftMargin <= screen.rightMargin, screen.rightMargin < columns else {
      return false
    }
    return screen.rows.allSatisfy { row in
      guard row.count == columns else { return false }
      for index in 0..<row.count {
        switch row.kind(at: index) {
        case 2:
          guard index + 1 < row.count, row.kind(at: index + 1) == 3 else { return false }
        case 3:
          guard index > 0, row.kind(at: index - 1) == 2 else { return false }
        default: break
        }
      }
      return true
    }
  }

  // The text at a redrawable OSC 133 marker belongs to the shell. Before a
  // width reflow, retain terminal output before the marker and move the cursor
  // back to that exact boundary. A deferred-wrap marker starts on the next row.
  mutating func clearPromptSuffix(_ screen: inout TerminalScreen, eraseStyle: TerminalStyle) -> Bool {
    guard let anchor = screen.promptAnchor,
          let rowIndex = screen.rows.firstIndex(where: { $0.id == anchor.row }) else {
      screen.retirePromptAnchor()
      return false
    }
    if !anchor.pendingWrap {
      erase(&screen, row: rowIndex,
            columns: min(columns, max(0, anchor.column))..<columns,
            style: eraseStyle)
    }
    if rowIndex + 1 < screen.rows.count {
      for index in (rowIndex + 1)..<screen.rows.count {
        screen.rows[index] = eraseRow(eraseStyle)
      }
    }
    screen.cursorRow = rowIndex
    screen.cursorColumn = min(columns - 1, max(0, anchor.column))
    screen.pendingWrap = anchor.pendingWrap
    return true
  }

  // This is the rich editing seam. The caller selects a screen; document code
  // owns pair repair and rectangular copying so command handlers do not learn
  // about continuations, links, styles, protection, or row identities.
  mutating func shift(_ screen: inout TerminalScreen, row: Int, column: Int, right: Int,
                      count: Int, inserting: Bool, eraseStyle: TerminalStyle) {
    guard screen.rows.indices.contains(row), column <= right, right < columns else { return }
    let amount = min(count, right - column + 1); guard amount > 0 else { return }
    if inserting {
      if column + amount <= right { screen.rows[row].shiftCells(column: column, right: right, amount: amount, inserting: true) }
      for index in column..<(column + amount) { screen.rows[row].erase(at: index, style: eraseStyle) }
    } else {
      if column <= right - amount { screen.rows[row].shiftCells(column: column, right: right, amount: amount, inserting: false) }
      for index in (right - amount + 1)...right { screen.rows[row].erase(at: index, style: eraseStyle) }
    }
    repairWidePairs(&screen.rows[row], eraseStyle: eraseStyle); screen.rows[row].revision &+= 1
  }
  mutating func erase(_ screen: inout TerminalScreen, row: Int, columns range: Range<Int>, style: TerminalStyle, selective: Bool = false) {
    guard screen.rows.indices.contains(row) else { return }
    let lower = max(0, range.lowerBound), upper = min(columns, range.upperBound); guard lower < upper else { return }
    for column in lower..<upper where !selective || !screen.rows[row].isProtected(at: column) { screen.rows[row].erase(at: column, style: style) }
    repairWidePairs(&screen.rows[row], eraseStyle: style); screen.rows[row].revision &+= 1
  }
  mutating func scrollRectangle(_ screen: inout TerminalScreen, top: Int, bottom: Int, left: Int, right: Int, count: Int, up: Bool, eraseStyle: TerminalStyle) {
    Self.scrollRectangleInPlace(&screen, columns: columns, top: top, bottom: bottom, left: left, right: right,
                                count: count, up: up, eraseStyle: eraseStyle)
  }
  private static func scrollRectangleInPlace(_ screen: inout TerminalScreen, columns: Int, top: Int, bottom: Int, left: Int, right: Int, count: Int, up: Bool, eraseStyle: TerminalStyle) {
    guard top >= 0, bottom < screen.rows.count, top <= bottom, left >= 0, right < columns, left <= right else { return }
    let amount = min(count, bottom - top + 1); guard amount > 0 else { return }
    let originals = screen.rows
    for step in 0...(bottom - top) {
      let destination = up ? top + step : bottom - step; let source = up ? destination + amount : destination - amount
      if source >= top && source <= bottom { screen.rows[destination].copyRange(from: originals[source], left...right) }
      else { for column in left...right { screen.rows[destination].erase(at: column, style: eraseStyle) }; screen.rows[destination].softWrapped = false }
      repairWidePairsInPlace(&screen.rows[destination], eraseStyle: eraseStyle); screen.rows[destination].revision &+= 1
    }
    if left != 0 || right != columns - 1 { screen.rows[top].softWrapped = false }
  }
  mutating func resize(_ screen: TerminalScreen, columns nextColumns: Int, rows nextRows: Int) -> TerminalScreen {
    var result = TerminalScreen(rows: [], columns: nextColumns); setSize(columns: nextColumns, rows: nextRows); result.rows = makeRows(nextRows)
    let start = max(0, screen.rows.count - nextRows)
    for (destination, source) in screen.rows.suffix(nextRows).enumerated() {
      var row = source; row.truncate(to: min(source.count, nextColumns))
      if row.count < nextColumns { row.appendBlanks(nextColumns - row.count) }
      repairWidePairs(&row, eraseStyle: TerminalStyle()); result.rows[destination] = row
    }
    result.cursorRow = min(nextRows - 1, max(0, screen.cursorRow - start)); result.cursorColumn = min(nextColumns - 1, screen.cursorColumn); result.pendingWrap = false
    return result
  }
  func resizedRow(_ source: TerminalRow, columns nextColumns: Int) -> TerminalRow {
    var row = source
    row.truncate(to: min(source.count, nextColumns))
    if row.count < nextColumns { row.appendBlanks(nextColumns - row.count) }
    repairWidePairs(&row, eraseStyle: TerminalStyle())
    if nextColumns != source.count { row.softWrapped = false; row.revision &+= 1 }
    return row
  }
  func repairedCellOwner(in row: TerminalRow, at column: Int) -> Int { Self.repairedCellOwner(in: row, at: column) }
  private static func repairedCellOwner(in row: TerminalRow, at column: Int) -> Int { column >= 0 && column < row.count && row.kind(at: column) == 3 && column > 0 ? column - 1 : column }
  private mutating func makeRows(_ count: Int) -> [TerminalRow] { (0..<count).map { _ in blankRow() } }
  private func repairWidePairs(_ row: inout TerminalRow, eraseStyle: TerminalStyle) {
    Self.repairWidePairsInPlace(&row, eraseStyle: eraseStyle)
  }
  private static func repairWidePairsInPlace(_ row: inout TerminalRow, eraseStyle: TerminalStyle) {
    repairWidePairsInPlace(&row, around: 0..<row.count, eraseStyle: eraseStyle)
  }
  // A cell mutation can only orphan a wide pair at the mutation's two edges:
  // cells wholly inside an overwritten span are erased, while an untouched
  // interior pair remains adjacent. Keep the full-row entry point above for
  // operations that replace arbitrary row regions, but scalar printing repairs
  // only the changed span and its crossing neighbours.
  private static func repairWidePairsInPlace(_ row: inout TerminalRow, around changed: Range<Int>, eraseStyle: TerminalStyle) {
    guard row.count > 0 else { return }
    let lower = max(0, changed.lowerBound)
    let upper = min(row.count, changed.upperBound)
    guard lower < upper else { return }
    let first = max(0, lower - 1)
    let last = min(row.count - 1, upper)
    for index in first...last {
      if row.kind(at: index) == 2 && (index + 1 >= row.count || row.kind(at: index + 1) != 3) { row.erase(at: index, style: eraseStyle) }
      if row.kind(at: index) == 3 && (index == 0 || row.kind(at: index - 1) != 2) { row.erase(at: index, style: eraseStyle) }
    }
  }
}

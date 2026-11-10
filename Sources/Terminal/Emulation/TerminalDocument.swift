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

// The hot row representation: eight reference-free bytes per cell. Text is
// either the single Unicode scalar here, or an exceptional payload in the row
// dictionary below. The style is an index into the owning row's style table;
// zero is the default style, so plain rows carry no table at all.
// `hasScalar` distinguishes a real U+0000 from empty.
private struct TerminalRowSlot: Equatable {
  var scalar: UInt32 = 0
  var style: UInt16 = 0
  var flags: UInt8 = 0
  // Cell kind in the low five bits; the top three record scalar presence,
  // protection, and whether the row's payload dictionary has an entry for
  // this cell. The last spares ordinary cells every dictionary probe.
  private var tag: UInt8 = 0
  private static let scalarBit: UInt8 = 0x80, protectedBit: UInt8 = 0x40, payloadBit: UInt8 = 0x20
  private static let kindMask: UInt8 = 0x1f

  init() {}
  init(scalar: UInt32 = 0, style: UInt16, hasScalar: Bool = false, kind: UInt8 = 0,
       flags: UInt8 = 0, protected: Bool = false, hasPayload: Bool = false) {
    self.scalar = scalar; self.style = style; self.flags = flags
    tag = (kind & Self.kindMask) | (hasScalar ? Self.scalarBit : 0) | (protected ? Self.protectedBit : 0)
      | (hasPayload ? Self.payloadBit : 0)
  }
  var hasPayload: Bool {
    get { tag & Self.payloadBit != 0 }
    set { tag = newValue ? tag | Self.payloadBit : tag & ~Self.payloadBit }
  }
  var kind: UInt8 {
    get { tag & Self.kindMask }
    set { tag = (tag & ~Self.kindMask) | (newValue & Self.kindMask) }
  }
  var hasScalar: Bool {
    get { tag & Self.scalarBit != 0 }
    set { tag = newValue ? tag | Self.scalarBit : tag & ~Self.scalarBit }
  }
  var protected: Bool { tag & Self.protectedBit != 0 }

  // Bulk writes treat a slot as one 64-bit word whose low half is the scalar.
  // A field-by-field loop stores one cell per iteration; the word form lets
  // the compiler fill and widen with vector instructions.
  private var word: UInt64 { unsafeBitCast(self, to: UInt64.self) }

  /// UTF-8 bytes of the scalars held directly in `slots`.
  static func scalarUTF8Bytes(in slots: UnsafeBufferPointer<TerminalRowSlot>) -> UInt64 {
    let raw = UnsafeRawBufferPointer(slots)
    // The scalar-presence mark is each word's top bit. One simple pass counts
    // the scalars and learns whether any is beyond ASCII; rows of plain ASCII,
    // the usual case, need nothing more.
    var present: UInt64 = 0, union: UInt64 = 0
    for index in 0..<slots.count {
      let word = raw.loadUnaligned(fromByteOffset: index &* 8, as: UInt64.self)
      present &+= word >> 63
      union |= word
    }
    if UInt32(truncatingIfNeeded: union) < 0x80 { return present }
    var total: UInt64 = 0
    for index in 0..<slots.count {
      let word = raw.loadUnaligned(fromByteOffset: index &* 8, as: UInt64.self)
      let scalar = UInt32(truncatingIfNeeded: word)
      let length: UInt64 = 1 + (scalar > 0x7f ? 1 : 0) + (scalar > 0x7ff ? 1 : 0) + (scalar > 0xffff ? 1 : 0)
      total &+= (word >> 63) &* length
    }
    return total
  }
  /// Sets every slot in `slots` to this value.
  func fill(_ slots: UnsafeMutableBufferPointer<TerminalRowSlot>) {
    let word = word
    let raw = UnsafeMutableRawBufferPointer(slots)
    for index in 0..<slots.count {
      raw.storeBytes(of: word, toByteOffset: index &* 8, as: UInt64.self)
    }
  }
  /// Writes one copy of this slot per byte, each carrying that byte as its scalar.
  func write(ascii bytes: UnsafeBufferPointer<UInt8>, to slots: UnsafeMutableBufferPointer<TerminalRowSlot>) {
    precondition(bytes.count <= slots.count)
    let template = word & ~UInt64(UInt32.max)
    let raw = UnsafeMutableRawBufferPointer(slots)
    for index in 0..<bytes.count {
      raw.storeBytes(of: template | UInt64(bytes[index]), toByteOffset: index &* 8, as: UInt64.self)
    }
  }
}

private struct TerminalRowPayload: Equatable {
  var text: String?
  var link: String?
  var utf8Bytes: UInt64 { UInt64(text?.utf8.count ?? 0) + UInt64(link?.utf8.count ?? 0) }
}

// The sparse payload owner keeps its resource charge with its entries.
// Every replacement/removal updates both atomically; scalar-only rows never
// enter this path. Reflow can therefore reserve an input generation without
// scanning every cell or retaining an uncharged history generation first.
//
// Entries are kept in column order. Printing writes left to right, so a new
// payload is nearly always an append, and a bulk overwrite removes one
// contiguous run; neither hashes anything.
private struct TerminalRowPayloads: Equatable {
  struct Entry: Equatable {
    var column: Int
    var payload: TerminalRowPayload
  }
  private(set) var entries: [Entry] = []
  private(set) var utf8Bytes: UInt64 = 0
  // Most entries held at once since the last reset. Reflow admission charges
  // the capacity of the dictionary these entries used to live in; that
  // capacity grew with this count and never shrank.
  private var peakCount = 0
  var count: Int { entries.count }
  var capacity: Int { TerminalHistory.dictionaryCapacity(holding: peakCount) }
  var isEmpty: Bool { entries.isEmpty }

  static func == (lhs: TerminalRowPayloads, rhs: TerminalRowPayloads) -> Bool { lhs.entries == rhs.entries }

  /// Position of the first entry at or right of `column`.
  @inline(__always) private func position(of column: Int) -> Int {
    guard let last = entries.last, last.column >= column else { return entries.count }
    var lower = 0, upper = entries.count - 1
    while lower < upper {
      let middle = (lower + upper) / 2
      if entries[middle].column < column { lower = middle + 1 } else { upper = middle }
    }
    return lower
  }
  subscript(_ column: Int) -> TerminalRowPayload? {
    get {
      let position = position(of: column)
      return position < entries.count && entries[position].column == column ? entries[position].payload : nil
    }
    set {
      let position = position(of: column)
      let exists = position < entries.count && entries[position].column == column
      if let newValue {
        if exists {
          utf8Bytes -= entries[position].payload.utf8Bytes
          entries[position].payload = newValue
        } else {
          let entry = Entry(column: column, payload: newValue)
          if position == entries.count { entries.append(entry) } else { entries.insert(entry, at: position) }
          peakCount = max(peakCount, entries.count)
        }
        utf8Bytes += newValue.utf8Bytes
      } else if exists {
        utf8Bytes -= entries.remove(at: position).payload.utf8Bytes
      }
    }
  }
  mutating func removeValue(forKey column: Int) { self[column] = nil }
  mutating func removeAll(keepingCapacity: Bool = false) {
    entries.removeAll(keepingCapacity: keepingCapacity); utf8Bytes = 0
    if !keepingCapacity { peakCount = 0 }
  }
  /// Leaves every column in `range` with a payload that is only `link`, or
  /// with none when `link` is nil.
  mutating func replace(in range: Range<Int>, link: String?) {
    if link == nil && entries.isEmpty { return }
    let lower = position(of: range.lowerBound), upper = position(of: range.upperBound)
    for position in lower..<upper { utf8Bytes -= entries[position].payload.utf8Bytes }
    guard let link else {
      if lower < upper { entries.removeSubrange(lower..<upper) }
      return
    }
    let payload = TerminalRowPayload(text: nil, link: link)
    entries.replaceSubrange(lower..<upper, with: range.lazy.map { Entry(column: $0, payload: payload) })
    utf8Bytes += UInt64(range.count) * payload.utf8Bytes
    peakCount = max(peakCount, entries.count)
  }
  /// Drops every payload at or right of `column`. The modeled capacity
  /// starts over from the survivors, as the rebuilt dictionary's did.
  mutating func truncate(to column: Int) {
    let lower = position(of: column)
    for position in lower..<entries.count { utf8Bytes -= entries[position].payload.utf8Bytes }
    entries.removeSubrange(lower...)
    peakCount = entries.count
  }
  /// Gives the columns `source` shifted by `offset` the payloads of `source`.
  /// Columns outside that target keep theirs.
  mutating func move(_ source: Range<Int>, by offset: Int) {
    guard !entries.isEmpty, !source.isEmpty else { return }
    let moved = entries[position(of: source.lowerBound)..<position(of: source.upperBound)].map {
      Entry(column: $0.column + offset, payload: $0.payload)
    }
    let lower = position(of: source.lowerBound + offset), upper = position(of: source.upperBound + offset)
    for position in lower..<upper { utf8Bytes -= entries[position].payload.utf8Bytes }
    for entry in moved { utf8Bytes += entry.payload.utf8Bytes }
    entries.replaceSubrange(lower..<upper, with: moved)
    peakCount = max(peakCount, entries.count)
  }
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
  // Non-default styles used by this row; a slot's style index is its position
  // plus one. Entries are append-only between compactions, so an index stays
  // valid for the whole of one row edit.
  var styles: [TerminalStyle]
  var logicalCapacity: Int
  var detachCapacity: Int
  init(slots: [TerminalRowSlot], payloads: TerminalRowPayloads = TerminalRowPayloads(),
       styles: [TerminalStyle] = [], logicalCapacity: Int, detachCapacity: Int) {
    self.slots = slots; self.payloads = payloads; self.styles = styles
    self.logicalCapacity = logicalCapacity; self.detachCapacity = detachCapacity
  }
  /// A blank row whose every cell carries `style` (already reduced to its erased form).
  convenience init(blankColumns columns: Int, style: TerminalStyle, logicalCapacity: Int) {
    let plain = style == TerminalStyle()
    self.init(slots: Array(repeating: TerminalRowSlot(style: plain ? 0 : 1), count: columns),
              styles: plain ? [] : [style], logicalCapacity: logicalCapacity, detachCapacity: logicalCapacity)
  }
  @inline(__always) func compactStylesIfNeeded() {
    if styles.count >= 64 { compactStyles() }
  }
  @inline(__always) func style(_ index: UInt16) -> TerminalStyle {
    index == 0 ? TerminalStyle() : styles[Int(index) - 1]
  }
  @inline(__always) func payload(at index: Int) -> TerminalRowPayload? {
    slots[index].hasPayload ? payloads[index] : nil
  }
  /// Replaces one cell together with its exceptional payload, if any. Every
  /// single-cell write goes through here so the slot's payload mark stays exact.
  @inline(__always) func setSlot(_ slot: TerminalRowSlot, payload: TerminalRowPayload?, at index: Int) {
    var slot = slot
    if let payload {
      payloads[index] = payload
      slot.hasPayload = true
    } else {
      if slots[index].hasPayload { payloads.removeValue(forKey: index) }
      slot.hasPayload = false
    }
    slots[index] = slot
  }
  /// Prepares `range` for a bulk overwrite: every cell gets `link`, or loses its payload.
  func replacePayloads(in range: Range<Int>, link: String?) {
    payloads.replace(in: range, link: link)
  }
  /// Writes each scalar as a fresh one- or two-cell cluster starting at
  /// `column`, and returns the column after the last.
  func writeSingletons(_ scalars: UnsafeBufferPointer<Unicode.Scalar>, at column: Int, style: UInt16,
                       flags: UInt8, protected: Bool, linked: Bool) -> Int {
    slots.withUnsafeMutableBufferPointer { slots in
      var index = column
      for scalar in scalars {
        let width = TerminalText.scalarClass(of: scalar).width
        slots[index] = TerminalRowSlot(scalar: scalar.value, style: style, hasScalar: true,
                                       kind: width == 2 ? 2 : 1, flags: flags, protected: protected,
                                       hasPayload: linked)
        if width == 2 {
          slots[index + 1] = TerminalRowSlot(style: style, kind: 3, flags: flags, protected: protected,
                                            hasPayload: linked)
        }
        index += width
      }
      return index
    }
  }
  /// Writes a fresh multi-scalar cluster at `column` and returns the column
  /// after it.
  func writeCluster(text: String, link: String?, wide: Bool, at column: Int, style: UInt16,
                    flags: UInt8, protected: Bool) -> Int {
    payloads[column] = TerminalRowPayload(text: text, link: link)
    return slots.withUnsafeMutableBufferPointer { slots in
      slots[column] = TerminalRowSlot(style: style, kind: wide ? 2 : 1, flags: flags, protected: protected,
                                      hasPayload: true)
      guard wide else { return column + 1 }
      slots[column + 1] = TerminalRowSlot(style: style, kind: 3, flags: flags, protected: protected,
                                          hasPayload: link != nil)
      return column + 2
    }
  }
  /// Index for `style`, appended when this row has not used it yet. Recently
  /// added styles are searched first: consecutive writes usually share one.
  func intern(_ style: TerminalStyle) -> UInt16 {
    if style == TerminalStyle() { return 0 }
    var index = styles.count
    while index > 0 {
      if styles[index - 1] == style { return UInt16(index) }
      index -= 1
    }
    styles.append(style)
    return UInt16(styles.count)
  }
  /// Drops styles no cell uses once overwritten entries dominate the table.
  /// Runs only at the start of an edit, never between `intern` and its use.
  private func compactStyles() {
    guard styles.count >= 2 * slots.count else { return }
    var remap = [UInt16](repeating: 0, count: styles.count + 1)
    var kept: [TerminalStyle] = []
    for index in slots.indices {
      let old = Int(slots[index].style)
      guard old != 0 else { continue }
      if remap[old] == 0 { kept.append(styles[old - 1]); remap[old] = UInt16(kept.count) }
      slots[index].style = remap[old]
    }
    styles = kept
  }
  /// Fills every cell with a blank of `style` and forgets all other styles.
  func reset(style: TerminalStyle) {
    let plain = style == TerminalStyle()
    if !styles.isEmpty { styles.removeAll(keepingCapacity: true) }
    if !plain { styles.append(style) }
    slots.withUnsafeMutableBufferPointer { TerminalRowSlot(style: plain ? 0 : 1).fill($0) }
    if !payloads.isEmpty { payloads.removeAll(keepingCapacity: true) }
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
    didSet { if oldValue != softWrapped, observation != nil { selectionObservation?.softEdgeChanged() } }
  }
  // Rows move on every scroll, and few are ever observed. Keeping the
  // observation behind one reference halves the row; the box is never mutated
  // after it is installed, so a copied row still observes independently.
  private final class ObservationBox {
    let value: SelectionObservation
    init(_ value: SelectionObservation) { self.value = value }
  }
  private var observation: ObservationBox?
  var selectionObservation: SelectionObservation? {
    get { observation?.value }
    set { observation = newValue.map(ObservationBox.init) }
  }
  /// The row's stride before the observation was boxed. Reflow admission keeps
  /// charging it so existing budget decisions do not move.
  static let admissionStride = 80
  private mutating func observeSelectionWrite(_ range: Range<Int>) {
    guard let current = observation?.value, !current.overwritten else { return }
    var updated = current
    updated.write(range)
    if updated.overwritten { observation = ObservationBox(updated) }
  }
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
    TerminalRow(id: id, storage: TerminalRowStorage(blankColumns: columns, style: style.erased(),
                                                     logicalCapacity: logicalCellCapacity))
  }
  mutating func resetForReuse(columns: Int, logicalCellCapacity: Int,
                              style: TerminalStyle, id: UInt64) {
    selectionObservation = nil
    if storage.slots.count != columns || !isKnownUniquelyReferenced(&storage) {
      storage = TerminalRowStorage(blankColumns: columns, style: style.erased(),
                                   logicalCapacity: logicalCellCapacity)
      self.id = id; revision = 0; softWrapped = false
      return
    }
    storage.reset(style: style.erased())
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
      let slot = storage.slots[position]
      return TerminalRow.project(slot, storage.style(slot.style), storage.payload(at: position))
    }
  }
  var cells: Cells { Cells(storage: storage) }
  var count: Int { storage.slots.count }
  var payloadCount: Int { storage.payloads.count }
  var retainedCellCapacity: Int { storage.logicalCapacity }

  func cell(_ index: Int) -> TerminalCell {
    let slot = storage.slots[index]
    return Self.project(slot, storage.style(slot.style), storage.payload(at: index))
  }
  private static func project(_ slot: TerminalRowSlot, _ style: TerminalStyle,
                              _ payload: TerminalRowPayload?) -> TerminalCell {
    let text: String
    if let payloadText = payload?.text { text = payloadText }
    else if slot.hasScalar, let scalar = Unicode.Scalar(slot.scalar) { text = String(scalar) }
    else { text = "" }
    return TerminalCell(text: text, kind: slot.kind, style: style,
                        link: payload?.link, flags: slot.flags, protected: slot.protected)
  }
  private mutating func ensureUniqueForCellEdit() {
    if !isKnownUniquelyReferenced(&storage) {
      storage = TerminalRowStorage(slots: storage.slots, payloads: storage.payloads, styles: storage.styles,
                                   logicalCapacity: storage.detachCapacity,
                                   detachCapacity: storage.detachCapacity)
    }
    storage.compactStylesIfNeeded()
  }

  mutating func setCell(_ cell: TerminalCell, at index: Int) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    var slot = TerminalRowSlot(scalar: 0, style: storage.intern(cell.style), hasScalar: false,
                               kind: cell.kind, flags: cell.flags, protected: cell.protected)
    var payload = TerminalRowPayload(text: nil, link: cell.link)
    let scalars = cell.text.unicodeScalars
    if scalars.count == 1, let scalar = scalars.first {
      slot.scalar = scalar.value
      slot.hasScalar = true
    } else if !cell.text.isEmpty {
      payload.text = cell.text
    }
    storage.setSlot(slot, payload: payload.text != nil || payload.link != nil ? payload : nil, at: index)
  }

  mutating func setScalar(_ scalar: Unicode.Scalar, at index: Int, kind: UInt8,
                          style: TerminalStyle, link: String?, flags: UInt8, protected: Bool) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    let slot = TerminalRowSlot(scalar: scalar.value, style: storage.intern(style), hasScalar: true,
                               kind: kind, flags: flags, protected: protected)
    storage.setSlot(slot, payload: link.map { TerminalRowPayload(text: nil, link: $0) }, at: index)
  }

  /// Re-forms the cells of a multi-scalar cluster after it gained a scalar:
  /// its lead, and its continuation when it is two cells wide. The cluster's
  /// text follows in one `setClusterText` once the print transaction has seen
  /// its last scalar; until then the lead's text is stale.
  mutating func reformCluster(at index: Int, wide: Bool, style: TerminalStyle, link: String?,
                              flags: UInt8, protected: Bool) {
    let width = wide ? 2 : 1
    guard index >= 0, index + width <= storage.slots.count else { return }
    clearPairHalves(outside: index..<(index + width), eraseStyle: style.erased())
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    let styleIndex = storage.intern(style)
    storage.slots[index] = TerminalRowSlot(style: styleIndex, kind: wide ? 2 : 1, flags: flags,
                                           protected: protected, hasPayload: storage.slots[index].hasPayload)
    if wide {
      observeSelectionWrite((index + 1)..<(index + 2))
      storage.setSlot(TerminalRowSlot(style: styleIndex, kind: 3, flags: flags & ~UInt8(1), protected: protected),
                      payload: link.map { TerminalRowPayload(text: nil, link: $0) }, at: index + 1)
    }
    revision &+= 1
  }
  /// Reads the cell a cluster is about to grow from: its attributes, and its
  /// text as scalars in `scalars`.
  fileprivate func clusterLead(at index: Int, scalars: inout [Unicode.Scalar]) -> TerminalDocument.ClusterLead {
    let slot = storage.slots[index]
    let payload = storage.payload(at: index)
    scalars.removeAll(keepingCapacity: true)
    if let text = payload?.text {
      for scalar in text.unicodeScalars { scalars.append(scalar) }
    } else if slot.hasScalar, let scalar = Unicode.Scalar(slot.scalar) {
      scalars.append(scalar)
    }
    return TerminalDocument.ClusterLead(style: storage.style(slot.style), link: payload?.link, flags: slot.flags,
                                        protected: slot.protected, wide: slot.kind == 2)
  }
  mutating func setClusterText(_ text: String, link: String?, at index: Int) {
    ensureUniqueForCellEdit()
    storage.payloads[index] = TerminalRowPayload(text: text, link: link)
    storage.slots[index].hasPayload = true
  }
  mutating func erase(at index: Int, style: TerminalStyle = TerminalStyle()) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    storage.setSlot(TerminalRowSlot(style: storage.intern(style.erased())), payload: nil, at: index)
  }
  mutating func copyCell(from source: TerminalRow, at sourceIndex: Int, to index: Int) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    var slot = source.storage.slots[sourceIndex]
    slot.style = storage.intern(source.storage.style(slot.style))
    storage.setSlot(slot, payload: source.storage.payload(at: sourceIndex), at: index)
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
    // Style indices are row-local: translate each source index once per run.
    var sourceStyle: UInt16 = 0, targetStyle: UInt16 = 0
    for offset in 0..<range.count {
      var slot = source.storage.slots[range.lowerBound + offset]
      if slot.style != sourceStyle {
        sourceStyle = slot.style
        targetStyle = storage.intern(source.storage.style(sourceStyle))
      }
      slot.style = targetStyle
      storage.setSlot(slot, payload: source.storage.payload(at: range.lowerBound + offset), at: destination + offset)
    }
  }
  mutating func setKind(_ kind: UInt8, at index: Int) { observeSelectionWrite(index..<(index + 1)); ensureUniqueForCellEdit(); storage.slots[index].kind = kind }
  mutating func setFlags(_ flags: UInt8, at index: Int) { observeSelectionWrite(index..<(index + 1)); ensureUniqueForCellEdit(); storage.slots[index].flags = flags }
  mutating func addFlags(_ flags: UInt8, at index: Int) { observeSelectionWrite(index..<(index + 1)); ensureUniqueForCellEdit(); storage.slots[index].flags |= flags }
  mutating func clearText(at index: Int) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit(); storage.slots[index].scalar = 0
    storage.slots[index].hasScalar = false
    if var payload = storage.payload(at: index) {
      payload.text = nil
      if payload.link != nil { storage.payloads[index] = payload }
      else { storage.payloads.removeValue(forKey: index); storage.slots[index].hasPayload = false }
    }
  }
  func kind(at index: Int) -> UInt8 { storage.slots[index].kind }
  func flags(at index: Int) -> UInt8 { storage.slots[index].flags }
  func style(at index: Int) -> TerminalStyle { storage.style(storage.slots[index].style) }
  func isProtected(at index: Int) -> Bool { storage.slots[index].protected }
  func scalarCount(at index: Int) -> Int {
    storage.payload(at: index)?.text?.unicodeScalars.count ?? (storage.slots[index].hasScalar ? 1 : 0)
  }
  mutating func appendScalar(_ scalar: Unicode.Scalar, at index: Int) {
    var cell = cell(index)
    cell.text.unicodeScalars.append(scalar)
    setCell(cell, at: index)
  }
  mutating func truncate(to newCount: Int) {
    if newCount < count { observeSelectionWrite(newCount..<count) }
    let next = Self.legacyCapacity(existingCount: storage.slots.count, capacity: storage.logicalCapacity, truncatingTo: newCount)
    if !isKnownUniquelyReferenced(&storage) { storage = TerminalRowStorage(slots: storage.slots, payloads: storage.payloads, styles: storage.styles, logicalCapacity: storage.logicalCapacity, detachCapacity: storage.detachCapacity) }
    storage.logicalCapacity = next; storage.detachCapacity = Self.blankLogicalCapacity(columns: newCount)
    storage.slots = Array(storage.slots.prefix(newCount))
    storage.payloads.truncate(to: newCount)
  }
  mutating func appendBlanks(_ count: Int) {
    guard count > 0 else { return }
    let next = Self.legacyCapacity(existingCount: storage.slots.count, capacity: storage.logicalCapacity, appending: count)
    if !isKnownUniquelyReferenced(&storage) { storage = TerminalRowStorage(slots: storage.slots, payloads: storage.payloads, styles: storage.styles, logicalCapacity: storage.logicalCapacity, detachCapacity: storage.detachCapacity) }
    storage.logicalCapacity = next; storage.detachCapacity = Self.blankLogicalCapacity(columns: storage.slots.count + count)
    storage.slots.append(contentsOf: repeatElement(TerminalRowSlot(), count: count))
  }
  mutating func copyRange(from source: TerminalRow, _ range: ClosedRange<Int>) {
    for index in range { copyCell(from: source, at: index, to: index) }
  }
  mutating func shiftCells(column: Int, right: Int, amount: Int, inserting: Bool) {
    observeSelectionWrite(column..<(right + 1))
    ensureUniqueForCellEdit()
    // A slot's payload mark travels with the slot.
    if inserting {
      storage.payloads.move(column..<(right - amount + 1), by: amount)
      for destination in stride(from: right, through: column + amount, by: -1) {
        storage.slots[destination] = storage.slots[destination - amount]
      }
    } else {
      storage.payloads.move((column + amount)..<(right + 1), by: -amount)
      for destination in column...(right - amount) {
        storage.slots[destination] = storage.slots[destination + amount]
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
    storage.replacePayloads(in: range, link: link)
    let styleIndex = storage.intern(style)
    storage.slots.withUnsafeMutableBufferPointer { slots in
      var index = column
      for scalar in scalars {
        slots[index] = TerminalRowSlot(scalar: scalar.value, style: styleIndex, hasScalar: true,
                                       kind: 1, flags: protected ? 2 : 0, protected: protected,
                                       hasPayload: link != nil)
        index += 1
      }
    }
  }

  /// Writes printable ASCII bytes as fresh width-one cells. The caller has
  /// bounded the run to this row and repaired wide pairs at its two edges.
  /// A print is about to own `range`: erase the half of a wide pair that it
  /// would leave behind just outside either edge. Cells inside the range are
  /// the caller's to write.
  private mutating func clearPairHalves(outside range: Range<Int>, eraseStyle: TerminalStyle) {
    let lower = range.lowerBound, upper = range.upperBound
    let clearsLeft = lower > 0 && storage.slots[lower].kind == 3 && storage.slots[lower - 1].kind == 2
    let clearsRight = upper < storage.slots.count && storage.slots[upper - 1].kind == 2
      && storage.slots[upper].kind == 3
    if clearsLeft { erase(at: lower - 1, style: eraseStyle) }
    if clearsRight { erase(at: upper, style: eraseStyle) }
  }
  mutating func writeASCII(_ bytes: UnsafeBufferPointer<UInt8>, at column: Int, style: TerminalStyle,
                           link: String?, protected: Bool) {
    let count = bytes.count
    guard count > 0, column >= 0, column + count <= storage.slots.count else { return }
    let range = column..<(column + count)
    clearPairHalves(outside: range, eraseStyle: style.erased())
    ensureUniqueForCellEdit()
    observeSelectionWrite(range)
    storage.replacePayloads(in: range, link: link)
    let slot = TerminalRowSlot(scalar: 0, style: storage.intern(style), hasScalar: true, kind: 1,
                               flags: protected ? 2 : 0, protected: protected, hasPayload: link != nil)
    storage.slots.withUnsafeMutableBufferPointer { slots in
      slot.write(ascii: bytes, to: UnsafeMutableBufferPointer(rebasing: slots[range]))
    }
    revision &+= UInt64(count)
  }

  /// Writes a run of fresh clusters that the caller has admitted and that fits
  /// this row. Each scalar is a one- or two-cell cluster of its own, except
  /// where `clusters` (in buffer order) names a longer one held in `texts`.
  fileprivate mutating func replaceClusters(at column: Int, scalars: UnsafeBufferPointer<Unicode.Scalar>,
                                            clusters: [TerminalDocument.PrintedCluster],
                                            texts: borrowing TerminalDocument.ClusterCache, cellCount: Int,
                                            style: TerminalStyle, link: String?, protected: Bool) {
    guard cellCount > 0, column >= 0, column + cellCount <= storage.slots.count else { return }
    let range = column..<(column + cellCount)
    clearPairHalves(outside: range, eraseStyle: style.erased())
    ensureUniqueForCellEdit()
    observeSelectionWrite(range)
    storage.replacePayloads(in: range, link: link)
    revision &+= UInt64(scalars.count)
    let styleIndex = storage.intern(style)
    let flags: UInt8 = protected ? 2 : 0
    let linked = link != nil
    var index = column, position = 0
    for cluster in clusters {
      index = storage.writeSingletons(UnsafeBufferPointer(rebasing: scalars[position..<cluster.start]), at: index,
                                      style: styleIndex, flags: flags, protected: protected, linked: linked)
      index = storage.writeCluster(text: texts.text(in: cluster.slot), link: link, wide: cluster.wide, at: index,
                                   style: styleIndex, flags: flags, protected: protected)
      position = cluster.start + cluster.count
    }
    _ = storage.writeSingletons(UnsafeBufferPointer(rebasing: scalars[position...]), at: index,
                                style: styleIndex, flags: flags, protected: protected, linked: linked)
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
  // Admission keeps charging the 24 bytes a cell occupied before styles moved
  // into the row table. That over-covers the packed slots and their table for
  // ordinary rows and leaves every existing budget decision unchanged.
  private static let admissionSlotCharge = 24
  var allocationSlotCost: UInt64 { 64 + UInt64(storage.slots.capacity * Self.admissionSlotCharge) }
  var reflowAllocationBytes: UInt64 { allocationBaseCost + 2 * storage.payloads.utf8Bytes + (selectionObservation?.allocationBytes ?? 0) }
  func reflowCellStorage(at index: Int) -> (textBytes: UInt64, linkBytes: UInt64, sparse: Bool, hasLink: Bool) {
    let slot = storage.slots[index]
    let payload = storage.payload(at: index)
    return (slot.hasScalar ? UInt64(Self.utf8Length(of: slot.scalar)) : UInt64(payload?.text?.utf8.count ?? 0),
            UInt64(payload?.link?.utf8.count ?? 0), payload != nil, payload?.link != nil)
  }
  var retainedStorageCost: UInt64 {
    var bytes = Self.logicalRowCharge + UInt64(storage.logicalCapacity) * Self.logicalCellCharge
    bytes += storage.slots.withUnsafeBufferPointer { TerminalRowSlot.scalarUTF8Bytes(in: $0) }
    if storage.payloads.isEmpty { return bytes }
    return bytes + storage.payloads.utf8Bytes
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
    if lhs.storage.slots == rhs.storage.slots && lhs.storage.styles == rhs.storage.styles
        && lhs.storage.payloads == rhs.storage.payloads { return true }
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
  /// The most recently printed cluster, retained for REP. A fresh scalar is the
  /// common case and needs no String until a repeat actually asks for one.
  enum PrintedText: Equatable {
    case scalar(Unicode.Scalar)
    case cluster(String)
    var text: String {
      switch self {
      case .scalar(let scalar): return String(scalar)
      case .cluster(let text): return text
      }
    }
  }
  struct PrintEffect {
    var appendedHistoryCount: Int
    var lastPrinted: PrintedText?
    /// Nil means the attributes the caller supplied for this transaction.
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
    // Scratch for the cluster being extended; it carries nothing between
    // transactions and lives here only so its buffer is reused.
    var clusterScalars: [Unicode.Scalar] = []
    var clusters = ClusterCache()
    // Scratch for the multi-scalar clusters of the run being admitted.
    var runClusters: [PrintedCluster] = []

    mutating func reset() {
      segmenter = TerminalText.Segmenter()
      openCluster = nil
      retainedScalars = 0
      capped = false
    }
  }
  /// The attributes of a cluster's lead cell, as an extension needs them.
  fileprivate struct ClusterLead {
    var style: TerminalStyle
    var link: String?
    var flags: UInt8
    var protected: Bool
    var wide: Bool
  }
  /// A multi-scalar cluster inside a run handed to `replaceClusters`:
  /// `count` scalars from buffer position `start`, whose text is in cluster
  /// cache slot `slot`.
  fileprivate struct PrintedCluster {
    var start: Int
    var count: Int
    var slot: Int
    var wide: Bool
  }
  /// Multi-scalar clusters printed recently, with what assembling one scalar
  /// at a time would have to derive again: the text, and whether each prefix is
  /// one or two cells wide. Terminal output repeats the same few emoji, flags
  /// and accented letters, so a small direct-mapped table answers nearly all.
  fileprivate struct ClusterCache {
    static let maximumScalars = 24
    private static let slotCount = 256
    // Parallel per-slot columns, so a lookup compares scalars without
    // retaining anything.
    private var keys: [Unicode.Scalar] = []
    private var counts: [UInt8] = []
    private var texts: [String] = []
    private var widePrefixes: [UInt32] = []
    // A run being admitted refers to its clusters by slot until it is
    // written. Slots it has used carry its number and are not replaced.
    private var runs: [UInt32] = []
    private var run: UInt32 = 0

    /// Starts a run: no slot is pinned any more.
    @inline(__always) mutating func beginRun() { run &+= 1 }

    /// The slot holding the cluster `scalars`, which has between one and
    /// `maximumScalars` scalars. With `pinning`, the slot stays as it is until
    /// the next run begins, and the result is nil when that would mean
    /// replacing a slot this run has pinned.
    mutating func slot(for scalars: UnsafeBufferPointer<Unicode.Scalar>, pinning: Bool = false) -> Int? {
      var hash: UInt32 = 2_166_136_261
      for scalar in scalars { hash = (hash ^ scalar.value) &* 16_777_619 }
      let slot = Int((hash ^ hash >> 16) & 255)
      let base = slot * Self.maximumScalars
      if keys.isEmpty {
        keys = Array(repeating: "\0", count: Self.slotCount * Self.maximumScalars)
        counts = Array(repeating: 0, count: Self.slotCount)
        texts = Array(repeating: "", count: Self.slotCount)
        widePrefixes = Array(repeating: 0, count: Self.slotCount)
        runs = Array(repeating: 0, count: Self.slotCount)
      } else if Int(counts[slot]) == scalars.count {
        let matches = keys.withUnsafeBufferPointer { keys in
          var index = 0
          while index < scalars.count, keys[base + index] == scalars[index] { index += 1 }
          return index == scalars.count
        }
        if matches {
          if pinning { runs[slot] = run }
          return slot
        }
      }
      if pinning && runs[slot] == run { return nil }
      var wide: UInt32 = 0
      for count in 1...scalars.count
      where TerminalWidth.width(of: Array(scalars[..<count])[...]) >= 2 {
        wide |= 1 << UInt32(count)
      }
      for index in 0..<scalars.count { keys[base + index] = scalars[index] }
      counts[slot] = UInt8(scalars.count)
      texts[slot] = TerminalText.string(from: Array(scalars))
      widePrefixes[slot] = wide
      runs[slot] = pinning ? run : run &- 1
      return slot
    }
    @inline(__always) func text(in slot: Int) -> String { texts[slot] }
    /// Cells occupied by the first `count` scalars of the cluster in `slot`.
    @inline(__always) func width(in slot: Int, ofFirst count: Int) -> Int {
      widePrefixes[slot] & (1 << UInt32(count)) != 0 ? 2 : 1
    }
    /// Whether the cluster in `slot` never narrows as its scalars arrive.
    @inline(__always) func onlyWidens(in slot: Int) -> Bool {
      // Its wide prefixes are then one unbroken run ending at the full
      // cluster: adding the lowest wide bit carries out past the last scalar.
      let wide = widePrefixes[slot] >> 1
      return wide == 0 || wide &+ (wide & (0 &- wide)) == UInt32(1) << UInt32(counts[slot])
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
    let removed = rotateRegion(&screen.rows, top: top, bottom: bottom, up: up, columns: columns,
                               blankCellCapacity: blankCellCapacity, eraseStyle: eraseStyle,
                               recycle: recycleDiscarded, history: &history, nextRowID: &nextRowID)
    return up && top == 0 && bottom == screen.rows.count - 1 ? removed : nil
  }

  /// Rotates a full-width region by one row with a single move of the rows
  /// between its edges. The departing row is either recycled as the entering
  /// blank row or returned to the caller, which decides whether history keeps it.
  private static func rotateRegion(_ rows: inout [TerminalRow], top: Int, bottom: Int, up: Bool,
                                   columns: Int, blankCellCapacity: Int, eraseStyle: TerminalStyle,
                                   recycle: Bool, history: inout TerminalHistory,
                                   nextRowID: inout UInt64) -> TerminalRow? {
    precondition(top >= 0 && top <= bottom && bottom < rows.count)
    let id = nextRowID
    nextRowID &+= 1
    return rows.withUnsafeMutableBufferPointer { rows -> TerminalRow? in
      let base = rows.baseAddress!
      var departing = (base + (up ? top : bottom)).move()
      if up {
        (base + top).moveInitialize(from: base + top + 1, count: bottom - top)
      } else {
        (base + top + 1).moveInitialize(from: base + top, count: bottom - top)
      }
      let entering = base + (up ? bottom : top)
      if recycle {
        departing.resetForReuse(columns: columns, logicalCellCapacity: blankCellCapacity,
                                style: eraseStyle, id: id)
        entering.initialize(to: departing)
        return nil
      }
      entering.initialize(to: erasedRow(columns: columns, logicalCellCapacity: blankCellCapacity,
                                        style: eraseStyle, id: id, history: &history))
      return departing
    }
  }

  /// Moves the cursor to the next row for a deferred wrap, scrolling the region
  /// when the cursor is on its bottom margin. Returns the number of rows that
  /// entered primary history.
  private static func wrapCursor(in screen: inout TerminalScreen, columns: Int, blankCellCapacity: Int,
                                 horizontal: (left: Int, right: Int), style: TerminalStyle,
                                 history: inout TerminalHistory, nextRowID: inout UInt64,
                                 retainHistory: Bool) -> Int {
    var appended = 0
    let fullWidth = horizontal.left == 0 && horizontal.right == columns - 1
    screen.rows[screen.cursorRow].softWrapped = fullWidth
    let inside = (horizontal.left...horizontal.right).contains(screen.cursorColumn)
    if screen.cursorRow == screen.bottomMargin && inside {
      if fullWidth {
        let removed = rotateRegion(&screen.rows, top: screen.topMargin, bottom: screen.bottomMargin, up: true,
                                   columns: columns, blankCellCapacity: blankCellCapacity, eraseStyle: style,
                                   recycle: !retainHistory, history: &history, nextRowID: &nextRowID)
        if let removed, screen.topMargin == 0 && screen.bottomMargin == screen.rows.count - 1 {
          history.append(removed)
          appended = 1
        }
      } else {
        scrollRectangleInPlace(&screen, columns: columns, top: screen.topMargin, bottom: screen.bottomMargin,
                               left: horizontal.left, right: horizontal.right, count: 1,
                               up: true, eraseStyle: style)
      }
    } else {
      screen.cursorRow = min(screen.rows.count - 1, screen.cursorRow + 1)
    }
    screen.cursorColumn = screen.cursorColumn <= horizontal.right ? horizontal.left : 0
    screen.pendingWrap = false
    return appended
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
                      attributes: PrintAttributes) -> PrintBatchEffect where C.Element == Unicode.Scalar {
    let contiguous = scalars.withContiguousStorageIfAvailable {
      print($0, usingAlternate: usingAlternate, leftRightMargins: leftRightMargins, autoWrap: autoWrap,
            insertMode: insertMode, attributes: attributes)
    }
    if let contiguous { return contiguous }
    return Array(scalars).withUnsafeBufferPointer {
      print($0, usingAlternate: usingAlternate, leftRightMargins: leftRightMargins, autoWrap: autoWrap,
            insertMode: insertMode, attributes: attributes)
    }
  }
  mutating func print(_ scalars: UnsafeBufferPointer<Unicode.Scalar>, usingAlternate: Bool,
                      leftRightMargins: Bool, autoWrap: Bool, insertMode: Bool,
                      attributes: borrowing PrintAttributes) -> PrintBatchEffect {
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

  struct ASCIIPrintResult {
    /// Zero when the next byte needs the scalar transaction; nothing was changed.
    var consumedCount: Int
    var appendedHistoryCount: Int
  }
  /// Text transaction for a run of printable ASCII bytes (0x20...0x7E), borrowed
  /// from the parser's input for the duration of the call. Equivalent to printing
  /// each consumed byte as a scalar; like `print`, it yields after a history
  /// append. The last consumed byte is the repeatable text, with `attributes`.
  mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>, usingAlternate: Bool,
                           leftRightMargins: Bool, autoWrap: Bool, insertMode: Bool,
                           attributes: borrowing PrintAttributes) -> ASCIIPrintResult {
    if usingAlternate {
      return Self.printASCII(bytes, in: &alternate, columns: columns, blankCellCapacity: blankCellCapacity,
                             leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                             insertMode: insertMode, attributes: attributes, history: &history,
                             retainHistory: false, state: &printState, nextRowID: &nextRowID)
    }
    return Self.printASCII(bytes, in: &primary, columns: columns, blankCellCapacity: blankCellCapacity,
                           leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                           insertMode: insertMode, attributes: attributes, history: &history,
                           retainHistory: true, state: &printState, nextRowID: &nextRowID)
  }

  private static func printASCII(_ bytes: UnsafeBufferPointer<UInt8>, in screen: inout TerminalScreen,
                                 columns: Int, blankCellCapacity: Int, leftRightMargins: Bool,
                                 autoWrap: Bool, insertMode: Bool,
                                 attributes: borrowing PrintAttributes,
                                 history: inout TerminalHistory, retainHistory: Bool,
                                 state: inout PrintState, nextRowID: inout UInt64) -> ASCIIPrintResult {
    let horizontal = leftRightMargins ? (screen.leftMargin, screen.rightMargin) : (0, columns - 1)
    var consumed = 0, appended = 0
    while consumed < bytes.count, appended == 0 {
      // Printable ASCII starts a cluster unless it follows a Prepend scalar.
      // That case, insert mode and an invalid cursor stay with the scalar
      // transaction; everything else is a fresh run of width-one cells.
      guard state.segmenter.printableASCIIStartsCluster, !insertMode,
            screen.rows.indices.contains(screen.cursorRow),
            (0..<columns).contains(screen.cursorColumn) else { break }
      state.segmenter.pushPrintableASCII()
      if screen.pendingWrap && autoWrap {
        appended += wrapCursor(
          in: &screen, columns: columns, blankCellCapacity: blankCellCapacity, horizontal: horizontal,
          style: attributes.style, history: &history, nextRowID: &nextRowID, retainHistory: retainHistory)
      }
      let row = screen.cursorRow, column = screen.cursorColumn
      let right = column <= horizontal.1 ? horizontal.1 : columns - 1
      // Without auto-wrap the cursor stays on the right edge, so a run may fill
      // the cells before the edge, or overwrite the edge cell one scalar at a time.
      let room = autoWrap ? right - column + 1 : max(1, right - column)
      // The byte whose wrap appended history is admitted alone, so the caller
      // enforces history limits before anything else is printed.
      let count = appended > 0 ? 1 : min(bytes.count - consumed, room)
      screen.rows[row].writeASCII(UnsafeBufferPointer(rebasing: bytes[consumed..<(consumed + count)]),
                                  at: column, style: attributes.style, link: attributes.link,
                                  protected: attributes.protected)
      state.openCluster = (row, column + count - 1)
      state.retainedScalars = 1
      state.capped = false
      screen.cursorColumn = min(right, column + count)
      screen.pendingWrap = column + count > right && autoWrap
      consumed += count
    }
    return ASCIIPrintResult(consumedCount: consumed, appendedHistoryCount: appended)
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

  private static func printBatch(_ scalars: UnsafeBufferPointer<Unicode.Scalar>, in screen: inout TerminalScreen,
                                 columns: Int, blankCellCapacity: Int, leftRightMargins: Bool,
                                 autoWrap: Bool, insertMode: Bool,
                                 attributes: borrowing PrintAttributes,
                                 history: inout TerminalHistory, retainHistory: Bool,
                                 state: inout PrintState,
                                 nextRowID: inout UInt64) -> PrintBatchEffect {
    var effect = PrintEffect(appendedHistoryCount: 0, lastPrinted: nil, repeatAttributes: nil)
    var consumed = 0, mutations = 0
    let horizontal = leftRightMargins ? (screen.leftMargin, screen.rightMargin) : (0, columns - 1)
    while consumed < scalars.count {
      // Most text is a run of fresh one- or two-cell clusters of one scalar:
      // ASCII, CJK, precomposed letters, box drawing, the first scalar of an
      // emoji. Admit the longest such run that fits this row and write it as
      // one row edit. The segmenter runs on a copy, so a rejected scalar leaves
      // it untouched for the code below, which owns everything else: cluster
      // extension, zero-width and ignorable scalars, insert mode and
      // wide-glyph wrapping.
      if !insertMode, screen.rows.indices.contains(screen.cursorRow),
         (0..<columns).contains(screen.cursorColumn) {
        let wraps = screen.pendingWrap && autoWrap
        let column = wraps ? (screen.cursorColumn <= horizontal.1 ? horizontal.0 : 0) : screen.cursorColumn
        let right = column <= horizontal.1 ? horizontal.1 : columns - 1
        let capacity = right - column + (autoWrap ? 1 : 0)
        var segmenter = state.segmenter
        var end = consumed, cells = 0, lastWidth = 0
        // Where the cluster most recently admitted to this run begins.
        var lead = -1
        if !state.runClusters.isEmpty { state.runClusters.removeAll(keepingCapacity: true) }
        state.clusters.beginRun()
        // A wrap on the primary screen can append history. Its scalar is
        // admitted alone, so the caller enforces history limits before
        // anything else is printed.
        let limit = wraps && retainHistory ? min(scalars.count, consumed + 1) : scalars.count
        while end < limit, cells < capacity {
          let candidate = scalars[end]
          let width: Int
          if candidate.value &- 0x20 < 0x5f {
            guard segmenter.printableASCIIStartsCluster else { break }
            segmenter.pushPrintableASCII()
            width = 1
          } else {
            let scalarClass = TerminalText.scalarClass(of: candidate)
            if scalarClass.isPlainText, segmenter.isAfterPlainText {
              // Ordinary text after ordinary text: a boundary that leaves
              // the segmenter as it is.
              width = scalarClass.width
              guard width == 1 || width == 2, cells + width <= capacity else { break }
              lead = end
              cells += width
              lastWidth = width
              end += 1
              continue
            }
            guard !scalarClass.isUnprintedControl else { break }
            var next = segmenter
            guard next.push(candidate, class: scalarClass) else {
              // `candidate` joins the cluster before it. When this run began
              // that cluster, take the rest of it from the buffer and admit
              // the whole; otherwise the code below extends its cell.
              guard lead >= 0 else { break }
              var clusterEnd = end + 1
              while clusterEnd < limit {
                var following = next
                let admitted = admit(scalars[clusterEnd], to: &following)
                guard !admitted.skipped, !admitted.startsCluster else { break }
                next = following
                clusterEnd += 1
              }
              guard clusterEnd - lead <= ClusterCache.maximumScalars,
                    let slot = state.clusters.slot(for: UnsafeBufferPointer(rebasing: scalars[lead..<clusterEnd]),
                                                   pinning: true) else { break }
              let clusterWidth = state.clusters.width(in: slot, ofFirst: clusterEnd - lead)
              guard state.clusters.onlyWidens(in: slot), cells - lastWidth + clusterWidth <= capacity else { break }
              state.runClusters.append(PrintedCluster(start: lead - consumed, count: clusterEnd - lead,
                                                      slot: slot, wide: clusterWidth == 2))
              cells += clusterWidth - lastWidth
              lastWidth = clusterWidth
              segmenter = next
              end = clusterEnd
              lead = -1
              continue
            }
            guard !scalarClass.isDefaultIgnorable else { break }
            width = scalarClass.width
            guard width == 1 || width == 2, cells + width <= capacity else { break }
            segmenter = next
          }
          lead = end
          cells += width
          lastWidth = width
          end += 1
        }
        if end > consumed {
          if wraps {
            effect.appendedHistoryCount += wrapCursor(
              in: &screen, columns: columns, blankCellCapacity: blankCellCapacity, horizontal: horizontal,
              style: attributes.style, history: &history, nextRowID: &nextRowID, retainHistory: retainHistory)
          }
          let row = screen.cursorRow, count = end - consumed
          screen.rows[row].replaceClusters(
            at: column, scalars: UnsafeBufferPointer(rebasing: scalars[consumed..<end]),
            clusters: state.runClusters, texts: state.clusters, cellCount: cells,
            style: attributes.style, link: attributes.link, protected: attributes.protected)
          state.segmenter = segmenter
          state.openCluster = (row, column + cells - lastWidth)
          state.capped = false
          if let last = state.runClusters.last, last.start + last.count == count {
            state.retainedScalars = last.count
            effect.lastPrinted = .cluster(state.clusters.text(in: last.slot))
            // An extended cluster repeats with its lead cell's attributes,
            // which here are the caller's, stated outright as extension does.
            effect.repeatAttributes = PrintAttributes(style: attributes.style, link: attributes.link,
                                                      protected: attributes.protected)
          } else {
            state.retainedScalars = 1
            effect.lastPrinted = .scalar(scalars[end - 1])
            effect.repeatAttributes = nil
          }
          screen.cursorColumn = min(right, column + cells)
          screen.pendingWrap = column + cells > right && autoWrap
          consumed = end
          mutations += count
          // Only a primary-history append yields: Core must enforce budgets and
          // viewport clamps before another scalar can scroll the document.
          if effect.appendedHistoryCount > 0 { break }
          continue
        }
      }

      let scalar = scalars[consumed]
      consumed += 1
      let admitted = admit(scalar, to: &state.segmenter)
      if admitted.skipped { continue }
      if admitted.ignorable,
         admitted.startsCluster || !hasExtendablePrintOwner(state.openCluster, in: screen) {
        state.reset()
        continue
      }
      if !admitted.startsCluster, let owner = state.openCluster, owner.row == screen.cursorRow,
         screen.rows[owner.row].count > owner.column {
        // This scalar joins the cluster in the owner cell. Take the rest of
        // that cluster from the buffer too, and extend it in one step.
        var segmenter = state.segmenter
        var end = consumed
        while end < scalars.count {
          var next = segmenter
          let following = admit(scalars[end], to: &next)
          guard !following.skipped, !following.startsCluster else { break }
          segmenter = next
          end += 1
        }
        if extendCluster(at: owner, with: UnsafeBufferPointer(rebasing: scalars[(consumed - 1)..<end]),
                         in: &screen, columns: columns, horizontal: horizontal, autoWrap: autoWrap,
                         insertMode: insertMode, state: &state, effect: &effect) {
          state.segmenter = segmenter
          mutations += end - consumed + 1
          consumed = end
          continue
        }
      }
      Self.print(scalar, category: admitted.category, startsCluster: admitted.startsCluster, in: &screen, columns: columns, blankCellCapacity: blankCellCapacity,
                 leftRightMargins: leftRightMargins, autoWrap: autoWrap, insertMode: insertMode,
                 attributes: attributes, history: &history, nextRowID: &nextRowID,
                 retainHistory: retainHistory, state: &state, effect: &effect)
      mutations += 1
      if effect.appendedHistoryCount > 0 { break }
    }
    return PrintBatchEffect(effect: effect, consumedScalarCount: consumed, mutationCount: mutations)
  }

  /// Classifies one decoded scalar and advances `segmenter` past it. CR, LF
  /// and other controls are skipped: they are never printed and do not take
  /// part in segmentation.
  @inline(__always)
  private static func admit(_ scalar: Unicode.Scalar, to segmenter: inout TerminalText.Segmenter)
    -> (category: TerminalText.Category, skipped: Bool, startsCluster: Bool, ignorable: Bool) {
    if scalar.value &- 0x20 < 0x5f { return (.other, false, segmenter.pushPrintableASCII(), false) }
    if scalar.value < 0x80 {
      let category = category(for: scalar)
      switch category {
      case .control, .cr, .lf: return (category, true, false, false)
      default: return (category, false, segmenter.push(scalar, category: category), false)
      }
    }
    let scalarClass = TerminalText.scalarClass(of: scalar)
    let category = scalarClass.category
    if scalarClass.isUnprintedControl { return (category, true, false, false) }
    return (category, false, segmenter.push(scalar, class: scalarClass), scalarClass.isDefaultIgnorable)
  }

  /// Appends `added` to the cluster whose lead is at `owner`: the same result
  /// as extending it one scalar at a time, with the width of each step and the
  /// final text taken from the cluster cache. Returns false, leaving the screen
  /// untouched, when a step needs the scalar transaction: the cluster is capped
  /// or too long, outgrows the row edge, or shifts cells in insert mode.
  private static func extendCluster(at owner: (row: Int, column: Int),
                                    with added: UnsafeBufferPointer<Unicode.Scalar>,
                                    in screen: inout TerminalScreen, columns: Int,
                                    horizontal: (Int, Int), autoWrap: Bool, insertMode: Bool,
                                    state: inout PrintState, effect: inout PrintEffect) -> Bool {
    guard !state.capped, state.retainedScalars + added.count <= 64 else { return false }
    let lead = screen.rows[owner.row].clusterLead(at: owner.column, scalars: &state.clusterScalars)
    let leadCount = state.clusterScalars.count
    guard leadCount > 0, leadCount + added.count <= ClusterCache.maximumScalars else { return false }
    for scalar in added { state.clusterScalars.append(scalar) }
    // Without pinning, the cache always answers.
    guard let cluster = state.clusterScalars.withUnsafeBufferPointer({ state.clusters.slot(for: $0) })
    else { return false }
    let text = state.clusters.text(in: cluster)
    let steps = (leadCount + 1)...(leadCount + added.count)
    let right = owner.column <= horizontal.1 ? horizontal.1 : columns - 1
    let room = right + 1 - owner.column
    let shiftsOnGrowth = insertMode && (horizontal.0...horizontal.1).contains(owner.column)

    var wide = lead.wide
    for count in steps {
      let nominal = state.clusters.width(in: cluster, ofFirst: count), oldWidth = wide ? 2 : 1
      let occupied = min(nominal, room)
      if nominal > oldWidth && nominal > room && autoWrap { return false }
      if occupied > oldWidth && shiftsOnGrowth { return false }
      wide = nominal == 2 && occupied == 2
    }

    wide = lead.wide
    var flags = lead.flags, occupied = 0, formed = false
    for count in steps {
      let nominal = state.clusters.width(in: cluster, ofFirst: count)
      occupied = min(nominal, room)
      let nextWide = nominal == 2 && occupied == 2
      let nextFlags = flags | (nominal > occupied ? 1 : 0)
      if formed && nextWide == wide && nextFlags == flags {
        // The cells already have this shape; only the text grew.
        screen.rows[owner.row].revision &+= 1
      } else {
        screen.rows[owner.row].reformCluster(at: owner.column, wide: nextWide, style: lead.style,
                                             link: lead.link, flags: nextFlags, protected: lead.protected)
        formed = true
      }
      wide = nextWide
      flags = nextFlags
    }
    screen.rows[owner.row].setClusterText(text, link: lead.link, at: owner.column)
    state.retainedScalars += added.count
    screen.cursorRow = owner.row
    screen.cursorColumn = min(right, owner.column + occupied)
    screen.pendingWrap = owner.column + occupied > right && autoWrap
    effect.lastPrinted = .cluster(text)
    effect.repeatAttributes = PrintAttributes(style: lead.style, link: lead.link, protected: lead.protected)
    return true
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
    func wrap() {
      effect.appendedHistoryCount += Self.wrapCursor(
        in: &screen, columns: columns, blankCellCapacity: blankCellCapacity, horizontal: horizontal,
        style: attributes.style, history: &history, nextRowID: &nextRowID, retainHistory: retainHistory)
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
      effect.lastPrinted = .cluster(combined)
      effect.repeatAttributes = PrintAttributes(style: cell.style, link: cell.link, protected: cell.protected)
      return
    }
    state.openCluster = nil; state.retainedScalars = 0
    let measuredWidth = scalar.value < 0x80 && category == .other
      ? 1 : TerminalWidth.width(of: scalar)
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
    Self.replacePrintedScalar(in: &screen.rows[row], at: column, scalar: scalar, kind: kind,
                              style: attributes.style, link: attributes.link, flags: flags,
                              protected: attributes.protected)
    state.openCluster = (row, column); state.retainedScalars = 1
    effect.lastPrinted = .scalar(scalar)
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
    guard preparePrintedReplacement(in: &row, at: column, count: width, eraseStyle: lead.style.erased()) else { return }

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
    guard preparePrintedReplacement(in: &row, at: column, count: width, eraseStyle: style.erased()) else { return }
    row.setScalar(scalar, at: column, kind: kind, style: style, link: link, flags: flags,
                  protected: protected)
    if width == 2 {
      row.setCell(TerminalCell(text: "", kind: 3, style: style, link: link,
                                flags: flags & ~UInt8(1), protected: protected), at: column + 1)
    }
    row.revision &+= 1
  }

  // All print-time replacements share this boundary owner. It clears only
  // pair halves that survive outside the newly owned span; the caller writes
  // every cell inside that span directly.
  private static func preparePrintedReplacement(in row: inout TerminalRow, at column: Int,
                                                count: Int, eraseStyle: TerminalStyle) -> Bool {
    guard count > 0, column >= 0, column < row.count, column + count <= row.count else { return false }
    let end = column + count
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

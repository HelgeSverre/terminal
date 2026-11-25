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
  var linkID: String? = nil
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
  @inline(__always)
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
  var linkID: String? = nil
  var utf8Bytes: UInt64 { UInt64(text?.utf8.count ?? 0) + UInt64(link?.utf8.count ?? 0) + UInt64(linkID?.utf8.count ?? 0) }
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
  // Reflow admission charges the capacity of the dictionary these entries
  // used to live in. That capacity grew to hold the most entries the row had
  // held at once and never shrank, so the same figure is kept here.
  private(set) var capacity = 0
  var count: Int { entries.count }
  var isEmpty: Bool { entries.isEmpty }

  static func == (lhs: TerminalRowPayloads, rhs: TerminalRowPayloads) -> Bool { lhs.entries == rhs.entries }
  private mutating func grewCapacity() {
    if entries.count > capacity { capacity = TerminalHistory.dictionaryCapacity(holding: entries.count) }
  }

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
          grewCapacity()
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
    if !keepingCapacity { capacity = 0 }
  }
  /// Leaves every column in `range` with a payload that is only `link`, or
  /// with none when `link` is nil.
  mutating func replace(in range: Range<Int>, link: String?, linkID: String? = nil) {
    if link == nil && entries.isEmpty { return }
    let lower = position(of: range.lowerBound), upper = position(of: range.upperBound)
    for position in lower..<upper { utf8Bytes -= entries[position].payload.utf8Bytes }
    guard let link else {
      if lower < upper { entries.removeSubrange(lower..<upper) }
      return
    }
    let payload = TerminalRowPayload(text: nil, link: link, linkID: linkID)
    entries.replaceSubrange(lower..<upper, with: range.lazy.map { Entry(column: $0, payload: payload) })
    utf8Bytes += UInt64(range.count) * payload.utf8Bytes
    grewCapacity()
  }
  /// Drops every payload at or right of `column`. The modeled capacity
  /// starts over from the survivors, as the rebuilt dictionary's did.
  mutating func truncate(to column: Int) {
    let lower = position(of: column)
    for position in lower..<entries.count { utf8Bytes -= entries[position].payload.utf8Bytes }
    entries.removeSubrange(lower...)
    capacity = TerminalHistory.dictionaryCapacity(holding: entries.count)
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
    grewCapacity()
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
  @exclusivity(unchecked) var slots: [TerminalRowSlot]
  @exclusivity(unchecked) var payloads = TerminalRowPayloads()
  // Non-default styles used by this row; a slot's style index is its position
  // plus one. Entries are append-only between compactions, so an index stays
  // valid for the whole of one row edit.
  @exclusivity(unchecked) var styles: [TerminalStyle]
  @exclusivity(unchecked) var logicalCapacity: Int
  @exclusivity(unchecked) var detachCapacity: Int
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
  @inline(__always) func replacePayloads(in range: Range<Int>, link: String?, linkID: String? = nil) {
    if payloads.isEmpty && link == nil { return }
    payloads.replace(in: range, link: link, linkID: linkID)
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
  private static let asciiStrings: [String] = (UInt32(0x20)...UInt32(0x7e)).map {
    String(Unicode.Scalar($0)!)
  }

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

  @inline(__always)
  private static func cellStyle(for style: TerminalStyle, palette: TerminalPalette) -> CellStyle {
    let resolved = palette.presentationStyle(style)
    let flags = resolved.flags
    return CellStyle(
      foreground: TerminalColor(packed: resolved.foreground),
      background: TerminalColor(packed: resolved.background),
      underline_color: TerminalColor(packed: resolved.underline),
      underline: Int(resolved.underlineKind),
      bold: flags & 1 != 0, faint: flags & 2 != 0, italic: flags & 4 != 0,
      inverse: flags & 8 != 0, conceal: flags & 16 != 0, strike: flags & 32 != 0,
      overline: flags & 64 != 0, blink: flags & 128 != 0)
  }

  /// Projects all slots directly to `CellSnapshot` values, resolving each
  /// distinct row style once and reusing pre-interned strings for printable ASCII.
  func snapshotCells(palette: TerminalPalette) -> [CellSnapshot]? {
    let defaultStyle = Self.cellStyle(for: TerminalStyle(), palette: palette)
    let resolvedStyles: [CellStyle]
    if storage.styles.isEmpty {
      resolvedStyles = []
    } else {
      var table: [CellStyle] = []
      table.reserveCapacity(storage.styles.count + 1)
      table.append(defaultStyle)
      for style in storage.styles {
        table.append(Self.cellStyle(for: style, palette: palette))
      }
      resolvedStyles = table
    }
    let payloadEntries = storage.payloads.entries
    var payloadCursor = 0
    return storage.slots.withUnsafeBufferPointer { slots -> [CellSnapshot]? in
      var cells: [CellSnapshot] = []
      cells.reserveCapacity(slots.count)
      for index in 0..<slots.count {
        let slot = slots[index]
        guard let kind = CellKind(rawValue: slot.kind) else { return nil }
        let style = slot.style == 0 ? defaultStyle : resolvedStyles[Int(slot.style)]
        let payload: TerminalRowPayload?
        if slot.hasPayload {
          while payloadCursor < payloadEntries.count && payloadEntries[payloadCursor].column < index {
            payloadCursor += 1
          }
          if payloadCursor < payloadEntries.count && payloadEntries[payloadCursor].column == index {
            payload = payloadEntries[payloadCursor].payload
            payloadCursor += 1
          } else {
            payload = nil
          }
        } else {
          payload = nil
        }
        let text: String
        if let payloadText = payload?.text {
          text = payloadText
        } else if slot.hasScalar {
          let rawScalar = slot.scalar
          if rawScalar &- 0x20 < 0x5f {
            text = Self.asciiStrings[Int(rawScalar &- 0x20)]
          } else if let scalar = Unicode.Scalar(rawScalar) {
            text = String(scalar)
          } else {
            text = ""
          }
        } else {
          text = ""
        }
        cells.append(CellSnapshot(text: text, kind: kind, style: style,
                                  link: payload?.link, linkID: payload?.linkID, flags: Int(slot.flags)))
      }
      return cells
    }
  }

  /// Inspect the leading scalar without projecting styles, links or a String
  /// for ordinary cells. Graphics scans use this to skip non-placeholder text.
  func starts(with scalar: UInt32, at index: Int) -> Bool {
    let slot = storage.slots[index]
    if slot.hasScalar { return slot.scalar == scalar }
    guard slot.hasPayload else { return false }
    return storage.payload(at: index)?.text?.unicodeScalars.first?.value == scalar
  }

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
                        link: payload?.link, linkID: payload?.linkID, flags: slot.flags, protected: slot.protected)
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
    var payload = TerminalRowPayload(text: nil, link: cell.link, linkID: cell.linkID)
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
                          style: TerminalStyle, link: String?, linkID: String? = nil, flags: UInt8, protected: Bool) {
    observeSelectionWrite(index..<(index + 1))
    ensureUniqueForCellEdit()
    let slot = TerminalRowSlot(scalar: scalar.value, style: storage.intern(style), hasScalar: true,
                               kind: kind, flags: flags, protected: protected)
    storage.setSlot(slot, payload: link.map { TerminalRowPayload(text: nil, link: $0, linkID: linkID) }, at: index)
  }

  /// Re-forms the cells of a multi-scalar cluster after it gained a scalar:
  /// its lead, and its continuation when it is two cells wide. The cluster's
  /// text follows in one `setClusterText` once the print transaction has seen
  /// its last scalar; until then the lead's text is stale.
  mutating func reformCluster(at index: Int, wide: Bool, style: TerminalStyle, link: String?, linkID: String? = nil,
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
                      payload: link.map { TerminalRowPayload(text: nil, link: $0, linkID: linkID) }, at: index + 1)
    }
    revision &+= 1
  }
  /// Reads the cell a cluster is about to grow from: its attributes, and its
  /// text as scalars in `scalars`.
  func clusterLead(at index: Int, scalars: inout [Unicode.Scalar]) -> TerminalDocument.ClusterLead {
    let slot = storage.slots[index]
    let payload = storage.payload(at: index)
    scalars.removeAll(keepingCapacity: true)
    if let text = payload?.text {
      for scalar in text.unicodeScalars { scalars.append(scalar) }
    } else if slot.hasScalar, let scalar = Unicode.Scalar(slot.scalar) {
      scalars.append(scalar)
    }
    return TerminalDocument.ClusterLead(style: storage.style(slot.style), link: payload?.link, linkID: payload?.linkID, flags: slot.flags,
                                        protected: slot.protected, wide: slot.kind == 2)
  }
  mutating func setClusterText(_ text: String, link: String?, linkID: String? = nil, at index: Int) {
    ensureUniqueForCellEdit()
    storage.payloads[index] = TerminalRowPayload(text: text, link: link, linkID: linkID)
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
  func isISOProtected(at index: Int) -> Bool { storage.slots[index].flags & 8 != 0 }
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
                                             link: String?, linkID: String? = nil, protected: Bool, isoProtected: Bool = false) where C.Element == Unicode.Scalar {
    let count = scalars.count
    guard count > 0, column >= 0, column + count <= storage.slots.count else { return }
    ensureUniqueForCellEdit()
    let range = column..<(column + count)
    observeSelectionWrite(range)
    storage.replacePayloads(in: range, link: link, linkID: linkID)
    let styleIndex = storage.intern(style)
    storage.slots.withUnsafeMutableBufferPointer { slots in
      var index = column
      for scalar in scalars {
        slots[index] = TerminalRowSlot(scalar: scalar.value, style: styleIndex, hasScalar: true,
                                       kind: 1, flags: (protected ? 2 : 0) | (isoProtected ? 8 : 0), protected: protected,
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
  @inline(__always)
  private mutating func clearPairHalves(outside range: Range<Int>, eraseStyle: TerminalStyle) {
    let lower = range.lowerBound, upper = range.upperBound
    let (clearsLeft, clearsRight) = storage.slots.withUnsafeBufferPointer { slots in
      let left = lower > 0 && slots[lower].kind == 3 && slots[lower - 1].kind == 2
      let right = upper < slots.count && slots[upper - 1].kind == 2 && slots[upper].kind == 3
      return (left, right)
    }
    if clearsLeft { erase(at: lower - 1, style: eraseStyle) }
    if clearsRight { erase(at: upper, style: eraseStyle) }
  }
  mutating func writeASCII(_ bytes: UnsafeBufferPointer<UInt8>, at column: Int, style: TerminalStyle,
                           link: String?, linkID: String? = nil, protected: Bool, isoProtected: Bool = false) {
    let count = bytes.count
    guard count > 0, column >= 0, column + count <= storage.slots.count else { return }
    let range = column..<(column + count)
    clearPairHalves(outside: range, eraseStyle: style.erased())
    ensureUniqueForCellEdit()
    observeSelectionWrite(range)
    storage.replacePayloads(in: range, link: link, linkID: linkID)
    let slot = TerminalRowSlot(scalar: 0, style: storage.intern(style), hasScalar: true, kind: 1,
                               flags: (protected ? 2 : 0) | (isoProtected ? 8 : 0), protected: protected, hasPayload: link != nil)
    storage.slots.withUnsafeMutableBufferPointer { slots in
      slot.write(ascii: bytes, to: UnsafeMutableBufferPointer(rebasing: slots[range]))
    }
    revision &+= UInt64(count)
  }

  /// Writes a run of fresh clusters that the caller has admitted and that fits
  /// this row. Each scalar is a one- or two-cell cluster of its own (with its
  /// precomputed width in `widths`), except where `clusters` (in buffer order)
  /// names a longer one held in `texts`.
  mutating func replaceClusters(at column: Int, scalars: UnsafeBufferPointer<Unicode.Scalar>,
                                widths: [UInt8],
                                clusters: [TerminalDocument.PrintedCluster],
                                texts: borrowing TerminalDocument.ClusterCache, cellCount: Int,
                                style: TerminalStyle, link: String?, linkID: String? = nil, protected: Bool, isoProtected: Bool = false) {
    guard cellCount > 0, column >= 0, column + cellCount <= storage.slots.count else { return }
    let range = column..<(column + cellCount)
    clearPairHalves(outside: range, eraseStyle: style.erased())
    ensureUniqueForCellEdit()
    observeSelectionWrite(range)
    storage.replacePayloads(in: range, link: link, linkID: linkID)
    revision &+= UInt64(scalars.count)
    let styleIndex = storage.intern(style)
    let flags: UInt8 = (protected ? 2 : 0) | (isoProtected ? 8 : 0)
    let linked = link != nil
    let storage = self.storage
    widths.withUnsafeBufferPointer { widths in
      storage.slots.withUnsafeMutableBufferPointer { slots in
        var narrowSlot = TerminalRowSlot(scalar: 0, style: styleIndex, hasScalar: true, kind: 1,
                                         flags: flags, protected: protected, hasPayload: linked)
        var wideSlot = TerminalRowSlot(scalar: 0, style: styleIndex, hasScalar: true, kind: 2,
                                       flags: flags, protected: protected, hasPayload: linked)
        let continuationSlot = TerminalRowSlot(style: styleIndex, kind: 3, flags: flags, protected: protected,
                                               hasPayload: linked)
        let narrowClusterSlot = TerminalRowSlot(style: styleIndex, kind: 1, flags: flags, protected: protected,
                                                hasPayload: true)
        let wideClusterSlot = TerminalRowSlot(style: styleIndex, kind: 2, flags: flags, protected: protected,
                                              hasPayload: true)
        var index = column, position = 0
        for cluster in clusters {
          let clusterStart = cluster.start
          while position < clusterStart {
            if widths[position] == 2 {
              wideSlot.scalar = scalars[position].value
              slots[index] = wideSlot
              slots[index + 1] = continuationSlot
              index += 2
            } else {
              narrowSlot.scalar = scalars[position].value
              slots[index] = narrowSlot
              index += 1
            }
            position += 1
          }
          storage.payloads[index] = TerminalRowPayload(text: texts.text(in: cluster.slot), link: link, linkID: linkID)
          if cluster.wide {
            slots[index] = wideClusterSlot
            slots[index + 1] = continuationSlot
            index += 2
          } else {
            slots[index] = narrowClusterSlot
            index += 1
          }
          position = clusterStart + cluster.count
        }
        let scalarCount = scalars.count
        while position < scalarCount {
          if widths[position] == 2 {
            wideSlot.scalar = scalars[position].value
            slots[index] = wideSlot
            slots[index + 1] = continuationSlot
            index += 2
          } else {
            narrowSlot.scalar = scalars[position].value
            slots[index] = narrowSlot
            index += 1
          }
          position += 1
        }
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
      + UInt64(storage.payloads.capacity) * 96 + UInt64(storage.payloads.count) * 64
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
            UInt64(payload?.link?.utf8.count ?? 0) + UInt64(payload?.linkID?.utf8.count ?? 0), payload != nil, payload?.link != nil)
  }
  /// Enumerate sparse metadata without projecting ordinary scalar cells.
  func forEachLinkID(_ body: (Int, String) -> Void) {
    for entry in storage.payloads.entries {
      if let id = entry.payload.linkID { body(entry.column, id) }
    }
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

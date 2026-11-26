import Foundation

struct PromptAnchor: Equatable {
  var row: UInt64
  var column: Int
  var pendingWrap: Bool
}
/// What DECSC keeps besides the position, which reflow has to remap.
struct SavedRendition: Equatable {
  var origin = false
  var style = TerminalStyle()
  var link: String?
  var linkID: String?
  var protected = false
  var charsetSpecial = [false, false]
  var charsetSlot = 0
}
struct TerminalScreen: Equatable {
  enum PromptPhase { case none, drawing, inputReady }
  var rows: [TerminalRow]; var cursorRow = 0; var cursorColumn = 0; var pendingWrap = false
  var savedRow = 0; var savedColumn = 0; var savedPendingWrap = false
  var savedRendition = SavedRendition()
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
    var linkID: String? = nil
    var protected: Bool
    // ISO SPA/EPA protects against ordinary erasure; DEC DECSCA protects
    // against selective erasure. They are independent protocols.
    var isoProtected = false
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
    var partialScrollCount = 0
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
    // Scratch for the precomputed cell widths (1 or 2) of scalars in the run being admitted.
    var runWidths: [UInt8] = []
    /// Whether text is laid out by code point width (mode 2027 reset).
    var legacy = false

    mutating func reset() {
      segmenter = TerminalText.Segmenter(legacy: legacy)
      openCluster = nil
      retainedScalars = 0
      capped = false
    }
  }
  /// The attributes of a cluster's lead cell, as an extension needs them.
  struct ClusterLead {
    var style: TerminalStyle
    var link: String?
    var linkID: String? = nil
    var flags: UInt8
    var protected: Bool
    var wide: Bool
  }
  /// A multi-scalar cluster inside a run handed to `replaceClusters`:
  /// `count` scalars from buffer position `start`, whose text is in cluster
  /// cache slot `slot`.
  struct PrintedCluster {
    var start: Int
    var count: Int
    var slot: Int
    var wide: Bool
  }
  /// Multi-scalar clusters printed recently, with what assembling one scalar
  /// at a time would have to derive again: the text, and whether each prefix is
  /// one or two cells wide. Terminal output repeats the same few emoji, flags
  /// and accented letters, so a small direct-mapped table answers nearly all.
  struct ClusterCache {
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
      let count = scalars.count
      var hash: UInt32 = 2_166_136_261
      for index in 0..<count { hash = (hash ^ scalars[index].value) &* 16_777_619 }
      let slot = Int((hash ^ hash >> 16) & 255)
      let base = slot &* Self.maximumScalars
      if !keys.isEmpty {
        if Int(counts[slot]) == count {
          let matches = keys.withUnsafeBufferPointer { keys in
            var index = 0
            while index < count, keys[base &+ index] == scalars[index] { index &+= 1 }
            return index == count
          }
          if matches {
            if pinning && runs[slot] != run { runs[slot] = run }
            return slot
          }
        }
      } else {
        keys = Array(repeating: "\0", count: Self.slotCount * Self.maximumScalars)
        counts = Array(repeating: 0, count: Self.slotCount)
        texts = Array(repeating: "", count: Self.slotCount)
        widePrefixes = Array(repeating: 0, count: Self.slotCount)
        runs = Array(repeating: 0, count: Self.slotCount)
      }
      if pinning && runs[slot] == run { return nil }
      var wide: UInt32 = 0
      for prefixCount in 1...count
      where TerminalWidth.width(of: UnsafeBufferPointer(rebasing: scalars[..<prefixCount])) >= 2 {
        wide |= 1 << UInt32(prefixCount)
      }
      keys.withUnsafeMutableBufferPointer { keys in
        for index in 0..<count { keys[base &+ index] = scalars[index] }
      }
      counts[slot] = UInt8(count)
      texts[slot] = TerminalText.string(from: scalars)
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
  /// Chooses between grapheme clusters and code point widths for the text
  /// printed from now on. Cells already written stay as they are.
  mutating func setGraphemeClustering(_ enabled: Bool) {
    printState.legacy = !enabled
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
      } else if screen.cursorRow != screen.topMargin {
        screen.cursorRow = max(0, screen.cursorRow - 1)
      }
    } else if screen.cursorRow == screen.bottomMargin && inside {
      return scrollForIndex(&screen, columns: columns, blankCellCapacity: blankCellCapacity, recycleDiscarded: recycleDiscarded, top: screen.topMargin, bottom: screen.bottomMargin,
                            left: horizontal.0, right: horizontal.1, up: true, eraseStyle: eraseStyle,
                            history: &history, nextRowID: &nextRowID)
    } else if screen.cursorRow != screen.bottomMargin {
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
    var partialScrollCount = 0
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
    var consumed = 0, appended = 0, partialScrolls = 0
    while consumed < bytes.count, appended == 0 {
      // Printable ASCII starts a cluster unless it follows a Prepend scalar.
      // That case, insert mode and an invalid cursor stay with the scalar
      // transaction; everything else is a fresh run of width-one cells.
      guard state.segmenter.printableASCIIStartsCluster, !insertMode,
            screen.rows.indices.contains(screen.cursorRow),
            (0..<columns).contains(screen.cursorColumn) else { break }
      state.segmenter.pushPrintableASCII()
      if screen.pendingWrap && autoWrap {
        if (horizontal.0 != 0 || horizontal.1 != columns - 1), screen.cursorRow == screen.bottomMargin,
          (horizontal.0...horizontal.1).contains(screen.cursorColumn) { partialScrolls += 1 }
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
                                  at: column, style: attributes.style, link: attributes.link, linkID: attributes.linkID,
                                  protected: attributes.protected, isoProtected: attributes.isoProtected)
      state.openCluster = (row, column + count - 1)
      state.retainedScalars = 1
      state.capped = false
      screen.cursorColumn = min(right, column + count)
      screen.pendingWrap = column + count > right && autoWrap
      consumed += count
    }
    return ASCIIPrintResult(consumedCount: consumed, appendedHistoryCount: appended, partialScrollCount: partialScrolls)
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
        let maxRunScalars = min(limit - consumed, max(0, capacity) * ClusterCache.maximumScalars)
        if state.runWidths.count < maxRunScalars {
          state.runWidths.append(contentsOf: repeatElement(0, count: maxRunScalars - state.runWidths.count))
        }
        state.runWidths.withUnsafeMutableBufferPointer { runWidths in
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
                runWidths[end - consumed] = UInt8(width)
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
                guard lead >= 0, !segmenter.legacy else { break }
                var clusterEnd = end + 1
                while clusterEnd < limit {
                  let followingScalar = scalars[clusterEnd]
                  if followingScalar.value &- 0x20 < 0x5f, next.printableASCIIStartsCluster {
                    break
                  }
                  var following = next
                  let admitted = admit(followingScalar, to: &following)
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
            runWidths[end - consumed] = UInt8(width)
            lead = end
            cells += width
            lastWidth = width
            end += 1
          }
        }
        if end > consumed {
          if wraps {
            if (horizontal.0 != 0 || horizontal.1 != columns - 1), screen.cursorRow == screen.bottomMargin,
              (horizontal.0...horizontal.1).contains(screen.cursorColumn) { effect.partialScrollCount += 1 }
            effect.appendedHistoryCount += wrapCursor(
              in: &screen, columns: columns, blankCellCapacity: blankCellCapacity, horizontal: horizontal,
              style: attributes.style, history: &history, nextRowID: &nextRowID, retainHistory: retainHistory)
          }
          let row = screen.cursorRow, count = end - consumed
          state.runWidths.withUnsafeBufferPointer { widths in
            screen.rows[row].replaceClusters(
              at: column, scalars: UnsafeBufferPointer(rebasing: scalars[consumed..<end]),
              widths: UnsafeBufferPointer(rebasing: widths[0..<count]),
              clusters: state.runClusters, texts: state.clusters, cellCount: cells,
              style: attributes.style, link: attributes.link, linkID: attributes.linkID, protected: attributes.protected,
              isoProtected: attributes.isoProtected)
          }
          state.segmenter = segmenter
          state.openCluster = (row, column + cells - lastWidth)
          state.capped = false
          if let last = state.runClusters.last, last.start + last.count == count {
            state.retainedScalars = last.count
            effect.lastPrinted = .cluster(state.clusters.text(in: last.slot))
            // An extended cluster repeats with its lead cell's attributes,
            // which here are the caller's, stated outright as extension does.
            effect.repeatAttributes = PrintAttributes(style: attributes.style, link: attributes.link, linkID: attributes.linkID,
                                                      protected: attributes.protected, isoProtected: attributes.isoProtected)
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
          let followingScalar = scalars[end]
          if followingScalar.value &- 0x20 < 0x5f, segmenter.printableASCIIStartsCluster {
            break
          }
          var next = segmenter
          let following = admit(followingScalar, to: &next)
          guard !following.skipped, !following.startsCluster else { break }
          segmenter = next
          end += 1
        }
        if !state.legacy, extendCluster(at: owner, with: UnsafeBufferPointer(rebasing: scalars[(consumed - 1)..<end]),
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
                                             link: lead.link, linkID: lead.linkID, flags: nextFlags, protected: lead.protected)
        formed = true
      }
      wide = nextWide
      flags = nextFlags
    }
    screen.rows[owner.row].setClusterText(text, link: lead.link, linkID: lead.linkID, at: owner.column)
    state.retainedScalars += added.count
    screen.cursorRow = owner.row
    screen.cursorColumn = min(right, owner.column + occupied)
    screen.pendingWrap = owner.column + occupied > right && autoWrap
    effect.lastPrinted = .cluster(text)
    effect.repeatAttributes = PrintAttributes(style: lead.style, link: lead.link, linkID: lead.linkID, protected: lead.protected, isoProtected: lead.flags & 8 != 0)
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
      if (horizontal.0 != 0 || horizontal.1 != columns - 1), screen.cursorRow == screen.bottomMargin,
        (horizontal.0...horizontal.1).contains(screen.cursorColumn) { effect.partialScrollCount += 1 }
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
      let oldWidth = cell.kind == 2 ? 2 : 1
      // By code point width, a joining scalar has no width to add.
      let nominal = state.legacy ? oldWidth : min(2, max(1, TerminalText.cellWidth(of: combined)))
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
                                style: cell.style, link: cell.link, linkID: cell.linkID,
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
                                style: cell.style, link: cell.link, linkID: cell.linkID,
                                flags: cell.flags | (nominal > occupied ? 1 : 0),
                                protected: cell.protected)
        Self.replacePrintedLead(in: &screen.rows[owner.row], at: owner.column, with: lead)
        screen.cursorRow = owner.row; screen.cursorColumn = min(right, owner.column + occupied); screen.pendingWrap = owner.column + occupied > right && autoWrap
      }
      effect.lastPrinted = .cluster(combined)
      effect.repeatAttributes = PrintAttributes(style: cell.style, link: cell.link, linkID: cell.linkID, protected: cell.protected, isoProtected: cell.flags & 8 != 0)
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
    let flags: UInt8 = (attributes.protected ? 2 : 0) | (truncated ? 1 : 0) | (attributes.isoProtected ? 8 : 0)
    Self.replacePrintedScalar(in: &screen.rows[row], at: column, scalar: scalar, kind: kind,
                              style: attributes.style, link: attributes.link, linkID: attributes.linkID, flags: flags,
                              protected: attributes.protected)
    state.openCluster = (row, column); state.retainedScalars = 1
    effect.lastPrinted = .scalar(scalar)
    effect.repeatAttributes = PrintAttributes(style: attributes.style, link: attributes.link, linkID: attributes.linkID,
                                              protected: attributes.protected, isoProtected: attributes.isoProtected)
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
                                link: lead.link, linkID: lead.linkID, flags: lead.flags & ~UInt8(1),
                                protected: lead.protected), at: column + 1)
    }
    row.revision &+= 1
  }

  private static func replacePrintedScalar(in row: inout TerminalRow, at column: Int,
                                           scalar: Unicode.Scalar, kind: UInt8, style: TerminalStyle,
                                           link: String?, linkID: String? = nil, flags: UInt8, protected: Bool) {
    guard column >= 0, column < row.count else { return }
    let width = kind == 2 ? 2 : 1
    guard column + width <= row.count else { return }
    guard preparePrintedReplacement(in: &row, at: column, count: width, eraseStyle: style.erased()) else { return }
    row.setScalar(scalar, at: column, kind: kind, style: style, link: link, linkID: linkID, flags: flags,
                  protected: protected)
    if width == 2 {
      row.setCell(TerminalCell(text: "", kind: 3, style: style, link: link, linkID: linkID,
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
  mutating func erase(_ screen: inout TerminalScreen, row: Int, columns range: Range<Int>, style: TerminalStyle,
                      selective: Bool = false, respectISOProtection: Bool = false) {
    guard screen.rows.indices.contains(row) else { return }
    let lower = max(0, range.lowerBound), upper = min(columns, range.upperBound); guard lower < upper else { return }
    var erasedAll = lower == 0 && upper == columns
    for column in lower..<upper {
      if selective && screen.rows[row].isProtected(at: column) { erasedAll = false; continue }
      if respectISOProtection && screen.rows[row].isISOProtected(at: column) { erasedAll = false; continue }
      screen.rows[row].erase(at: column, style: style)
    }
    if erasedAll { screen.rows[row].softWrapped = false }
    repairWidePairs(&screen.rows[row], eraseStyle: style); screen.rows[row].revision &+= 1
  }
  /// Rectangle edits retain destination row identities. Snapshot the source
  /// before writing so overlapping copies have memmove semantics, and repair
  /// wide characters cut by either edge of the rectangle.
  mutating func copyRectangle(_ screen: inout TerminalScreen, top: Int, left: Int,
                             bottom: Int, right: Int, destinationTop: Int,
                             destinationLeft: Int, lastRow: Int, lastColumn: Int,
                             eraseStyle: TerminalStyle) {
    let source = screen.rows
    let height = min(bottom - top + 1, lastRow - destinationTop + 1)
    let width = min(right - left + 1, lastColumn - destinationLeft + 1)
    guard height > 0, width > 0 else { return }
    for offset in 0..<height {
      let row = destinationTop + offset
      // Detach an existing glyph crossing either destination boundary. A
      // copied continuation must not pair with an unrelated old lead.
      if destinationLeft > 0, screen.rows[row].kind(at: destinationLeft) == 3 {
        screen.rows[row].erase(at: destinationLeft - 1, style: eraseStyle)
      }
      let destinationRight = destinationLeft + width - 1
      if destinationRight + 1 < columns, screen.rows[row].kind(at: destinationRight) == 2 {
        screen.rows[row].erase(at: destinationRight + 1, style: eraseStyle)
      }
      for column in 0..<width {
        let cell = source[top + offset].cell(left + column)
        if (column == 0 && cell.kind == 3) || (column == width - 1 && cell.kind == 2) {
          screen.rows[row].erase(at: destinationLeft + column, style: eraseStyle)
        } else {
          screen.rows[row].setCell(cell, at: destinationLeft + column)
        }
      }
      repairWidePairs(&screen.rows[row], eraseStyle: eraseStyle)
      screen.rows[row].revision &+= 1
    }
  }
  mutating func fillRectangle(_ screen: inout TerminalScreen, top: Int, left: Int,
                             bottom: Int, right: Int, scalar: Unicode.Scalar,
                             style: TerminalStyle) {
    for row in top...bottom {
      for column in left...right {
        screen.rows[row].setScalar(scalar, at: column, kind: 1, style: style,
                                   link: nil, flags: 0, protected: false)
      }
      repairWidePairs(&screen.rows[row], eraseStyle: style.erased())
      screen.rows[row].revision &+= 1
    }
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

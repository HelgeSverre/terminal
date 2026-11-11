import Foundation

// Owns terminal emulation and the stable C compatibility boundary.  The public C-shaped surface is
// deliberately thin: the state machine owns parsing, grid mutation, history,
// snapshots, and input encoding so neither Session nor the renderer needs to
// duplicate terminal policy.


private func decSpecialGraphics(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
  let mapping: [UInt32: UInt32] = [
    0x5f: 0x00a0, 0x60: 0x25c6, 0x61: 0x2592, 0x62: 0x2409, 0x63: 0x240c, 0x64: 0x240d, 0x65: 0x240a,
    0x66: 0x00b0, 0x67: 0x00b1, 0x68: 0x2424, 0x69: 0x240b, 0x6a: 0x2518, 0x6b: 0x2510, 0x6c: 0x250c, 0x6d: 0x2514,
    0x6e: 0x253c, 0x6f: 0x23ba, 0x70: 0x23bb, 0x71: 0x2500, 0x72: 0x23bc, 0x73: 0x23bd, 0x74: 0x251c, 0x75: 0x2524,
    0x76: 0x2534, 0x77: 0x252c, 0x78: 0x2502, 0x79: 0x2264, 0x7a: 0x2265, 0x7b: 0x03c0, 0x7c: 0x2260, 0x7d: 0x00a3, 0x7e: 0x00b7,
  ]
  return mapping[scalar.value].flatMap(Unicode.Scalar.init) ?? scalar
}

private enum VTParserState { case ground, escape, charset(Int), escapeIntermediate(UInt8), csi, osc, osc52(OSC52Decoder, escaped: Bool), apc, discardString(escaped: Bool, osc: Bool) }

private final class TerminalSearchToken {
  // The task contains only immutable page snapshots while it is with the
  // worker. The core is consulted exclusively by fill/accept on its owner.
  var task: TerminalSearchTask
  init(_ task: TerminalSearchTask) { self.task = task }
}

#if SNAPSHOT_ABI_DIAGNOSTICS
// Test-build counters distinguish the direct value path from both C oracles.
// No counter or per-cell instrumentation is compiled into the application.
enum SnapshotABIDiagnostics {
  static var borrowedStringAllocations = 0
  static var jsonPublications = 0
}
#endif

// Owns byte storage for a synchronous ABI snapshot callback.  The callback
// promise is deliberately narrow: clients copy before return, so storage can
// be released immediately afterwards.
private final class BorrowedSnapshotCells {
  var text: [UnsafeMutablePointer<UInt8>] = []
  var links: [UnsafeMutablePointer<UInt8>] = []
  deinit { text.forEach { $0.deallocate() }; links.forEach { $0.deallocate() } }
  func copy(_ string: String, into target: inout [UnsafeMutablePointer<UInt8>]) -> UnsafePointer<UInt8>? {
    #if SNAPSHOT_ABI_DIAGNOSTICS
    SnapshotABIDiagnostics.borrowedStringAllocations += 1
    #endif
    let bytes = Array(string.utf8)
    // A non-nil zero-length link means OSC 8 explicitly supplied an empty
    // URI; nil means no link. Preserve that distinction over the ABI.
    let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, bytes.count))
    for (offset, byte) in bytes.enumerated() { pointer.advanced(by: offset).initialize(to: byte) }
    if bytes.isEmpty { pointer.initialize(to: 0) }
    target.append(pointer)
    return UnsafePointer(pointer)
  }
}

private final class TerminalEmulator {
  private enum DisplayClearAction: UInt32 {
    case ignoredAlternate = 0, cleared = 1, redrawPrompt = 2
  }
  private(set) var columns: Int
  private(set) var rowCount: Int
  private var document: TerminalDocument
  private let selection = TerminalSelection()
  private var selectionDocumentGeneration = UUID()
  private var selectionSnapshotID: UInt64 = 0
  private var pendingSelectionRevision: UInt64?
  private struct PendingPresentedContent {
    var revision: UInt64
    let historyEpoch: UInt64
    let validator: TerminalPresentedContentValidator
  }
  private var pendingPresentedContent: PendingPresentedContent?
  private struct PendingResize {
    let geometry: TerminalResizeGeometry
    var revision: UInt64
    var transaction: DocumentReflowTransaction
    var relievingPressure = false
  }
  private var pendingResize: PendingResize?
  private var primary: TerminalScreen { get { document.primary } set { document.primary = newValue } }
  private var alternate: TerminalScreen { get { document.alternate } set { document.alternate = newValue } }
  private var usingAlternate = false
  private var history: TerminalHistory { document.history }
  private var historyLimit = 50_000
  private var historyByteLimit = 64 * 1024 * 1024
  private var viewOffset = 0
  // Nil means follow-tail. A retained row identity keeps a viewport stable as
  // output appends history and is remapped during document reflow.
  private var viewAnchor: UInt64?
  private var viewportClampRevision: UInt64 = 1
  private var viewportWasClamped = false
  // Modes describe protocol policy. Geometry itself belongs to each document
  // screen, because primary and alternate retain independent margins.
  private var originMode = false
  private var leftRightMargins = false
  private var autoWrap = true
  private var insertMode = false
  private var newlineMode = false
  private var syncDeadline: UInt64?
  private var clock: UInt64 = 0
  private var parser = VTParserState.ground
  private var utf8 = TerminalText.UTF8Decoder()
  private var sequence = ""
  // Style, link and protection of the next printed cell. They live in one
  // value so a print transaction borrows them instead of assembling a copy.
  private var attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
  private var pen: TerminalStyle {
    get { attributes.style }
    set { captureRepeatAttributes(); attributes.style = newValue }
  }
  private var currentLink: String? {
    get { attributes.link }
    set { captureRepeatAttributes(); attributes.link = newValue }
  }
  private var protectedOutput: Bool {
    get { attributes.protected }
    set { captureRepeatAttributes(); attributes.protected = newValue }
  }
  private var replies = Data()
  private var nextClipboardRequestID: UInt64 = 1
  private var clipboardRequests: [(UInt64, Data)] = []
  private var pendingClipboardRequests = Set<UInt64>()
  private var palette = TerminalPalette()
  private var title = ""
  private var currentDirectory: String?
  private var applicationCursor = false
  private var applicationKeypad = false
  private var bracketedPaste = false
  private var focusReporting = false
  private var reverseVideo = false
  private var mouseMode = 0
  private var sgrMouse = false
  private var tabs: [Bool]
  private var tabsCleared = false
  private var revision: UInt64 = 1
  private var geometryEpoch: UInt64 = 1
  // TerminalDocument deliberately restarts row IDs after a hard reset. Keep a
  // monotonic identity generation so a pending search cannot mistake a fresh
  // post-RIS row for an old (id, revision) pair.
  private var searchGeneration: UInt64 = 1
  private var documentEpoch: UInt64 = 1
  private var historyEpoch: UInt64 = 1
  private var screenEpoch: UInt64 = 1
  // Accepted matches stay in document identity space. Each keeps the row
  // revision that was proven at accept time, so a later change to an
  // unrelated row does not discard a valid decoration while a changed row can
  // never inherit one. Snapshot publication resolves these proofs against its
  // selected rows, so a non-view snapshot never paints a viewport-relative
  // coordinate onto unrelated live output.
  private struct SearchHits {
    let stamp: TerminalSearchStamp
    /// Document order, oldest first. Anchors are refreshed when navigation
    /// finds that history eviction moved a match.
    var matches: [TerminalSearchMatch]
    var current: Int
    let capped: Bool
    /// Row identity to the (match, span) pairs drawn on that row, so
    /// publication costs the visible rows and not the retained match count.
    let byRow: [UInt64: [(match: Int, span: Int)]]
  }
  private var searchHits: SearchHits?
  private let graphics = KittyGraphicsStore()
  private var cellPixelWidth = 8
  private var cellPixelHeight = 16
  private var lastPrinted: TerminalDocument.PrintedText?
  // REP prints with the attributes of the last printed cluster. Those are
  // nearly always the current `attributes`, so they are copied only when the
  // current ones are about to change (or when a cluster kept its own).
  private var lastPrintedAttributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
  private var repeatUsesCurrentAttributes = false
  private func captureRepeatAttributes() {
    guard repeatUsesCurrentAttributes else { return }
    lastPrintedAttributes = attributes
    repeatUsesCurrentAttributes = false
  }
  private func forgetLastPrinted() {
    lastPrinted = nil
    lastPrintedAttributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
    repeatUsesCurrentAttributes = false
    repeatRemaining = 0
  }
  private var repeatRemaining = 0
  private var charsetSpecial = [false, false]
  private var charsetSlot = 0
  // Decoded text waiting to be printed: the first `decodedScalarCount`
  // elements of a buffer that keeps its full size, so that decoding writes
  // into it directly. Those before `decodedScalarStart` are already printed.
  private var decodedScalars = [Unicode.Scalar](repeating: "\0", count: 2 * decodedFlushCount)
  private var decodedScalarCount = 0
  private var decodedScalarStart = 0
  /// Pending decoded scalars are printed once this many have gathered.
  private static let decodedFlushCount = 1024
  // A shorter ASCII run that follows undrained decoded text joins that text,
  // so mixed-script output reaches the document as one transaction.
  private static let minimumDirectASCIIRun = 16
  // CSI input itself is capped at 16 KiB, so this reusable numeric scratch is
  // bounded by the parser's existing sequence limit.
  private var csiParameterScratch: [Int] = []
  private var csiBytes: [UInt8] = []
  // Preserve the old scalar-backed String limit: bytes >= 0x80 took two UTF-8 bytes.
  private var csiUTF8Count = 0

  init(columns: Int, rows: Int) {
    self.columns = max(1, min(4096, columns))
    self.rowCount = max(1, min(4096, rows))
    document = TerminalDocument(columns: self.columns, rows: self.rowCount)
    tabs = (0..<self.columns).map { $0 > 0 && $0.isMultiple(of: 8) }
    csiParameterScratch.reserveCapacity(16)
    csiBytes.reserveCapacity(64)
  }

  private var screen: TerminalScreen {
    get { usingAlternate ? alternate : primary }
    set { if usingAlternate { alternate = newValue } else { primary = newValue } }
  }
  private var horizontalMargins: (left: Int, right: Int) {
    let s = screen
    return leftRightMargins ? (s.leftMargin, s.rightMargin) : (0, columns - 1)
  }
  private var verticalMargins: (top: Int, bottom: Int) {
    let s = screen
    return (s.topMargin, s.bottomMargin)
  }
  private func writeBounds(_ column: Int) -> (left: Int, right: Int) {
    let margins = horizontalMargins
    return column <= margins.right ? margins : (0, columns - 1)
  }
  private func eraseStyle() -> TerminalStyle { pen.erased() }
  private func changed(history: Bool = false, geometry: Bool = false,
                       document: Bool = true, screen: Bool = true) {
    revision &+= 1
    // Geometry changes alter column coordinates. Ordinary document edits are
    // instead resolved lazily against each accepted row's revision, retaining
    // hits through unrelated output.
    if geometry { searchHits = nil }
    if document { documentEpoch &+= 1 }
    if screen { screenEpoch &+= 1 }
    if history { historyEpoch &+= 1 }
    if geometry { geometryEpoch &+= 1 }
  }
  private func advanceSearchGeneration() {
    searchGeneration &+= 1
    searchHits = nil
  }
  private func finishDecodedText() {
    if utf8.isIdle && decodedScalarCount == 0 { return }
    // Escape/control input interrupts an incomplete UTF-8 sequence. Emit its
    // maximal invalid prefix now so that the control byte is still parsed.
    flushDecodedScalars()
    emitDecoded(utf8.finish())
    flushDecodedScalars()
  }
  @inline(__always)
  private func emitDecoded(_ emission: TerminalText.UTF8Decoder.Emission) {
    switch emission {
    case .none: break
    case .one(let scalar): appendDecoded(charsetSpecial[charsetSlot] ? decSpecialGraphics(scalar) : scalar)
    case .two(let first, let second):
      appendDecoded(charsetSpecial[charsetSlot] ? decSpecialGraphics(first) : first)
      appendDecoded(charsetSpecial[charsetSlot] ? decSpecialGraphics(second) : second)
    }
  }
  private func appendDecoded(_ scalar: Unicode.Scalar) {
    if decodedScalarCount == decodedScalars.count { growDecodedScalars() }
    decodedScalars[decodedScalarCount] = scalar
    decodedScalarCount += 1
    if decodedScalarCount - decodedScalarStart == Self.decodedFlushCount { flushDecodedScalars() }
  }
  /// Makes room when a flush left text pending in a full buffer.
  private func growDecodedScalars() {
    decodedScalars.append(contentsOf: repeatElement("\0", count: decodedScalars.count))
  }
  private func flushDecodedScalars() {
    if decodedScalarCount == 0 { return }
    while decodedScalarStart < decodedScalarCount {
      let batch = decodedScalars.withUnsafeBufferPointer { scalars in
        document.print(UnsafeBufferPointer(rebasing: scalars[decodedScalarStart..<decodedScalarCount]),
                       usingAlternate: usingAlternate, leftRightMargins: leftRightMargins,
                       autoWrap: autoWrap, insertMode: insertMode, attributes: attributes)
      }
      guard batch.consumedScalarCount > 0 else { return }
      decodedScalarStart += batch.consumedScalarCount
      apply(batch.effect, mutations: batch.mutationCount)
    }
    decodedScalarCount = 0
    decodedScalarStart = 0
  }
  /// Decodes consecutive well-formed multi-byte scalars that lie wholly inside
  /// the buffer, and returns the bytes consumed. It stops — possibly at once —
  /// before anything the streaming decoder must judge: controls, a malformed
  /// sequence, or a scalar cut off by the end of the buffer. With
  /// `joiningASCII`, a run of printable ASCII too short to print directly is
  /// taken along, as `printASCIIRun` would add it to pending text; the run
  /// then stops before a longer one.
  private func decodeUTF8Run(_ bytes: UnsafePointer<UInt8>, offset: Int, limit: Int, joiningASCII: Bool) -> Int {
    @inline(__always) func continuation(_ byte: UInt8) -> Bool { byte & 0xc0 == 0x80 }
    /// The scalar encoded at `index` and its length, or nil where the run ends.
    @inline(__always) func scalar(at index: Int) -> (value: UInt32, length: Int)? {
      let lead = bytes[index]
      if lead < 0xc2 {
        return nil
      } else if lead < 0xe0 {
        guard index + 1 < limit, continuation(bytes[index + 1]) else { return nil }
        return (UInt32(lead & 0x1f) << 6 | UInt32(bytes[index + 1] & 0x3f), 2)
      } else if lead < 0xf0 {
        guard index + 2 < limit else { return nil }
        let second = bytes[index + 1], third = bytes[index + 2]
        // E0 excludes overlong forms; ED excludes surrogates.
        guard continuation(second), continuation(third),
              lead != 0xe0 || second >= 0xa0, lead != 0xed || second <= 0x9f else { return nil }
        return (UInt32(lead & 0x0f) << 12 | UInt32(second & 0x3f) << 6 | UInt32(third & 0x3f), 3)
      } else if lead <= 0xf4 {
        guard index + 3 < limit else { return nil }
        let second = bytes[index + 1], third = bytes[index + 2], fourth = bytes[index + 3]
        // F0 excludes overlong forms; F4 excludes values above U+10FFFF.
        guard continuation(second), continuation(third), continuation(fourth),
              lead != 0xf0 || second >= 0x90, lead != 0xf4 || second <= 0x8f else { return nil }
        return (UInt32(lead & 0x07) << 18 | UInt32(second & 0x3f) << 12
                  | UInt32(third & 0x3f) << 6 | UInt32(fourth & 0x3f), 4)
      }
      return nil
    }
    var index = offset
    var ended = false
    // Bytes left of a short ASCII run that has begun to join pending text.
    var asciiRemaining = 0
    while !ended {
      if decodedScalarCount == decodedScalars.count { growDecodedScalars() }
      // Each pass stops where pending text reaches the flush threshold, so
      // the document sees the same batches whatever the run's length.
      let pending = decodedScalarCount - decodedScalarStart
      let start = decodedScalarCount
      var end = start
      decodedScalars.withUnsafeMutableBufferPointer { buffer in
        let stop = pending < Self.decodedFlushCount
          ? min(buffer.count, start + Self.decodedFlushCount - pending) : buffer.count
        while end < stop {
          guard index < limit else { ended = true; break }
          if joiningASCII, bytes[index] &- 0x20 < 0x5f {
            if asciiRemaining == 0 {
              // Like `printASCIIRun`: only a short run joins, and only text
              // that is still pending.
              var runEnd = index + 1
              while runEnd < limit, runEnd - index < Self.minimumDirectASCIIRun, bytes[runEnd] &- 0x20 < 0x5f {
                runEnd += 1
              }
              guard runEnd - index < Self.minimumDirectASCIIRun, end > decodedScalarStart else {
                ended = true
                break
              }
              asciiRemaining = runEnd - index
            }
            // A run that crosses the flush threshold continues after the flush.
            let taken = min(asciiRemaining, stop - end)
            for _ in 0..<taken {
              buffer[end] = Unicode.Scalar(bytes[index])
              end += 1
              index += 1
            }
            asciiRemaining -= taken
            continue
          }
          guard let next = scalar(at: index) else { ended = true; break }
          // The guards above admit exactly the well-formed encodings of a scalar.
          buffer[end] = Unicode.Scalar(next.value).unsafelyUnwrapped
          end += 1
          index += next.length
        }
      }
      decodedScalarCount = end
      if end - decodedScalarStart == Self.decodedFlushCount { flushDecodedScalars() }
    }
    return index - offset
  }
  /// Prints the run of printable ASCII that starts at `offset` and returns its
  /// length. The document borrows the feed buffer only for the transaction and
  /// stores scalar values; history effects are applied at every document yield.
  /// The caller has established ground state, an idle UTF-8 decoder and the
  /// ASCII character set.
  private func printASCIIRun(_ bytes: UnsafePointer<UInt8>, offset: Int, limit: Int) -> Int {
    var end = offset + 1
    while end < limit, bytes[end] &- 0x20 < 0x5f { end += 1 }
    let count = end - offset
    if count < Self.minimumDirectASCIIRun, decodedScalarStart < decodedScalarCount {
      for index in offset..<end { appendDecoded(Unicode.Scalar(bytes[index])) }
      return count
    }
    flushDecodedScalars()
    var consumed = 0
    while consumed < count {
      let result = document.printASCII(
        UnsafeBufferPointer(start: bytes + offset + consumed, count: count - consumed),
        usingAlternate: usingAlternate, leftRightMargins: leftRightMargins, autoWrap: autoWrap,
        insertMode: insertMode, attributes: attributes)
      guard result.consumedCount > 0 else {
        // The scalar transaction owns this byte (insert mode, an open Prepend cluster).
        put(Unicode.Scalar(bytes[offset + consumed]))
        consumed += 1
        continue
      }
      consumed += result.consumedCount
      lastPrinted = .scalar(Unicode.Scalar(bytes[offset + consumed - 1]))
      repeatUsesCurrentAttributes = true
      applyAppendedHistory(result.appendedHistoryCount)
      let mutations = UInt64(result.consumedCount)
      revision &+= mutations; documentEpoch &+= mutations; screenEpoch &+= mutations
    }
    return count
  }
  private func apply(_ effect: TerminalDocument.PrintEffect, mutations: Int = 1) {
    guard mutations > 0 else { return }
    applyAppendedHistory(effect.appendedHistoryCount)
    if let printed = effect.lastPrinted {
      lastPrinted = printed
      if let kept = effect.repeatAttributes {
        lastPrintedAttributes = kept
        repeatUsesCurrentAttributes = false
      } else {
        repeatUsesCurrentAttributes = true
      }
    }
    revision &+= UInt64(mutations); documentEpoch &+= UInt64(mutations); screenEpoch &+= UInt64(mutations)
  }
  private func applyAppendedHistory(_ count: Int) {
    guard count > 0 else { return }
    if viewAnchor != nil { viewOffset += count }
    enforceHistoryLimits()
    historyEpoch &+= 1
  }
  private func resetClusterBoundary() { document.resetPrintCluster() }
  private func tick(_ now: UInt64) {
    clock = now
    graphics.tick(now: now)
    if let deadline = syncDeadline, now >= deadline {
      syncDeadline = nil
      let previousRevision = revision
      changed()
      // The watchdog publishes the same committed document. Keep a clean
      // resize generation current without concealing any earlier mutation.
      if pendingResize?.revision == previousRevision { pendingResize?.revision = revision }
      if pendingSelectionRevision == previousRevision { pendingSelectionRevision = revision }
      if pendingPresentedContent?.revision == previousRevision { pendingPresentedContent?.revision = revision }
    }
  }
  private func repeatLastPrinted() {
    let saved = attributes
    if !repeatUsesCurrentAttributes { attributes = lastPrintedAttributes }
    resetClusterBoundary()
    switch lastPrinted {
    case .scalar(let scalar): put(scalar)
    case .cluster(let text): for scalar in text.unicodeScalars { put(scalar) }
    case nil: break
    }
    resetClusterBoundary()
    captureRepeatAttributes()
    attributes = saved
  }
  func feed(_ bytes: UnsafePointer<UInt8>?, count: Int, now: UInt64) -> Int {
    tick(now)
    // REP is intentionally resumable. It keeps the owner responsive and lets
    // an admitted input event observe modes established *after* the repeat.
    if repeatRemaining > 0, lastPrinted == nil {
      // REP after RIS (or before any printable scalar) is a no-op. Clear it
      // and continue processing this same ABI turn's suffix.
      repeatRemaining = 0
    }
    if repeatRemaining > 0 {
      let budget = min(4_096, repeatRemaining)
      for _ in 0..<budget { repeatLastPrinted() }
      repeatRemaining -= budget
      return 0
    }
    guard let bytes, count > 0 else { return 0 }
    let limit = min(count, 65_536)
    var offset = 0
    while offset < limit {
      // Finish the command that produced a reply, then stop before admitting
      // another byte. The owner drains replies before replaying this suffix.
      if replies.count >= 32_768 { flushDecodedScalars(); return offset }
      let byte = bytes[offset]
      // Ground state is decided before the general switch: matching the other
      // states copies their payloads, which ordinary text never needs.
      if case .ground = parser {
        if byte &- 0x20 < 0x5f, utf8.isIdle, !charsetSpecial[charsetSlot] {
          offset += printASCIIRun(bytes, offset: offset, limit: limit)
          continue
        }
        switch byte {
        case 0x1b:
          finishDecodedText()
          if let length = applyCompleteSGR(bytes, offset: offset, limit: limit) {
            offset += length
            continue
          }
          parser = .escape
        case 0x00...0x07: finishDecodedText(); if byte == 0x07 { /* bell belongs to host */ }
        case 0x08: finishDecodedText(); backspace()
        case 0x09: finishDecodedText(); tab()
        case 0x0a, 0x0b, 0x0c: finishDecodedText(); lineFeed()
        case 0x0d: finishDecodedText(); carriageReturn()
        case 0x0e: finishDecodedText(); charsetSlot = 1
        case 0x0f: finishDecodedText(); charsetSlot = 0
        default:
          if byte >= 0xc2, utf8.isIdle {
            let decoded = decodeUTF8Run(bytes, offset: offset, limit: limit,
                                        joiningASCII: !charsetSpecial[charsetSlot])
            if decoded > 0 {
              offset += decoded
              continue
            }
          }
          emitDecoded(utf8.push(byte))
        }
        offset += 1
        continue
      }
      switch parser {
      case .ground: preconditionFailure("Ground state is handled above")
      case .escape:
        handleEscapedByte(byte)
      case .charset(let slot):
        parser = .ground
        if byte == 0x30 { charsetSpecial[slot] = true }
        else if byte == 0x42 { charsetSpecial[slot] = false }
      case .escapeIntermediate(let intermediate):
        if (0x30...0x7e).contains(byte) {
          parser = .ground
          if intermediate == 0x23 && byte == 0x38 { screenAlignment() }
        } else if byte == 0x18 || byte == 0x1a { parser = .ground }
        else if byte == 0x1b { parser = .escape }
        else if byte < 0x20 { executeControl(byte) }
      case .csi:
        // Parameter bytes cannot produce replies or REP work. Admit their
        // contiguous run once, preserving the scalar-backed UTF-8 budget.
        let start = offset
        var budget = csiUTF8Count
        while offset < limit {
          let next = bytes[offset]
          if (0x40...0x7e).contains(next) || next < 0x20 || budget >= 16_384 { break }
          budget += next < 0x80 ? 1 : 2
          offset += 1
        }
        if offset > start {
          csiBytes.append(contentsOf: UnsafeBufferPointer(start: bytes + start, count: offset - start))
          csiUTF8Count = budget
        }
        if offset == limit { continue }
        let final = bytes[offset]
        if (0x40...0x7e).contains(final) {
          handleCSI(csiBytes, final: final); parser = .ground
          if repeatRemaining > 0 { return offset + 1 }
        } else if final < 0x20 {
          // CAN and SUB cancel the sequence, ESC starts a new one, and any
          // other C0 control executes without ending it.
          if final == 0x18 || final == 0x1a || final == 0x1b {
            csiBytes.removeAll(keepingCapacity: true); csiUTF8Count = 0
            parser = final == 0x1b ? .escape : .ground
          } else { executeControl(final) }
        } else {
          // A final is accepted even at the limit; only a further parameter
          // byte overflows, and that byte is consumed without interpretation.
          parser = .ground; csiBytes.removeAll(keepingCapacity: true); csiUTF8Count = 0
        }
      case .osc:
        if byte == 0x18 || byte == 0x1a { sequence = ""; parser = .ground }
        else if byte == 0x07 { finishString(); parser = .ground }
        // String Terminator is the two-byte ESC \\ sequence. Keep parser
        // ownership in the string state until the following byte decides it;
        // switching to generic Escape would lose APC/OSC context.
        else if byte == 0x1b, sequence.utf8.count < 65_536 { sequence.append("\u{1b}") }
        else if byte == 0x1b { parser = .discardString(escaped: true, osc: true); sequence = "" }
        else if sequence.last == "\u{1b}" && byte == 0x5c { sequence.removeLast(); finishString(); parser = .ground }
        else if sequence.utf8.count < 65_536 {
          sequence.unicodeScalars.append(UnicodeScalar(byte))
          if sequence == "52;c;" {
            parser = .osc52(OSC52Decoder(acceptingWrites: pendingClipboardRequests.count < 4), escaped: false)
            sequence = ""
          }
        }
        else { parser = .discardString(escaped: false, osc: true); sequence = "" }
      case .osc52(let decoder, let escaped):
        if byte == 0x18 || byte == 0x1a { parser = .ground }
        else if byte == 0x07 || (escaped && byte == 0x5c) {
          switch decoder.finish() {
          case .write(let data): enqueueClipboard(data)
          case .query: replies.append(Data("\u{1b}]52;c;\u{1b}\\".utf8))
          case .reject: break
          }
          parser = .ground
        } else if byte == 0x1b { parser = .osc52(decoder, escaped: true) }
        else if escaped {
          // An ESC that is not ST abandons OSC 52. The following byte is the
          // first byte of a fresh escape sequence, matching the streaming
          // parser rather than treating it as encoded payload.
          parser = .escape
          handleEscapedByte(byte)
        }
        else {
          _ = decoder.push(byte)
          parser = .osc52(decoder, escaped: false)
        }
      case .apc:
        if byte == 0x18 || byte == 0x1a { graphics.abort(); sequence = ""; parser = .ground }
        else if sequence.last == "\u{1b}" && byte == 0x5c { sequence.removeLast(); finishString(); parser = .ground }
        else if byte == 0x1b { if sequence.last != "\u{1b}" { sequence.append("\u{1b}") } }
        else if sequence.last == "\u{1b}" || sequence.utf8.count >= 8192 {
          graphics.abort(); parser = .discardString(escaped: false, osc: false); sequence = ""
        }
        else if sequence.isEmpty && byte != 0x47 { parser = .discardString(escaped: false, osc: false) }
        else if byte >= 0x20 && byte != 0x7f { sequence.unicodeScalars.append(UnicodeScalar(byte)) }
      case .discardString(let escaped, let osc):
        if byte == 0x18 || byte == 0x1a { parser = .ground }
        else if osc && byte == 0x07 { parser = .ground }
        else if escaped && byte == 0x5c { parser = .ground }
        else { parser = .discardString(escaped: byte == 0x1b, osc: osc) }
      }
      offset += 1
    }
    flushDecodedScalars()
    return limit
  }
  /// Applies `ESC [ digits-and-semicolons m` when the whole sequence is in the
  /// buffer, and returns its length. Anything else — other finals, private
  /// markers, colons, a split or oversized sequence — returns nil with nothing
  /// consumed, so the streaming parser handles it exactly as before.
  private func applyCompleteSGR(_ bytes: UnsafePointer<UInt8>, offset: Int, limit: Int) -> Int? {
    let maximumValues = 32
    guard offset + 2 < limit, bytes[offset + 1] == 0x5b else { return nil }
    return withUnsafeTemporaryAllocation(of: Int.self, capacity: maximumValues) { values -> Int? in
      var count = 0
      // Nine digits cannot overflow; a longer field goes to the streaming
      // parser, which owns the exact UInt32 overflow rule.
      var value = 0, digits = 0
      var index = offset + 2
      let end = min(limit, offset + 96)
      while index < end {
        let byte = bytes[index]
        let digit = Int(byte &- 0x30)
        if digit < 10 {
          guard digits < 9 else { return nil }
          value = value * 10 + digit
          digits += 1
        } else if byte == 0x3b || byte == 0x6d {
          guard count < maximumValues else { return nil }
          values[count] = value
          count += 1
          value = 0
          digits = 0
          if byte == 0x6d {
            applySGR(UnsafeBufferPointer(rebasing: values[..<count]))
            changed()
            return index + 1 - offset
          }
        } else {
          return nil
        }
        index += 1
      }
      return nil
    }
  }
  private func handleEscapedByte(_ byte: UInt8) {
    parser = .ground
    switch byte {
    case 0x5b: csiBytes.removeAll(keepingCapacity: true); csiUTF8Count = 0; parser = .csi
    case 0x5d: sequence = ""; parser = .osc
    case 0x5f: sequence = ""; parser = .apc
    // DCS, SOS and PM carry strings this terminal does not interpret. They
    // are consumed up to ST so their bodies never reach the screen.
    case 0x50, 0x58, 0x5e: parser = .discardString(escaped: false, osc: false)
    case 0x28: parser = .charset(0)
    case 0x29: parser = .charset(1)
    // Other intermediates (`ESC #`, `ESC *`, `ESC %`, `ESC SP` …) take a
    // final byte; only DECALN among them is implemented.
    case 0x20...0x2f: parser = .escapeIntermediate(byte)
    case 0x37: saveCursor()
    case 0x38: restoreCursor()
    case 0x48: tabs[screen.cursorColumn] = true
    // IND advances within the scroll region but, unlike LF/VT/FF, never
    // applies LNM's carriage return.
    case 0x44: resetClusterBoundary(); index(reverse: false)
    case 0x4d: reverseIndex()
    case 0x45: carriageReturn(); lineFeed()
    case 0x63: reset()
    case 0x3d: applicationKeypad = true
    case 0x3e: applicationKeypad = false
    case 0x1b: parser = .escape
    default: break
    }
  }
  /// A C0 control received inside an escape sequence.
  private func executeControl(_ byte: UInt8) {
    switch byte {
    case 0x08: backspace()
    case 0x09: tab()
    case 0x0a, 0x0b, 0x0c: lineFeed()
    case 0x0d: carriageReturn()
    case 0x0e: charsetSlot = 1
    case 0x0f: charsetSlot = 0
    default: break
    }
  }
  /// DECALN: fill the screen with `E` in the default rendition, reset the
  /// scroll region and home the cursor.
  private func screenAlignment() {
    resetClusterBoundary()
    var s = screen
    s.rows = (0..<rowCount).map { _ in document.eraseRow(TerminalStyle()) }
    s.topMargin = 0; s.bottomMargin = rowCount - 1
    screen = s
    let kept = attributes
    attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
    for row in 0..<rowCount {
      var line = screen; line.cursorRow = row; line.cursorColumn = 0; line.pendingWrap = false; screen = line
      for _ in 0..<columns {
        if let effect = document.print(
          "E", usingAlternate: usingAlternate, leftRightMargins: false, autoWrap: false,
          insertMode: false, attributes: attributes) { apply(effect) }
      }
    }
    attributes = kept
    var home = screen; home.cursorRow = 0; home.cursorColumn = 0; home.pendingWrap = false; screen = home
    forgetLastPrinted()
    changed()
  }
  private func put(_ scalar: Unicode.Scalar) {
    guard let effect = document.print(
      scalar, usingAlternate: usingAlternate,
      leftRightMargins: leftRightMargins, autoWrap: autoWrap, insertMode: insertMode,
      attributes: attributes) else { return }
    apply(effect)
  }

  private func index(reverse: Bool) {
    let appendedCount = document.index(usingAlternate: usingAlternate, reverse: reverse,
                              leftRightMargins: leftRightMargins, eraseStyle: eraseStyle())
    applyAppendedHistory(appendedCount)
    changed(history: !reverse && !usingAlternate)
  }
  private func lineFeed() {
    resetClusterBoundary()
    index(reverse: false)
    if newlineMode { carriageReturn() }
  }
  private func carriageReturn() { document.carriageReturn(usingAlternate: usingAlternate, leftRightMargins: leftRightMargins); changed() }
  private func backspace() { resetClusterBoundary(); var s = screen; let left = horizontalMargins.left; s.cursorColumn = max(s.cursorColumn >= left ? left : 0, s.cursorColumn - 1); s.pendingWrap = false; screen = s; changed() }
  private func tab(_ reverse: Bool = false, count: Int = 1) {
    resetClusterBoundary()
    var s = screen; let margins = horizontalMargins
    let left = s.cursorColumn >= margins.left ? margins.left : 0
    let right = writeBounds(s.cursorColumn).right
    for _ in 0..<min(count, columns) {
      if reverse {
        guard s.cursorColumn > left else { s.cursorColumn = left; continue }
        s.cursorColumn = stride(from: s.cursorColumn - 1, through: left, by: -1)
          .first(where: { tabs[$0] }) ?? left
      } else {
        guard s.cursorColumn < right else { s.cursorColumn = right; continue }
        s.cursorColumn = ((s.cursorColumn + 1)...right)
          .first(where: { tabs[$0] }) ?? right
      }
    }
    s.pendingWrap = false; screen = s; changed()
  }
  private func reverseIndex() { index(reverse: true) }
  private func saveCursor() { var s = screen; s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedPendingWrap = s.pendingWrap; s.savedOrigin = originMode; s.savedStyle = pen; s.savedLink = currentLink; screen = s }
  private func restoreCursor() { var s = screen; originMode = s.savedOrigin; pen = s.savedStyle; currentLink = s.savedLink; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = s.savedPendingWrap; screen = s; changed() }
  private func reset() {
    selectionDocumentGeneration = UUID(); selection.reset(); pendingSelectionRevision = nil
    graphics.clear()
    document = TerminalDocument(columns: columns, rows: rowCount)
    advanceSearchGeneration()
    usingAlternate = false; viewAnchor = nil; viewOffset = 0
    pen = TerminalStyle(); originMode = false; leftRightMargins = false; autoWrap = true
    insertMode = false; newlineMode = false; protectedOutput = false; syncDeadline = nil
    applicationCursor = false; applicationKeypad = false; bracketedPaste = false
    focusReporting = false; reverseVideo = false; mouseMode = 0; sgrMouse = false
    currentLink = nil
    palette.reset()
    charsetSpecial = [false, false]; charsetSlot = 0
    forgetLastPrinted()
    tabs = (0..<columns).map { $0 > 0 && $0.isMultiple(of: 8) }
    tabsCleared = false
    resetClusterBoundary()
    changed(history: true)
  }
  private struct CSIParameterPacket {
    var values: [Int]
    // CSI > ... u and CSI = ... u historically parsed their first field
    // before any generic filtering.  Keep that protocol-specific value
    // alongside the ordinary flattened fields.
    var keyboardFlags: UInt32?
    var hasColon: Bool
  }
  // CSI parameter syntax is ASCII. Scan it once rather than repeatedly
  // traversing Character collections and allocating filtered strings. The
  // accumulator deliberately preserves the legacy grammar: non-semicolon
  // syntax bytes are ignored between digits, while each semicolon creates an
  // empty/defaulted field when needed. Every value consumed by a non-SGR
  // command is bounded to UInt32, matching the wire protocol.
  private static func parseCSIParameters<Bytes: Collection>(_ bytes: Bytes, final: UInt8,
                                         into parameters: inout [Int]) -> CSIParameterPacket? where Bytes.Element == UInt8 {
    // The streaming CSI parser stores one input byte per scalar. A non-ASCII
    // scalar cannot be terminal parameter syntax; reject it instead of
    // silently turning a numeric-looking malformed byte into default zero.
    parameters.removeAll(keepingCapacity: true)
    var rawRun: UInt32 = 0
    var rawHasDigits = false
    var filtered: UInt32 = 0
    var filteredHasDigits = false
    let hasColon = bytes.contains(0x3a)
    let preservingColonSGR = final == 0x6d && hasColon
    let keyboardPrefix = final == 0x75 && (bytes.first == 0x3e || bytes.first == 0x3d)
    let preservesRawSyntax = preservingColonSGR || keyboardPrefix
    var keyboardValue: UInt32 = 0
    var keyboardHasDigits = false
    var keyboardNegative = false
    var keyboardSawSign = false
    var keyboardValid = keyboardPrefix
    var keyboardFinished = !keyboardPrefix
    for (index, byte) in bytes.enumerated() {
      guard byte < 0x80 else { return nil }
      if (0x30...0x39).contains(byte) {
        let digit = UInt32(byte - 0x30)
        if rawHasDigits {
          guard rawRun <= (UInt32.max - digit) / 10 else { return nil }
          rawRun = rawRun * 10 + digit
        } else {
          rawRun = digit
          rawHasDigits = true
        }
        if !preservesRawSyntax {
          guard filtered <= (UInt32.max - digit) / 10 else { return nil }
          filtered = filtered * 10 + digit
          filteredHasDigits = true
        }
      } else {
        rawRun = 0
        rawHasDigits = false
        if !preservesRawSyntax, byte == 0x3b {
          parameters.append(filteredHasDigits ? Int(filtered) : 0)
          filtered = 0
          filteredHasDigits = false
        }
      }
      if keyboardPrefix && !keyboardFinished {
        if index == 0 { continue }
        if byte == 0x3b {
          keyboardFinished = true
        } else if (0x30...0x39).contains(byte), keyboardValid {
          let digit = UInt32(byte - 0x30)
          guard keyboardValue <= (UInt32.max - digit) / 10 else { keyboardValid = false; continue }
          keyboardValue = keyboardValue * 10 + digit
          keyboardHasDigits = true
        } else if (byte == 0x2b || byte == 0x2d), !keyboardSawSign && !keyboardHasDigits && keyboardValue == 0, keyboardValid {
          keyboardNegative = byte == 0x2d
          keyboardSawSign = true
        } else {
          keyboardValid = false
        }
      }
    }
    if !preservesRawSyntax { parameters.append(filteredHasDigits ? Int(filtered) : 0) }
    let keyboardFlags: UInt32? = keyboardPrefix
      ? (keyboardValid && keyboardHasDigits && !keyboardNegative ? keyboardValue : 0)
      : nil
    return CSIParameterPacket(values: parameters, keyboardFlags: keyboardFlags, hasColon: hasColon)
  }
  /// Whether the command with this final byte, and the private marker and
  /// intermediate byte found in `raw`, is one `handleCSI` carries out.
  static func implementsCSI(final: UInt8, raw: [UInt8]) -> Bool {
    let marker = raw.first.flatMap { (0x3c...0x3f).contains($0) ? $0 : nil }
    let intermediates = raw.filter { (0x20...0x2f).contains($0) }
    // A marker anywhere but first, or more than one intermediate, is no
    // command this terminal knows.
    guard !raw.dropFirst().contains(where: { (0x3c...0x3f).contains($0) }), intermediates.count <= 1 else { return false }
    switch (marker, intermediates.first) {
    case (nil, nil): return true
    // DECSED and DECSEL, DEC private modes, DSR, the keyboard-flags query.
    case (0x3f, nil): return [0x4a, 0x4b, 0x68, 0x6c, 0x6e, 0x75].contains(final)
    // Keyboard flags (set, push, pop); secondary device attributes.
    case (0x3d, nil), (0x3c, nil): return final == 0x75
    case (0x3e, nil): return final == 0x75 || final == 0x63
    // DECSTR, DECSCA, DECSCUSR, DECRQM for an ANSI or a private mode.
    case (nil, 0x21), (nil, 0x24): return final == 0x70
    case (nil, 0x22), (nil, 0x20): return final == 0x71
    case (0x3f, 0x24): return final == 0x70
    default: return false
    }
  }
  private func handleCSI(_ raw: [UInt8], final: UInt8) {
    switch final {
    case 0x6d, 0x6e, 0x63, 0x75: break
    default: resetClusterBoundary()
    }
    // A private marker or an intermediate byte makes a different command of
    // the same final byte. `CSI > 4 ; 2 m` enables xterm's modifyOtherKeys; it
    // is not SGR 4;2. `CSI ? 1 ; 1 ; 0 S` asks about graphics; it does not
    // scroll. Combinations this terminal does not implement are ignored.
    guard Self.implementsCSI(final: final, raw: raw) else { return }
    guard let packet = Self.parseCSIParameters(raw, final: final, into: &csiParameterScratch) else { return }
    // SGR changes the pen only. Preserve the usual semantic revision without
    // copying and writing back an unchanged screen or clearing pending wrap.
    if final == 0x6d {
      applySGR(packet.values, colonSyntax: packet.hasColon ? String(decoding: raw, as: UTF8.self) : nil)
      changed()
      return
    }
    let params = packet.values
    let first = raw.first
    let last = raw.last
    let privateMode = first == 0x3f
    let n = max(1, params.first ?? 0)
    var s = screen
    var changedActiveScreen = false
    var semanticChange = true
    var clearsPending = true
    switch final {
    case 0x41: moveCursorVertically(&s, up: true, count: n)
    case 0x42: moveCursorVertically(&s, up: false, count: n)
    case 0x43: s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, s.cursorColumn + n)
    case 0x44: s.cursorColumn = max(originMode ? horizontalMargins.left : 0, s.cursorColumn - n)
    case 0x45:
      moveCursorVertically(&s, up: false, count: n)
      let left = horizontalMargins.left
      s.cursorColumn = s.cursorColumn >= left ? left : 0
    case 0x46:
      moveCursorVertically(&s, up: true, count: n)
      let left = horizontalMargins.left
      s.cursorColumn = s.cursorColumn >= left ? left : 0
    case 0x47: s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + n - 1)
    case 0x64: s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, (originMode ? s.topMargin : 0) + n - 1)
    case 0x48, 0x66: s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, (originMode ? s.topMargin : 0) + max(0, (params.first ?? 1) - 1)); s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + max(0, (params.dropFirst().first ?? 1) - 1))
    case 0x4a: eraseDisplay(params.first ?? 0, selective: privateMode); changedActiveScreen = true
    case 0x4b: eraseLine(params.first ?? 0); changedActiveScreen = true
    case 0x40: insertCharacters(n); changedActiveScreen = true
    case 0x50: deleteCharacters(n); changedActiveScreen = true
    case 0x58: eraseCharacters(n); changedActiveScreen = true
    case 0x4c: insertLines(n); changedActiveScreen = true
    case 0x4d: deleteLines(n); changedActiveScreen = true
    case 0x49: tab(false, count: n); changedActiveScreen = true
    case 0x5a: tab(true, count: n); changedActiveScreen = true
    case 0x67:
      if params.first == 3 { tabs = Array(repeating: false, count: columns); tabsCleared = true }
      else if params.first ?? 0 == 0 { tabs[s.cursorColumn] = false }
    case 0x72: setVerticalMargins(params); changedActiveScreen = true
    case 0x53: resetClusterBoundary(); scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: true, allowHistory: true)
    case 0x54: resetClusterBoundary(); scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: false, allowHistory: false)
    case 0x62:
      repeatRemaining = lastPrinted == nil ? 0 : min(1_000_000, max(0, params.first ?? 1))
      clearsPending = false
    case 0x73:
      if leftRightMargins { setHorizontalMargins(params); changedActiveScreen = true }
      else { s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedOrigin = originMode }
    case 0x75:
      clearsPending = false
      if first == 0x3e {
        if s.keyboardStack.count == 32 { s.keyboardStack.removeFirst() }
        s.keyboardStack.append(s.keyboardFlags); s.keyboardFlags = (packet.keyboardFlags ?? 0) & 31
      }
      else if first == 0x3f { replies.append(contentsOf: "\u{1b}[?\(s.keyboardFlags)u".utf8) }
      else if first == 0x3c { for _ in 0..<min(32, n) { s.keyboardFlags = s.keyboardStack.popLast() ?? 0 } }
      else if first == 0x3d {
        let flags = (packet.keyboardFlags ?? 0) & 31
        let action = String(decoding: raw, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).dropFirst().first.flatMap { Int($0) } ?? 1
        if action == 1 { s.keyboardFlags = flags }
        else if action == 2 { s.keyboardFlags |= flags }
        else if action == 3 { s.keyboardFlags &= ~flags }
      }
      else { originMode = s.savedOrigin; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = false }
    case 0x6e: clearsPending = false; if params.first == 5 { replies.append(contentsOf: "\u{1b}[0n".utf8) } else if params.first == 6 { let row = s.cursorRow + 1 - (originMode ? s.topMargin : 0); let column = s.cursorColumn + 1 - (originMode ? horizontalMargins.left : 0); replies.append(contentsOf: "\u{1b}[\(privateMode ? "?" : "")\(row);\(column)R".utf8) }
    // Secondary device attributes: a VT220-class terminal, firmware version
    // 10, no ROM cartridge. Primary attributes otherwise.
    case 0x63 where first == 0x3e: clearsPending = false; replies.append(contentsOf: "\u{1b}[>1;10;0c".utf8)
    // VT220 with ANSI color. Sixel (4) is not implemented, so it is not
    // advertised: programs that trust DA1 would send it.
    case 0x63: clearsPending = false; replies.append(contentsOf: "\u{1b}[?62;22c".utf8)
    case 0x70 where last == 0x24:
      clearsPending = false
      let mode = params.first ?? 0
      replies.append(contentsOf: "\u{1b}[\(privateMode ? "?" : "")\(mode);\(modeReport(mode, privateMode: privateMode))$y".utf8)
    case 0x70 where last == 0x21: softReset(); changedActiveScreen = true
    case 0x71 where last == 0x22: protectedOutput = (params.first ?? 0) == 1; clearsPending = false
    case 0x71 where last == 0x20: s.cursorShape = UInt8(min(6, max(0, params.first ?? 0))); clearsPending = false
    case 0x71: clearsPending = false; semanticChange = false
    case 0x68, 0x6c:
      if privateMode, params.allSatisfy({ [47, 1047, 1049].contains($0) }), params.allSatisfy({ _ in usingAlternate == (final == 0x68) }) { semanticChange = false }
      changedActiveScreen = setMode(params, enabled: final == 0x68, privateMode: privateMode)
    default: break
    }
    // DEC alternate-screen modes swap the screen object.  Keeping the swap
    // inside mode ownership prevents this generic CSI epilogue from writing a
    // stale primary copy back into the newly active alternate buffer.
    if !changedActiveScreen { if clearsPending { s.pendingWrap = false }; screen = s }
    // Scroll commits its replacement screen before eviction resolves anchors.
    if final == 0x53 { enforceHistoryLimits() }
    if graphics.hasPlacements {
      switch final {
      case 0x4a, 0x4c, 0x4d, 0x53, 0x54, 0x68, 0x6c: pruneGraphicsAnchors()
      default: break
      }
    }
    if semanticChange { changed() }
  }
  // Moving up stops at the top margin unless already above it; moving down
  // stops at the bottom margin unless already below it. Otherwise use the
  // corresponding screen edge, independently of origin mode.
  // Keeping this policy here prevents redraw commands from drifting apart.
  private func moveCursorVertically(_ screen: inout TerminalScreen, up: Bool, count: Int) {
    if up {
      let limit = screen.cursorRow < screen.topMargin ? 0 : screen.topMargin
      screen.cursorRow -= min(count, screen.cursorRow - limit)
    } else {
      let limit = screen.cursorRow > screen.bottomMargin ? rowCount - 1 : screen.bottomMargin
      screen.cursorRow += min(count, limit - screen.cursorRow)
    }
  }
  private func eraseDisplay(_ mode: Int, selective: Bool = false) { if mode == 2 { graphics.clear(alternate: usingAlternate) }; var s = screen; switch mode { case 2, 3: if selective { for row in 0..<rowCount { document.erase(&s, row: row, columns: 0..<columns, style: eraseStyle(), selective: true) } } else { s.rows = (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) } }; if mode == 3 && !usingAlternate { document.clearHistory(); advanceSearchGeneration(); historyEpoch &+= 1 }; case 1: for row in 0...s.cursorRow { document.erase(&s, row: row, columns: 0..<(row == s.cursorRow ? s.cursorColumn + 1 : columns), style: eraseStyle(), selective: selective) }; default: for row in s.cursorRow..<rowCount { document.erase(&s, row: row, columns: (row == s.cursorRow ? s.cursorColumn : 0)..<columns, style: eraseStyle(), selective: selective) } }; s.pendingWrap = false; screen = s }
  private func eraseLine(_ mode: Int) { var s = screen; let range: Range<Int>; switch mode { case 1: range = 0..<(s.cursorColumn + 1); case 2: range = 0..<columns; default: range = s.cursorColumn..<columns }; document.erase(&s, row: s.cursorRow, columns: range, style: eraseStyle()); s.pendingWrap = false; screen = s }
  private func eraseCharacters(_ count: Int) {
    var s = screen
    let end = s.cursorColumn + min(count, columns - s.cursorColumn)
    document.erase(&s, row: s.cursorRow, columns: s.cursorColumn..<end, style: eraseStyle())
    s.pendingWrap = false
    screen = s
  }
  private func insertCharacters(_ count: Int) {
    var s = screen; let margins = horizontalMargins
    if (margins.left...margins.right).contains(s.cursorColumn) { document.shift(&s, row: s.cursorRow, column: s.cursorColumn, right: margins.right, count: count, inserting: true, eraseStyle: eraseStyle()); s.pendingWrap = false }
    else { s.pendingWrap = false }; screen = s
  }
  private func deleteCharacters(_ count: Int) {
    var s = screen; let margins = horizontalMargins
    if (margins.left...margins.right).contains(s.cursorColumn) { document.shift(&s, row: s.cursorRow, column: s.cursorColumn, right: margins.right, count: count, inserting: false, eraseStyle: eraseStyle()); s.pendingWrap = false }; screen = s
  }
  private func insertLines(_ count: Int) { scrollLines(count, up: false) }
  private func deleteLines(_ count: Int) { scrollLines(count, up: true) }
  private func setVerticalMargins(_ params: [Int]) {
    let top = max(0, (params.first ?? 1) - 1)
    let bottom = min(rowCount - 1, ((params.dropFirst().first ?? rowCount) == 0 ? rowCount : (params.dropFirst().first ?? rowCount)) - 1)
    guard top < bottom else { return }
    var s = screen; s.topMargin = top; s.bottomMargin = bottom; s.cursorRow = originMode ? top : 0; s.cursorColumn = originMode ? horizontalMargins.left : 0; s.pendingWrap = false; screen = s
  }
  private func scrollLines(_ count: Int, up: Bool) {
    var s = screen; let margins = horizontalMargins
    guard s.cursorRow >= s.topMargin, s.cursorRow <= s.bottomMargin, (margins.left...margins.right).contains(s.cursorColumn) else { s.pendingWrap = false; screen = s; return }
    scroll(&s, top: s.cursorRow, bottom: s.bottomMargin, count: count, up: up, allowHistory: false); s.cursorColumn = margins.left; s.pendingWrap = false; screen = s
  }
  private func scroll(_ s: inout TerminalScreen, top: Int, bottom: Int, count: Int, up: Bool, allowHistory: Bool) {
    let margins = horizontalMargins; let amount = min(count, bottom - top + 1); guard amount > 0 else { return }
    if margins.left != 0 || margins.right != columns - 1 {
      document.scrollRectangle(&s, top: top, bottom: bottom, left: margins.left, right: margins.right, count: amount, up: up, eraseStyle: eraseStyle()); return
    }
    for _ in 0..<amount {
      let removed: TerminalRow
      if up { removed = s.rows.remove(at: top); s.rows.insert(document.eraseRow(eraseStyle()), at: bottom) }
      else { removed = s.rows.remove(at: bottom); s.rows.insert(document.eraseRow(eraseStyle()), at: top) }
      if up && allowHistory && !usingAlternate && top == 0 && bottom == rowCount - 1 {
        document.history.append(removed)
        if viewAnchor != nil { viewOffset += 1 }
        historyEpoch &+= 1
      }
    }
  }
  private func setHorizontalMargins(_ params: [Int]) {
    let left = max(0, (params.first ?? 1) - 1); let suppliedRight = params.dropFirst().first ?? columns
    let requestedRight = suppliedRight == 0 ? columns : suppliedRight
    guard requestedRight <= columns else { return }
    let right = requestedRight - 1
    guard left < right else { return }
    var s = screen; s.leftMargin = left; s.rightMargin = right
    s.cursorRow = originMode ? s.topMargin : 0; s.cursorColumn = originMode ? left : 0; s.pendingWrap = false; screen = s
  }
  private func applySGR(_ p: [Int], colonSyntax raw: String? = nil) {
    // Colon-form SGR parameters cannot pass through the general CSI integer
    // parser: removing ':' turns `4:3` into 43. Handle each colon group at
    // the SGR boundary, while delegating ordinary semicolon groups to the
    // established parser so mixed sequences retain their ordering.
    if let raw {
      let groups = raw.split(separator: ";", omittingEmptySubsequences: false)
      var group = 0
      while group < groups.count {
        let value = groups[group]
        guard value.utf8.contains(0x3a) else {
          guard let code = value.isEmpty ? 0 : Int(value) else { group += 1; continue }
          // Keep extended semicolon colors together; handling them as single
          // values would lose the RGB/index operands beside a colon group.
          if [38, 48, 58].contains(code), group + 1 < groups.count,
            let mode = Int(groups[group + 1])
          {
            let count = mode == 2 ? 5 : mode == 5 ? 3 : 1
            if group + count <= groups.count {
              var nestedParameters: [Int] = []
              if let packet = Self.parseCSIParameters(groups[group..<(group + count)].joined(separator: ";").utf8, final: 0x6d, into: &nestedParameters) {
                applySGR(packet.values, colonSyntax: nil)
              }
              group += count
              continue
            }
          }
          applySGR([code], colonSyntax: nil)
          group += 1
          continue
        }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard let code = fields.first.flatMap({ Int($0) }) else { group += 1; continue }
        if code == 4, let subtype = fields.dropFirst().first.flatMap({ Int($0) }), (0...5).contains(subtype) {
          pen.underlineKind = UInt8(subtype)
          group += 1
          continue
        }
        guard [38, 48, 58].contains(code), fields.count >= 3,
          let mode = Int(fields[1])
        else { group += 1; continue }
        switch mode {
        case 5:
          guard let index = fields.dropFirst(2).first.flatMap({ Int($0) }),
                (0...255).contains(index) else { group += 1; continue }
          let color = 0x0100_0000 | UInt32(index)
          if code == 38 { pen.foreground = color }
          else if code == 48 { pen.background = color }
          else { pen.underline = color }
        case 2:
          // An optional color-space field precedes exactly three channels.
          // Missing/invalid channels leave the existing color unchanged.
          let start = fields.count >= 6 ? 3 : 2
          guard fields.count >= start + 3 else { group += 1; continue }
          let rgb = fields[start..<(start + 3)].compactMap { Int($0) }
          guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else { group += 1; continue }
          let color = 0x0200_0000 | UInt32(rgb[0] << 16) | UInt32(rgb[1] << 8) | UInt32(rgb[2])
          if code == 38 { pen.foreground = color }
          else if code == 48 { pen.background = color }
          else { pen.underline = color }
        default: group += 1; continue
        }
        group += 1
      }
      return
    }
    (p.isEmpty ? [0] : p).withUnsafeBufferPointer { applySGR($0) }
  }
  /// Applies ordinary (semicolon-separated) SGR values in order.
  private func applySGR(_ values: UnsafeBufferPointer<Int>) {
    var style = pen
    defer { pen = style }
    var i = 0
    while i < values.count {
      let code = values[i]
      switch code {
      case 0: style = TerminalStyle()
      case 1: style.flags |= 1
      case 2: style.flags |= 2
      case 3: style.flags |= 4
      case 4: style.underlineKind = 1
      case 5, 6: style.flags |= 128
      case 7: style.flags |= 8
      case 8: style.flags |= 16
      case 9: style.flags |= 32
      case 53: style.flags |= 64
      case 21: style.underlineKind = 2
      case 22: style.flags &= ~UInt16(3)
      case 23: style.flags &= ~UInt16(4)
      case 24: style.underlineKind = 0
      case 27: style.flags &= ~UInt16(8)
      case 28: style.flags &= ~UInt16(16)
      case 25: style.flags &= ~UInt16(128)
      case 29: style.flags &= ~UInt16(32)
      case 55: style.flags &= ~UInt16(64)
      case 30...37: style.foreground = 0x0100_0000 | UInt32(code - 30)
      case 39: style.foreground = 0
      case 40...47: style.background = 0x0100_0000 | UInt32(code - 40)
      case 49: style.background = 0
      case 90...97: style.foreground = 0x0100_0000 | UInt32(code - 90 + 8)
      case 100...107: style.background = 0x0100_0000 | UInt32(code - 100 + 8)
      case 38, 48, 58:
        if i + 2 < values.count && values[i + 1] == 5 {
          if (0...255).contains(values[i + 2]) {
            let color = 0x0100_0000 | UInt32(values[i + 2])
            if code == 38 { style.foreground = color } else if code == 48 { style.background = color } else { style.underline = color }
          }
          i += 2
        } else if i + 4 < values.count && values[i + 1] == 2 {
          if values[(i + 2)...(i + 4)].allSatisfy({ (0...255).contains($0) }) {
            let color = 0x0200_0000 | (UInt32(values[i + 2]) << 16)
              | (UInt32(values[i + 3]) << 8) | UInt32(values[i + 4])
            if code == 38 { style.foreground = color } else if code == 48 { style.background = color } else { style.underline = color }
          }
          i += 4
        }
      case 59: style.underline = 0
      default: break
      }
      i += 1
    }
  }
  /// DECRQM status: 1 set, 2 reset, 0 for a mode `setMode` does not implement.
  private func modeReport(_ mode: Int, privateMode: Bool) -> Int {
    let enabled: Bool
    if !privateMode {
      switch mode {
      case 4: enabled = insertMode
      case 20: enabled = newlineMode
      default: return 0
      }
    } else {
      switch mode {
      case 1: enabled = applicationCursor
      case 5: enabled = reverseVideo
      case 6: enabled = originMode
      case 7: enabled = autoWrap
      case 25: enabled = screen.cursorVisible
      case 47, 1047, 1049: enabled = usingAlternate
      case 69: enabled = leftRightMargins
      case 9, 1000, 1002, 1003: enabled = mouseMode == mode
      case 1004: enabled = focusReporting
      case 1006: enabled = sgrMouse
      case 2004: enabled = bracketedPaste
      case 2026: enabled = syncDeadline != nil
      default: return 0
      }
    }
    return enabled ? 1 : 2
  }
  private func setMode(_ params: [Int], enabled: Bool, privateMode: Bool) -> Bool {
    var changedActiveScreen = false
    if !privateMode {
      for mode in params {
        if mode == 4 { insertMode = enabled }
        if mode == 20 { newlineMode = enabled }
      }
      return false
    }
    for mode in params where privateMode {
      switch mode {
      case 1: applicationCursor = enabled
      case 6: originMode = enabled; var s = screen; s.cursorRow = enabled ? s.topMargin : 0; s.cursorColumn = enabled ? horizontalMargins.left : 0; s.pendingWrap = false; screen = s; changedActiveScreen = true
      case 7: autoWrap = enabled; if !enabled { var s = screen; s.pendingWrap = false; screen = s }; changedActiveScreen = true
      case 25:
        var s = screen; s.cursorVisible = enabled; screen = s
        changedActiveScreen = true
      case 47, 1047, 1049:
        if usingAlternate != enabled {
          resetClusterBoundary()
          advanceSearchGeneration()
          usingAlternate = enabled
          if enabled && (mode == 1047 || mode == 1049) {
            let keyboardFlags = alternate.keyboardFlags
            let keyboardStack = alternate.keyboardStack
            let cursorVisible = alternate.cursorVisible
            let cursorShape = alternate.cursorShape
            alternate = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns)
            alternate.keyboardFlags = keyboardFlags; alternate.keyboardStack = keyboardStack
            alternate.cursorVisible = cursorVisible; alternate.cursorShape = cursorShape
          }
          changedActiveScreen = true
        }
      case 1004: focusReporting = enabled
      case 9, 1000, 1002, 1003: mouseMode = enabled ? mode : 0
      case 1006: sgrMouse = enabled
      case 2004: bracketedPaste = enabled
      case 5: reverseVideo = enabled
      case 69:
        leftRightMargins = enabled
        if !enabled { primary.leftMargin = 0; primary.rightMargin = columns - 1; primary.pendingWrap = false; alternate.leftMargin = 0; alternate.rightMargin = columns - 1; alternate.pendingWrap = false; originMode = false }
        changedActiveScreen = true
      case 2026:
        if enabled { if syncDeadline == nil { syncDeadline = clock &+ 150 } }
        else { syncDeadline = nil }
      default: break
      }
    }
    return changedActiveScreen
  }
  private func softReset() {
    originMode = false; leftRightMargins = false; autoWrap = true; insertMode = false
    newlineMode = false; protectedOutput = false
    pen = TerminalStyle(); currentLink = nil; applicationCursor = false; applicationKeypad = false
    bracketedPaste = false; focusReporting = false; reverseVideo = false; mouseMode = 0; sgrMouse = false; syncDeadline = nil
    forgetLastPrinted()
    var s = screen
    s.topMargin = 0; s.bottomMargin = rowCount - 1; s.cursorRow = 0; s.cursorColumn = 0
    s.pendingWrap = false; s.cursorVisible = true; s.cursorShape = 0
    screen = s
    primary.leftMargin = 0; primary.rightMargin = columns - 1; alternate.leftMargin = 0; alternate.rightMargin = columns - 1
    primary.keyboardFlags = 0; primary.keyboardStack.removeAll(); alternate.keyboardFlags = 0; alternate.keyboardStack.removeAll()
  }
  private func finishString() {
    let payload = sequence; sequence = ""
    if case .osc = parser {
      // OSC bytes are lossy UTF-8 decoded before command dispatch.
      let bytes = payload.unicodeScalars.map { UInt8($0.value) }
      let decoded = String(decoding: bytes, as: UTF8.self)
      guard let separator = decoded.firstIndex(of: ";") else { return }
      let command = String(decoded[..<separator])
      let value = String(decoded[decoded.index(after: separator)...])
      if command == "0" || command == "2" { title = sanitizedTitle(value) }
      else if command == "7" {
        if value.utf8.count <= 8192 { currentDirectory = value }
      }
      else if command == "8" {
        if let parameterSeparator = value.firstIndex(of: ";") {
          let uri = String(value[value.index(after: parameterSeparator)...])
          if uri.utf8.count <= 8192 { currentLink = uri.isEmpty ? nil : uri }
        }
      }
      else if ["4", "10", "11", "104"].contains(command) {
        for reply in palette.applyOSC(command: command, value: value) { replies.append(contentsOf: reply.utf8) }
      }
      else if command == "133" {
        let marker = value.split(separator: ";", omittingEmptySubsequences: false).first
        var current = screen
        switch marker {
        case "A", "B":
          if marker == "A" {
            current.promptPhase = .drawing
            current.promptRedraw = value.split(separator: ";", omittingEmptySubsequences: false).dropFirst().contains { $0 == "redraw=1" }
            current.promptAnchor = PromptAnchor(row: current.rows[current.cursorRow].id,
                                                column: current.cursorColumn,
                                                pendingWrap: current.pendingWrap)
          } else {
            current.promptPhase = .inputReady
          }
        case "C", "D": current.promptPhase = .none; current.retirePromptAnchor()
        default: break
        }
        screen = current
      }
      return
    }
    guard case .apc = parser else { return }
    // Printing can move history rows, but the graphics protocol is the only
    // path that needs live anchor membership.  Pruning here keeps ordinary
    // scalar output O(1) while retaining the placement cap semantics.
    pruneGraphicsAnchors()
    let s = screen
    let outcome = graphics.consume(Data(payload.utf8), context: KittyGraphicsContext(
      alternate: usingAlternate, row: s.rows[s.cursorRow].id, column: s.cursorColumn,
      cellWidth: cellPixelWidth, cellHeight: cellPixelHeight), now: clock)
    if let reply = outcome.reply { replies.append(reply) }
    if let advance = outcome.advance {
      resetClusterBoundary()
      var moved = s
      moved.cursorColumn = min(columns - 1, moved.cursorColumn + advance.0)
      moved.cursorRow = min(rowCount - 1, moved.cursorRow + advance.1)
      moved.pendingWrap = false
      screen = moved
    }
  }
  private func enqueueClipboard(_ data: Data) {
    guard data.count <= OSC52Decoder.maximumDecodedBytes, pendingClipboardRequests.count < 4 else { return }
    var requestID = nextClipboardRequestID
    repeat {
      nextClipboardRequestID &+= 1
      if nextClipboardRequestID == 0 { nextClipboardRequestID = 1 }
      if requestID != 0 && !pendingClipboardRequests.contains(requestID) { break }
      requestID = nextClipboardRequestID
    } while true
    pendingClipboardRequests.insert(requestID)
    clipboardRequests.append((requestID, data))
  }
  private var selectionScreen: TerminalSelectionScreen { usingAlternate ? .alternate : .primary }
  private func validatedSelection() {
    if selection.hasPendingWork {
      if pendingSelectionRevision != revision { selection.cancel(in: &document, preservePrevious: false); pendingSelectionRevision = nil }
      else { return }
    }
    if selection.hasSelection { selection.validate(in: document, lookup: TerminalSelectionLookup(document)) }
  }
  private func selectionFailure(_ reason: TerminalSelectionFailure) -> TerminalSelectionProgress {
    selection.report(reason); selectionViewChanged()
    return .rejected(reason)
  }
  private func selectionViewChanged() {
    let previous = revision
    revision &+= 1
    if pendingResize?.revision == previous { pendingResize?.revision = revision }
    if pendingSelectionRevision == previous { pendingSelectionRevision = revision }
  }
  func beginSelection(_ action: TerminalSelectionAction) -> TerminalSelectionProgress {
    guard pendingPresentedContent == nil else { return .rejected(.busy) }
    guard pendingResize == nil else { return selectionFailure(.busy) }
    if let error = selection.begin(action, in: &document, screen: selectionScreen,
      documentGeneration: selectionDocumentGeneration, geometryEpoch: geometryEpoch, snapshotID: selectionSnapshotID) {
      return selectionFailure(error)
    }
    if selection.hasPendingWork { pendingSelectionRevision = revision; return .pending }
    selectionViewChanged()
    return .completed(copiedText: nil)
  }
  func advanceSelection() -> TerminalSelectionProgress {
    guard let expected = pendingSelectionRevision else { return selectionFailure(.noSelection) }
    guard expected == revision else { selection.cancel(in: &document, preservePrevious: false); pendingSelectionRevision = nil; return selectionFailure(.staleTarget) }
    guard let result = selection.advance(in: &document) else { return .pending }
    pendingSelectionRevision = nil
    switch result {
    case .failure(let error): return selectionFailure(error)
    case .success(let text): selectionViewChanged(); return .completed(copiedText: text)
    }
  }
  func cancelSelection() { selection.cancel(in: &document, preservePrevious: pendingSelectionRevision == revision); pendingSelectionRevision = nil }
  func beginPresentedContent(_ content: TerminalPresentedContent) -> TerminalPresentedContentProgress {
    guard pendingPresentedContent == nil, pendingResize == nil, !selection.hasPendingWork else { return .rejected(.busy) }
    let context = TerminalPresentationContext(documentGeneration: selectionDocumentGeneration,
      screen: selectionScreen, geometryEpoch: geometryEpoch, snapshotID: selectionSnapshotID, columns: columns)
    switch TerminalPresentedContentValidator.begin(content, context: context) {
    case .failure(let error): return .rejected(error)
    case .success(let validator):
      pendingPresentedContent = PendingPresentedContent(revision: revision, historyEpoch: historyEpoch, validator: validator)
      return .pending
    }
  }
  func advancePresentedContent() -> TerminalPresentedContentProgress {
    guard let pending = pendingPresentedContent else { return .rejected(.cancelled) }
    guard pending.revision == revision, pending.historyEpoch == historyEpoch else {
      pendingPresentedContent = nil; return .rejected(.staleTarget)
    }
    let result = pending.validator.advance(in: document)
    if case .pending = result {} else { pendingPresentedContent = nil }
    return result
  }
  func cancelPresentedContent() { pendingPresentedContent = nil }
  private var resizeGeometry: TerminalResizeGeometry {
    TerminalResizeGeometry(columns: columns, rows: rowCount, cellWidth: cellPixelWidth, cellHeight: cellPixelHeight)
  }
  func beginResize(_ geometry: TerminalResizeGeometry) -> TerminalResizeProgress {
    guard geometry.isValid else { return .rejected(.invalidGeometry, retained: resizeGeometry) }
    guard pendingResize == nil, !selection.hasPendingWork, pendingPresentedContent == nil else { return .rejected(.resizeInProgress, retained: resizeGeometry) }
    if geometry.columns == columns && geometry.rows == rowCount {
      cellPixelWidth = geometry.cellWidth; cellPixelHeight = geometry.cellHeight
      return .committed(resizeGeometry)
    }
    pendingResize = PendingResize(geometry: geometry, revision: revision,
      transaction: makeResizeTransaction(geometry))
    return .pending
  }
  private func makeResizeTransaction(_ geometry: TerminalResizeGeometry) -> DocumentReflowTransaction {
    validatedSelection()
    let promptStyle = !usingAlternate && geometry.columns != columns && primary.atPrompt && primary.promptRedraw
      ? eraseStyle() : nil
    return DocumentReflowTransaction(source: document, geometry: geometry,
      anchor: viewAnchor, promptEraseStyle: promptStyle, historyRows: historyLimit, historyBytes: historyByteLimit,
      primarySelection: selection.reflowInput(.primary), alternateSelection: selection.reflowInput(.alternate))
  }
  func advanceResize() -> TerminalResizeProgress {
    guard var pending = pendingResize else { return .rejected(.noOperation, retained: resizeGeometry) }
    guard pending.revision == revision else {
      pending.transaction.retire()
      pendingResize = nil
      return .rejected(.staleInput, retained: resizeGeometry)
    }
    if pending.relievingPressure {
      switch pending.transaction.relieveHistoryPressure(in: &document) {
      case .pending: return .pending
      case .rejected(let reason):
        pendingResize = nil
        return .rejected(reason, retained: resizeGeometry)
      case .evicted:
        didEvictHistory()
        changed(history: true, screen: false)
        pending.revision = revision
      case .ready:
        pending.transaction = makeResizeTransaction(pending.geometry)
        pending.relievingPressure = false
      }
      pendingResize = pending
      return .pending
    }
    let replacement: DocumentReflowTransaction.Replacement
    switch pending.transaction.advance() {
    case .pending: return .pending
    case .pressure:
      pending.relievingPressure = true
      pendingResize = pending
      return .pending
    case .rejected(let reason):
      pending.transaction.retire()
      pendingResize = nil
      return .rejected(reason, retained: resizeGeometry)
    case .ready(let value): replacement = value
    }
    let oldColumns = columns
    let geometry = pending.geometry
    document = replacement.document
    resetClusterBoundary()
    syncDeadline = nil
    columns = geometry.columns; rowCount = geometry.rows
    cellPixelWidth = geometry.cellWidth; cellPixelHeight = geometry.cellHeight
    if columns != oldColumns {
      graphics.clear(alternate: false)
      tabs = Array(tabs.prefix(columns))
      if columns > oldColumns {
        tabs.append(contentsOf: (oldColumns..<columns).map { !tabsCleared && $0 > 0 && $0.isMultiple(of: 8) })
      }
    }
    if replacement.evictedHistory { didEvictHistory() }
    viewAnchor = replacement.mapping.anchor ?? viewAnchor
    resolveViewportAnchor(clamp: true)
    graphics.pruneAnchors(retaining: replacement.retainedRowIDs)
    changed(geometry: true)
    selection.applyReflow(replacement.selection, document: document,
      documentGeneration: selectionDocumentGeneration, geometryEpoch: geometryEpoch, snapshotID: selectionSnapshotID)
    pending.transaction.retire()
    pendingResize = nil
    return .committed(resizeGeometry)
  }
  func cancelResize() { pendingResize?.transaction.retire(); pendingResize = nil }
  func resize(columns nextColumns: Int, rows nextRows: Int) -> Bool {
    resize(columns: nextColumns, rows: nextRows, cellWidth: cellPixelWidth, cellHeight: cellPixelHeight)
  }
  func resize(columns nextColumns: Int, rows nextRows: Int, cellWidth: Int, cellHeight: Int) -> Bool {
    var progress = beginResize(TerminalResizeGeometry(columns: nextColumns, rows: nextRows,
      cellWidth: cellWidth, cellHeight: cellHeight))
    while case .pending = progress { progress = advanceResize() }
    if case .committed = progress { return true }
    return false
  }
  func scroll(_ amount: Int) {
    guard !usingAlternate, amount != 0 else { return }
    let current = resolveViewportAnchor(clamp: true)
    let offset: Int
    if amount > 0 { offset = min(history.count, current + amount) }
    else { offset = amount == Int.min ? 0 : max(0, current + amount) }
    setViewOffset(offset); changed(document: false, screen: false)
  }
  func followTail() { guard !usingAlternate else { return }; viewAnchor = nil; viewOffset = 0; viewportWasClamped = false; changed(document: false, screen: false) }
  private func setViewOffset(_ offset: Int) {
    let bounded = min(history.count, max(0, offset)); viewOffset = bounded
    viewAnchor = bounded > 0 ? history[history.count - bounded].id : nil; viewportWasClamped = false
  }
  @discardableResult private func resolveViewportAnchor(clamp: Bool) -> Int {
    guard let anchor = viewAnchor else { viewOffset = 0; return 0 }
    if let historyIndex = history.index(ofRowID: anchor) {
      viewOffset = history.count - historyIndex; return viewOffset
    }
    if let primaryIndex = primary.rows.firstIndex(where: { $0.id == anchor }) {
      viewOffset = 0
      if primaryIndex > 0 && clamp { viewAnchor = primary.rows[0].id; viewportClampRevision &+= 1 }
      return 0
    }
    if clamp { clampViewportAfterEviction() }
    return viewOffset
  }
  private func clampViewportAfterEviction() {
    guard viewAnchor != nil else { return }
    if let row = history.first ?? primary.rows.first { viewAnchor = row.id; viewOffset = history.first == nil ? 0 : history.count; if !viewportWasClamped { viewportClampRevision &+= 1; viewportWasClamped = true } }
  }
  private func enforceHistoryLimits() {
    if document.trimHistory(rowLimit: historyLimit, byteLimit: historyByteLimit) > 0 { didEvictHistory() }
  }
  private func didEvictHistory() {
    if let retainedAnchor = viewAnchor,
       history.index(ofRowID: retainedAnchor) == nil,
       !primary.rows.contains(where: { $0.id == retainedAnchor }) {
      clampViewportAfterEviction()
    }
  }
  private func pruneGraphicsAnchors() {
    guard graphics.hasPlacements else { return }
    // Retired placements retain only bounded (<= 256) row IDs, never rows.
    // Rebuilding this membership set is therefore deferred to graphics seams.
    var retained = Set(history.map(\.id))
    retained.formUnion(primary.rows.map(\.id)); retained.formUnion(alternate.rows.map(\.id))
    graphics.pruneAnchors(retaining: retained)
  }
  private func visibleImages(offset: Int) -> [KittyImagePlacement] {
    guard graphics.hasPlacements else { return [] }
    var positions: [UInt64: Int] = [:]
    if usingAlternate {
      for (index, row) in alternate.rows.enumerated() { positions[row.id] = index }
    } else {
      let start = history.count - min(offset, history.count)
      for (index, row) in history.enumerated() { positions[row.id] = index - start }
      for (index, row) in primary.rows.enumerated() { positions[row.id] = history.count + index - start }
    }
    return graphics.visible(alternate: usingAlternate, positions: positions, height: rowCount)
  }
  func setHistoryLimit(_ value: Int) { historyLimit = max(0, value); enforceHistoryLimits(); historyEpoch &+= 1; _ = resolveViewportAnchor(clamp: true) }
  func setHistoryByteLimit(_ value: Int) { historyByteLimit = max(0, value); enforceHistoryLimits(); historyEpoch &+= 1; _ = resolveViewportAnchor(clamp: true) }
  func clearDisplay() -> UInt32 {
    guard !usingAlternate else { return DisplayClearAction.ignoredAlternate.rawValue }
    var current = primary
    let action: DisplayClearAction = current.atPrompt ? .redrawPrompt : .cleared
    document.clearHistory()
    viewAnchor = nil; viewOffset = 0; viewportWasClamped = false
    if current.atPrompt {
      let margins = (current.topMargin, current.bottomMargin, current.leftMargin, current.rightMargin)
      let promptPhase = current.promptPhase
      let promptRedraw = current.promptRedraw
      let saved = (current.savedRow, current.savedColumn, current.savedPendingWrap, current.savedOrigin, current.savedStyle, current.savedLink)
      let keyboard = (current.keyboardFlags, current.keyboardStack)
      let cursorAppearance = (current.cursorVisible, current.cursorShape)
      current = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns)
      current.topMargin = margins.0; current.bottomMargin = margins.1
      current.leftMargin = margins.2; current.rightMargin = margins.3
      current.savedRow = saved.0; current.savedColumn = saved.1; current.savedPendingWrap = saved.2
      current.savedOrigin = saved.3; current.savedStyle = saved.4; current.savedLink = saved.5
      current.keyboardFlags = keyboard.0; current.keyboardStack = keyboard.1
      current.cursorVisible = cursorAppearance.0; current.cursorShape = cursorAppearance.1
      current.promptPhase = promptPhase
      current.promptRedraw = promptRedraw
      current.promptAnchor = PromptAnchor(row: current.rows[0].id, column: 0, pendingWrap: false)
    } else {
      let retained = Array(current.rows.dropFirst(current.cursorRow))
      current.rows = retained + (0..<(rowCount - retained.count)).map { _ in document.eraseRow(eraseStyle()) }
      current.cursorRow = 0
    }
    primary = current
    graphics.clear(alternate: false, removeResources: true)
    advanceSearchGeneration()
    syncDeadline = nil
    changed(history: true, document: false)
    return action.rawValue
  }
  func input(_ text: String, key: UInt32, modifiers: UInt32, event: UInt32,
             metadata: TerminalInputEncoder.KeyMetadata? = nil) -> Data? {
    let modes = TerminalInputEncoder.Modes(
      applicationCursor: applicationCursor, applicationKeypad: applicationKeypad, newline: newlineMode,
      bracketedPaste: bracketedPaste, focusReporting: focusReporting, kittyFlags: screen.keyboardFlags)
    // The C ABI's key=0 path represents committed text, not a physical key.
    // It must retain every scalar (automation, IME commits, and multi-scalar
    // insertText: calls), so it is passed through as its UTF-8 bytes.
    if key == 0 { return Data(text.utf8) }
    if key == 1 { return TerminalInputEncoder.paste(text, modes: modes) }
    if key == 2 { return TerminalInputEncoder.focus(event == 1, modes: modes) }
    let modifier = TerminalInputEncoder.Modifiers(
      shift: modifiers & 1 != 0, option: modifiers & 2 != 0,
      control: modifiers & 4 != 0, command: modifiers & 8 != 0,
      capsLock: modifiers & 64 != 0, numLock: modifiers & 128 != 0)
    let phase: TerminalInputEncoder.Event = event == 1 ? .repeatKey : event == 2 ? .release : .press
    guard let semantic = inputKey(key, text: text) else { return Data() }
    return TerminalInputEncoder.key(semantic, modifiers: modifier, event: phase, modes: modes, metadata: metadata)
  }
  private func inputKey(_ code: UInt32, text: String) -> TerminalInputEncoder.Key? {
    let navigation: [UInt32: TerminalInputEncoder.Key] = [
      10: .up, 11: .down, 12: .right, 13: .left, 14: .home, 15: .end,
      16: .pageUp, 17: .pageDown, 18: .insert, 19: .delete, 20: .backspace,
      21: .tab, 22: .enter, 23: .escape]
    if let value = navigation[code] { return value }
    if (100...111).contains(code) { return .function(Int(code - 99)) }
    if (300...317).contains(code), let keypad = TerminalInputEncoder.KeypadKey(rawValue: Int(code - 300)) {
      return .keypad(keypad, nativeText: text.unicodeScalars.first.map(Character.init))
    }
    if (400...411).contains(code) { return .modifier(57441 + code - 400) }
    if code == 412 { return .modifier(57358) }
    if code >= 50_000 { return .modifier(code) }
    if code == 0 || code == 200 { return text.unicodeScalars.first.map { .character(Character($0)) } }
    return nil
  }
  func takeReplies() -> Data { defer { replies.removeAll(keepingCapacity: true) }; return replies }
  func takeClipboardRequests() -> [(UInt64, Data)] {
    defer { clipboardRequests.removeAll(keepingCapacity: true) }
    return clipboardRequests
  }
  func completeClipboardRequest(_ requestID: UInt64) -> Bool {
    pendingClipboardRequests.remove(requestID) != nil
  }
  func finish() {
    finishDecodedText()
    graphics.abort()
    // OSC 52 writes require BEL/ST framing. EOF is an abort, never an
    // implicit successful terminator.
    parser = .ground
  }
  var hasPendingWork: Bool { repeatRemaining > 0 }
  var publicationGated: Bool { syncDeadline != nil }
  func snapshot(scroll: Int?, now: UInt64) -> Data? {
    tick(now)
    return publicationGated ? nil : snapshotJSON(scroll: scroll)
  }
  func snapshotValue(scroll: Int?, now: UInt64) -> (snapshot: TerminalSnapshot?, error: String?) {
    tick(now)
    guard !publicationGated else { return (nil, nil) }
    validatedSelection()
    let selected = selectSnapshot(scroll: scroll)
    let cursor = screen
    if let error = TerminalSnapshot.geometryError(columns: columns, rows: selected.rows.count) {
      return (nil, error)
    }
    guard selectionSnapshotID < UInt64.max else { return (nil, "Snapshot identity exhausted") }
    selectionSnapshotID += 1
    let colors = palette.snapshotPalette
    let foreground = palette.snapshotDefaultForeground
    let background = palette.snapshotDefaultBackground
    guard colors.count == 256, colors.allSatisfy({ $0.count == 3 }),
          foreground.count == 3, background.count == 3 else {
      return (nil, "Invalid snapshot dimensions or palette")
    }
    let kinds = ["Empty", "Lead1", "Lead2", "Continuation", "WrapSpacer"]
    var rows: [RowSnapshot] = []
    rows.reserveCapacity(selected.rows.count)
    for row in selected.rows {
      guard row.count == columns else { return (nil, "Invalid snapshot dimensions or palette") }
      var cells: [CellSnapshot] = []
      cells.reserveCapacity(columns)
      for cell in row.cells {
        guard Int(cell.kind) < kinds.count else { return (nil, "Invalid cell kind") }
        let flags = cell.style.flags
        let style = CellStyle(
          foreground: TerminalColor(packed: cell.style.foreground),
          background: TerminalColor(packed: cell.style.background),
          underline_color: TerminalColor(packed: cell.style.underline),
          underline: Int(cell.style.underlineKind), bold: flags & 1 != 0, faint: flags & 2 != 0,
          italic: flags & 4 != 0, inverse: flags & 8 != 0, conceal: flags & 16 != 0,
          strike: flags & 32 != 0, overline: flags & 64 != 0, blink: flags & 128 != 0)
        cells.append(CellSnapshot(text: cell.text, kind: kinds[Int(cell.kind)], style: style,
                                  link: cell.link, flags: Int(cell.flags)))
      }
      rows.append(RowSnapshot(cells: cells, soft_wrapped: row.softWrapped, id: row.id, revision: row.revision))
    }
    let highlights = visibleSearchHighlights(in: selected.rows, offset: selected.offset)
    func highlight(_ value: [String: Int]) -> SearchHighlight {
      SearchHighlight(row: value["row"]!, start: value["start"]!, end: value["end"]!)
    }
    let search = highlights.current.map(highlight)
    let images = visibleImages(offset: selected.offset).map {
      ImagePlacementSnapshot(image: $0.image, generation: $0.generation, width: $0.width, height: $0.height,
                             source: $0.source, row: $0.row, col: $0.column, columns: $0.columns,
                             rows: $0.rows, offset: $0.offset, natural: $0.natural, z: $0.z, placement: $0.placement)
    }
    return (TerminalSnapshot(
      at_prompt: cursor.atPrompt, input_ready: cursor.inputReady, search: search, images: images,
      revision: revision, geometry_epoch: geometryEpoch, document_epoch: documentEpoch,
      history_epoch: historyEpoch, screen_epoch: screenEpoch, scroll_offset: selected.offset,
      following_tail: selected.followingTail, viewport_clamp_revision: viewportClampRevision,
      cols: columns, rows: rows,
      cursor: CursorSnapshot(row: cursor.cursorRow, col: cursor.cursorColumn, pending_wrap: cursor.pendingWrap,
                             visible: cursor.cursorVisible, shape: Int(cursor.cursorShape)),
      modes: ModesSnapshot(application_cursor: applicationCursor, bracketed_paste: bracketedPaste,
                           focus: focusReporting, mouse: mouseMode, sgr_mouse: sgrMouse,
                           reverse_video: reverseVideo, newline: newlineMode),
      alternate: usingAlternate, title: title, cwd: currentDirectory, history_rows: history.count,
      palette: colors, default_fg: foreground, default_bg: background,
      selectionPresentation: TerminalSelectionPresentation(snapshotID: selectionSnapshotID,
        documentGeneration: selectionDocumentGeneration, screen: selectionScreen, geometryEpoch: geometryEpoch,
        columns: columns, rows: selected.rows.map { .init(id: $0.id, revision: $0.revision, softWrapped: $0.softWrapped) }),
      selection: selection.snapshot(screen: selectionScreen, rows: selected.rows),
      search_matches: highlights.others.map(highlight)), nil)
  }
  func isValid() -> Bool {
    document.hasValidInvariants(primary) && document.hasValidInvariants(alternate) &&
      history.allSatisfy { $0.cells.count == columns }
  }
  func historyBytes() -> UInt64 { document.history.byteCount }
  func imageRGBA(id: UInt32, generation: UInt64) -> Data? { graphics.imageRGBA(id: id, generation: generation) }
  private func searchKind(_ kind: UInt8) -> TerminalSearchCellKind {
    switch kind {
    case 0: return .empty
    case 1: return .lead1
    case 2: return .lead2
    case 3: return .continuation
    default: return .wrapSpacer
    }
  }
  private func searchProjection(_ row: TerminalRow) -> TerminalSearchRow {
    // This conversion happens for one owner-admitted row only. In particular,
    // starting a search does not turn all retained scrollback into String
    // cells, and the worker retains just its current immutable page.
    TerminalSearchRow(
      id: row.id, revision: row.revision,
      cells: row.cells.map { cell in
        TerminalSearchCell(cell.text, searchKind(cell.kind), hasBackground: cell.style.background != 0)
      }, softWrapsToNext: row.softWrapped)
  }
  /// Resolves a captured search coordinate without materializing rich search
  /// cells. The source closures all route through this one ownership boundary.
  private func capturedSearchRow(_ index: Int, alternateMode: Bool, historyCount: Int) -> TerminalRow? {
    guard usingAlternate == alternateMode else { return nil }
    if alternateMode { return alternate.rows.indices.contains(index) ? alternate.rows[index] : nil }
    if index < historyCount { return history.indices.contains(index) ? history[index] : nil }
    let primaryIndex = index - historyCount
    return primary.rows.indices.contains(primaryIndex) ? primary.rows[primaryIndex] : nil
  }
  private func capturedSearchSoftNextID(_ index: Int, alternateMode: Bool, historyCount: Int) -> UInt64? {
    guard let row = capturedSearchRow(index, alternateMode: alternateMode, historyCount: historyCount),
          row.softWrapped else { return nil }
    return capturedSearchRow(index + 1, alternateMode: alternateMode, historyCount: historyCount)?.id
  }
  private func searchSource() -> TerminalSearchSource {
    let alternateMode = usingAlternate
    let historyCount = history.count
    let rowCount = alternateMode ? alternate.rows.count : historyCount + primary.rows.count
    // Printing and scrollback admission advance the renderer publication
    // counters. Search instead follows captured row identities and verifies
    // row proofs at acceptance: later output must not make it chase rows, and
    // eviction/mutation still fails lookup/proof. Geometry/alternate changes
    // remain structural stamp boundaries.
    let stamp = TerminalSearchStamp(document: searchGeneration, history: 0,
                                 geometry: geometryEpoch, screen: 0,
                                 alternate: alternateMode)
    return TerminalSearchSource(
      stamp: stamp, rowCount: rowCount,
      rowAt: { [unowned self] index in
        guard let row = self.capturedSearchRow(index, alternateMode: alternateMode, historyCount: historyCount) else { return nil }
        return self.searchProjection(row)
      },
      rowIDAt: { [unowned self] index in
        self.capturedSearchRow(index, alternateMode: alternateMode, historyCount: historyCount)?.id
      },
      proofAt: { [unowned self] index in
        guard let row = self.capturedSearchRow(index, alternateMode: alternateMode, historyCount: historyCount) else { return nil }
        return TerminalSearchProof(id: row.id, revision: row.revision,
                                softNextID: self.capturedSearchSoftNextID(index, alternateMode: alternateMode, historyCount: historyCount))
      },
      softNextIDAt: { [unowned self] index in
        self.capturedSearchSoftNextID(index, alternateMode: alternateMode, historyCount: historyCount)
      },
      retainedBytesAt: { [unowned self] index in
        let row = self.capturedSearchRow(index, alternateMode: alternateMode, historyCount: historyCount)
        guard let row else { return nil }
        return row.retainedStorageCost > UInt64(Int.max) ? Int.max : Int(row.retainedStorageCost)
      })
  }
  func createSearch(_ query: String) -> TerminalSearchToken? {
    searchHits = nil
    return try? TerminalSearchToken(TerminalSearchTask(query: query, source: searchSource()))
  }
  private func searchStatus(_ status: TerminalSearchStatus) -> UInt32 {
    switch status {
    case .working: return 0
    case .needsPage: return 1
    case .complete: return 2
    case .changed, .cancelled: return 3
    case .resourceLimit: return 4
    }
  }
  func fillSearch(_ token: TerminalSearchToken) -> UInt32 {
    searchStatus(token.task.fill(from: searchSource()))
  }
  static func stepSearch(_ token: TerminalSearchToken) -> UInt32 {
    // No core/document access: Session explicitly migrates this token to its
    // utility worker before calling this function.
    switch token.task.step() {
    case .working: return 0
    case .needsPage: return 1
    case .complete: return 2
    case .changed, .cancelled: return 3
    case .resourceLimit: return 4
    }
  }
  func acceptSearch(_ token: TerminalSearchToken) -> UInt32 {
    let source = searchSource()
    switch token.task.accept(in: source) {
    case .found(let matches, let capped):
      var byRow: [UInt64: [(match: Int, span: Int)]] = [:]
      for (matchIndex, match) in matches.enumerated() {
        for (spanIndex, resolved) in match.spans.enumerated() where resolved.span.start < resolved.span.end {
          byRow[resolved.span.proof.id, default: []].append((matchIndex, spanIndex))
        }
      }
      // The newest match is the first stop; navigation then walks to older output.
      searchHits = SearchHits(stamp: source.stamp, matches: matches, current: matches.count - 1,
                              capped: capped, byRow: byRow)
      revealSearchMatch(anchor: matches[matches.count - 1].anchor)
      return 5
    case .missing: return 2
    case .working: return 0
    case .needsPage: return 1
    case .changed, .cancelled: return 3
    case .resourceLimit: return 4
    }
  }
  /// Centers the match. A find bar docked over the first rows would cover a
  /// match pinned to the top of the viewport.
  private func revealSearchMatch(anchor: Int) {
    guard !usingAlternate else { return }
    setViewOffset(history.count - anchor + rowCount / 2)
  }
  /// Resolves a retained match against the live document, following history
  /// eviction. Nil means a contributing row changed or left the document.
  private func liveSearchAnchor(_ match: TerminalSearchMatch, in source: TerminalSearchSource) -> Int? {
    guard let first = match.spans.first?.span.proof.id else { return nil }
    let anchor: Int
    if source.rowIDAt(match.anchor) == first { anchor = match.anchor }
    else if let found = (0..<source.rowCount).first(where: { source.rowIDAt($0) == first }) { anchor = found }
    else { return nil }
    for (offset, resolved) in match.spans.enumerated() {
      guard source.rowIDAt(anchor + offset) == resolved.span.proof.id,
            source.proofAt(anchor + offset) == resolved.span.proof
      else { return nil }
    }
    return anchor
  }
  /// One-based position counted from the newest match, as a find bar shows it.
  func searchPosition() -> (position: Int, total: Int, capped: Bool)? {
    guard let hits = searchHits, hits.stamp == searchSource().stamp else { return nil }
    return (hits.matches.count - hits.current, hits.matches.count, hits.capped)
  }
  /// Moves to the adjacent live match and reveals it, wrapping at either end.
  /// Stale matches are skipped; nil means no retained match is still valid.
  func navigateSearch(older: Bool) -> (position: Int, total: Int, capped: Bool)? {
    guard var hits = searchHits else { return nil }
    let source = searchSource()
    guard hits.stamp == source.stamp else { searchHits = nil; return nil }
    let count = hits.matches.count
    var index = hits.current
    for _ in 0..<count {
      index = (index + (older ? count - 1 : 1)) % count
      guard let anchor = liveSearchAnchor(hits.matches[index], in: source) else { continue }
      hits.matches[index].anchor = anchor
      hits.current = index
      searchHits = hits
      revealSearchMatch(anchor: anchor)
      changed(document: false, screen: false)
      return (count - index, count, hits.capped)
    }
    clearSearch()
    return nil
  }
  func clearSearch() {
    guard searchHits != nil else { return }
    searchHits = nil
    changed(document: false, screen: false)
  }
  private func sanitizedTitle(_ value: String) -> String {
    var result = ""
    var byteCount = 0
    // Only Unicode's Cc category counts as control. In
    // particular, format scalars such as ZWJ and WORD JOINER remain titles.
    for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control {
      let nextCount = scalar.utf8.count
      guard byteCount + nextCount <= 4096 else { break }
      result.unicodeScalars.append(scalar)
      byteCount += nextCount
    }
    return result
  }
  private struct SnapshotSelection {
    var rows: [TerminalRow]
    var offset: Int
    var followingTail: Bool
  }
  private func rowsForSnapshot(offset: Int) -> (rows: [TerminalRow], offset: Int) {
    let requested = max(0, offset)
    guard !usingAlternate, requested > 0 else { return (screen.rows, 0) }
    let all = history + primary.rows
    let end = max(rowCount, all.count - min(requested, history.count))
    return (Array(all[max(0, end - rowCount)..<end]), min(requested, history.count))
  }
  private func selectSnapshot(scroll: Int?) -> SnapshotSelection {
    guard let scroll else {
      let selected = rowsForSnapshot(offset: viewOffset)
      return SnapshotSelection(rows: selected.rows, offset: selected.offset,
                               followingTail: usingAlternate || viewAnchor == nil)
    }
    let selected = rowsForSnapshot(offset: scroll)
    return SnapshotSelection(rows: selected.rows, offset: selected.offset,
                             followingTail: selected.offset == 0)
  }
  /// Highlights for one published row selection: the navigated match and the
  /// remaining visible matches. `offset` is the selection's scroll offset; it
  /// locates the rows in document space so each proof is checked exactly.
  private func visibleSearchHighlights(in rows: [TerminalRow], offset: Int)
    -> (current: [[String: Int]], others: [[String: Int]]) {
    guard let hits = searchHits, let firstRow = rows.first else { return ([], []) }
    let source = searchSource()
    guard source.stamp == hits.stamp else { return ([], []) }
    let base: Int
    if usingAlternate { base = 0 }
    else if offset <= 0 { base = history.count }
    else {
      let total = history.count + primary.rows.count
      base = max(0, max(rowCount, total - min(offset, history.count)) - rowCount)
    }
    guard source.rowIDAt(base) == firstRow.id else { return ([], []) }
    var proofs: [Int: TerminalSearchProof?] = [:]
    func proven(_ index: Int, _ proof: TerminalSearchProof) -> Bool {
      if let known = proofs[index] { return known == proof }
      let live = source.proofAt(index)
      proofs[index] = live
      return live == proof
    }
    var current: [[String: Int]] = []
    var others: [[String: Int]] = []
    for (visible, row) in rows.enumerated() {
      guard let entries = hits.byRow[row.id] else { continue }
      for entry in entries {
        let match = hits.matches[entry.match]
        let first = base + visible - entry.span
        // A multi-row match is drawn only while all of its rows are still
        // adjacent and unchanged.
        guard first >= 0, match.spans.enumerated().allSatisfy({ proven(first + $0.offset, $0.element.span.proof) })
        else { continue }
        let span = match.spans[entry.span].span
        let highlight = ["row": visible, "start": span.start, "end": span.end]
        if entry.match == hits.current { current.append(highlight) } else { others.append(highlight) }
      }
    }
    return (current, others)
  }
  func publishBinary(scroll: Int?, now: UInt64, context: UnsafeMutableRawPointer?, callback: SnapshotCallback?) -> Bool {
    tick(now)
    guard !publicationGated else { return false }
    guard let callback else { return false }
    let selected = selectSnapshot(scroll: scroll)
    var metadataObject = snapshotMetadata(cursor: screen, offset: selected.offset,
                                          followingTail: selected.followingTail,
                                          search: visibleSearchHighlights(in: selected.rows, offset: selected.offset))
    metadataObject["row_identities"] = selected.rows.map { ["id": $0.id, "revision": $0.revision] }
    #if SNAPSHOT_ABI_DIAGNOSTICS
    SnapshotABIDiagnostics.jsonPublications += 1
    #endif
    guard let metadata = try? JSONSerialization.data(withJSONObject: metadataObject) else { return false }
    let borrowed = BorrowedSnapshotCells()
    var views: [TerminalCellView] = []
    views.reserveCapacity(selected.rows.count * columns)
    for row in selected.rows {
      for cell in row.cells {
        var view = TerminalCellView()
        view.text = borrowed.copy(cell.text, into: &borrowed.text)
        view.text_len = cell.text.utf8.count
        if let link = cell.link {
          view.link = borrowed.copy(link, into: &borrowed.links)
          view.link_len = link.utf8.count
        }
        view.foreground = cell.style.foreground
        view.background = cell.style.background
        view.underline_color = cell.style.underline
        view.style_flags = cell.style.flags
        view.kind = cell.kind
        view.cell_flags = cell.flags
        view.underline = cell.style.underlineKind
        views.append(view)
      }
    }
    let wraps = selected.rows.map { $0.softWrapped ? UInt8(1) : UInt8(0) }
    return metadata.withUnsafeBytes { metadataBuffer in
      views.withUnsafeBufferPointer { viewBuffer in
        wraps.withUnsafeBufferPointer { wrapBuffer in
          callback(context, metadataBuffer.bindMemory(to: UInt8.self).baseAddress, metadata.count,
                   viewBuffer.baseAddress, views.count, wrapBuffer.baseAddress, wraps.count)
        }
      }
      return true
    }
  }
  func snapshotJSON(scroll: Int?) -> Data {
    #if SNAPSHOT_ABI_DIAGNOSTICS
    SnapshotABIDiagnostics.jsonPublications += 1
    #endif
    let source: [TerminalRow]; let offset: Int
    let selected = selectSnapshot(scroll: scroll)
    source = selected.rows; offset = selected.offset
    let rows: [[String: Any]] = source.map { row in ["id": row.id, "revision": row.revision, "soft_wrapped": row.softWrapped, "cells": row.cells.map { cell in ["text": cell.text, "kind": ["Empty","Lead1","Lead2","Continuation","WrapSpacer"][Int(cell.kind)], "style": ["foreground": colorJSON(cell.style.foreground), "background": colorJSON(cell.style.background), "underline_color": colorJSON(cell.style.underline), "underline": Int(cell.style.underlineKind), "bold": cell.style.flags & 1 != 0, "faint": cell.style.flags & 2 != 0, "italic": cell.style.flags & 4 != 0, "inverse": cell.style.flags & 8 != 0, "conceal": cell.style.flags & 16 != 0, "strike": cell.style.flags & 32 != 0, "overline": cell.style.flags & 64 != 0, "blink": cell.style.flags & 128 != 0], "link": cell.link as Any, "flags": Int(cell.flags)] } ] }
    var data = snapshotMetadata(cursor: screen, offset: offset,
                                followingTail: selected.followingTail,
                                search: visibleSearchHighlights(in: source, offset: offset))
    data["rows"] = rows
    return (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8)
  }
  private func snapshotMetadata(cursor: TerminalScreen, offset: Int,
                                followingTail: Bool,
                                search: (current: [[String: Int]], others: [[String: Int]])) -> [String: Any] {
    let images = visibleImages(offset: offset).map { image in ["image": image.image, "generation": image.generation, "width": image.width, "height": image.height, "source": image.source, "row": image.row, "col": image.column, "columns": image.columns, "rows": image.rows, "offset": image.offset, "natural": image.natural, "z": image.z, "placement": image.placement] as [String: Any] }
    var metadata: [String: Any] = ["at_prompt":cursor.atPrompt,"input_ready":cursor.inputReady,"search":search.current,"search_matches":search.others,"images":images,"revision":revision,"geometry_epoch":geometryEpoch,"document_epoch":documentEpoch,"history_epoch":historyEpoch,"screen_epoch":screenEpoch,"scroll_offset":offset,"following_tail":followingTail,"viewport_clamp_revision":viewportClampRevision,"cols":columns,"cursor":["row":cursor.cursorRow,"col":cursor.cursorColumn,"pending_wrap":cursor.pendingWrap,"visible":cursor.cursorVisible,"shape":Int(cursor.cursorShape)],"modes":["application_cursor":applicationCursor,"application_keypad":applicationKeypad,"autowrap":autoWrap,"bracketed_paste":bracketedPaste,"focus":focusReporting,"insert":insertMode,"left_right_margins":leftRightMargins,"mouse":mouseMode,"newline":newlineMode,"origin":originMode,"reverse_video":reverseVideo,"sgr_mouse":sgrMouse],"primary_margins":[primary.leftMargin, primary.rightMargin],"alternate_margins":[alternate.leftMargin, alternate.rightMargin],"vertical_margins":[cursor.topMargin, cursor.bottomMargin],"alternate":usingAlternate,"title":title,"history_rows":history.count,"palette":palette.snapshotPalette,"default_fg":palette.snapshotDefaultForeground,"default_bg":palette.snapshotDefaultBackground]
    metadata["cwd"] = currentDirectory as Any? ?? NSNull()
    return metadata
  }
  private func colorJSON(_ color: UInt32) -> Any { if color >> 24 == 1 { return ["Indexed": Int(color & 255)] }; if color >> 24 == 2 { return ["Rgb": [Int((color >> 16) & 255), Int((color >> 8) & 255), Int(color & 255)]] }; return "Default" }
}

// MARK: C ABI bridge. The app imports Bridge.h, so native call sites keep one
// stable C-shaped surface.

private func core(_ pointer: OpaquePointer?) -> TerminalEmulator? { pointer.map { Unmanaged<TerminalEmulator>.fromOpaque(UnsafeMutableRawPointer($0)).takeUnretainedValue() } }
// Internal Swift adapter: same owner-confined handle, no C callback or borrowed
// row/cell storage. The returned value survives later mutation and destruction.
func swiftTerminalSnapshot(_ pointer: OpaquePointer?, scroll: Int?, now: UInt64) -> (snapshot: TerminalSnapshot?, error: String?) {
  core(pointer)?.snapshotValue(scroll: scroll, now: now) ?? (nil, nil)
}
enum TerminalSelectionBridge {
  static func begin(core pointer: OpaquePointer, action: TerminalSelectionAction) -> TerminalSelectionProgress {
    core(pointer)!.beginSelection(action)
  }
  static func advance(core pointer: OpaquePointer) -> TerminalSelectionProgress { core(pointer)!.advanceSelection() }
  static func cancel(core pointer: OpaquePointer) { core(pointer)!.cancelSelection() }
}
enum TerminalPresentedContentBridge {
  static func begin(core pointer: OpaquePointer, content: TerminalPresentedContent) -> TerminalPresentedContentProgress {
    core(pointer)!.beginPresentedContent(content)
  }
  static func advance(core pointer: OpaquePointer) -> TerminalPresentedContentProgress { core(pointer)!.advancePresentedContent() }
  static func cancel(core pointer: OpaquePointer) { core(pointer)!.cancelPresentedContent() }
}
enum TerminalResizeBridge {
  static func begin(core pointer: OpaquePointer, columns: Int, rows: Int,
                    cellWidth: Int, cellHeight: Int) -> TerminalResizeProgress {
    core(pointer)!.beginResize(TerminalResizeGeometry(columns: columns, rows: rows,
      cellWidth: cellWidth, cellHeight: cellHeight))
  }
  static func advance(core pointer: OpaquePointer) -> TerminalResizeProgress { core(pointer)!.advanceResize() }
  static func cancel(core pointer: OpaquePointer) { core(pointer)!.cancelResize() }
}
private func inputCharacter(_ scalar: UInt32) -> Character? {
  guard scalar != 0, let value = UnicodeScalar(scalar) else { return nil }
  return Character(String(value))
}
typealias BytesCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
typealias ClipboardCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<UInt8>?, Int) -> Void
typealias SnapshotCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int) -> Void

@_cdecl("terminal_abi_version") func swift_terminal_abi_version() -> UInt32 { 1 }
@_cdecl("terminal_create") func swift_terminal_create(_ cols: UInt32, _ rows: UInt32) -> OpaquePointer? {
  guard (1...4096).contains(cols), (1...4096).contains(rows), cols <= 1_048_576 / rows else { return nil }
  return OpaquePointer(Unmanaged.passRetained(TerminalEmulator(columns: Int(cols), rows: Int(rows))).toOpaque())
}
@_cdecl("terminal_destroy") func swift_terminal_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<TerminalEmulator>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_feed") func swift_terminal_feed(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ now: UInt64) -> Int { core(pointer)?.feed(bytes, count: count, now: now) ?? 0 }
@_cdecl("terminal_resize") func swift_terminal_resize(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows)) ?? false }
@_cdecl("terminal_resize_pixels") func swift_terminal_resize_pixels(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32, _ width: UInt32, _ height: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows), cellWidth: Int(width), cellHeight: Int(height)) ?? false }
@_cdecl("terminal_search_position") func swift_terminal_search_position(_ pointer: OpaquePointer?, _ position: UnsafeMutablePointer<UInt32>?, _ total: UnsafeMutablePointer<UInt32>?, _ capped: UnsafeMutablePointer<Bool>?) -> Bool {
  guard let value = core(pointer)?.searchPosition() else { return false }
  position?.pointee = UInt32(value.position); total?.pointee = UInt32(value.total); capped?.pointee = value.capped
  return true
}
@_cdecl("terminal_search_navigate") func swift_terminal_search_navigate(_ pointer: OpaquePointer?, _ older: Bool, _ position: UnsafeMutablePointer<UInt32>?, _ total: UnsafeMutablePointer<UInt32>?, _ capped: UnsafeMutablePointer<Bool>?) -> Bool {
  guard let value = core(pointer)?.navigateSearch(older: older) else { return false }
  position?.pointee = UInt32(value.position); total?.pointee = UInt32(value.total); capped?.pointee = value.capped
  return true
}
@_cdecl("terminal_search_clear") func swift_terminal_search_clear(_ pointer: OpaquePointer?) { core(pointer)?.clearSearch() }
@_cdecl("terminal_finish") func swift_terminal_finish(_ pointer: OpaquePointer?) { core(pointer)?.finish() }
@_cdecl("terminal_validate") func swift_terminal_validate(_ pointer: OpaquePointer?) -> Bool { core(pointer)?.isValid() ?? false }
@_cdecl("terminal_has_work") func swift_terminal_has_work(_ pointer: OpaquePointer?) -> Bool { core(pointer)?.hasPendingWork ?? false }
@_cdecl("terminal_set_history_limit") func swift_terminal_set_history_limit(_ pointer: OpaquePointer?, _ limit: UInt32) { core(pointer)?.setHistoryLimit(Int(limit)) }
@_cdecl("terminal_set_history_byte_limit") func swift_terminal_set_history_byte_limit(_ pointer: OpaquePointer?, _ limit: UInt64) { core(pointer)?.setHistoryByteLimit(limit > UInt64(Int.max) ? Int.max : Int(limit)) }
@_cdecl("terminal_history_bytes") func swift_terminal_history_bytes(_ pointer: OpaquePointer?) -> UInt64 { core(pointer)?.historyBytes() ?? 0 }
@_cdecl("terminal_snapshot") func swift_terminal_snapshot(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64) -> UnsafeMutablePointer<CChar>? { guard let snapshot = core(pointer)?.snapshot(scroll: scroll, now: now) else { return nil }; return strdup(String(data: snapshot, encoding: .utf8) ?? "{}") }
@_cdecl("terminal_string_free") func swift_terminal_string_free(_ value: UnsafeMutablePointer<CChar>?) { if let value { free(value) } }
@_cdecl("terminal_snapshot_binary") func swift_terminal_snapshot_binary(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(scroll: scroll, now: now, context: context, callback: callback) ?? false }
@_cdecl("terminal_view_snapshot_binary") func swift_terminal_view_snapshot_binary(_ pointer: OpaquePointer?, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(scroll: nil, now: now, context: context, callback: callback) ?? false }
@_cdecl("terminal_view_scroll") func swift_terminal_view_scroll(_ pointer: OpaquePointer?, _ amount: Int64) { core(pointer)?.scroll(Int(amount)) }
@_cdecl("terminal_view_follow_tail") func swift_terminal_view_follow_tail(_ pointer: OpaquePointer?) { core(pointer)?.followTail() }
@_cdecl("terminal_clear_display") func swift_terminal_clear_display(_ pointer: OpaquePointer?) -> UInt32 { core(pointer)?.clearDisplay() ?? 0 }
@_cdecl("terminal_replies") func swift_terminal_replies(_ pointer: OpaquePointer?, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) { guard let callback, let data = core(pointer)?.takeReplies(), !data.isEmpty else { return }; data.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, data.count) } }
@_cdecl("terminal_take_clipboard_requests") func swift_terminal_take_clipboard_requests(_ pointer: OpaquePointer?, _ context: UnsafeMutableRawPointer?, _ callback: ClipboardCallback?) {
  guard let callback else { return }
  for (requestID, data) in core(pointer)?.takeClipboardRequests() ?? [] {
    if data.isEmpty {
      // An empty write still passes a non-null pointer, for hosts whose callback validates the pointer before
      // observing the zero length.
      var sentinel: UInt8 = 0
      withUnsafePointer(to: &sentinel) { callback(context, requestID, $0, 0) }
    } else {
      data.withUnsafeBytes { callback(context, requestID, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    }
  }
}
@_cdecl("terminal_complete_clipboard_request") func swift_terminal_complete_clipboard_request(_ pointer: OpaquePointer?, _ requestID: UInt64) -> Bool { core(pointer)?.completeClipboardRequest(requestID) ?? false }
@_cdecl("terminal_input") func swift_terminal_input(_ pointer: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ key: UInt32, _ modifiers: UInt32, _ event: UInt32, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { guard let value = core(pointer)?.input(text.map { String(cString: $0) } ?? "", key: key, modifiers: modifiers, event: event) else { return false }; if let callback, !value.isEmpty { value.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, value.count) } }; return true }
@_cdecl("terminal_input_with_metadata") func swift_terminal_input_with_metadata(_ pointer: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ key: UInt32, _ modifiers: UInt32, _ event: UInt32, _ associated: UnsafePointer<CChar>?, _ legacy: UnsafePointer<CChar>?, _ shifted: UInt32, _ baseLayout: UInt32, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool {
  func optionalText(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer, pointer.pointee != 0 else { return nil }
    return String(cString: pointer)
  }
  let metadata = TerminalInputEncoder.KeyMetadata(
    shifted: inputCharacter(shifted), baseLayout: inputCharacter(baseLayout),
    associatedText: optionalText(associated), legacyText: optionalText(legacy))
  guard let value = core(pointer)?.input(text.map { String(cString: $0) } ?? "", key: key,
                                         modifiers: modifiers, event: event, metadata: metadata) else { return false }
  if let callback, !value.isEmpty { value.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, value.count) } }
  return true
}
@_cdecl("terminal_image_rgba") func swift_terminal_image_rgba(_ pointer: OpaquePointer?, _ image: UInt32, _ generation: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { guard let callback, let pixels = core(pointer)?.imageRGBA(id: image, generation: generation) else { return false }; pixels.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, pixels.count) }; return true }
@_cdecl("terminal_search_create") func swift_terminal_search_create(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) -> OpaquePointer? {
  guard let bytes, count > 0, count <= 4_096,
        let query = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8),
        let token = core(pointer)?.createSearch(query)
  else { return nil }
  return OpaquePointer(Unmanaged.passRetained(token).toOpaque())
}
@_cdecl("terminal_search_destroy") func swift_terminal_search_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_search_fill") func swift_terminal_search_fill(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 {
  guard let terminal = core(pointer), let task else { return 3 }
  return terminal.fillSearch(Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue())
}
@_cdecl("terminal_search_step") func swift_terminal_search_step(_ pointer: OpaquePointer?) -> UInt32 {
  guard let pointer else { return 3 }
  return TerminalEmulator.stepSearch(Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).takeUnretainedValue())
}
@_cdecl("terminal_search_accept") func swift_terminal_search_accept(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 {
  guard let terminal = core(pointer), let task else { return 3 }
  return terminal.acceptSearch(Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue())
}

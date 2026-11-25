import Foundation
import TerminalInterop

// Owns terminal emulation and the stable C compatibility boundary.  The public C-shaped surface is
// deliberately thin: the state machine owns parsing, grid mutation, history,
// snapshots, and input encoding so neither Session nor the renderer needs to
// duplicate terminal policy.


private func decSpecialGraphics(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
  switch scalar.value {
  case 0x5f: return "\u{00a0}"
  case 0x60: return "\u{25c6}"
  case 0x61: return "\u{2592}"
  case 0x62: return "\u{2409}"
  case 0x63: return "\u{240c}"
  case 0x64: return "\u{240d}"
  case 0x65: return "\u{240a}"
  case 0x66: return "\u{00b0}"
  case 0x67: return "\u{00b1}"
  case 0x68: return "\u{2424}"
  case 0x69: return "\u{240b}"
  case 0x6a: return "\u{2518}"
  case 0x6b: return "\u{2510}"
  case 0x6c: return "\u{250c}"
  case 0x6d: return "\u{2514}"
  case 0x6e: return "\u{253c}"
  case 0x6f: return "\u{23ba}"
  case 0x70: return "\u{23bb}"
  case 0x71: return "\u{2500}"
  case 0x72: return "\u{23bc}"
  case 0x73: return "\u{23bd}"
  case 0x74: return "\u{251c}"
  case 0x75: return "\u{2524}"
  case 0x76: return "\u{2534}"
  case 0x77: return "\u{252c}"
  case 0x78: return "\u{2502}"
  case 0x79: return "\u{2264}"
  case 0x7a: return "\u{2265}"
  case 0x7b: return "\u{03c0}"
  case 0x7c: return "\u{2260}"
  case 0x7d: return "\u{00a3}"
  case 0x7e: return "\u{00b7}"
  default: return scalar
  }
}

enum VTParserState { case ground, escape, charset(Int), escapeIntermediate(UInt8), csi, osc, osc52(OSC52Decoder, escaped: Bool), apc, discardString(escaped: Bool, osc: Bool), inlineImage(InlineImageDecoder, escaped: Bool), dcsHeader, dcsQuery(escaped: Bool), sixel(SixelDecoder, escaped: Bool) }

final class TerminalEmulator {
  private enum DisplayClearAction: UInt32 {
    case ignoredAlternate = 0, cleared = 1, redrawPrompt = 2
  }
  @exclusivity(unchecked) private(set) var columns: Int
  @exclusivity(unchecked) private(set) var rowCount: Int
  @exclusivity(unchecked) var document: TerminalDocument
  let selection = TerminalSelection()
  @exclusivity(unchecked) var selectionDocumentGeneration = UUID()
  @exclusivity(unchecked) var selectionSnapshotID: UInt64 = 0
  @exclusivity(unchecked) private var pendingSelectionRevision: UInt64?
  private struct PendingPresentedContent {
    var revision: UInt64
    let historyEpoch: UInt64
    let validator: TerminalPresentedContentValidator
  }
  @exclusivity(unchecked) private var pendingPresentedContent: PendingPresentedContent?
  private struct PendingResize {
    let geometry: TerminalResizeGeometry
    var revision: UInt64
    var transaction: DocumentReflowTransaction
    var relievingPressure = false
  }
  @exclusivity(unchecked) private var pendingResize: PendingResize?
  var primary: TerminalScreen { get { document.primary } set { document.primary = newValue } }
  var alternate: TerminalScreen { get { document.alternate } set { document.alternate = newValue } }
  @exclusivity(unchecked) var usingAlternate = false
  var history: TerminalHistory { document.history }
  @exclusivity(unchecked) private var historyLimit = 50_000
  @exclusivity(unchecked) private var historyByteLimit = 64 * 1024 * 1024
  @exclusivity(unchecked) var viewOffset = 0
  // Nil means follow-tail. A retained row identity keeps a viewport stable as
  // output appends history and is remapped during document reflow.
  @exclusivity(unchecked) var viewAnchor: UInt64?
  @exclusivity(unchecked) var viewportClampRevision: UInt64 = 1
  @exclusivity(unchecked) private var viewportWasClamped = false
  // Modes describe protocol policy. Geometry itself belongs to each document
  // screen, because primary and alternate retain independent margins.
  @exclusivity(unchecked) var originMode = false
  @exclusivity(unchecked) var leftRightMargins = false
  @exclusivity(unchecked) var autoWrap = true
  @exclusivity(unchecked) var reverseWrap = false
  @exclusivity(unchecked) var reverseWrapUnlimited = false
  @exclusivity(unchecked) var cursesTabWrap = false
  @exclusivity(unchecked) var savedPrivateModes: [Int: Bool] = [:]
  // SPA activates ISO erasure protection until terminal reset. EPA stops
  // protecting new cells but does not disable protection of existing cells.
  @exclusivity(unchecked) var isoEraseProtection = false
  @exclusivity(unchecked) var insertMode = false
  @exclusivity(unchecked) var newlineMode = false
  @exclusivity(unchecked) var syncDeadline: UInt64?
  @exclusivity(unchecked) var clock: UInt64 = 0
  @exclusivity(unchecked) var parser = VTParserState.ground
  @exclusivity(unchecked) private var utf8 = TerminalText.UTF8Decoder()
  @exclusivity(unchecked) var sequenceBytes: [UInt8] = []
  private static let osc52Prefix: [UInt8] = Array("52;c;".utf8)
  private static let oscFilePrefix: [UInt8] = Array("1337;File=".utf8)
  private static let oscFilePartPrefix: [UInt8] = Array("1337;FilePart=".utf8)
  // Style, link and protection of the next printed cell. They live in one
  // value so a print transaction borrows them instead of assembling a copy.
  @exclusivity(unchecked) var attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
  var pen: TerminalStyle {
    get { attributes.style }
    set { captureRepeatAttributes(); attributes.style = newValue }
  }
  var currentLink: String? {
    get { attributes.link }
    set { captureRepeatAttributes(); attributes.link = newValue; attributes.linkID = nil }
  }
  var protectedOutput: Bool {
    get { attributes.protected }
    set { captureRepeatAttributes(); attributes.protected = newValue }
  }
  @exclusivity(unchecked) var replies = Data()
  @exclusivity(unchecked) var nextClipboardRequestID: UInt64 = 1
  @exclusivity(unchecked) var clipboardRequests: [(UInt64, Data)] = []
  @exclusivity(unchecked) var pendingClipboardRequests = Set<UInt64>()
  @exclusivity(unchecked) var palette = TerminalPalette()
  private var sixelPalette: [UInt32]?
  var sixelDisplayMode = false
  var sixelCursorRight = false
  var multipartImage: InlineImageDecoder?
  let downloads = TerminalDownloads()
  @exclusivity(unchecked) var title = ""
  @exclusivity(unchecked) var iconTitle = ""
  @exclusivity(unchecked) var titleStack: [(title: String?, icon: String?)] = []
  @exclusivity(unchecked) var identity = TerminalIdentity.helgeTerminal
  @exclusivity(unchecked) var colorSchemeReports = false
  @exclusivity(unchecked) var currentDirectory: String?
  @exclusivity(unchecked) var commandHistory = TerminalCommandHistory()
  @exclusivity(unchecked) var applicationCursor = false
  @exclusivity(unchecked) var applicationKeypad = false
  @exclusivity(unchecked) var bracketedPaste = false
  @exclusivity(unchecked) var focusReporting = false
  @exclusivity(unchecked) var reverseVideo = false
  @exclusivity(unchecked) var mouseMode = 0
  @exclusivity(unchecked) var mouseEncoding = 0
  @exclusivity(unchecked) var modifyOtherKeys = 0
  var sgrMouse: Bool { mouseEncoding == 1006 || mouseEncoding == 1016 }
  @exclusivity(unchecked) var tabs: [Bool]
  @exclusivity(unchecked) var tabsCleared = false
  @exclusivity(unchecked) var revision: UInt64 = 1
  @exclusivity(unchecked) var graphemeClustering = true
  @exclusivity(unchecked) private var hostGraphemeClustering = true
  /// BEL characters since the host last asked.
  @exclusivity(unchecked) private var bells: UInt32 = 0
  func takeBells() -> UInt32 { defer { bells = 0 }; return bells }
  @exclusivity(unchecked) var geometryEpoch: UInt64 = 1
  // TerminalDocument deliberately restarts row IDs after a hard reset. Keep a
  // monotonic identity generation so a pending search cannot mistake a fresh
  // post-RIS row for an old (id, revision) pair.
  @exclusivity(unchecked) private var searchGeneration: UInt64 = 1
  @exclusivity(unchecked) var documentEpoch: UInt64 = 1
  @exclusivity(unchecked) var historyEpoch: UInt64 = 1
  @exclusivity(unchecked) var screenEpoch: UInt64 = 1
  // Accepted matches stay in document identity space. Each keeps the row
  // revision that was proven at accept time, so a later change to an
  // unrelated row does not discard a valid decoration while a changed row can
  // never inherit one. Snapshot publication resolves these proofs against its
  // selected rows, so a non-view snapshot never paints a viewport-relative
  // coordinate onto unrelated live output.
  struct SearchHits {
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
  @exclusivity(unchecked) var searchHits: SearchHits?
  let graphics = KittyGraphicsStore()
  @exclusivity(unchecked) var cellPixelWidth = 8
  @exclusivity(unchecked) var cellPixelHeight = 16
  @exclusivity(unchecked) var lastPrinted: TerminalDocument.PrintedText?
  // REP prints with the attributes of the last printed cluster. Those are
  // nearly always the current `attributes`, so they are copied only when the
  // current ones are about to change (or when a cluster kept its own).
  @exclusivity(unchecked) private var lastPrintedAttributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
  @exclusivity(unchecked) private var repeatUsesCurrentAttributes = false
  private func captureRepeatAttributes() {
    guard repeatUsesCurrentAttributes else { return }
    lastPrintedAttributes = attributes
    repeatUsesCurrentAttributes = false
  }
  func forgetLastPrinted() {
    lastPrinted = nil
    lastPrintedAttributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
    repeatUsesCurrentAttributes = false
    repeatRemaining = 0
  }
  @exclusivity(unchecked) var repeatRemaining = 0
  @exclusivity(unchecked) var charsetSpecial = [false, false]
  @exclusivity(unchecked) var charsetSlot = 0
  // Decoded text waiting to be printed: the first `decodedScalarCount`
  // elements of a buffer that keeps its full size, so that decoding writes
  // into it directly. Those before `decodedScalarStart` are already printed.
  @exclusivity(unchecked) private var decodedScalars = [Unicode.Scalar](repeating: "\0", count: 2 * decodedFlushCount)
  @exclusivity(unchecked) private var decodedScalarCount = 0
  @exclusivity(unchecked) private var decodedScalarStart = 0
  /// Pending decoded scalars are printed once this many have gathered.
  private static let decodedFlushCount = 1024
  // A shorter ASCII run that follows undrained decoded text joins that text,
  // so mixed-script output reaches the document as one transaction.
  private static let minimumDirectASCIIRun = 16
  // CSI input itself is capped at 16 KiB, so this reusable numeric scratch is
  // bounded by the parser's existing sequence limit.
  @exclusivity(unchecked) var csiParameterScratch: [Int] = []
  @exclusivity(unchecked) private var csiBytes: [UInt8] = []
  // Preserve the old scalar-backed String limit: bytes >= 0x80 took two UTF-8 bytes.
  @exclusivity(unchecked) private var csiUTF8Count = 0

  init(columns: Int, rows: Int) {
    self.columns = max(1, min(4096, columns))
    self.rowCount = max(1, min(4096, rows))
    document = TerminalDocument(columns: self.columns, rows: self.rowCount)
    tabs = (0..<self.columns).map { $0 > 0 && $0.isMultiple(of: 8) }
    csiParameterScratch.reserveCapacity(16)
    csiBytes.reserveCapacity(64)
  }

  var screen: TerminalScreen {
    get { usingAlternate ? alternate : primary }
    set { if usingAlternate { alternate = newValue } else { primary = newValue } }
  }
  var horizontalMargins: (left: Int, right: Int) {
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
  func eraseStyle() -> TerminalStyle { pen.erased() }
  func changed(history: Bool = false, geometry: Bool = false,
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
  func advanceSearchGeneration() {
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
      applyPartialGraphicsScroll(result.partialScrollCount)
      let mutations = UInt64(result.consumedCount)
      revision &+= mutations; documentEpoch &+= mutations; screenEpoch &+= mutations
    }
    return count
  }
  private func apply(_ effect: TerminalDocument.PrintEffect, mutations: Int = 1) {
    guard mutations > 0 else { return }
    applyAppendedHistory(effect.appendedHistoryCount)
    applyPartialGraphicsScroll(effect.partialScrollCount)
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
  func resetClusterBoundary() { document.resetPrintCluster() }
  func tick(_ now: UInt64) {
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
    if graphics.transportPending {
      guard let outcome = graphics.completeTransport() else { return 0 }
      applyGraphicsOutcome(outcome)
    }
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
        case 0x00...0x07: finishDecodedText(); if byte == 0x07 { bells &+= 1 }
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
        if byte == 0x18 || byte == 0x1a {
          sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
          parser = .ground
        }
        else if byte == 0x07 { finishString(); parser = .ground }
        // String Terminator is the two-byte ESC \\ sequence. Keep parser
        // ownership in the string state until the following byte decides it;
        // switching to generic Escape would lose APC/OSC context.
        else if byte == 0x1b, sequenceBytes.count < 65_536 { sequenceBytes.append(0x1b) }
        else if byte == 0x1b {
          parser = .discardString(escaped: true, osc: true)
          sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
        }
        else if sequenceBytes.last == 0x1b && byte == 0x5c { sequenceBytes.removeLast(); finishString(); parser = .ground }
        else if sequenceBytes.count < 65_536 {
          sequenceBytes.append(byte)
          switch sequenceBytes.count {
          case 5:
            if sequenceBytes == Self.osc52Prefix {
              parser = .osc52(OSC52Decoder(acceptingWrites: pendingClipboardRequests.count < 4), escaped: false)
              sequenceBytes.removeAll(keepingCapacity: true)
            }
          case 10:
            if sequenceBytes == Self.oscFilePrefix {
              // An iTerm2 inline image: megabytes of base64, read as it comes.
              parser = .inlineImage(InlineImageDecoder(), escaped: false)
              sequenceBytes.removeAll(keepingCapacity: true)
              multipartImage = nil
            }
          case 14:
            if sequenceBytes == Self.oscFilePartPrefix {
              if let decoder = multipartImage {
                decoder.beginPart(); parser = .inlineImage(decoder, escaped: false)
              } else { parser = .discardString(escaped: false, osc: true) }
              sequenceBytes.removeAll(keepingCapacity: true)
            }
          default: break
          }
        }
        else {
          parser = .discardString(escaped: false, osc: true)
          sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
        }
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
      case .inlineImage(let decoder, let escaped):
        if byte == 0x18 || byte == 0x1a { multipartImage = nil; parser = .ground }
        else if byte == 0x07 || (escaped && byte == 0x5c) {
          parser = .ground
          if !decoder.waitsForFileEnd, let image = decoder.finish(download: { [self] in _ = downloads.enqueue(name: $0, data: $1) }) {
            showInlineImage(image.request, width: image.width, height: image.height, rgba: image.rgba, frames: image.frames)
          }
        } else if byte == 0x1b { parser = .inlineImage(decoder, escaped: true) }
        else if escaped { multipartImage = nil; parser = .escape; handleEscapedByte(byte) }
        else { decoder.push(byte) }
      case .dcsHeader:
        // A short header selects Sixel or one of our bounded DCS queries.
        if byte == 0x18 || byte == 0x1a { sequenceBytes.removeAll(keepingCapacity: true); parser = .ground }
        else if byte == 0x71, sequenceBytes.count == 1 && (sequenceBytes[0] == 0x24 || sequenceBytes[0] == 0x2b) {
          sequenceBytes.append(0x71); parser = .dcsQuery(escaped: false)
        }
        else if byte == 0x71, sequenceBytes.allSatisfy({ (0x30...0x3b).contains($0) }) {
          let header = String(decoding: sequenceBytes, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
          sequenceBytes.removeAll(keepingCapacity: true)
          parser = .sixel(SixelDecoder(header: header, palette: sixelPalette, background: palette.snapshotDefaultBackground), escaped: false)
        }
        else if sequenceBytes.count < 64, (0x20...0x3f).contains(byte) {
          sequenceBytes.append(byte)
        }
        else { sequenceBytes.removeAll(keepingCapacity: true); parser = .discardString(escaped: byte == 0x1b, osc: false) }
      case .dcsQuery(let escaped):
        if byte == 0x18 || byte == 0x1a { sequenceBytes.removeAll(keepingCapacity: true); parser = .ground }
        else if escaped && byte == 0x5c {
          finishQuery(); parser = .ground
        } else if byte == 0x1b { parser = .dcsQuery(escaped: true) }
        else if escaped { sequenceBytes.removeAll(keepingCapacity: true); parser = .escape; handleEscapedByte(byte) }
        else if (0x20...0x7e).contains(byte), sequenceBytes.count < TerminalQueries.maximumPayloadBytes + 2 {
          sequenceBytes.append(byte)
        } else { sequenceBytes.removeAll(keepingCapacity: true); parser = .discardString(escaped: false, osc: false) }
      case .sixel(let decoder, let escaped):
        if byte == 0x18 || byte == 0x1a { parser = .ground }
        else if escaped && byte == 0x5c {
          parser = .ground
          let picture = decoder.finish()
          sixelPalette = decoder.palette
          if let picture {
            showSixel(width: picture.width, height: picture.height, rgba: picture.rgba)
          }
        } else if byte == 0x1b { parser = .sixel(decoder, escaped: true) }
        else if escaped { parser = .escape; handleEscapedByte(byte) }
        else { decoder.push(byte) }
      case .apc:
        if byte == 0x18 || byte == 0x1a {
          graphics.abort()
          sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
          parser = .ground
        }
        else if sequenceBytes.last == 0x1b && byte == 0x5c { sequenceBytes.removeLast(); finishString(); parser = .ground }
        else if byte == 0x1b { if sequenceBytes.last != 0x1b { sequenceBytes.append(0x1b) } }
        else if sequenceBytes.last == 0x1b || sequenceBytes.count >= KittyGraphicsStore.maximumPacketBytes {
          graphics.abort()
          parser = .discardString(escaped: false, osc: false)
          sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
        }
        else if sequenceBytes.isEmpty && byte != 0x47 { parser = .discardString(escaped: false, osc: false) }
        else if byte >= 0x20 && byte != 0x7f { sequenceBytes.append(byte) }
      case .discardString(let escaped, let osc):
        if byte == 0x18 || byte == 0x1a { parser = .ground }
        else if osc && byte == 0x07 { parser = .ground }
        else if escaped && byte == 0x5c { parser = .ground }
        else { parser = .discardString(escaped: byte == 0x1b, osc: osc) }
      }
      offset += 1
      if graphics.transportPending { flushDecodedScalars(); return offset }
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
    case 0x5d: sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536); parser = .osc
    case 0x5f: sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536); parser = .apc
    case 0x50: sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536); parser = .dcsHeader
    // SOS and PM carry strings this terminal does not interpret. They are
    // consumed up to ST so their bodies never reach the screen.
    case 0x58, 0x5e: parser = .discardString(escaped: false, osc: false)
    case 0x28: parser = .charset(0)
    case 0x29: parser = .charset(1)
    // Other intermediates (`ESC #`, `ESC *`, `ESC %`, `ESC SP` …) take a
    // final byte; only DECALN among them is implemented.
    case 0x20...0x2f: parser = .escapeIntermediate(byte)
    case 0x37: saveCursor()
    case 0x38: restoreCursor()
    case 0x36: horizontalIndex(reverse: true)
    case 0x39: horizontalIndex(reverse: false)
    case 0x56: captureRepeatAttributes(); attributes.isoProtected = true; isoEraseProtection = true
    case 0x57: captureRepeatAttributes(); attributes.isoProtected = false
    case 0x48: tabs[screen.cursorColumn] = true
    // IND advances within the scroll region but, unlike LF/VT/FF, never
    // applies LNM's carriage return.
    case 0x44: resetClusterBoundary(); index(reverse: false)
    case 0x4d: reverseIndex()
    // NEL decides scrolling from the incoming column. Returning first could
    // move a cursor outside the horizontal margins into the scroll region.
    case 0x45: lineFeed(); carriageReturn()
    case 0x63: reset()
    case 0x3d: applicationKeypad = true
    case 0x3e: applicationKeypad = false
    // DECID: the older request for the primary device attributes.
    case 0x5a: replies.append(contentsOf: Self.primaryDeviceAttributes.utf8)
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
    s.leftMargin = 0; s.rightMargin = columns - 1
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

  func index(reverse: Bool) {
    if graphics.hasPlacements {
      let s = screen, margins = horizontalMargins
      if (margins.left != 0 || margins.right != columns - 1),
        s.cursorRow == (reverse ? s.topMargin : s.bottomMargin),
        (margins.left...margins.right).contains(s.cursorColumn) {
        graphics.scrollRectangle(alternate: usingAlternate, rows: s.rows.map(\.id), top: s.topMargin, bottom: s.bottomMargin,
          left: margins.left, right: margins.right, amount: 1, up: !reverse)
      }
    }
    let appendedCount = document.index(usingAlternate: usingAlternate, reverse: reverse,
                              leftRightMargins: leftRightMargins, eraseStyle: eraseStyle())
    applyAppendedHistory(appendedCount)
    changed(history: !reverse && !usingAlternate)
  }
  private func applyPartialGraphicsScroll(_ count: Int) {
    guard count > 0, graphics.hasPlacements else { return }
    let s = screen, margins = horizontalMargins
    graphics.scrollRectangle(alternate: usingAlternate, rows: s.rows.map(\.id), top: s.topMargin, bottom: s.bottomMargin,
      left: margins.left, right: margins.right, amount: count, up: true)
  }
  private func lineFeed() {
    resetClusterBoundary()
    index(reverse: false)
    if newlineMode { carriageReturn() }
  }
  private func carriageReturn() { document.carriageReturn(usingAlternate: usingAlternate, leftRightMargins: leftRightMargins); changed() }
  private func backspace() {
    resetClusterBoundary()
    var s = screen
    if s.pendingWrap && autoWrap && (reverseWrap || reverseWrapUnlimited) {
      s.pendingWrap = false
    } else { moveCursorBackward(&s, count: 1) }
    s.pendingWrap = false; screen = s; changed()
  }
  func moveCursorBackward(_ s: inout TerminalScreen, count: Int) {
    let margins = horizontalMargins
    if autoWrap && reverseWrapUnlimited && (s.topMargin...s.bottomMargin).contains(s.cursorRow)
      && (margins.left...margins.right).contains(s.cursorColumn) {
      // The margin rectangle is one ring of cells: any count is a single modulo.
      let width = margins.right - margins.left + 1
      let cells = (s.bottomMargin - s.topMargin + 1) * width
      let position = (s.cursorRow - s.topMargin) * width + (s.cursorColumn - margins.left)
      let target = (position - count % cells + cells) % cells
      s.cursorRow = s.topMargin + target / width; s.cursorColumn = margins.left + target % width
      return
    }
    var remaining = count
    // At most one pass over the visible page, even for an enormous parameter.
    for _ in 0...rowCount {
      let left = s.cursorColumn >= margins.left ? margins.left : 0
      let amount = min(remaining, max(0, s.cursorColumn - left))
      s.cursorColumn -= amount; remaining -= amount
      guard remaining > 0, autoWrap, reverseWrap || reverseWrapUnlimited else { break }
      if s.cursorRow > s.topMargin {
        guard reverseWrapUnlimited || s.rows[s.cursorRow - 1].softWrapped else { break }
        s.cursorRow -= 1
      } else if reverseWrapUnlimited && s.cursorRow == s.topMargin {
        // Repeating a complete traversal returns to this same position.
        // Reduce huge CUB parameters without an input-controlled loop.
        let pageCells = (s.bottomMargin - s.topMargin + 1) * (margins.right - margins.left + 1)
        if s.cursorColumn == margins.left { remaining %= pageCells }
        if remaining == 0 { break }
        s.cursorRow = s.bottomMargin
      } else { break }
      s.cursorColumn = margins.right; remaining -= 1
      if remaining == 0 { break }
    }
  }
  func tab(_ reverse: Bool = false, count: Int = 1) {
    resetClusterBoundary()
    if !reverse && cursesTabWrap && autoWrap && screen.pendingWrap {
      index(reverse: false)
      var next = screen; next.cursorColumn = 0; screen = next
    }
    var s = screen
    let previousColumn = s.cursorColumn
    // CBT searches page tab stops to the left edge. HT/CHT still stop at
    // the right margin, matching DEC terminals and xterm.
    let left = 0, right = writeBounds(s.cursorColumn).right
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
    if reverse || s.cursorColumn != previousColumn { s.pendingWrap = false }
    screen = s; changed()
  }
  private func reverseIndex() { index(reverse: true) }
  func saveCursor() {
    var s = screen
    s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedPendingWrap = s.pendingWrap
    s.savedRendition = SavedRendition(origin: originMode, style: pen, link: currentLink, linkID: attributes.linkID,
      protected: protectedOutput, charsetSpecial: charsetSpecial, charsetSlot: charsetSlot)
    screen = s
  }
  func restoreCursor() {
    var s = screen
    let saved = s.savedRendition
    originMode = saved.origin; pen = saved.style; currentLink = saved.link; attributes.linkID = saved.linkID
    charsetSpecial = saved.charsetSpecial; charsetSlot = saved.charsetSlot
    protectedOutput = saved.protected
    s.cursorRow = min(rowCount - 1, s.savedRow); s.cursorColumn = min(columns - 1, s.savedColumn)
    if originMode {
      s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin)
      s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right)
    }
    s.pendingWrap = s.savedPendingWrap && autoWrap; screen = s; changed()
  }
  private func reset() {
    commandHistory = TerminalCommandHistory()
    selectionDocumentGeneration = UUID(); selection.reset(); pendingSelectionRevision = nil
    graphics.clear()
    document = TerminalDocument(columns: columns, rows: rowCount)
    advanceSearchGeneration()
    usingAlternate = false; viewAnchor = nil; viewOffset = 0
    pen = TerminalStyle(); originMode = false; leftRightMargins = false; autoWrap = true
    reverseWrap = false; reverseWrapUnlimited = false; savedPrivateModes.removeAll()
    cursesTabWrap = false
    insertMode = false; newlineMode = false; protectedOutput = false; syncDeadline = nil
    attributes.isoProtected = false
    isoEraseProtection = false
    applicationCursor = false; applicationKeypad = false; bracketedPaste = false
    focusReporting = false; reverseVideo = false; mouseMode = 0; mouseEncoding = 0; modifyOtherKeys = 0
    currentLink = nil
    palette.reset()
    refreshGraphicsPalette()
    colorSchemeReports = false; titleStack.removeAll(keepingCapacity: true)
    multipartImage = nil
    downloads.clear()
    sixelPalette = nil; sixelDisplayMode = false; sixelCursorRight = false
    applyGraphemeClustering(hostGraphemeClustering)
    charsetSpecial = [false, false]; charsetSlot = 0
    forgetLastPrinted()
    tabs = (0..<columns).map { $0 > 0 && $0.isMultiple(of: 8) }
    tabsCleared = false
    resetClusterBoundary()
    changed(history: true)
  }
  var colorSchemeReply: String { "\u{1b}[?997;\(palette.schemeIsDark ? 1 : 2)n" }
  func setIdentity(_ value: TerminalIdentity) { identity = value }
  var selectionScreen: TerminalSelectionScreen { usingAlternate ? .alternate : .primary }
  func validatedSelection() {
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
      primarySelection: selection.reflowInput(.primary), alternateSelection: selection.reflowInput(.alternate),
      graphicsAnchors: graphics.reflowAnchors, trackedRows: commandHistory.rowIDs)
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
      graphics.applyReflow(replacement.mapping.graphics)
      commandHistory.remap(replacement.mapping.rows)
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
  func commands() -> [TerminalCommandRecord] { commandHistory.records }
  func navigateCommand(older: Bool) {
    guard !usingAlternate else { return }
    let top = history.count - resolveViewportAnchor(clamp: true)
    let positions = commandHistory.records.compactMap { record -> Int? in
      if let index = history.index(ofRowID: record.promptRowID) { return index }
      return primary.rows.firstIndex(where: { $0.id == record.promptRowID }).map { history.count + $0 }
    }
    let target = older ? positions.filter { $0 < top }.max() : positions.filter { $0 > top }.min()
    if let target {
      setViewOffset(max(0, history.count - target)); changed(document: false, screen: false)
    } else if !older { followTail() }
  }
  func followTail() { guard !usingAlternate else { return }; viewAnchor = nil; viewOffset = 0; viewportWasClamped = false; changed(document: false, screen: false) }
  private func setViewOffset(_ offset: Int) {
    let bounded = min(history.count, max(0, offset)); viewOffset = bounded
    viewAnchor = bounded > 0 ? history[history.count - bounded].id : nil; viewportWasClamped = false
  }
  @discardableResult func resolveViewportAnchor(clamp: Bool) -> Int {
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
  func enforceHistoryLimits() {
    if document.trimHistory(rowLimit: historyLimit, byteLimit: historyByteLimit) > 0 { didEvictHistory() }
  }
  private func didEvictHistory() {
    if let retainedAnchor = viewAnchor,
       history.index(ofRowID: retainedAnchor) == nil,
       !primary.rows.contains(where: { $0.id == retainedAnchor }) {
      clampViewportAfterEviction()
    }
  }
  func pruneGraphicsAnchors() {
    guard graphics.hasPlacements else { return }
    // Retired placements retain only bounded (<= 256) row IDs, never rows.
    // Rebuilding this membership set is therefore deferred to graphics seams.
    let screens = Set(primary.rows.map(\.id) + alternate.rows.map(\.id))
    graphics.pruneAnchors(isRetained: { screens.contains($0) || history.index(ofRowID: $0) != nil })
  }
  struct HistoryVirtualOrigin {
    var rowID: UInt64
    var rowOffset: Int
    var columnRowID: UInt64
    var column: Int
  }
  struct VirtualOriginCache {
    let geometry: UInt64
    let placements: [UInt64]
    var tail: UInt64?
    var origins: [UInt64: HistoryVirtualOrigin] = [:]
  }
  // Retained history rows are immutable. Cache only each prototype's two
  // extrema and scan newly appended rows, not all history after live output.
  // Rebuild if reflow/prototype changes or eviction removes an extremum/tail.
  // At most 256 entries; no cached rows, cells or per-history-row metadata.
  var virtualOriginCache: VirtualOriginCache?
  /// Mode 2027. Set: a grapheme cluster, such as an emoji with a skin tone,
  /// takes the cells of one character. Reset: each code point with a width
  /// takes its own cells, which is what a program that sums `wcwidth` expects.
  func applyGraphemeClustering(_ enabled: Bool) {
    graphemeClustering = enabled
    document.setGraphemeClustering(enabled)
  }
  /// The host's choice: the state the mode starts in and a reset returns to.
  func setGraphemeClusteringDefault(_ enabled: Bool) {
    hostGraphemeClustering = enabled
    applyGraphemeClustering(enabled)
  }
  func setColorScheme(_ value: TerminalColorScheme) {
    let changed = palette.hostScheme != value
    palette.setScheme(value)
    refreshGraphicsPalette()
    if changed && colorSchemeReports { replies.append(contentsOf: colorSchemeReply.utf8) }
    self.changed(document: false)
  }
  /// Every palette change calls this; a graphics command only finds the
  /// initial palette still unsent.
  var graphicsPaletteStale = true
  func refreshGraphicsPalette() {
    graphicsPaletteStale = false
    graphics.setPalette(palette.snapshotGraphicsPalette)
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
      let saved = (current.savedRow, current.savedColumn, current.savedPendingWrap, current.savedRendition)
      let keyboard = (current.keyboardFlags, current.keyboardStack)
      let cursorAppearance = (current.cursorVisible, current.cursorShape)
      current = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns)
      current.topMargin = margins.0; current.bottomMargin = margins.1
      current.leftMargin = margins.2; current.rightMargin = margins.3
      current.savedRow = saved.0; current.savedColumn = saved.1; current.savedPendingWrap = saved.2
      current.savedRendition = saved.3
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
      bracketedPaste: bracketedPaste, focusReporting: focusReporting, kittyFlags: screen.keyboardFlags,
      modifyOtherKeys: modifyOtherKeys)
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
  /// When the next animation frame on screen is due, in the emulator's
  /// milliseconds, or nil when nothing on screen is animating.
  func nextFrameTime(now: UInt64) -> UInt64? {
    tick(now)
    return graphics.nextFrameTime(alternate: usingAlternate)
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
    multipartImage = nil
    // OSC 52 writes require BEL/ST framing. EOF is an abort, never an
    // implicit successful terminator.
    parser = .ground
  }
  var hasPendingWork: Bool { repeatRemaining > 0 || graphics.transportPending }
  var pendingDownloads: [TerminalPendingDownload] { downloads.pending }
  func resolveDownload(_ id: UInt64, take: Bool) -> TerminalDownload? { downloads.resolve(id, take: take) }
  func takeDownloads() -> [TerminalDownload] { downloads.takeAll() }
  func enableAsynchronousGraphics() { graphics.asynchronousTransport = true }
  func whenGraphicsReady(_ callback: @escaping () -> Void) -> Bool {
    guard graphics.transportPending else { return false }
    graphics.whenTransportReady(callback); return true
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
  /// At most 64 rows, 32,768 cells and 65,536 UTF-16 units per owner turn.
  /// Lookup uses the history row index; no full history array is constructed.
  func accessibilityHistoryPage(_ request: TerminalHistoryPageRequest) -> TerminalHistoryPage? {
    let historyCount = usingAlternate ? 0 : history.count
    let screenRows = usingAlternate ? alternate.rows : primary.rows
    let total = historyCount + screenRows.count
    func index(_ cursor: TerminalHistoryCursor) -> Int? {
      guard cursor.document == selectionDocumentGeneration, cursor.alternate == usingAlternate else { return nil }
      if !usingAlternate, let index = history.index(ofRowID: cursor.row) { return index }
      return screenRows.firstIndex(where: { $0.id == cursor.row }).map { historyCount + $0 }
    }
    let backwards: Bool, start: Int
    switch request {
    case .latest: backwards = true; start = total - 1
    case .older(let cursor):
      guard let anchor = index(cursor) else { return nil }
      backwards = true; start = anchor - 1
    case .newer(let cursor):
      guard let anchor = index(cursor) else { return nil }
      backwards = false; start = anchor + 1
    }
    var position = start, cellCount = 0, textCount = 0
    var result: [(Int, TerminalHistoryPage.Row)] = []
    while (0..<total).contains(position), result.count < 64 {
      let row = position < historyCount ? history[position] : screenRows[position - historyCount]
      guard cellCount + row.count <= 32_768, textCount < 65_472 else { break }
      var text = "", pendingSpaces = 0, rowTextCount = 0, truncated = false
      for cell in row.cells {
        if cell.kind == 3 || cell.kind == 4 { continue }
        if cell.kind == 0 { pendingSpaces += 1; continue }
        let remaining = 65_472 - textCount - rowTextCount
        guard remaining > pendingSpaces else { truncated = true; break }
        text += String(repeating: " ", count: pendingSpaces)
        rowTextCount += pendingSpaces
        pendingSpaces = 0
        let room = 65_472 - textCount - rowTextCount
        let units = Array(cell.text.utf16.prefix(room + 1))
        let clipped = units.count > room
        let admitted = units.prefix(room)
        let safe = admitted.last.map { (0xD800...0xDBFF).contains($0) } == true ? admitted.dropLast() : admitted
        text += String(decoding: safe, as: UTF16.self)
        rowTextCount += safe.count
        if clipped { truncated = true; break }
      }
      let cursor = TerminalHistoryCursor(document: selectionDocumentGeneration, alternate: usingAlternate, row: row.id)
      result.append((position, TerminalHistoryPage.Row(cursor: cursor, text: text, truncated: truncated)))
      cellCount += row.count
      textCount += rowTextCount + 1
      position += backwards ? -1 : 1
    }
    if backwards { result.reverse() }
    return TerminalHistoryPage(rows: result.map(\.1), hasOlder: (result.first?.0 ?? 0) > 0,
      hasNewer: (result.last?.0 ?? total - 1) < total - 1)
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
  func searchSource() -> TerminalSearchSource {
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
  func createSearch(_ query: String, options: TerminalSearchOptions = .init()) -> TerminalSearchToken? {
    searchHits = nil
    return try? TerminalSearchToken(TerminalSearchTask(query: query, source: searchSource(), options: options))
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
      revealSearchMatch(matches[matches.count - 1])
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
  private func revealSearchMatch(_ match: TerminalSearchMatch) {
    // Boundary rows remain in the proof chain, but the viewport must reveal
    // the actual match. Zero-width matched newlines still count as content.
    let matchedRow = match.spans.firstIndex { !$0.span.isBoundaryOnly } ?? 0
    let anchor = match.anchor + matchedRow
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
      revealSearchMatch(hits.matches[index])
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
}

extension TerminalEmulator {
  func recoveryCapture(maximumBytes: Int) -> TerminalRecoveryCapture {
    TerminalRecoveryCapture(history: history, primary: primary.rows, limit: historyLimit, maximumBytes: maximumBytes)
  }
  func seedRecovery(_ text: String) {
    let saved = attributes
    pen.flags |= 2
    // Literal Unicode only. ESC, C0/C1 and DEL cannot become parser actions,
    // OSC clipboard requests, image transports or shell input on restoration.
    for scalar in text.unicodeScalars {
      if scalar.value == 10 { carriageReturn(); lineFeed() }
      else if scalar.value == 9 { for _ in 0..<8 { put(" ") } }
      else if scalar.value >= 32 && !(127...159).contains(scalar.value) { put(scalar) }
    }
    if primary.cursorColumn != 0 { carriageReturn(); lineFeed() }
    attributes = saved
    forgetLastPrinted()
    changed(history: true)
  }
}
extension TerminalEmulator {
  var handoffBoundary: Bool {
    guard case .ground = parser else { return false }
    return utf8.isIdle && repeatRemaining == 0 && syncDeadline == nil
  }
  /// The switches a handoff carries, under their names in its `modes`. A
  /// name stays with its switch for good: another build reads it.
  nonisolated(unsafe) private static let handoffSwitches: [(name: String, value: ReferenceWritableKeyPath<TerminalEmulator, Bool>)] = [
    ("origin", \.originMode), ("leftRightMargins", \.leftRightMargins), ("autoWrap", \.autoWrap),
    ("reverseWrap", \.reverseWrap), ("reverseWrapUnlimited", \.reverseWrapUnlimited),
    ("cursesTabWrap", \.cursesTabWrap), ("isoEraseProtection", \.isoEraseProtection),
    ("insert", \.insertMode), ("newline", \.newlineMode),
    ("applicationCursor", \.applicationCursor), ("applicationKeypad", \.applicationKeypad),
    ("bracketedPaste", \.bracketedPaste), ("focusReporting", \.focusReporting),
    ("reverseVideo", \.reverseVideo), ("colorSchemeReports", \.colorSchemeReports),
    ("graphemeClustering", \.graphemeClustering),
    ("sixelDisplay", \.sixelDisplayMode), ("sixelCursorRight", \.sixelCursorRight),
  ]
  /// The same for settings with a number, and the numbers each may have.
  nonisolated(unsafe) private static let handoffNumbers: [(name: String, value: ReferenceWritableKeyPath<TerminalEmulator, Int>, allowed: Set<Int>)] = [
    ("mouse", \.mouseMode, [0, 9, 1000, 1002, 1003]),
    ("mouseEncoding", \.mouseEncoding, [0, 1005, 1006, 1015, 1016]),
    ("modifyOtherKeys", \.modifyOtherKeys, [0, 1, 2]),
  ]
  private func handoffScreen(_ screen: TerminalScreen) -> TerminalHandoffState.Screen {
    let saved = screen.savedRendition
    return TerminalHandoffState.Screen(
      cursorRow: screen.cursorRow, cursorColumn: screen.cursorColumn, pendingWrap: screen.pendingWrap,
      savedRow: screen.savedRow, savedColumn: screen.savedColumn, savedPendingWrap: screen.savedPendingWrap,
      savedOrigin: saved.origin, savedStyle: .init(saved.style), savedLink: saved.link,
      savedProtected: saved.protected, savedCharsetSpecial: saved.charsetSpecial, savedCharsetSlot: saved.charsetSlot,
      keyboardFlags: screen.keyboardFlags, keyboardStack: screen.keyboardStack,
      cursorVisible: screen.cursorVisible, cursorShape: screen.cursorShape,
      top: screen.topMargin, bottom: screen.bottomMargin, left: screen.leftMargin, right: screen.rightMargin)
  }
  private func restore(_ state: TerminalHandoffState.Screen, into screen: inout TerminalScreen) {
    let lastRow = rowCount - 1, lastColumn = columns - 1
    func row(_ value: Int) -> Int { min(lastRow, max(0, value)) }
    func column(_ value: Int) -> Int { min(lastColumn, max(0, value)) }
    screen.cursorRow = row(state.cursorRow); screen.cursorColumn = column(state.cursorColumn)
    screen.pendingWrap = state.pendingWrap
    screen.savedRow = row(state.savedRow); screen.savedColumn = column(state.savedColumn)
    screen.savedPendingWrap = state.savedPendingWrap
    screen.savedRendition = SavedRendition(
      origin: state.savedOrigin, style: state.savedStyle.style, link: state.savedLink, linkID: nil,
      protected: state.savedProtected,
      charsetSpecial: state.savedCharsetSpecial.count == 2 ? state.savedCharsetSpecial : [false, false],
      charsetSlot: state.savedCharsetSlot == 1 ? 1 : 0)
    screen.keyboardFlags = state.keyboardFlags
    screen.keyboardStack = Array(state.keyboardStack.suffix(16))
    screen.cursorVisible = state.cursorVisible; screen.cursorShape = state.cursorShape
    if state.top < state.bottom, state.bottom <= lastRow, state.top >= 0 {
      screen.topMargin = state.top; screen.bottomMargin = state.bottom
    }
    if state.left < state.right, state.right <= lastColumn, state.left >= 0 {
      screen.leftMargin = state.left; screen.rightMargin = state.right
    }
  }
  func captureHandoff() -> TerminalHandoff {
    var content = TerminalHandoffContent()
    content.paint(history: history, screen: primary.rows)
    if usingAlternate {
      content.paint(alternate: alternate.rows)
    }
    content.finish()
    var state = TerminalHandoffState()
    state.usingAlternate = usingAlternate
    state.primary = handoffScreen(primary)
    state.alternate = handoffScreen(alternate)
    state.pen = .init(attributes.style); state.penLink = attributes.link; state.penProtected = attributes.protected
    state.charsetSpecial = charsetSpecial; state.charsetSlot = charsetSlot
    for entry in Self.handoffSwitches { state.modes[entry.name] = self[keyPath: entry.value] ? 1 : 0 }
    for entry in Self.handoffNumbers { state.modes[entry.name] = self[keyPath: entry.value] }
    state.savedPrivateModes = Dictionary(uniqueKeysWithValues: savedPrivateModes.map { (String($0.key), $0.value) })
    state.tabs = tabs; state.tabsCleared = tabsCleared
    state.title = title; state.iconTitle = iconTitle; state.directory = currentDirectory
    state.colors = palette.handoffCommands
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = (try? encoder.encode(state)) ?? Data()
    return TerminalHandoff(columns: columns, rows: rowCount, content: content.bytes, state: encoded)
  }
  func restoreHandoff(_ handoff: TerminalHandoff, now: UInt64) -> Bool {
    guard handoff.columns == columns, handoff.rows == rowCount else { return false }
    handoff.content.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var offset = 0, stalled = 0
      while offset < buffer.count, stalled < 4 {
        let consumed = feed(base + offset, count: buffer.count - offset, now: now)
        offset += consumed
        stalled = consumed == 0 ? stalled + 1 : 0
      }
    }
    // Painting is this terminal's own text, and nothing in it asks a question.
    replies.removeAll(keepingCapacity: true)
    bells = 0
    defer { forgetLastPrinted(); changed(history: true) }
    guard let state = try? JSONDecoder().decode(TerminalHandoffState.self, from: handoff.state), state.version == 1 else {
      if usingAlternate { usingAlternate = false }
      return false
    }
    usingAlternate = state.usingAlternate
    var screen = primary; restore(state.primary, into: &screen); primary = screen
    screen = alternate; restore(state.alternate, into: &screen); alternate = screen
    attributes = TerminalDocument.PrintAttributes(style: state.pen.style, link: state.penLink, protected: state.penProtected)
    if state.charsetSpecial.count == 2 { charsetSpecial = state.charsetSpecial }
    charsetSlot = state.charsetSlot == 1 ? 1 : 0
    for entry in Self.handoffSwitches {
      if let value = state.modes[entry.name] { self[keyPath: entry.value] = value != 0 }
    }
    for entry in Self.handoffNumbers {
      if let value = state.modes[entry.name], entry.allowed.contains(value) { self[keyPath: entry.value] = value }
    }
    savedPrivateModes = Dictionary(uniqueKeysWithValues: state.savedPrivateModes.compactMap { key, value in
      Int(key).map { ($0, value) }
    })
    if state.tabs.count == columns { tabs = state.tabs; tabsCleared = state.tabsCleared }
    title = sanitizedTitle(state.title); iconTitle = sanitizedTitle(state.iconTitle)
    currentDirectory = state.directory
    for command in state.colors where command.count == 2 { palette.applyOSC(command: command[0], value: command[1]) }
    graphicsPaletteStale = true
    return true
  }
}

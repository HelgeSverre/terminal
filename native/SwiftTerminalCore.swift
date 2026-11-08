import Foundation

// Swift implementation of the terminal core ABI.  The public C-shaped surface is
// deliberately thin: the state machine owns parsing, grid mutation, history,
// snapshots, and input encoding so neither Session nor the renderer needs to
// duplicate terminal policy.

private typealias SwiftStyle = TerminalStyle
private typealias SwiftCell = TerminalCell
private typealias SwiftRow = TerminalRow
private typealias SwiftScreen = TerminalScreen

private func decSpecialGraphics(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
  let mapping: [UInt32: UInt32] = [
    0x5f: 0x00a0, 0x60: 0x25c6, 0x61: 0x2592, 0x62: 0x2409, 0x63: 0x240c, 0x64: 0x240d, 0x65: 0x240a,
    0x66: 0x00b0, 0x67: 0x00b1, 0x68: 0x2424, 0x69: 0x240b, 0x6a: 0x2518, 0x6b: 0x2510, 0x6c: 0x250c, 0x6d: 0x2514,
    0x6e: 0x253c, 0x6f: 0x23ba, 0x70: 0x23bb, 0x71: 0x2500, 0x72: 0x23bc, 0x73: 0x23bd, 0x74: 0x251c, 0x75: 0x2524,
    0x76: 0x2534, 0x77: 0x252c, 0x78: 0x2502, 0x79: 0x2264, 0x7a: 0x2265, 0x7b: 0x03c0, 0x7c: 0x2260, 0x7d: 0x00a3, 0x7e: 0x00b7,
  ]
  return mapping[scalar.value].flatMap(Unicode.Scalar.init) ?? scalar
}

private enum SwiftParserState { case ground, escape, charset(Int), csi, osc, osc52(OSC52Decoder, escaped: Bool), apc, discardString(escaped: Bool, osc: Bool) }

private final class SwiftCoreSearchToken {
  // The task contains only immutable page snapshots while it is with the
  // worker. The core is consulted exclusively by fill/accept on its owner.
  var task: SwiftSearchTask
  init(_ task: SwiftSearchTask) { self.task = task }
}

// Owns byte storage for a synchronous ABI snapshot callback.  The callback
// promise is deliberately narrow: clients copy before return, so storage can
// be released immediately afterwards.
private final class SwiftBorrowedCells {
  var text: [UnsafeMutablePointer<UInt8>] = []
  var links: [UnsafeMutablePointer<UInt8>] = []
  deinit { text.forEach { $0.deallocate() }; links.forEach { $0.deallocate() } }
  func copy(_ string: String, into target: inout [UnsafeMutablePointer<UInt8>]) -> UnsafePointer<UInt8>? {
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

// This view is valid only during the synchronous C ABI feed call. It feeds
// the reusable decoder scratch; Document continues to receive ArraySlice.
private struct ASCIIInputScalars: RandomAccessCollection {
  typealias Element = Unicode.Scalar
  typealias Index = Int

  let bytes: UnsafePointer<UInt8>
  let startIndex = 0
  let endIndex: Int

  init(_ bytes: UnsafePointer<UInt8>, count: Int) {
    self.bytes = bytes
    endIndex = count
  }

  @inline(__always) subscript(position: Int) -> Unicode.Scalar {
    Unicode.Scalar(bytes[position])
  }
}

private final class SwiftTerminalCore {
  private enum DisplayClearAction: UInt32 {
    case ignoredAlternate = 0, cleared = 1, redrawPrompt = 2
  }
  private(set) var columns: Int
  private(set) var rowCount: Int
  private var document: TerminalDocument
  private var primary: SwiftScreen { get { document.primary } set { document.primary = newValue } }
  private var alternate: SwiftScreen { get { document.alternate } set { document.alternate = newValue } }
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
  private var protectedOutput = false
  private var syncDeadline: UInt64?
  private var clock: UInt64 = 0
  private var parser = SwiftParserState.ground
  private var utf8 = SwiftUnicode.UTF8Decoder()
  private var sequence = ""
  private var pen = SwiftStyle()
  private var currentLink: String?
  private var replies = Data()
  private var nextClipboardRequestID: UInt64 = 1
  private var clipboardRequests: [(UInt64, Data)] = []
  private var pendingClipboardRequests = Set<UInt64>()
  private var title = ""
  private var applicationCursor = false
  private var applicationKeypad = false
  private var bracketedPaste = false
  private var focusReporting = false
  private var reverseVideo = false
  private var cursorVisible = true
  private var cursorShape: UInt8 = 0
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
  private var searchHit: (stamp: SwiftSearchStamp, spans: [SwiftSearchResolvedSpan])?
  private let graphics = KittyGraphicsStore()
  private var cellPixelWidth = 8
  private var cellPixelHeight = 16
  private var lastPrinted = ""
  private var lastPrintedStyle = SwiftStyle()
  private var lastPrintedLink: String?
  private var lastPrintedFlags: UInt8 = 0
  private var repeatRemaining = 0
  private var charsetSpecial = [false, false]
  private var charsetSlot = 0
  private var decodedScalars: [Unicode.Scalar] = []
  private var decodedScalarStart = 0
  private static let minimumASCIIInputRun = 16
  // CSI input itself is capped at 16 KiB, so this reusable numeric scratch is
  // bounded by the parser's existing sequence limit.
  private var csiParameterScratch: [Int] = []

  init(columns: Int, rows: Int) {
    self.columns = max(1, min(4096, columns))
    self.rowCount = max(1, min(4096, rows))
    document = TerminalDocument(columns: self.columns, rows: self.rowCount)
    decodedScalars.reserveCapacity(1024)
    csiParameterScratch.reserveCapacity(16)
  }

  private var screen: SwiftScreen {
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
  private func eraseStyle() -> SwiftStyle { pen.erased() }
  private func changed(history: Bool = false, geometry: Bool = false,
                       document: Bool = true, screen: Bool = true) {
    revision &+= 1
    // Geometry changes alter column coordinates. Ordinary document edits are
    // instead resolved lazily against each accepted row's revision, retaining
    // hits through unrelated output exactly as the Rust owner does.
    if geometry { searchHit = nil }
    if document { documentEpoch &+= 1 }
    if screen { screenEpoch &+= 1 }
    if history { historyEpoch &+= 1 }
    if geometry { geometryEpoch &+= 1 }
  }
  private func advanceSearchGeneration() {
    searchGeneration &+= 1
    searchHit = nil
  }
  private func finishDecodedText() {
    // Escape/control input interrupts an incomplete UTF-8 sequence. Emit its
    // maximal invalid prefix now so that the control byte is still parsed.
    flushDecodedScalars()
    emitDecoded(utf8.finish())
    flushDecodedScalars()
  }
  @inline(__always)
  private func emitDecoded(_ emission: SwiftUnicode.UTF8Decoder.Emission) {
    switch emission {
    case .none: break
    case .one(let scalar): appendDecoded(charsetSpecial[charsetSlot] ? decSpecialGraphics(scalar) : scalar)
    case .two(let first, let second):
      appendDecoded(charsetSpecial[charsetSlot] ? decSpecialGraphics(first) : first)
      appendDecoded(charsetSpecial[charsetSlot] ? decSpecialGraphics(second) : second)
    }
  }
  private func appendDecoded(_ scalar: Unicode.Scalar) {
    decodedScalars.append(scalar)
    if decodedScalars.count - decodedScalarStart == 1024 { flushDecodedScalars() }
  }
  private func flushDecodedScalars() {
    while decodedScalarStart < decodedScalars.count {
      let batch = document.print(decodedScalars[decodedScalarStart...], usingAlternate: usingAlternate,
                                 leftRightMargins: leftRightMargins, autoWrap: autoWrap,
                                 insertMode: insertMode,
                                 attributes: TerminalDocument.PrintAttributes(style: pen, link: currentLink, protected: protectedOutput))
      guard batch.consumedScalarCount > 0 else { return }
      decodedScalarStart += batch.consumedScalarCount
      apply(batch.effect, mutations: batch.mutationCount)
    }
    decodedScalars.removeAll(keepingCapacity: true)
    decodedScalarStart = 0
  }
  // Long printable ASCII bypasses per-byte UTF-8 decoding, but remains in the
  // same bounded scratch array and therefore reaches the specialized
  // ArraySlice document transaction used by every other decoder emission.
  private func appendASCIIInput(_ bytes: UnsafePointer<UInt8>, offset: Int, limit: Int) -> Int? {
    guard case .ground = parser, utf8.isIdle, !charsetSpecial[charsetSlot] else { return nil }
    var count = 0
    while offset + count < limit {
      let byte = bytes[offset + count]
      guard (0x20...0x7e).contains(byte) else { break }
      count += 1
    }
    guard count > 0 else { return nil }
    if count < Self.minimumASCIIInputRun {
      // Consume the known short range at once so ANSI/Unicode-adjacent text
      // cannot pay a triangular sequence of run scans.
      for index in 0..<count { emitDecoded(utf8.push(bytes[offset + index])) }
      return count
    }

    var admitted = 0
    while admitted < count {
      let available = 1024 - (decodedScalars.count - decodedScalarStart)
      if available == 0 {
        flushDecodedScalars()
        continue
      }
      let amount = min(available, count - admitted)
      decodedScalars.append(contentsOf: ASCIIInputScalars(bytes.advanced(by: offset + admitted), count: amount))
      admitted += amount
      if decodedScalars.count - decodedScalarStart == 1024 { flushDecodedScalars() }
    }
    return count
  }
  private func apply(_ effect: TerminalDocument.PrintEffect, mutations: Int = 1) {
    guard mutations > 0 else { return }
    applyAppendedHistory(effect.appendedHistory)
    if let printed = effect.lastPrinted {
      lastPrinted = printed
      let attributes = effect.repeatAttributes ?? TerminalDocument.PrintAttributes(style: pen, link: currentLink, protected: protectedOutput)
      lastPrintedStyle = attributes.style; lastPrintedLink = attributes.link
      lastPrintedFlags = attributes.protected ? 2 : 0
    }
    revision &+= UInt64(mutations); documentEpoch &+= UInt64(mutations); screenEpoch &+= UInt64(mutations)
  }
  private func applyAppendedHistory(_ rows: [SwiftRow]) {
    guard !rows.isEmpty else { return }
    if viewAnchor != nil { viewOffset += rows.count }
    enforceHistoryLimits()
    historyEpoch &+= 1
  }
  private func resetClusterBoundary() { document.resetPrintCluster() }
  private func tick(_ now: UInt64) {
    clock = now
    if let deadline = syncDeadline, now >= deadline {
      syncDeadline = nil
      changed()
    }
  }
  private func repeatLastPrinted() {
    let savedPen = pen, savedLink = currentLink, savedProtected = protectedOutput
    pen = lastPrintedStyle; currentLink = lastPrintedLink; protectedOutput = lastPrintedFlags & 2 != 0
    resetClusterBoundary()
    for scalar in lastPrinted.unicodeScalars { put(scalar) }
    resetClusterBoundary()
    pen = savedPen; currentLink = savedLink; protectedOutput = savedProtected
  }
  func feed(_ bytes: UnsafePointer<UInt8>?, count: Int, now: UInt64) -> Int {
    tick(now)
    // REP is intentionally resumable. It keeps the owner responsive and lets
    // an admitted input event observe modes established *after* the repeat.
    if repeatRemaining > 0, !lastPrinted.isEmpty {
      let budget = min(4_096, repeatRemaining)
      for _ in 0..<budget { repeatLastPrinted() }
      repeatRemaining -= budget
      return 0
    }
    guard let bytes, count > 0 else { return 0 }
    let limit = min(count, 65_536)
    var offset = 0
    while offset < limit {
      let byte = bytes[offset]
      switch parser {
      case .ground:
        if (0x20...0x7e).contains(byte),
           let admitted = appendASCIIInput(bytes, offset: offset, limit: limit) {
          offset += admitted
          continue
        }
        switch byte {
        case 0x1b: finishDecodedText(); parser = .escape
        case 0x00...0x07: finishDecodedText(); if byte == 0x07 { /* bell belongs to host */ }
        case 0x08: finishDecodedText(); backspace()
        case 0x09: finishDecodedText(); tab()
        case 0x0a, 0x0b, 0x0c: finishDecodedText(); lineFeed()
        case 0x0d: finishDecodedText(); carriageReturn()
        case 0x0e: finishDecodedText(); charsetSlot = 1
        case 0x0f: finishDecodedText(); charsetSlot = 0
        default:
          emitDecoded(utf8.push(byte))
        }
      case .escape:
        handleEscapedByte(byte)
      case .charset(let slot):
        parser = .ground
        if byte == 0x30 { charsetSpecial[slot] = true }
        else if byte == 0x42 { charsetSpecial[slot] = false }
      case .csi:
        if (0x40...0x7e).contains(byte) {
          handleCSI(sequence, final: Character(UnicodeScalar(byte))); parser = .ground
          if repeatRemaining > 0 { return offset + 1 }
        }
        else if sequence.utf8.count < 16_384 { sequence.unicodeScalars.append(UnicodeScalar(byte)) }
        else { parser = .ground; sequence = "" }
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
        if byte == 0x18 || byte == 0x1a { sequence = ""; parser = .ground }
        else if byte == 0x1b, sequence.utf8.count < 65_536 { sequence.append("\u{1b}") }
        else if byte == 0x1b { parser = .discardString(escaped: true, osc: false); sequence = "" }
        else if sequence.last == "\u{1b}" && byte == 0x5c { sequence.removeLast(); finishString(); parser = .ground }
        else if sequence.utf8.count < 65_536 { sequence.unicodeScalars.append(UnicodeScalar(byte)) }
        else { parser = .discardString(escaped: false, osc: false); sequence = "" }
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
  private func handleEscapedByte(_ byte: UInt8) {
    parser = .ground
    switch byte {
    case 0x5b: sequence = ""; parser = .csi
    case 0x5d: sequence = ""; parser = .osc
    case 0x5f: sequence = ""; parser = .apc
    case 0x28: parser = .charset(0)
    case 0x29: parser = .charset(1)
    case 0x37: saveCursor()
    case 0x38: restoreCursor()
    case 0x44: lineFeed()
    case 0x4d: reverseIndex()
    case 0x45: carriageReturn(); lineFeed()
    case 0x63: reset()
    case 0x3d: applicationKeypad = true
    case 0x3e: applicationKeypad = false
    case 0x1b: parser = .escape
    default: break
    }
  }
  private func put(_ scalar: Unicode.Scalar) {
    guard let effect = document.print(
      scalar, usingAlternate: usingAlternate,
      leftRightMargins: leftRightMargins, autoWrap: autoWrap, insertMode: insertMode,
      attributes: TerminalDocument.PrintAttributes(style: pen, link: currentLink, protected: protectedOutput)) else { return }
    apply(effect)
  }

  private func index(reverse: Bool) {
    let rows = document.index(usingAlternate: usingAlternate, reverse: reverse,
                              leftRightMargins: leftRightMargins, eraseStyle: eraseStyle())
    applyAppendedHistory(rows)
    changed(history: !reverse && !usingAlternate)
  }
  private func lineFeed() { resetClusterBoundary(); index(reverse: false) }
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
          .first(where: { $0 > 0 && $0 % 8 == 0 }) ?? left
      } else {
        guard s.cursorColumn < right else { s.cursorColumn = right; continue }
        s.cursorColumn = ((s.cursorColumn + 1)...right)
          .first(where: { $0 > 0 && $0 % 8 == 0 }) ?? right
      }
    }
    s.pendingWrap = false; screen = s; changed()
  }
  private func reverseIndex() { index(reverse: true) }
  private func saveCursor() { var s = screen; s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedPendingWrap = s.pendingWrap; s.savedOrigin = originMode; s.savedStyle = pen; s.savedLink = currentLink; screen = s }
  private func restoreCursor() { var s = screen; originMode = s.savedOrigin; pen = s.savedStyle; currentLink = s.savedLink; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = s.savedPendingWrap; screen = s; changed() }
  private func reset() { document = TerminalDocument(columns: columns, rows: rowCount); advanceSearchGeneration(); usingAlternate = false; viewAnchor = nil; viewOffset = 0; pen = SwiftStyle(); originMode = false; leftRightMargins = false; autoWrap = true; insertMode = false; protectedOutput = false; syncDeadline = nil; cursorVisible = true; cursorShape = 0; charsetSpecial = [false, false]; charsetSlot = 0; resetClusterBoundary(); changed(history: true) }
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
  private static func parseCSIParameters(_ raw: String, final: Character,
                                         into parameters: inout [Int]) -> CSIParameterPacket? {
    // The streaming CSI parser stores one input byte per scalar. A non-ASCII
    // scalar cannot be terminal parameter syntax; reject it instead of
    // silently turning a numeric-looking malformed byte into default zero.
    parameters.removeAll(keepingCapacity: true)
    var rawRun: UInt32 = 0
    var rawHasDigits = false
    var filtered: UInt32 = 0
    var filteredHasDigits = false
    let bytes = raw.utf8
    let hasColon = bytes.contains(0x3a)
    let preservingColonSGR = final == "m" && hasColon
    let keyboardPrefix = final == "u" && (bytes.first == 0x3e || bytes.first == 0x3d)
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
  private func handleCSI(_ raw: String, final: Character) {
    if !["m", "n", "c", "u"].contains(final) { resetClusterBoundary() }
    guard let packet = Self.parseCSIParameters(raw, final: final, into: &csiParameterScratch) else { return }
    let params = packet.values
    let first = raw.utf8.first
    let last = raw.utf8.last
    let privateMode = first == 0x3f
    let n = max(1, params.first ?? 0)
    var s = screen
    var changedActiveScreen = false
    var semanticChange = true
    var clearsPending = true
    switch final {
    case "A": s.cursorRow = max(originMode ? s.topMargin : 0, s.cursorRow - n)
    case "B": s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, s.cursorRow + n)
    case "C": s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, s.cursorColumn + n)
    case "D": s.cursorColumn = max(originMode ? horizontalMargins.left : 0, s.cursorColumn - n)
    case "G": s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + n - 1)
    case "d": s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, (originMode ? s.topMargin : 0) + n - 1)
    case "H", "f": s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, (originMode ? s.topMargin : 0) + max(0, (params.first ?? 1) - 1)); s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + max(0, (params.dropFirst().first ?? 1) - 1))
    case "J": eraseDisplay(params.first ?? 0, selective: privateMode); changedActiveScreen = true
    case "K": eraseLine(params.first ?? 0); changedActiveScreen = true
    case "@": insertCharacters(n); changedActiveScreen = true
    case "P": deleteCharacters(n); changedActiveScreen = true
    case "L": insertLines(n); changedActiveScreen = true
    case "M": deleteLines(n); changedActiveScreen = true
    case "I": tab(false, count: n); changedActiveScreen = true
    case "Z": tab(true, count: n); changedActiveScreen = true
    case "r": setVerticalMargins(params); changedActiveScreen = true
    case "S": resetClusterBoundary(); scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: true, allowHistory: false)
    case "T": resetClusterBoundary(); scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: false, allowHistory: false)
    case "b": repeatRemaining = min(1_000_000, max(0, params.first ?? 1)); clearsPending = false
    case "m": applySGR(params, colonSyntax: packet.hasColon ? raw : nil); clearsPending = false
    case "s":
      if leftRightMargins { setHorizontalMargins(params); changedActiveScreen = true }
      else { s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedOrigin = originMode }
    case "u":
      clearsPending = false
      if first == 0x3e || first == 0x3d { s.keyboardFlags = (packet.keyboardFlags ?? 0) & 31 }
      else if first == 0x3f { replies.append(contentsOf: "\u{1b}[?\(s.keyboardFlags)u".utf8) }
      else if first == 0x3c { s.keyboardFlags = 0 }
      else { originMode = s.savedOrigin; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = false }
    case "n": clearsPending = false; if params.first == 5 { replies.append(contentsOf: "\u{1b}[0n".utf8) } else if params.first == 6 { let row = s.cursorRow + 1 - (originMode ? s.topMargin : 0); let column = s.cursorColumn + 1 - (originMode ? horizontalMargins.left : 0); replies.append(contentsOf: "\u{1b}[\(row);\(column)R".utf8) }
    case "c": clearsPending = false; replies.append(contentsOf: "\u{1b}[?62;4c".utf8)
    case "p" where privateMode && last == 0x24:
      clearsPending = false
      replies.append(contentsOf: "\u{1b}[?\(params.first ?? 0);\(params.first == 69 ? (leftRightMargins ? 1 : 2) : 0)$y".utf8)
    case "p" where last == 0x21: softReset(); changedActiveScreen = true
    case "q" where last == 0x22: protectedOutput = (params.first ?? 0) == 1; clearsPending = false
    case "q": cursorShape = UInt8(min(6, max(0, params.first ?? 0))); clearsPending = false
    case "h", "l":
      if privateMode, params.allSatisfy({ [47, 1047, 1049].contains($0) }), params.allSatisfy({ _ in usingAlternate == (final == "h") }) { semanticChange = false }
      changedActiveScreen = setMode(params, enabled: final == "h", privateMode: privateMode)
    default: break
    }
    // DEC alternate-screen modes swap the screen object.  Keeping the swap
    // inside mode ownership prevents this generic CSI epilogue from writing a
    // stale primary copy back into the newly active alternate buffer.
    if !changedActiveScreen { if clearsPending { s.pendingWrap = false }; screen = s }
    if semanticChange { changed() }
  }
  private func eraseDisplay(_ mode: Int, selective: Bool = false) { var s = screen; switch mode { case 2, 3: if selective { for row in 0..<rowCount { document.erase(&s, row: row, columns: 0..<columns, style: eraseStyle(), selective: true) } } else { s.rows = (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) } }; if mode == 3 && !usingAlternate { document.clearHistory(); advanceSearchGeneration(); historyEpoch &+= 1 }; case 1: for row in 0...s.cursorRow { document.erase(&s, row: row, columns: 0..<(row == s.cursorRow ? s.cursorColumn + 1 : columns), style: eraseStyle(), selective: selective) }; default: for row in s.cursorRow..<rowCount { document.erase(&s, row: row, columns: (row == s.cursorRow ? s.cursorColumn : 0)..<columns, style: eraseStyle(), selective: selective) } }; s.pendingWrap = false; screen = s }
  private func eraseLine(_ mode: Int) { var s = screen; let range: Range<Int>; switch mode { case 1: range = 0..<(s.cursorColumn + 1); case 2: range = 0..<columns; default: range = s.cursorColumn..<columns }; document.erase(&s, row: s.cursorRow, columns: range, style: eraseStyle()); s.pendingWrap = false; screen = s }
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
  private func scroll(_ s: inout SwiftScreen, top: Int, bottom: Int, count: Int, up: Bool, allowHistory: Bool) {
    let margins = horizontalMargins; let amount = min(count, bottom - top + 1); guard amount > 0 else { return }
    if margins.left != 0 || margins.right != columns - 1 {
      document.scrollRectangle(&s, top: top, bottom: bottom, left: margins.left, right: margins.right, count: amount, up: up, eraseStyle: eraseStyle()); return
    }
    for _ in 0..<amount {
      let removed: SwiftRow
      if up { removed = s.rows.remove(at: top); s.rows.insert(document.eraseRow(eraseStyle()), at: bottom) }
      else { removed = s.rows.remove(at: bottom); s.rows.insert(document.eraseRow(eraseStyle()), at: top) }
      if up && allowHistory && !usingAlternate && top == 0 && bottom == rowCount - 1 {
        document.history.append(removed)
        if viewAnchor != nil { viewOffset += 1 }
        enforceHistoryLimits()
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
          guard let code = Int(value) else { group += 1; continue }
          // Keep extended semicolon colors together; handling them as single
          // values would lose the RGB/index operands beside a colon group.
          if [38, 48, 58].contains(code), group + 1 < groups.count,
            let mode = Int(groups[group + 1])
          {
            let count = mode == 2 ? 5 : mode == 5 ? 3 : 1
            if group + count <= groups.count {
              var nestedParameters: [Int] = []
              if let packet = Self.parseCSIParameters(String(groups[group..<(group + count)].joined(separator: ";")), final: "m", into: &nestedParameters) {
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
          guard let index = fields.dropFirst(2).first.flatMap({ Int($0) }) else { group += 1; continue }
          let color = 0x0100_0000 | UInt32(max(0, min(255, index)))
          if code == 38 { pen.foreground = color }
          else if code == 48 { pen.background = color }
          else { pen.underline = color }
        case 2:
          // ECMA-48 permits an optional color-space field between `2` and
          // RGB. Using the final three fields supports both forms.
          let rgb = fields.suffix(3).compactMap { Int($0) }
          guard rgb.count == 3 else { group += 1; continue }
          let color = 0x0200_0000 | UInt32(max(0, min(255, rgb[0])) << 16)
            | UInt32(max(0, min(255, rgb[1])) << 8) | UInt32(max(0, min(255, rgb[2])))
          if code == 38 { pen.foreground = color }
          else if code == 48 { pen.background = color }
          else { pen.underline = color }
        default: group += 1; continue
        }
        group += 1
      }
      return
    }
    let values = p.isEmpty ? [0] : p
    var i = 0
    while i < values.count {
      let code = values[i]
      switch code {
      case 0: pen = SwiftStyle()
      case 1: pen.flags |= 1
      case 2: pen.flags |= 2
      case 3: pen.flags |= 4
      case 4: pen.underlineKind = 1
      case 5: pen.flags |= 128
      case 7: pen.flags |= 8
      case 8: pen.flags |= 16
      case 9: pen.flags |= 32
      case 53: pen.flags |= 64
      case 22: pen.flags &= ~UInt16(3)
      case 23: pen.flags &= ~UInt16(4)
      case 24: pen.underlineKind = 0
      case 27: pen.flags &= ~UInt16(8)
      case 25: pen.flags &= ~UInt16(128)
      case 29: pen.flags &= ~UInt16(32)
      case 55: pen.flags &= ~UInt16(64)
      case 30...37: pen.foreground = 0x0100_0000 | UInt32(code - 30)
      case 39: pen.foreground = 0
      case 40...47: pen.background = 0x0100_0000 | UInt32(code - 40)
      case 49: pen.background = 0
      case 90...97: pen.foreground = 0x0100_0000 | UInt32(code - 90 + 8)
      case 100...107: pen.background = 0x0100_0000 | UInt32(code - 100 + 8)
      case 38, 48, 58:
        if i + 2 < values.count && values[i + 1] == 5 {
          let color = 0x0100_0000 | UInt32(max(0, min(255, values[i + 2])))
          if code == 38 { pen.foreground = color } else if code == 48 { pen.background = color } else { pen.underline = color }
          i += 2
        } else if i + 4 < values.count && values[i + 1] == 2 {
          let r = UInt32(max(0, min(255, values[i + 2])))
          let g = UInt32(max(0, min(255, values[i + 3])))
          let b = UInt32(max(0, min(255, values[i + 4])))
          let color = 0x0200_0000 | (r << 16) | (g << 8) | b
          if code == 38 { pen.foreground = color } else if code == 48 { pen.background = color } else { pen.underline = color }
          i += 4
        }
      case 59: pen.underline = 0
      default: break
      }
      i += 1
    }
    // ISO 8613-6 colon forms retain empty color-space fields, unlike the
    // semicolon form above. Handle each colon parameter independently so a
    // malformed extended color cannot reinterpret a following command.
    guard let raw else { return }
    for parameter in raw.split(separator: ";", omittingEmptySubsequences: false) where parameter.utf8.contains(0x3a) {
      let fields = parameter.split(separator: ":", omittingEmptySubsequences: false)
      guard let command = fields.first.flatMap({ Int($0) }), [38, 48, 58].contains(command),
            fields.count >= 5, fields[1] == "2" else { continue }
      let channels = fields.dropFirst(2).compactMap { Int($0) }
      guard channels.count >= 3 else { continue }
      let rgb = channels.suffix(3).map { UInt32(max(0, min(255, $0))) }
      let color = 0x0200_0000 | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
      if command == 38 { pen.foreground = color }
      else if command == 48 { pen.background = color }
      else { pen.underline = color }
    }
  }
  private func setMode(_ params: [Int], enabled: Bool, privateMode: Bool) -> Bool {
    var changedActiveScreen = false
    if !privateMode && params.contains(4) { insertMode = enabled }
    for mode in params where privateMode {
      switch mode {
      case 1: applicationCursor = enabled
      case 6: originMode = enabled; var s = screen; s.cursorRow = enabled ? s.topMargin : 0; s.cursorColumn = enabled ? horizontalMargins.left : 0; s.pendingWrap = false; screen = s; changedActiveScreen = true
      case 7: autoWrap = enabled; if !enabled { var s = screen; s.pendingWrap = false; screen = s }; changedActiveScreen = true
      case 25: cursorVisible = enabled
      case 47, 1047, 1049:
        if usingAlternate != enabled {
          resetClusterBoundary()
          advanceSearchGeneration()
          usingAlternate = enabled
          if enabled && (mode == 1047 || mode == 1049) { alternate = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns) }
          changedActiveScreen = true
        }
      case 1004: focusReporting = enabled
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
    originMode = false; leftRightMargins = false; autoWrap = true; insertMode = false; protectedOutput = false
    pen = SwiftStyle(); currentLink = nil; applicationCursor = false; applicationKeypad = false
    bracketedPaste = false; focusReporting = false; syncDeadline = nil
    var s = screen; s.topMargin = 0; s.bottomMargin = rowCount - 1; s.cursorRow = 0; s.cursorColumn = 0; s.pendingWrap = false; screen = s
    primary.leftMargin = 0; primary.rightMargin = columns - 1; alternate.leftMargin = 0; alternate.rightMargin = columns - 1
  }
  private func finishString() {
    let payload = sequence; sequence = ""
    if case .osc = parser {
      let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
      guard let command = parts.first else { return }
      if command == "0" || command == "2" { title = parts.dropFirst().joined(separator: ";") }
      else if command == "8" { currentLink = parts.count > 2 ? String(parts.dropFirst(2).joined(separator: ";")) : nil }
      else if command == "133" {
        let marker = parts.dropFirst().first
        var current = screen
        switch marker {
        case "A", "B":
          if marker == "A" {
            current.promptPhase = .drawing
            current.promptRedraw = parts.dropFirst(2).contains { $0 == "redraw=1" }
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
    let s = screen
    let outcome = graphics.consume(Data(payload.utf8), context: KittyGraphicsContext(
      alternate: usingAlternate, row: s.cursorRow, column: s.cursorColumn,
      cellWidth: cellPixelWidth, cellHeight: cellPixelHeight), now: 0)
    if let reply = outcome.reply { replies.append(reply) }
    if let advance = outcome.advance {
      var moved = s
      moved.cursorColumn = min(columns - 1, moved.cursorColumn + advance.0)
      moved.cursorRow = min(rowCount - 1, moved.cursorRow + advance.1)
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
  func resize(columns nextColumns: Int, rows nextRows: Int) -> Bool {
    guard (1...4096).contains(nextColumns), (1...4096).contains(nextRows), nextColumns <= 1_048_576 / nextRows else { return false }
    if nextColumns == columns && nextRows == rowCount { return true }
    resetClusterBoundary()
    if !usingAlternate && nextColumns != columns && primary.atPrompt && primary.promptRedraw {
      var promptScreen = primary
      _ = document.clearPromptSuffix(&promptScreen, eraseStyle: eraseStyle())
      primary = promptScreen
    }
    let oldAlternate = alternate
    let mapped = document.reflowPrimary(columns: nextColumns, rows: nextRows, anchor: viewAnchor)
    let resizedAlternate = document.resize(oldAlternate, columns: nextColumns, rows: nextRows)
    columns = nextColumns; rowCount = nextRows; alternate = resizedAlternate
    enforceHistoryLimits()
    viewAnchor = mapped.anchor ?? viewAnchor
    resolveViewportAnchor(clamp: true)
    syncDeadline = nil
    changed(geometry: true)
    return true
  }
  func resize(columns nextColumns: Int, rows nextRows: Int, cellWidth: Int, cellHeight: Int) -> Bool { guard resize(columns: nextColumns, rows: nextRows) else { return false }; cellPixelWidth = max(1, cellWidth); cellPixelHeight = max(1, cellHeight); return true }
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
    if let historyIndex = history.firstIndex(where: { $0.id == anchor }) {
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
    let retainedAnchor = viewAnchor
    let evicted = document.trimHistory(rowLimit: historyLimit, byteLimit: historyByteLimit) > 0
    if evicted, let retainedAnchor,
       !history.contains(where: { $0.id == retainedAnchor }),
       !primary.rows.contains(where: { $0.id == retainedAnchor }) {
      clampViewportAfterEviction()
    }
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
      current = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns)
      current.topMargin = margins.0; current.bottomMargin = margins.1
      current.leftMargin = margins.2; current.rightMargin = margins.3
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
             metadata: SwiftInputEncoder.KeyMetadata = .init()) -> Data? {
    let modes = SwiftInputEncoder.Modes(
      applicationCursor: applicationCursor, applicationKeypad: applicationKeypad,
      bracketedPaste: bracketedPaste, focusReporting: focusReporting, kittyFlags: screen.keyboardFlags)
    // The C ABI's key=0 path represents committed text, not a physical key.
    // It must retain every scalar (automation, IME commits, and multi-scalar
    // insertText: calls), matching the Rust FFI's text.as_bytes() path.
    if key == 0 { return Data(text.utf8) }
    if key == 1 { return SwiftInputEncoder.paste(text, modes: modes) }
    if key == 2 { return SwiftInputEncoder.focus(event == 1, modes: modes) }
    let modifier = SwiftInputEncoder.Modifiers(
      shift: modifiers & 1 != 0, option: modifiers & 2 != 0,
      control: modifiers & 4 != 0, command: modifiers & 8 != 0,
      capsLock: modifiers & 64 != 0, numLock: modifiers & 128 != 0)
    let phase: SwiftInputEncoder.Event = event == 1 ? .repeatKey : event == 2 ? .release : .press
    guard let semantic = inputKey(key, text: text) else { return Data() }
    return SwiftInputEncoder.key(semantic, modifiers: modifier, event: phase, modes: modes, metadata: metadata)
  }
  private func inputKey(_ code: UInt32, text: String) -> SwiftInputEncoder.Key? {
    let navigation: [UInt32: SwiftInputEncoder.Key] = [
      10: .up, 11: .down, 12: .right, 13: .left, 14: .home, 15: .end,
      16: .pageUp, 17: .pageDown, 18: .insert, 19: .delete, 20: .backspace,
      21: .tab, 22: .enter, 23: .escape]
    if let value = navigation[code] { return value }
    if (100...111).contains(code) { return .function(Int(code - 99)) }
    if (300...317).contains(code), let keypad = SwiftInputEncoder.KeypadKey(rawValue: Int(code - 300)) {
      return .keypad(keypad, nativeText: text.first)
    }
    if (400...411).contains(code) { return .modifier(57441 + code - 400) }
    if code == 412 { return .modifier(57358) }
    if code >= 50_000 { return .modifier(code) }
    if code == 0 || code == 200 { return text.first.map { .character($0) } }
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
  func isValid() -> Bool {
    document.hasValidInvariants(primary) && document.hasValidInvariants(alternate) &&
      history.allSatisfy { $0.cells.count == columns }
  }
  func historyBytes() -> UInt64 { document.history.byteCount }
  func imageRGBA(id: UInt32, generation: UInt64) -> Data? { graphics.imageRGBA(id: id, generation: generation) }
  private func searchKind(_ kind: UInt8) -> SwiftSearchCellKind {
    switch kind {
    case 0: return .empty
    case 1: return .lead1
    case 2: return .lead2
    case 3: return .continuation
    default: return .wrapSpacer
    }
  }
  private func searchProjection(_ row: SwiftRow) -> SwiftSearchRow {
    // This conversion happens for one owner-admitted row only. In particular,
    // starting a search does not turn all retained scrollback into String
    // cells, and the worker retains just its current immutable page.
    SwiftSearchRow(
      id: row.id, revision: row.revision,
      cells: row.cells.map { cell in
        SwiftSearchCell(cell.text, searchKind(cell.kind), hasBackground: cell.style.background != 0)
      }, softWrapsToNext: row.softWrapped)
  }
  /// Resolves a captured search coordinate without materializing rich search
  /// cells. The source closures all route through this one ownership boundary.
  private func capturedSearchRow(_ index: Int, alternateMode: Bool, historyCount: Int) -> SwiftRow? {
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
  private func searchSource() -> SwiftSearchSource {
    let alternateMode = usingAlternate
    let historyCount = history.count
    let rowCount = alternateMode ? alternate.rows.count : historyCount + primary.rows.count
    // Printing and scrollback admission advance the renderer publication
    // counters. Search instead follows captured row identities and verifies
    // row proofs at acceptance: later output must not make it chase rows, and
    // eviction/mutation still fails lookup/proof. Geometry/alternate changes
    // remain structural stamp boundaries.
    let stamp = SwiftSearchStamp(document: searchGeneration, history: 0,
                                 geometry: geometryEpoch, screen: 0,
                                 alternate: alternateMode)
    return SwiftSearchSource(
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
        return SwiftSearchProof(id: row.id, revision: row.revision,
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
  func createSearch(_ query: String) -> SwiftCoreSearchToken? {
    searchHit = nil
    return try? SwiftCoreSearchToken(SwiftSearchTask(query: query, source: searchSource()))
  }
  private func searchStatus(_ status: SwiftSearchStatus) -> UInt32 {
    switch status {
    case .working: return 0
    case .needsPage: return 1
    case .complete: return 2
    case .changed, .cancelled: return 3
    case .resourceLimit: return 4
    }
  }
  func fillSearch(_ token: SwiftCoreSearchToken) -> UInt32 {
    searchStatus(token.task.fill(from: searchSource()))
  }
  static func stepSearch(_ token: SwiftCoreSearchToken) -> UInt32 {
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
  func acceptSearch(_ token: SwiftCoreSearchToken) -> UInt32 {
    let source = searchSource()
    switch token.task.accept(in: source) {
    case .found(let first, let spans):
      if !usingAlternate { setViewOffset(history.count - first) }
      searchHit = (source.stamp, spans)
      return 5
    case .missing: return 2
    case .working: return 0
    case .needsPage: return 1
    case .changed, .cancelled: return 3
    case .resourceLimit: return 4
    }
  }
  private func palette() -> [[Int]] {
    var output = [[27,28,31], [239,68,68], [34,197,94], [250,204,21], [96,165,250], [192,132,252], [34,211,238], [212,212,216], [107,111,118], [248,113,113], [74,222,128], [253,224,71], [147,197,253], [216,180,254], [103,232,249], [250,250,250]]
    for red in [0,95,135,175,215,255] { for green in [0,95,135,175,215,255] { for blue in [0,95,135,175,215,255] { output.append([red, green, blue]) } } }
    for index in 0..<24 { let value = 8 + index * 10; output.append([value, value, value]) }
    return output
  }
  private struct SnapshotSelection {
    var rows: [SwiftRow]
    var offset: Int
    var followingTail: Bool
  }
  private func rowsForSnapshot(offset: Int) -> (rows: [SwiftRow], offset: Int) {
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
  private func visibleSearchHighlights(in rows: [SwiftRow]) -> [[String: Int]] {
    guard let hit = searchHit else { return [] }
    let source = searchSource()
    guard source.stamp == hit.stamp,
          let first = hit.spans.first,
          let start = (0..<source.rowCount).first(where: { source.rowIDAt($0) == first.span.proof.id })
    else { return [] }
    for (offset, resolved) in hit.spans.enumerated() {
      let index = start + offset
      guard source.rowIDAt(index) == resolved.span.proof.id,
            source.proofAt(index) == resolved.span.proof
      else { return [] }
    }
    var byRow: [UInt64: [(UInt64, Int, Int)]] = [:]
    for resolved in hit.spans where resolved.span.start < resolved.span.end {
      let span = resolved.span
      byRow[span.proof.id, default: []].append((span.proof.revision, span.start, span.end))
    }
    return rows.enumerated().flatMap { index, row in
      (byRow[row.id] ?? []).compactMap { hit in
        guard hit.0 == row.revision else { return nil }
        return ["row": index, "start": hit.1, "end": hit.2]
      }
    }
  }
  func publishBinary(scroll: Int?, now: UInt64, context: UnsafeMutableRawPointer?, callback: SnapshotCallback?) -> Bool {
    tick(now)
    guard !publicationGated else { return false }
    guard let callback else { return false }
    let selected = selectSnapshot(scroll: scroll)
    let metadataObject = snapshotMetadata(cursor: screen, offset: selected.offset,
                                          followingTail: selected.followingTail,
                                          search: visibleSearchHighlights(in: selected.rows))
    guard let metadata = try? JSONSerialization.data(withJSONObject: metadataObject) else { return false }
    let borrowed = SwiftBorrowedCells()
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
    let source: [SwiftRow]; let offset: Int
    let selected = selectSnapshot(scroll: scroll)
    source = selected.rows; offset = selected.offset
    let rows: [[String: Any]] = source.map { row in ["id": row.id, "revision": row.revision, "soft_wrapped": row.softWrapped, "cells": row.cells.map { cell in ["text": cell.text, "kind": ["Empty","Lead1","Lead2","Continuation","WrapSpacer"][Int(cell.kind)], "style": ["foreground": colorJSON(cell.style.foreground), "background": colorJSON(cell.style.background), "underline_color": colorJSON(cell.style.underline), "underline": Int(cell.style.underlineKind), "bold": cell.style.flags & 1 != 0, "faint": cell.style.flags & 2 != 0, "italic": cell.style.flags & 4 != 0, "inverse": cell.style.flags & 8 != 0, "conceal": cell.style.flags & 16 != 0, "strike": cell.style.flags & 32 != 0, "overline": cell.style.flags & 64 != 0, "blink": cell.style.flags & 128 != 0], "link": cell.link as Any, "flags": Int(cell.flags)] } ] }
    var data = snapshotMetadata(cursor: screen, offset: offset,
                                followingTail: selected.followingTail,
                                search: visibleSearchHighlights(in: source))
    data["rows"] = rows
    return (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8)
  }
  private func snapshotMetadata(cursor: SwiftScreen, offset: Int,
                                followingTail: Bool, search: [[String: Int]]) -> [String: Any] {
    let images = graphics.visible(alternate: usingAlternate).map { image in ["image": image.image, "generation": image.generation, "width": image.width, "height": image.height, "source": image.source, "row": image.row, "col": image.column, "columns": image.columns, "rows": image.rows, "offset": image.offset, "natural": image.natural, "z": image.z, "placement": image.placement] as [String: Any] }
    return ["at_prompt":cursor.atPrompt,"input_ready":cursor.inputReady,"search":search,"images":images,"revision":revision,"geometry_epoch":geometryEpoch,"document_epoch":documentEpoch,"history_epoch":historyEpoch,"screen_epoch":screenEpoch,"scroll_offset":offset,"following_tail":followingTail,"viewport_clamp_revision":viewportClampRevision,"cols":columns,"cursor":["row":cursor.cursorRow,"col":cursor.cursorColumn,"pending_wrap":cursor.pendingWrap,"visible":cursorVisible,"shape":Int(cursorShape)],"modes":["application_cursor":applicationCursor,"application_keypad":applicationKeypad,"autowrap":autoWrap,"bracketed_paste":bracketedPaste,"focus":focusReporting,"insert":insertMode,"left_right_margins":leftRightMargins,"mouse":0,"newline":false,"origin":originMode,"reverse_video":reverseVideo,"sgr_mouse":false],"primary_margins":[primary.leftMargin, primary.rightMargin],"alternate_margins":[alternate.leftMargin, alternate.rightMargin],"vertical_margins":[cursor.topMargin, cursor.bottomMargin],"alternate":usingAlternate,"title":title,"history_rows":history.count,"palette":palette(),"default_fg":[230,230,230],"default_bg":[10,10,11]]
  }
  private func colorJSON(_ color: UInt32) -> Any { if color >> 24 == 1 { return ["Indexed": Int(color & 255)] }; if color >> 24 == 2 { return ["Rgb": [Int((color >> 16) & 255), Int((color >> 8) & 255), Int(color & 255)]] }; return "Default" }
}

// MARK: C ABI bridge. The app still imports Bridge.h, allowing a mechanical
// replacement of the static Rust archive while all native call sites stay stable.

private func core(_ pointer: OpaquePointer?) -> SwiftTerminalCore? { pointer.map { Unmanaged<SwiftTerminalCore>.fromOpaque(UnsafeMutableRawPointer($0)).takeUnretainedValue() } }
private func inputCharacter(_ scalar: UInt32) -> Character? {
  guard scalar != 0, let value = UnicodeScalar(scalar) else { return nil }
  return Character(String(value))
}
typealias BytesCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
typealias ClipboardCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<UInt8>?, Int) -> Void
typealias SnapshotCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int) -> Void

@_cdecl("terminal_abi_version") func swift_terminal_abi_version() -> UInt32 { 1 }
@_cdecl("terminal_create") func swift_terminal_create(_ cols: UInt32, _ rows: UInt32) -> OpaquePointer? { OpaquePointer(Unmanaged.passRetained(SwiftTerminalCore(columns: Int(cols), rows: Int(rows))).toOpaque()) }
@_cdecl("terminal_destroy") func swift_terminal_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<SwiftTerminalCore>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_feed") func swift_terminal_feed(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ now: UInt64) -> Int { core(pointer)?.feed(bytes, count: count, now: now) ?? 0 }
@_cdecl("terminal_resize") func swift_terminal_resize(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows)) ?? false }
@_cdecl("terminal_resize_pixels") func swift_terminal_resize_pixels(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32, _ width: UInt32, _ height: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows), cellWidth: Int(width), cellHeight: Int(height)) ?? false }
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
      // Rust's Vec::as_ptr is non-null even for an empty write. Preserve that
      // ABI convenience for hosts whose callback validates the pointer before
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
  let metadata = SwiftInputEncoder.KeyMetadata(
    shifted: inputCharacter(shifted), baseLayout: inputCharacter(baseLayout),
    associatedText: associated.map { String(cString: $0) }, legacyText: legacy.map { String(cString: $0) })
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
@_cdecl("terminal_search_destroy") func swift_terminal_search_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_search_fill") func swift_terminal_search_fill(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 {
  guard let terminal = core(pointer), let task else { return 3 }
  return terminal.fillSearch(Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue())
}
@_cdecl("terminal_search_step") func swift_terminal_search_step(_ pointer: OpaquePointer?) -> UInt32 {
  guard let pointer else { return 3 }
  return SwiftTerminalCore.stepSearch(Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).takeUnretainedValue())
}
@_cdecl("terminal_search_accept") func swift_terminal_search_accept(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 {
  guard let terminal = core(pointer), let task else { return 3 }
  return terminal.acceptSearch(Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue())
}

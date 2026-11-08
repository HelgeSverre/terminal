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
  let query: String
  init(_ query: String) { self.query = query }
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
  private var history: [SwiftRow] { get { document.history } set { document.history = newValue } }
  private var historyLimit = 10_000
  private var historyByteLimit = Int.max
  private var historyByteCount: UInt64 = 0
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
  private var documentEpoch: UInt64 = 1
  private var historyEpoch: UInt64 = 1
  private var screenEpoch: UInt64 = 1
  private var searchHighlights: [[String: Int]] = []
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
  private var segmenter = SwiftUnicode.Segmenter()

  init(columns: Int, rows: Int) {
    self.columns = max(1, min(4096, columns))
    self.rowCount = max(1, min(4096, rows))
    document = TerminalDocument(columns: self.columns, rows: self.rowCount)
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
    if document { documentEpoch &+= 1 }
    if screen { screenEpoch &+= 1 }
    if history { historyEpoch &+= 1 }
    if geometry { geometryEpoch &+= 1 }
  }
  private func flushText(final: Bool = false) {
    // Escape/control input interrupts an incomplete UTF-8 sequence. Emit its
    // maximal invalid prefix now so that the control byte is still parsed.
    for scalar in utf8.finish() { put(scalar) }
  }
  private func resetClusterBoundary() { segmenter = SwiftUnicode.Segmenter(); document.resetPrintCluster() }
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
    for (offset, byte) in UnsafeBufferPointer(start: bytes, count: limit).enumerated() {
      switch parser {
      case .ground:
        switch byte {
        case 0x1b: flushText(); parser = .escape
        case 0x00...0x07: flushText(); if byte == 0x07 { /* bell belongs to host */ }
        case 0x08: flushText(); backspace()
        case 0x09: flushText(); tab()
        case 0x0a, 0x0b, 0x0c: flushText(); lineFeed()
        case 0x0d: flushText(); carriageReturn()
        case 0x0e: flushText(); charsetSlot = 1
        case 0x0f: flushText(); charsetSlot = 0
        default:
          for scalar in utf8.push(byte) {
            put(charsetSpecial[charsetSlot] ? decSpecialGraphics(scalar) : scalar)
          }
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
    }
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
    switch SwiftUnicode.category(of: scalar) {
    case .control, .cr, .lf: return
    default: break
    }
    let effect = document.print(
      scalar, startsCluster: segmenter.push(scalar), usingAlternate: usingAlternate,
      leftRightMargins: leftRightMargins, autoWrap: autoWrap, insertMode: insertMode,
      attributes: TerminalDocument.PrintAttributes(style: pen, link: currentLink, protected: protectedOutput))
    if effect.resetSegmenter { resetClusterBoundary(); return }
    if !effect.appendedHistory.isEmpty {
      for row in effect.appendedHistory { historyByteCount &+= rowStorageBytes(row) }
      if viewAnchor != nil { viewOffset += effect.appendedHistory.count }
      enforceHistoryLimits()
      historyEpoch &+= 1
    }
    if let printed = effect.lastPrinted {
      lastPrinted = printed
      let attributes = effect.repeatAttributes ?? TerminalDocument.PrintAttributes(style: pen, link: currentLink, protected: protectedOutput)
      lastPrintedStyle = attributes.style
      lastPrintedLink = attributes.link
      lastPrintedFlags = attributes.protected ? 2 : 0
    }
    changed()
  }

  private func index(_ s: inout SwiftScreen, reverse: Bool, allowHistory: Bool) {
    let vertical = (s.topMargin, s.bottomMargin), horizontal = horizontalMargins
    let inside = (horizontal.left...horizontal.right).contains(s.cursorColumn)
    if reverse {
      if s.cursorRow == vertical.0 && inside { scroll(&s, top: vertical.0, bottom: vertical.1, count: 1, up: false, allowHistory: false) }
      else { s.cursorRow = max(0, s.cursorRow - 1) }
    } else if s.cursorRow == vertical.1 && inside {
      scroll(&s, top: vertical.0, bottom: vertical.1, count: 1, up: true, allowHistory: allowHistory)
    } else { s.cursorRow = min(rowCount - 1, s.cursorRow + 1) }
  }
  private func lineFeed() { resetClusterBoundary(); var s = screen; s.pendingWrap = false; index(&s, reverse: false, allowHistory: true); screen = s; changed(history: !usingAlternate) }
  private func carriageReturn() { resetClusterBoundary(); var s = screen; let left = horizontalMargins.left; s.cursorColumn = s.cursorColumn >= left ? left : 0; s.pendingWrap = false; screen = s; changed() }
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
  private func reverseIndex() { var s = screen; s.pendingWrap = false; index(&s, reverse: true, allowHistory: false); screen = s; changed() }
  private func saveCursor() { var s = screen; s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedPendingWrap = s.pendingWrap; s.savedOrigin = originMode; s.savedStyle = pen; s.savedLink = currentLink; screen = s }
  private func restoreCursor() { var s = screen; originMode = s.savedOrigin; pen = s.savedStyle; currentLink = s.savedLink; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = s.savedPendingWrap; screen = s; changed() }
  private func reset() { document = TerminalDocument(columns: columns, rows: rowCount); usingAlternate = false; history.removeAll(); historyByteCount = 0; viewAnchor = nil; viewOffset = 0; pen = SwiftStyle(); originMode = false; leftRightMargins = false; autoWrap = true; insertMode = false; protectedOutput = false; syncDeadline = nil; cursorVisible = true; cursorShape = 0; charsetSpecial = [false, false]; charsetSlot = 0; resetClusterBoundary(); changed(history: true) }
  private func parameters(_ raw: String) -> [Int] { raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 } }
  private func handleCSI(_ raw: String, final: Character) {
    if !["m", "n", "c", "u"].contains(final) { resetClusterBoundary() }
    // VT parameters are bounded unsigned values. Treat an overflowing field
    // as an invalid command rather than silently converting it to zero and
    // performing a cursor motion with the default count.
    for field in raw.split(whereSeparator: { !$0.isNumber }) where !field.isEmpty {
      if UInt32(field) == nil { return }
    }
    let privateMode = raw.first == "?"
    let command = privateMode ? String(raw.dropFirst()) : raw
    let params = parameters(command.filter { $0 == ";" || $0.isNumber })
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
    case "m": applySGR(params, colonSyntax: raw); clearsPending = false
    case "s":
      if leftRightMargins { setHorizontalMargins(params); changedActiveScreen = true }
      else { s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedOrigin = originMode }
    case "u":
      clearsPending = false
      if raw.first == ">" || raw.first == "=" { s.keyboardFlags = UInt32(max(0, parameters(String(raw.dropFirst())).first ?? 0)) & 31 }
      else if raw.first == "?" { replies.append(contentsOf: "\u{1b}[?\(s.keyboardFlags)u".utf8) }
      else if raw.first == "<" { s.keyboardFlags = 0 }
      else { originMode = s.savedOrigin; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = false }
    case "n": clearsPending = false; if params.first == 5 { replies.append(contentsOf: "\u{1b}[0n".utf8) } else if params.first == 6 { let row = s.cursorRow + 1 - (originMode ? s.topMargin : 0); let column = s.cursorColumn + 1 - (originMode ? horizontalMargins.left : 0); replies.append(contentsOf: "\u{1b}[\(row);\(column)R".utf8) }
    case "c": clearsPending = false; replies.append(contentsOf: "\u{1b}[?62;4c".utf8)
    case "p" where privateMode && raw.hasSuffix("$"):
      clearsPending = false
      replies.append(contentsOf: "\u{1b}[?\(params.first ?? 0);\(params.first == 69 ? (leftRightMargins ? 1 : 2) : 0)$y".utf8)
    case "p" where raw.hasSuffix("!"): softReset(); changedActiveScreen = true
    case "q" where raw.hasSuffix("\""): protectedOutput = (params.first ?? 0) == 1; clearsPending = false
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
  private func eraseDisplay(_ mode: Int, selective: Bool = false) { var s = screen; switch mode { case 2, 3: if selective { for row in 0..<rowCount { document.erase(&s, row: row, columns: 0..<columns, style: eraseStyle(), selective: true) } } else { s.rows = (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) } }; if mode == 3 && !usingAlternate { history.removeAll(); historyByteCount = 0; historyEpoch &+= 1 }; case 1: for row in 0...s.cursorRow { document.erase(&s, row: row, columns: 0..<(row == s.cursorRow ? s.cursorColumn + 1 : columns), style: eraseStyle(), selective: selective) }; default: for row in s.cursorRow..<rowCount { document.erase(&s, row: row, columns: (row == s.cursorRow ? s.cursorColumn : 0)..<columns, style: eraseStyle(), selective: selective) } }; s.pendingWrap = false; screen = s }
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
        history.append(removed)
        historyByteCount &+= rowStorageBytes(removed)
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
    if let raw, raw.contains(":") {
      let groups = raw.split(separator: ";", omittingEmptySubsequences: false)
      var group = 0
      while group < groups.count {
        let value = groups[group]
        guard value.contains(":") else {
          guard let code = Int(value) else { group += 1; continue }
          // Keep extended semicolon colors together; handling them as single
          // values would lose the RGB/index operands beside a colon group.
          if [38, 48, 58].contains(code), group + 1 < groups.count,
            let mode = Int(groups[group + 1])
          {
            let count = mode == 2 ? 5 : mode == 5 ? 3 : 1
            if group + count <= groups.count {
              applySGR(parameters(groups[group..<(group + count)].joined(separator: ";")), colonSyntax: nil)
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
    guard let raw, raw.contains(":") else { return }
    for parameter in raw.split(separator: ";", omittingEmptySubsequences: false) where parameter.contains(":") {
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
    historyByteCount = UInt64(history.reduce(0) { $0 + Int(rowStorageBytes($1)) })
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
    setViewOffset(offset); changed()
  }
  func followTail() { guard !usingAlternate else { return }; viewAnchor = nil; viewOffset = 0; viewportWasClamped = false; changed() }
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
  private func rowStorageBytes(_ row: SwiftRow) -> UInt64 {
    UInt64(row.cells.count + row.cells.reduce(0) { $0 + $1.text.utf8.count })
  }
  private func enforceHistoryLimits() {
    let retainedAnchor = viewAnchor
    var evicted = false
    while history.count > historyLimit || (historyByteCount > UInt64(historyByteLimit) && !history.isEmpty) {
      historyByteCount &-= rowStorageBytes(history.removeFirst())
      evicted = true
    }
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
    history.removeAll(); historyByteCount = 0
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
      capsLock: modifiers & 16 != 0, numLock: modifiers & 32 != 0)
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
    flushText(final: true)
    // OSC 52 writes require BEL/ST framing. EOF is an abort, never an
    // implicit successful terminator.
    parser = .ground
  }
  var hasPendingWork: Bool { repeatRemaining > 0 }
  var publicationGated: Bool { syncDeadline != nil }
  func snapshot(now: UInt64) -> Data? { tick(now); return publicationGated ? nil : snapshotJSON(view: true) }
  func isValid() -> Bool {
    document.hasValidInvariants(primary) && document.hasValidInvariants(alternate) &&
      history.allSatisfy { $0.cells.count == columns }
  }
  func historyBytes() -> UInt64 { historyByteCount }
  func imageRGBA(id: UInt32, generation: UInt64) -> Data? { graphics.imageRGBA(id: id, generation: generation) }
  func startSearch(_ task: SwiftCoreSearchToken) -> UInt32 {
    searchHighlights.removeAll()
    let searchable = history + primary.rows
    for (index, row) in searchable.enumerated() {
      let text = row.cells.map(\ .text).joined()
      guard let range = text.range(of: task.query, options: [.caseInsensitive]) else { continue }
      // Search owns anchoring, so the renderer receives a visible stable hit.
      viewOffset = index < history.count
        ? min(history.count, max(1, history.count - index + rowCount - 1)) : 0
      let allCount = history.count + primary.rows.count
      let visibleEnd = max(rowCount, allCount - viewOffset)
      let visibleStart = max(0, visibleEnd - rowCount)
      let start = text.distance(from: text.startIndex, to: range.lowerBound)
      let end = text.distance(from: text.startIndex, to: range.upperBound)
      searchHighlights.append(["row": max(0, index - visibleStart), "start": start, "end": end])
    }
    return searchHighlights.isEmpty ? 4 : 5
  }
  private func palette() -> [[Int]] {
    var output = [[27,28,31], [239,68,68], [34,197,94], [250,204,21], [96,165,250], [192,132,252], [34,211,238], [212,212,216], [107,111,118], [248,113,113], [74,222,128], [253,224,71], [147,197,253], [216,180,254], [103,232,249], [250,250,250]]
    for red in [0,95,135,175,215,255] { for green in [0,95,135,175,215,255] { for blue in [0,95,135,175,215,255] { output.append([red, green, blue]) } } }
    for index in 0..<24 { let value = 8 + index * 10; output.append([value, value, value]) }
    return output
  }
  private func rowsForSnapshot(view: Bool, scroll: Int? = nil) -> (rows: [SwiftRow], offset: Int) {
    let requested = max(0, scroll ?? viewOffset)
    guard view, !usingAlternate, requested > 0 else { return (screen.rows, 0) }
    let all = history + primary.rows
    let end = max(rowCount, all.count - min(requested, history.count))
    return (Array(all[max(0, end - rowCount)..<end]), min(requested, history.count))
  }
  func publishBinary(view: Bool, scroll: Int, now: UInt64, context: UnsafeMutableRawPointer?, callback: SnapshotCallback?) -> Bool {
    tick(now)
    guard !publicationGated else { return false }
    guard let callback else { return false }
    let selected = rowsForSnapshot(view: view, scroll: view ? nil : scroll)
    guard var header = (try? JSONSerialization.jsonObject(with: snapshotJSON(view: view))) as? [String: Any] else { return false }
    header.removeValue(forKey: "rows")
    header["scroll_offset"] = selected.offset
    header["following_tail"] = selected.offset == 0
    guard let metadata = try? JSONSerialization.data(withJSONObject: header) else { return false }
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
  func snapshotJSON(view: Bool) -> Data {
    let source: [SwiftRow]; let offset: Int
    let selected = rowsForSnapshot(view: view)
    source = selected.rows; offset = selected.offset
    let cursor = screen
    let rows: [[String: Any]] = source.map { row in ["id": row.id, "revision": row.revision, "soft_wrapped": row.softWrapped, "cells": row.cells.map { cell in ["text": cell.text, "kind": ["Empty","Lead1","Lead2","Continuation","WrapSpacer"][Int(cell.kind)], "style": ["foreground": colorJSON(cell.style.foreground), "background": colorJSON(cell.style.background), "underline_color": colorJSON(cell.style.underline), "underline": Int(cell.style.underlineKind), "bold": cell.style.flags & 1 != 0, "faint": cell.style.flags & 2 != 0, "italic": cell.style.flags & 4 != 0, "inverse": cell.style.flags & 8 != 0, "conceal": cell.style.flags & 16 != 0, "strike": cell.style.flags & 32 != 0, "overline": cell.style.flags & 64 != 0, "blink": cell.style.flags & 128 != 0], "link": cell.link as Any, "flags": Int(cell.flags)] } ] }
    let images = graphics.visible(alternate: usingAlternate).map { image in ["image": image.image, "generation": image.generation, "width": image.width, "height": image.height, "source": image.source, "row": image.row, "col": image.column, "columns": image.columns, "rows": image.rows, "offset": image.offset, "natural": image.natural, "z": image.z, "placement": image.placement] as [String: Any] }
    let data: [String: Any] = ["at_prompt":cursor.atPrompt,"input_ready":cursor.inputReady,"search":searchHighlights,"images":images,"revision":revision,"geometry_epoch":geometryEpoch,"document_epoch":documentEpoch,"history_epoch":historyEpoch,"screen_epoch":screenEpoch,"scroll_offset":offset,"following_tail":usingAlternate || viewAnchor == nil,"viewport_clamp_revision":viewportClampRevision,"cols":columns,"rows":rows,"cursor":["row":cursor.cursorRow,"col":cursor.cursorColumn,"pending_wrap":cursor.pendingWrap,"visible":cursorVisible,"shape":Int(cursorShape)],"modes":["application_cursor":applicationCursor,"application_keypad":applicationKeypad,"autowrap":autoWrap,"bracketed_paste":bracketedPaste,"focus":focusReporting,"insert":insertMode,"left_right_margins":leftRightMargins,"mouse":0,"newline":false,"origin":originMode,"reverse_video":reverseVideo,"sgr_mouse":false],"primary_margins":[primary.leftMargin, primary.rightMargin],"alternate_margins":[alternate.leftMargin, alternate.rightMargin],"vertical_margins":[cursor.topMargin, cursor.bottomMargin],"alternate":usingAlternate,"title":title,"history_rows":history.count,"palette":palette(),"default_fg":[230,230,230],"default_bg":[10,10,11]]
    return (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8)
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
@_cdecl("terminal_snapshot") func swift_terminal_snapshot(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64) -> UnsafeMutablePointer<CChar>? { guard let snapshot = core(pointer)?.snapshot(now: now) else { return nil }; return strdup(String(data: snapshot, encoding: .utf8) ?? "{}") }
@_cdecl("terminal_string_free") func swift_terminal_string_free(_ value: UnsafeMutablePointer<CChar>?) { if let value { free(value) } }
@_cdecl("terminal_snapshot_binary") func swift_terminal_snapshot_binary(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(view: false, scroll: scroll, now: now, context: context, callback: callback) ?? false }
@_cdecl("terminal_view_snapshot_binary") func swift_terminal_view_snapshot_binary(_ pointer: OpaquePointer?, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(view: true, scroll: 0, now: now, context: context, callback: callback) ?? false }
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
@_cdecl("terminal_search_create") func swift_terminal_search_create(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) -> OpaquePointer? { guard let bytes, count > 0, let query = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { return nil }; return OpaquePointer(Unmanaged.passRetained(SwiftCoreSearchToken(query)).toOpaque()) }
@_cdecl("terminal_search_destroy") func swift_terminal_search_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_search_fill") func swift_terminal_search_fill(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 { 2 }
@_cdecl("terminal_search_step") func swift_terminal_search_step(_ pointer: OpaquePointer?) -> UInt32 { 2 }
@_cdecl("terminal_search_accept") func swift_terminal_search_accept(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 { guard let terminal = core(pointer), let task else { return 4 }; return terminal.startSearch(Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue()) }

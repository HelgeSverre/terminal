import Foundation

// Swift implementation of the terminal core ABI.  The public C-shaped surface is
// deliberately thin: the state machine owns parsing, grid mutation, history,
// snapshots, and input encoding so neither Session nor the renderer needs to
// duplicate terminal policy.

private typealias SwiftStyle = TerminalStyle
private typealias SwiftCell = TerminalCell
private typealias SwiftRow = TerminalRow
private typealias SwiftScreen = TerminalScreen

private enum SwiftParserState { case ground, escape, csi, osc, apc }

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
    guard !bytes.isEmpty else { return nil }
    let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
    for (offset, byte) in bytes.enumerated() { pointer.advanced(by: offset).initialize(to: byte) }
    target.append(pointer)
    return UnsafePointer(pointer)
  }
}

private final class SwiftTerminalCore {
  private(set) var columns: Int
  private(set) var rowCount: Int
  private var document: TerminalDocument
  private var primary: SwiftScreen { get { document.primary } set { document.primary = newValue } }
  private var alternate: SwiftScreen { get { document.alternate } set { document.alternate = newValue } }
  private var usingAlternate = false
  private var history: [SwiftRow] { get { document.history } set { document.history = newValue } }
  private var historyLimit = 10_000
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
  private var protectedOutput = false
  private var synchronizedOutput = false
  private var parser = SwiftParserState.ground
  private var utf8 = SwiftUnicode.UTF8Decoder()
  private var sequence = ""
  private var pen = SwiftStyle()
  private var currentLink: String?
  private var replies = Data()
  private var title = ""
  private var applicationCursor = false
  private var applicationKeypad = false
  private var kittyKeyboardFlags: UInt32 = 0
  private var bracketedPaste = false
  private var focusReporting = false
  private var reverseVideo = false
  private var cursorVisible = true
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
  private var repeatRemaining = 0

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
    if final {
      for scalar in utf8.finish() { put(String(scalar)) }
    }
  }
  func feed(_ bytes: UnsafePointer<UInt8>?, count: Int) -> Int {
    guard let bytes, count > 0 else { return 0 }
    // REP is intentionally resumable. It keeps the owner responsive and lets
    // an admitted input event observe modes established *after* the repeat.
    if repeatRemaining > 0, !lastPrinted.isEmpty {
      let budget = min(4_096, repeatRemaining)
      for _ in 0..<budget { put(lastPrinted) }
      repeatRemaining -= budget
      return 0
    }
    for (offset, byte) in UnsafeBufferPointer(start: bytes, count: count).enumerated() {
      switch parser {
      case .ground:
        switch byte {
        case 0x1b: flushText(); parser = .escape
        case 0x00...0x07: flushText(); if byte == 0x07 { /* bell belongs to host */ }
        case 0x08: flushText(); backspace()
        case 0x09: flushText(); tab()
        case 0x0a, 0x0b, 0x0c: flushText(); lineFeed()
        case 0x0d: flushText(); carriageReturn()
        default:
          for scalar in utf8.push(byte) { put(String(scalar)) }
        }
      case .escape:
        parser = .ground
        switch byte {
        case 0x5b: sequence = ""; parser = .csi
        case 0x5d: sequence = ""; parser = .osc
        case 0x5f: sequence = ""; parser = .apc
        case 0x37: saveCursor()
        case 0x38: restoreCursor()
        case 0x44: lineFeed()
        case 0x4d: reverseIndex()
        case 0x45: carriageReturn(); lineFeed()
        case 0x63: reset()
        case 0x3d: applicationKeypad = true
        case 0x3e: applicationKeypad = false
        default: break
        }
      case .csi:
        if (0x40...0x7e).contains(byte) {
          handleCSI(sequence, final: Character(UnicodeScalar(byte))); parser = .ground
          if repeatRemaining > 0 { return offset + 1 }
        }
        else if sequence.utf8.count < 16_384 { sequence.unicodeScalars.append(UnicodeScalar(byte)) }
        else { parser = .ground; sequence = "" }
      case .osc, .apc:
        if byte == 0x07 { finishString(); parser = .ground }
        // String Terminator is the two-byte ESC \\ sequence. Keep parser
        // ownership in the string state until the following byte decides it;
        // switching to generic Escape would lose APC/OSC context.
        else if byte == 0x1b { sequence.append("\u{1b}") }
        else if sequence.last == "\u{1b}" && byte == 0x5c { sequence.removeLast(); finishString(); parser = .ground }
        else if sequence.utf8.count < 1_048_576 { sequence.unicodeScalars.append(UnicodeScalar(byte)) }
        else { parser = .ground; sequence = "" }
      }
    }
    return count
  }
  private func put(_ text: String) {
    var s = screen
    let measuredWidth = SwiftUnicode.cellWidth(of: text)
    if measuredWidth == 0 {
      if s.cursorColumn > 0 {
        let owner = document.repairedCellOwner(in: s.rows[s.cursorRow], at: s.cursorColumn - 1)
        s.rows[s.cursorRow].cells[owner].text.append(text)
      }
      screen = s; changed(); return
    }
    let width = min(2, max(1, measuredWidth))
    if s.pendingWrap && autoWrap { wrap(&s) }
    let bounds = writeBounds(s.cursorColumn)
    if width == 2 && s.cursorColumn + 2 > bounds.right + 1 && bounds.right > bounds.left && autoWrap {
      document.erase(&s, row: s.cursorRow, columns: s.cursorColumn..<(s.cursorColumn + 1), style: eraseStyle())
      if bounds.left == 0 && bounds.right == columns - 1 { s.rows[s.cursorRow].cells[s.cursorColumn].kind = 4 }
      wrap(&s)
    }
    guard s.cursorRow < s.rows.count, s.cursorColumn < columns else { return }
    let right = writeBounds(s.cursorColumn).right
    let occupied = min(width, right + 1 - s.cursorColumn)
    if occupied <= 0 { return }
    document.erase(&s, row: s.cursorRow, columns: s.cursorColumn..<(s.cursorColumn + occupied), style: eraseStyle())
    let truncatedWide = width == 2 && occupied < width
    s.rows[s.cursorRow].cells[s.cursorColumn] = SwiftCell(text: text, kind: width == 2 && occupied == 2 ? 2 : 1, style: pen, link: currentLink, flags: (protectedOutput ? 2 : 0) | (truncatedWide ? 1 : 0), protected: protectedOutput)
    lastPrinted = text
    if width == 2 && occupied == 2 { s.rows[s.cursorRow].cells[s.cursorColumn + 1] = SwiftCell(text: "", kind: 3, style: pen, link: currentLink, flags: protectedOutput ? 2 : 0, protected: protectedOutput) }
    let reachesPastRight = s.cursorColumn + occupied > right
    s.cursorColumn = min(right, s.cursorColumn + occupied)
    s.pendingWrap = reachesPastRight && autoWrap
    screen = s; changed()
  }
  private func wrap(_ s: inout SwiftScreen) {
    let old = s.cursorRow
    s.rows[old].softWrapped = horizontalMargins.left == 0 && horizontalMargins.right == columns - 1
    index(&s, reverse: false, allowHistory: true)
    s.cursorColumn = writeBounds(s.cursorColumn).left
    s.pendingWrap = false
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
  private func lineFeed() { var s = screen; s.pendingWrap = false; index(&s, reverse: false, allowHistory: true); screen = s; changed(history: !usingAlternate) }
  private func carriageReturn() { var s = screen; let left = horizontalMargins.left; s.cursorColumn = s.cursorColumn >= left ? left : 0; s.pendingWrap = false; screen = s; changed() }
  private func backspace() { var s = screen; let left = horizontalMargins.left; s.cursorColumn = max(s.cursorColumn >= left ? left : 0, s.cursorColumn - 1); s.pendingWrap = false; screen = s; changed() }
  private func tab(_ reverse: Bool = false, count: Int = 1) { var s = screen; let margins = horizontalMargins; let left = s.cursorColumn >= margins.left ? margins.left : 0; let right = writeBounds(s.cursorColumn).right; for _ in 0..<min(count, columns) { if reverse { s.cursorColumn = stride(from: s.cursorColumn - 1, through: left, by: -1).first(where: { $0 > 0 && $0 % 8 == 0 }) ?? left } else { s.cursorColumn = ((s.cursorColumn + 1)...right).first(where: { $0 > 0 && $0 % 8 == 0 }) ?? right } }; s.pendingWrap = false; screen = s; changed() }
  private func reverseIndex() { var s = screen; s.pendingWrap = false; index(&s, reverse: true, allowHistory: false); screen = s; changed() }
  private func saveCursor() { var s = screen; s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedOrigin = originMode; screen = s }
  private func restoreCursor() { var s = screen; originMode = s.savedOrigin; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = false; screen = s; changed() }
  private func reset() { document = TerminalDocument(columns: columns, rows: rowCount); usingAlternate = false; history.removeAll(); viewAnchor = nil; viewOffset = 0; pen = SwiftStyle(); originMode = false; leftRightMargins = false; autoWrap = true; protectedOutput = false; synchronizedOutput = false; cursorVisible = true; changed(history: true) }
  private func parameters(_ raw: String) -> [Int] { raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 } }
  private func handleCSI(_ raw: String, final: Character) {
    let privateMode = raw.first == "?"
    let command = privateMode ? String(raw.dropFirst()) : raw
    let params = parameters(command.filter { $0 == ";" || $0.isNumber })
    let n = max(1, params.first ?? 0)
    var s = screen
    var changedActiveScreen = false
    var semanticChange = true
    switch final {
    case "A": s.cursorRow = max(originMode ? s.topMargin : 0, s.cursorRow - n)
    case "B": s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, s.cursorRow + n)
    case "C": s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, s.cursorColumn + n)
    case "D": s.cursorColumn = max(originMode ? horizontalMargins.left : 0, s.cursorColumn - n)
    case "G": s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + n - 1)
    case "d": s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, (originMode ? s.topMargin : 0) + n - 1)
    case "H", "f": s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, (originMode ? s.topMargin : 0) + max(0, (params.first ?? 1) - 1)); s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + max(0, (params.dropFirst().first ?? 1) - 1))
    case "J": eraseDisplay(params.first ?? 0); changedActiveScreen = true
    case "K": eraseLine(params.first ?? 0); changedActiveScreen = true
    case "@": insertCharacters(n); changedActiveScreen = true
    case "P": deleteCharacters(n); changedActiveScreen = true
    case "L": insertLines(n); changedActiveScreen = true
    case "M": deleteLines(n); changedActiveScreen = true
    case "I": tab(false, count: n); changedActiveScreen = true
    case "Z": tab(true, count: n); changedActiveScreen = true
    case "r": setVerticalMargins(params); changedActiveScreen = true
    case "S": scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: true, allowHistory: false)
    case "T": scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: false, allowHistory: false)
    case "b": repeatRemaining = min(1_000_000, max(0, params.first ?? 1))
    case "m": applySGR(params)
    case "s":
      if leftRightMargins { setHorizontalMargins(params); changedActiveScreen = true }
      else { s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; s.savedOrigin = originMode }
    case "u":
      if raw.first == ">" { kittyKeyboardFlags = UInt32(max(0, parameters(String(raw.dropFirst())).first ?? 0)) & 31 }
      else if raw.first == "?" { replies.append(contentsOf: "\u{1b}[?\(kittyKeyboardFlags)u".utf8) }
      else { originMode = s.savedOrigin; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; if originMode { s.cursorRow = min(max(s.cursorRow, s.topMargin), s.bottomMargin); s.cursorColumn = min(max(s.cursorColumn, horizontalMargins.left), horizontalMargins.right) }; s.pendingWrap = false }
    case "n": if params.first == 5 { replies.append(contentsOf: "\u{1b}[0n".utf8) } else if params.first == 6 { let row = s.cursorRow + 1 - (originMode ? s.topMargin : 0); let column = s.cursorColumn + 1 - (originMode ? horizontalMargins.left : 0); replies.append(contentsOf: "\u{1b}[\(row);\(column)R".utf8) }
    case "c": replies.append(contentsOf: "\u{1b}[?62;4c".utf8)
    case "p" where privateMode && raw.hasSuffix("$"):
      replies.append(contentsOf: "\u{1b}[?\(params.first ?? 0);\(params.first == 69 ? (leftRightMargins ? 1 : 2) : 0)$y".utf8)
    case "p" where raw.hasSuffix("!"): softReset(); changedActiveScreen = true
    case "q" where raw.hasSuffix("\""): protectedOutput = (params.first ?? 0) == 1
    case "h", "l":
      if privateMode, params.allSatisfy({ [47, 1047, 1049].contains($0) }), params.allSatisfy({ _ in usingAlternate == (final == "h") }) { semanticChange = false }
      changedActiveScreen = setMode(params, enabled: final == "h", privateMode: privateMode)
    default: break
    }
    // DEC alternate-screen modes swap the screen object.  Keeping the swap
    // inside mode ownership prevents this generic CSI epilogue from writing a
    // stale primary copy back into the newly active alternate buffer.
    if !changedActiveScreen { s.pendingWrap = false; screen = s }
    if semanticChange { changed() }
  }
  private func eraseDisplay(_ mode: Int) { var s = screen; switch mode { case 2, 3: s.rows = (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }; if mode == 3 && !usingAlternate { history.removeAll(); historyEpoch &+= 1 }; case 1: for row in 0...s.cursorRow { document.erase(&s, row: row, columns: 0..<(row == s.cursorRow ? s.cursorColumn + 1 : columns), style: eraseStyle()) }; default: for row in s.cursorRow..<rowCount { document.erase(&s, row: row, columns: (row == s.cursorRow ? s.cursorColumn : 0)..<columns, style: eraseStyle()) } }; s.pendingWrap = false; screen = s }
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
        if viewAnchor != nil { viewOffset += 1 }
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit); clampViewportAfterEviction() }
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
  private func applySGR(_ p: [Int]) {
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
      case 22: pen.flags &= ~UInt16(3)
      case 23: pen.flags &= ~UInt16(4)
      case 24: pen.underlineKind = 0
      case 27: pen.flags &= ~UInt16(8)
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
  }
  private func setMode(_ params: [Int], enabled: Bool, privateMode: Bool) -> Bool {
    var changedActiveScreen = false
    for mode in params where privateMode {
      switch mode {
      case 1: applicationCursor = enabled
      case 6: originMode = enabled; var s = screen; s.cursorRow = enabled ? s.topMargin : 0; s.cursorColumn = enabled ? horizontalMargins.left : 0; s.pendingWrap = false; screen = s; changedActiveScreen = true
      case 7: autoWrap = enabled; if !enabled { var s = screen; s.pendingWrap = false; screen = s }; changedActiveScreen = true
      case 25: cursorVisible = enabled
      case 47, 1047, 1049:
        usingAlternate = enabled
        if enabled && (params.contains(1047) || params.contains(1049)) { alternate = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns) }
        changedActiveScreen = true
      case 1004: focusReporting = enabled
      case 2004: bracketedPaste = enabled
      case 5: reverseVideo = enabled
      case 69:
        leftRightMargins = enabled
        if !enabled { primary.leftMargin = 0; primary.rightMargin = columns - 1; primary.pendingWrap = false; alternate.leftMargin = 0; alternate.rightMargin = columns - 1; alternate.pendingWrap = false; originMode = false }
        changedActiveScreen = true
      case 2026: synchronizedOutput = enabled
      default: break
      }
    }
    return changedActiveScreen
  }
  private func softReset() {
    originMode = false; leftRightMargins = false; autoWrap = true; protectedOutput = false
    pen = SwiftStyle(); currentLink = nil; applicationCursor = false; applicationKeypad = false
    bracketedPaste = false; focusReporting = false
    var s = screen; s.topMargin = 0; s.bottomMargin = rowCount - 1; s.cursorRow = 0; s.cursorColumn = 0; s.pendingWrap = false; screen = s
    primary.leftMargin = 0; primary.rightMargin = columns - 1; alternate.leftMargin = 0; alternate.rightMargin = columns - 1
  }
  private func finishString() {
    let payload = sequence; sequence = ""
    if parser == .osc {
      let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
      guard let command = parts.first else { return }
      if command == "0" || command == "2" { title = parts.dropFirst().joined(separator: ";") }
      else if command == "8" { currentLink = parts.count > 2 ? String(parts.dropFirst(2).joined(separator: ";")) : nil }
      else if command == "133" {
        let marker = parts.dropFirst().first
        var current = screen
        switch marker {
        case "A", "B":
          current.atPrompt = true
          if marker == "A" {
            current.promptRedraw = parts.dropFirst(2).contains { $0 == "redraw=1" }
            current.promptAnchor = PromptAnchor(row: current.rows[current.cursorRow].id,
                                                column: current.cursorColumn,
                                                pendingWrap: current.pendingWrap)
          }
        case "C", "D": current.atPrompt = false; current.promptRedraw = false; current.promptAnchor = nil
        default: break
        }
        screen = current
      }
      return
    }
    guard parser == .apc else { return }
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
  func resize(columns nextColumns: Int, rows nextRows: Int) -> Bool {
    guard (1...4096).contains(nextColumns), (1...4096).contains(nextRows), nextColumns <= 1_048_576 / nextRows else { return false }
    if nextColumns == columns && nextRows == rowCount { return true }
    if !usingAlternate && primary.promptRedraw {
      var promptScreen = primary
      _ = document.clearPromptSuffix(&promptScreen, eraseStyle: eraseStyle())
      primary = promptScreen
    }
    let oldAlternate = alternate
    let mapped = document.reflowPrimary(columns: nextColumns, rows: nextRows, anchor: viewAnchor)
    let resizedAlternate = document.resize(oldAlternate, columns: nextColumns, rows: nextRows)
    columns = nextColumns; rowCount = nextRows; alternate = resizedAlternate
    viewAnchor = mapped.anchor ?? viewAnchor
    resolveViewportAnchor(clamp: true)
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
  func setHistoryLimit(_ value: Int) { historyLimit = max(0, value); if history.count > historyLimit { history.removeFirst(history.count - historyLimit); historyEpoch &+= 1; clampViewportAfterEviction() }; _ = resolveViewportAnchor(clamp: true) }
  func clearDisplay() -> UInt32 {
    guard !usingAlternate else { return 0 }
    var current = primary
    let action: UInt32 = current.atPrompt ? 1 : 2
    history.removeAll()
    viewAnchor = nil; viewOffset = 0; viewportWasClamped = false
    if current.atPrompt {
      let margins = (current.topMargin, current.bottomMargin, current.leftMargin, current.rightMargin)
      current = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns)
      current.topMargin = margins.0; current.bottomMargin = margins.1
      current.leftMargin = margins.2; current.rightMargin = margins.3
      current.atPrompt = true
      current.promptRedraw = primary.promptRedraw
      current.promptAnchor = PromptAnchor(row: current.rows[0].id, column: 0, pendingWrap: false)
    } else {
      let retained = Array(current.rows.dropFirst(current.cursorRow))
      current.rows = retained + (0..<(rowCount - retained.count)).map { _ in document.eraseRow(eraseStyle()) }
      current.cursorRow = 0
    }
    primary = current
    graphics.clear(alternate: false, removeResources: true)
    changed(history: true, document: action != 1)
    return action
  }
  func input(_ text: String, key: UInt32, modifiers: UInt32, event: UInt32) -> Data? {
    let modes = SwiftInputEncoder.Modes(
      applicationCursor: applicationCursor, applicationKeypad: applicationKeypad,
      bracketedPaste: bracketedPaste, focusReporting: focusReporting, kittyFlags: kittyKeyboardFlags)
    if key == 1 { return SwiftInputEncoder.paste(text, modes: modes) }
    if key == 2 { return SwiftInputEncoder.focus(event == 1, modes: modes) }
    let modifier = SwiftInputEncoder.Modifiers(
      shift: modifiers & 1 != 0, option: modifiers & 2 != 0,
      control: modifiers & 4 != 0, command: modifiers & 8 != 0)
    let phase: SwiftInputEncoder.Event = event == 1 ? .repeatKey : event == 2 ? .release : .press
    guard let semantic = inputKey(key, text: text) else { return Data() }
    return SwiftInputEncoder.key(semantic, modifiers: modifier, event: phase, modes: modes)
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
    if code == 0 || code == 200 { return text.first.map { .character($0) } }
    return nil
  }
  func takeReplies() -> Data { defer { replies.removeAll(keepingCapacity: true) }; return replies }
  func finish() { flushText(final: true) }
  var hasPendingWork: Bool { repeatRemaining > 0 }
  var publicationGated: Bool { synchronizedOutput }
  func historyBytes() -> UInt64 { UInt64(history.reduce(0) { $0 + $1.cells.reduce(0) { $0 + $1.text.utf8.count } }) }
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
  func publishBinary(view: Bool, scroll: Int, context: UnsafeMutableRawPointer?, callback: SnapshotCallback?) -> Bool {
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
    let data: [String: Any] = ["at_prompt":cursor.atPrompt,"search":searchHighlights,"images":images,"revision":revision,"geometry_epoch":geometryEpoch,"document_epoch":documentEpoch,"history_epoch":historyEpoch,"screen_epoch":screenEpoch,"scroll_offset":offset,"following_tail":usingAlternate || viewAnchor == nil,"viewport_clamp_revision":viewportClampRevision,"cols":columns,"rows":rows,"cursor":["row":cursor.cursorRow,"col":cursor.cursorColumn,"pending_wrap":cursor.pendingWrap,"visible":cursorVisible,"shape":0],"modes":["application_cursor":applicationCursor,"application_keypad":applicationKeypad,"autowrap":autoWrap,"bracketed_paste":bracketedPaste,"focus":focusReporting,"insert":false,"left_right_margins":leftRightMargins,"mouse":0,"newline":false,"origin":originMode,"reverse_video":reverseVideo,"sgr_mouse":false],"primary_margins":[primary.leftMargin, primary.rightMargin],"alternate_margins":[alternate.leftMargin, alternate.rightMargin],"vertical_margins":[cursor.topMargin, cursor.bottomMargin],"alternate":usingAlternate,"title":title,"history_rows":history.count,"palette":palette(),"default_fg":[230,230,230],"default_bg":[10,10,11]]
    return (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8)
  }
  private func colorJSON(_ color: UInt32) -> Any { if color >> 24 == 1 { return ["Indexed": Int(color & 255)] }; if color >> 24 == 2 { return ["Rgb": [Int((color >> 16) & 255), Int((color >> 8) & 255), Int(color & 255)]] }; return "Default" }
}

// MARK: C ABI bridge. The app still imports Bridge.h, allowing a mechanical
// replacement of the static Rust archive while all native call sites stay stable.

private func core(_ pointer: OpaquePointer?) -> SwiftTerminalCore? { pointer.map { Unmanaged<SwiftTerminalCore>.fromOpaque(UnsafeMutableRawPointer($0)).takeUnretainedValue() } }
typealias BytesCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
typealias SnapshotCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int) -> Void

@_cdecl("terminal_abi_version") func swift_terminal_abi_version() -> UInt32 { 1 }
@_cdecl("terminal_create") func swift_terminal_create(_ cols: UInt32, _ rows: UInt32) -> OpaquePointer? { OpaquePointer(Unmanaged.passRetained(SwiftTerminalCore(columns: Int(cols), rows: Int(rows))).toOpaque()) }
@_cdecl("terminal_destroy") func swift_terminal_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<SwiftTerminalCore>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_feed") func swift_terminal_feed(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ now: UInt64) -> Int { core(pointer)?.feed(bytes, count: count) ?? 0 }
@_cdecl("terminal_resize") func swift_terminal_resize(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows)) ?? false }
@_cdecl("terminal_resize_pixels") func swift_terminal_resize_pixels(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32, _ width: UInt32, _ height: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows), cellWidth: Int(width), cellHeight: Int(height)) ?? false }
@_cdecl("terminal_finish") func swift_terminal_finish(_ pointer: OpaquePointer?) { core(pointer)?.finish() }
@_cdecl("terminal_validate") func swift_terminal_validate(_ pointer: OpaquePointer?) -> Bool { core(pointer) != nil }
@_cdecl("terminal_has_work") func swift_terminal_has_work(_ pointer: OpaquePointer?) -> Bool { core(pointer)?.hasPendingWork ?? false }
@_cdecl("terminal_set_history_limit") func swift_terminal_set_history_limit(_ pointer: OpaquePointer?, _ limit: UInt32) { core(pointer)?.setHistoryLimit(Int(limit)) }
@_cdecl("terminal_history_bytes") func swift_terminal_history_bytes(_ pointer: OpaquePointer?) -> UInt64 { core(pointer)?.historyBytes() ?? 0 }
@_cdecl("terminal_snapshot") func swift_terminal_snapshot(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64) -> UnsafeMutablePointer<CChar>? { guard let value = core(pointer), !value.publicationGated else { return nil }; return strdup(String(data: value.snapshotJSON(view: true), encoding: .utf8) ?? "{}") }
@_cdecl("terminal_string_free") func swift_terminal_string_free(_ value: UnsafeMutablePointer<CChar>?) { if let value { free(value) } }
@_cdecl("terminal_snapshot_binary") func swift_terminal_snapshot_binary(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(view: false, scroll: scroll, context: context, callback: callback) ?? false }
@_cdecl("terminal_view_snapshot_binary") func swift_terminal_view_snapshot_binary(_ pointer: OpaquePointer?, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(view: true, scroll: 0, context: context, callback: callback) ?? false }
@_cdecl("terminal_view_scroll") func swift_terminal_view_scroll(_ pointer: OpaquePointer?, _ amount: Int64) { core(pointer)?.scroll(Int(amount)) }
@_cdecl("terminal_view_follow_tail") func swift_terminal_view_follow_tail(_ pointer: OpaquePointer?) { core(pointer)?.followTail() }
@_cdecl("terminal_clear_display") func swift_terminal_clear_display(_ pointer: OpaquePointer?) -> UInt32 { core(pointer)?.clearDisplay() ?? 0 }
@_cdecl("terminal_replies") func swift_terminal_replies(_ pointer: OpaquePointer?, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) { guard let callback, let data = core(pointer)?.takeReplies(), !data.isEmpty else { return }; data.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, data.count) } }
@_cdecl("terminal_input") func swift_terminal_input(_ pointer: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ key: UInt32, _ modifiers: UInt32, _ event: UInt32, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { guard let value = core(pointer)?.input(text.map { String(cString: $0) } ?? "", key: key, modifiers: modifiers, event: event) else { return false }; if let callback, !value.isEmpty { value.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, value.count) } }; return true }
@_cdecl("terminal_image_rgba") func swift_terminal_image_rgba(_ pointer: OpaquePointer?, _ image: UInt32, _ generation: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { guard let callback, let pixels = core(pointer)?.imageRGBA(id: image, generation: generation) else { return false }; pixels.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, pixels.count) }; return true }
@_cdecl("terminal_search_create") func swift_terminal_search_create(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) -> OpaquePointer? { guard let bytes, count > 0, let query = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { return nil }; return OpaquePointer(Unmanaged.passRetained(SwiftCoreSearchToken(query)).toOpaque()) }
@_cdecl("terminal_search_destroy") func swift_terminal_search_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_search_fill") func swift_terminal_search_fill(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 { 2 }
@_cdecl("terminal_search_step") func swift_terminal_search_step(_ pointer: OpaquePointer?) -> UInt32 { 2 }
@_cdecl("terminal_search_accept") func swift_terminal_search_accept(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 { guard let terminal = core(pointer), let task else { return 4 }; return terminal.startSearch(Unmanaged<SwiftCoreSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue()) }

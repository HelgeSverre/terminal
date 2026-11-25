import Foundation

extension TerminalEmulator {
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
    case (0x3f, nil): return [0x4a, 0x4b, 0x68, 0x6c, 0x6d, 0x6e, 0x72, 0x73, 0x75].contains(final)
    // Keyboard flags (set, push, pop); secondary device attributes.
    case (0x3d, nil), (0x3c, nil): return final == 0x75
    case (0x3e, nil): return [0x75, 0x63, 0x6d, 0x6e, 0x71].contains(final)
    // DECSTR, DECSCA, DECSCUSR, DECRQM for an ANSI or a private mode.
    case (nil, 0x21): return final == 0x70
    case (nil, 0x24): return [0x70, 0x76, 0x78, 0x7a, 0x7b].contains(final)
    case (nil, 0x22), (nil, 0x20): return final == 0x71
    case (0x3f, 0x24): return final == 0x70
    // DECRQCRA.
    case (nil, 0x2a): return final == 0x79
    case (nil, 0x27): return final == 0x7d || final == 0x7e
    default: return false
    }
  }
  func handleCSI(_ raw: [UInt8], final: UInt8) {
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
    if (raw.first == 0x3e && (final == 0x6d || final == 0x6e))
      || (raw.first == 0x3f && final == 0x6d) {
      // Resource controls must never reach SGR/DSR. Unsupported resources and
      // subparameter masks are ignored without changing the current setting.
      guard !packet.hasColon else { return }
      let params = packet.values
      if raw.first == 0x3f {
        if params == [4] { replies.append(contentsOf: "\u{1b}[>4;\(modifyOtherKeys)m".utf8) }
      } else if final == 0x6e {
        if params == [4] { modifyOtherKeys = -1; changed() }
      } else if params == [0] || params == [4] {
        modifyOtherKeys = 0; changed()
      } else if params.count == 2, params[0] == 4, (0...3).contains(params[1]) {
        modifyOtherKeys = params[1]; changed()
      }
      return
    }
    // SGR changes the pen only. Preserve the usual semantic revision without
    // copying and writing back an unchanged screen or clearing pending wrap.
    if final == 0x6d {
      applySGR(packet.values, colonSyntax: packet.hasColon ? String(decoding: raw, as: UTF8.self) : nil)
      changed()
      return
    }
    if final == 0x71, raw.first == 0x3e {
      if raw.dropFirst().allSatisfy({ $0 == 0x30 }) { replies.append(contentsOf: identity.versionReply.utf8) }
      return
    }
    let params = packet.values
    let first = raw.first
    let last = raw.last
    let privateMode = first == 0x3f
    let n = max(1, params.first ?? 0)
    if last == 0x24, [0x76, 0x78, 0x7a, 0x7b].contains(final) {
      editRectangle(params, final: final); changed(); return
    }
    if last == 0x27, final == 0x7d || final == 0x7e {
      shiftColumns(n, inserting: final == 0x7d); changed(); return
    }
    var s = screen
    var changedActiveScreen = false
    var semanticChange = true
    var clearsPending = true
    switch final {
    case 0x41: moveCursorVertically(&s, up: true, count: n)
    case 0x42: moveCursorVertically(&s, up: false, count: n)
    case 0x43: s.cursorColumn = min(s.cursorColumn <= horizontalMargins.right ? horizontalMargins.right : columns - 1, s.cursorColumn + n)
    case 0x44: moveCursorBackward(&s, count: n)
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
    // HPA, HPR and VPR do what CHA, CUF and CUD do, as in xterm.
    case 0x60: s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + n - 1)
    case 0x61: s.cursorColumn = min(s.cursorColumn <= horizontalMargins.right ? horizontalMargins.right : columns - 1, s.cursorColumn + n)
    case 0x65: moveCursorVertically(&s, up: false, count: n)
    case 0x48, 0x66: s.cursorRow = min(originMode ? s.bottomMargin : rowCount - 1, (originMode ? s.topMargin : 0) + max(0, (params.first ?? 1) - 1)); s.cursorColumn = min(originMode ? horizontalMargins.right : columns - 1, (originMode ? horizontalMargins.left : 0) + max(0, (params.dropFirst().first ?? 1) - 1))
    case 0x4a: eraseDisplay(params.first ?? 0, selective: privateMode); changedActiveScreen = true
    case 0x4b: eraseLine(params.first ?? 0, selective: privateMode); changedActiveScreen = true
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
    case 0x72 where !privateMode: setVerticalMargins(params); changedActiveScreen = true
    case 0x53: resetClusterBoundary(); scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: true, allowHistory: true)
    case 0x54: resetClusterBoundary(); scroll(&s, top: s.topMargin, bottom: s.bottomMargin, count: n, up: false, allowHistory: false)
    case 0x62:
      repeatRemaining = lastPrinted == nil ? 0 : min(1_000_000, n)
      clearsPending = false
    case 0x72 where privateMode:
      for mode in params {
        if let enabled = savedPrivateModes[mode] {
          changedActiveScreen = setMode([mode], enabled: enabled, privateMode: true) || changedActiveScreen
        }
      }
    case 0x73 where privateMode:
      for mode in params {
        let report = modeReport(mode, privateMode: true)
        if report == 1 || report == 2 { savedPrivateModes[mode] = report == 1 }
      }
      clearsPending = false
    case 0x73:
      if leftRightMargins { setHorizontalMargins(params); changedActiveScreen = true }
      else { saveCursor(); changedActiveScreen = true; clearsPending = false }
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
      else { restoreCursor(); changedActiveScreen = true }
    case 0x6e where privateMode && Self.deviceStatus(params) != nil:
      clearsPending = false; replies.append(contentsOf: Self.deviceStatus(params)!.utf8)
    case 0x6e: clearsPending = false; if privateMode && params.first == 996 { replies.append(contentsOf: colorSchemeReply.utf8) } else if params.first == 5 { replies.append(contentsOf: "\u{1b}[0n".utf8) } else if params.first == 6 { let row = max(1, s.cursorRow + 1 - (originMode ? s.topMargin : 0)); let column = max(1, s.cursorColumn + 1 - (originMode ? horizontalMargins.left : 0)); replies.append(contentsOf: "\u{1b}[\(privateMode ? "?" : "")\(row);\(column)R".utf8) }
    // Secondary device attributes: a VT220-class terminal, firmware version
    // 10, no ROM cartridge. Primary attributes otherwise.
    case 0x63 where first == 0x3e: clearsPending = false; replies.append(contentsOf: "\u{1b}[>1;10;0c".utf8)
    // VT220 with Sixel graphics (4) and ANSI color (22).
    case 0x63: clearsPending = false; replies.append(contentsOf: Self.primaryDeviceAttributes.utf8)
    // DECRQCRA: the checksum of a rectangle's characters, as xterm (patch
    // 334 and later) gives it: their code points summed, an empty cell
    // counted as a space, modulo 65536. Coordinates follow origin mode.
    // XTWINOPS reports, the ones that only read: the text area in pixels
    // (14), a cell in pixels (16), the text area in cells (18) and the
    // screen in cells (19, the same here). Changing the window is not done.
    case 0x74 where first != 0x3e && last != 0x24:
      clearsPending = false
      switch params.first ?? 0 {
      case 14: replies.append(contentsOf: "\u{1b}[4;\(rowCount * cellPixelHeight);\(columns * cellPixelWidth)t".utf8)
      case 16: replies.append(contentsOf: "\u{1b}[6;\(cellPixelHeight);\(cellPixelWidth)t".utf8)
      // 20 and 21 would report the icon and window titles. They are not
      // answered: a title is set by output, so reporting it lets output
      // place its own text in the input stream.
      case 22:
        let which = params.count > 1 ? params[1] : 0
        if (0...2).contains(which), params.count <= 2 || params[2] == 0 {
          if titleStack.count == 16 { titleStack.removeFirst() }
          titleStack.append((which == 1 ? nil : title, which == 2 ? nil : iconTitle))
        }
      case 23:
        let which = params.count > 1 ? params[1] : 0
        if (0...2).contains(which), params.count <= 2 || params[2] == 0, let saved = titleStack.popLast() {
          // A partial frame inherits its missing title from the nearest
          // older frame, matching xterm's mixed icon/window stack behavior.
          let restoredTitle = saved.title ?? titleStack.reversed().first(where: { $0.title != nil })?.title
          let restoredIcon = saved.icon ?? titleStack.reversed().first(where: { $0.icon != nil })?.icon
          if which != 1, let value = restoredTitle { title = value }
          if which != 2, let value = restoredIcon { iconTitle = value }
        }
      case 18, 19: replies.append(contentsOf: "\u{1b}[\((params.first ?? 18) == 18 ? 8 : 9);\(rowCount);\(columns)t".utf8)
      default: break
      }
    case 0x79 where last == 0x2a:
      clearsPending = false
      func value(_ index: Int, _ fallback: Int) -> Int { index < params.count && params[index] > 0 ? params[index] : fallback }
      let originRow = originMode ? s.topMargin : 0, originColumn = originMode && leftRightMargins ? s.leftMargin : 0
      let lastRow = originMode ? s.bottomMargin : rowCount - 1, lastColumn = originMode && leftRightMargins ? s.rightMargin : columns - 1
      let top = min(lastRow, originRow + value(2, 1) - 1), left = min(lastColumn, originColumn + value(3, 1) - 1)
      let bottom = min(lastRow, originRow + value(4, lastRow - originRow + 1) - 1)
      let right = min(lastColumn, originColumn + value(5, lastColumn - originColumn + 1) - 1)
      var sum: UInt32 = 0
      if top <= bottom, left <= right {
        for row in top...bottom where s.rows.indices.contains(row) {
          for column in left...right where column < s.rows[row].count {
            let cell = s.rows[row].cell(column)
            if cell.kind == 3 { continue }
            sum &+= cell.text.unicodeScalars.first.map { $0.value } ?? 0x20
          }
        }
      }
      replies.append(contentsOf: "\u{1b}P\(params.first ?? 0)!~\(String(format: "%04X", sum & 0xffff))\u{1b}\\".utf8)
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
  private func eraseDisplay(_ mode: Int, selective: Bool = false) {
    guard (0...3).contains(mode) else { return }
    if mode == 3 {
      if !usingAlternate {
        document.clearHistory(); advanceSearchGeneration(); historyEpoch &+= 1
        // Clearing retained rows evicts a pinned viewport's content; it
        // does not express the user's intent to start following output.
        resolveViewportAnchor(clamp: true)
      }
      return
    }
    if mode == 2 && !selective { graphics.clear(alternate: usingAlternate) }
    var s = screen
    let top = mode == 0 ? s.cursorRow : 0
    let bottom = mode == 1 ? s.cursorRow : rowCount - 1
    for row in top...bottom {
      let left = mode == 0 && row == s.cursorRow ? s.cursorColumn : 0
      let right = mode == 1 && row == s.cursorRow ? s.cursorColumn + 1 : columns
      document.erase(&s, row: row, columns: left..<right, style: eraseStyle(), selective: selective,
                     respectISOProtection: !selective && isoEraseProtection)
    }
    s.pendingWrap = false; screen = s
  }
  private func eraseLine(_ mode: Int, selective: Bool = false) {
    guard (0...2).contains(mode) else { return }
    var s = screen
    let range = (mode == 0 ? s.cursorColumn : 0)..<(mode == 1 ? s.cursorColumn + 1 : columns)
    document.erase(&s, row: s.cursorRow, columns: range, style: eraseStyle(), selective: selective,
                   respectISOProtection: !selective && isoEraseProtection)
    s.pendingWrap = false; screen = s
  }
  /// DEC rectangle coordinates are page-relative unless DECOM is enabled.
  /// A start outside the page is empty; only the bottom/right are clipped.
  private func editRectangle(_ params: [Int], final: UInt8) {
    var s = screen
    let originRow = originMode ? s.topMargin : 0
    let originColumn = originMode ? horizontalMargins.left : 0
    let lastRow = originMode ? s.bottomMargin : rowCount - 1
    let lastColumn = originMode ? horizontalMargins.right : columns - 1
    func value(_ index: Int, _ fallback: Int) -> Int {
      index < params.count && params[index] > 0 ? params[index] : fallback
    }
    let offset = final == 0x78 ? 1 : 0
    let top = originRow + value(offset, 1) - 1
    let left = originColumn + value(offset + 1, 1) - 1
    let bottom = min(lastRow, originRow + value(offset + 2, lastRow - originRow + 1) - 1)
    let right = min(lastColumn, originColumn + value(offset + 3, lastColumn - originColumn + 1) - 1)
    guard top <= bottom, left <= right else { return }
    if final == 0x76 {
      // This emulator has one page. Page 0 means the current page.
      guard value(4, 1) == 1, value(7, 1) == 1 else { return }
      let destinationTop = originRow + value(5, 1) - 1
      let destinationLeft = originColumn + value(6, 1) - 1
      document.copyRectangle(&s, top: top, left: left, bottom: bottom, right: right,
                             destinationTop: destinationTop, destinationLeft: destinationLeft,
                             lastRow: lastRow, lastColumn: lastColumn, eraseStyle: eraseStyle())
    } else if final == 0x78 {
      let code = params.first ?? 0
      guard (32...126).contains(code) || (160...255).contains(code),
            let scalar = Unicode.Scalar(code) else { return }
      document.fillRectangle(&s, top: top, left: left, bottom: bottom, right: right, scalar: scalar, style: pen)
    } else {
      for row in top...bottom {
        document.erase(&s, row: row, columns: left..<(right + 1), style: eraseStyle(), selective: final == 0x7b)
      }
    }
    // Rectangular operations do not move the cursor or change deferred wrap.
    screen = s
  }
  private func shiftColumns(_ count: Int, inserting: Bool) {
    var s = screen
    let margins = horizontalMargins
    guard (s.topMargin...s.bottomMargin).contains(s.cursorRow),
          (margins.left...margins.right).contains(s.cursorColumn) else { return }
    for row in s.topMargin...s.bottomMargin {
      document.shift(&s, row: row, column: s.cursorColumn, right: margins.right,
                     count: count, inserting: inserting, eraseStyle: eraseStyle())
    }
    s.pendingWrap = false; screen = s
  }
  func horizontalIndex(reverse: Bool) {
    resetClusterBoundary()
    var s = screen
    let margins = horizontalMargins
    let edge = reverse ? margins.left : margins.right
    if s.cursorColumn == edge, (s.topMargin...s.bottomMargin).contains(s.cursorRow) {
      for row in s.topMargin...s.bottomMargin {
        document.shift(&s, row: row, column: margins.left, right: margins.right,
                       count: 1, inserting: reverse, eraseStyle: eraseStyle())
      }
    } else {
      s.cursorColumn = min(columns - 1, max(0, s.cursorColumn + (reverse ? -1 : 1)))
    }
    s.pendingWrap = false; screen = s; changed()
  }
  private func eraseCharacters(_ count: Int) {
    var s = screen
    let end = s.cursorColumn + min(count, columns - s.cursorColumn)
    document.erase(&s, row: s.cursorRow, columns: s.cursorColumn..<end, style: eraseStyle(), respectISOProtection: isoEraseProtection)
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
      if graphics.hasPlacements {
        graphics.scrollRectangle(alternate: usingAlternate, rows: s.rows.map(\.id), top: top, bottom: bottom,
          left: margins.left, right: margins.right, amount: amount, up: up)
      }
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
  func applySGR(_ p: [Int], colonSyntax raw: String? = nil) {
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
  func applySGR(_ values: UnsafeBufferPointer<Int>) {
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
  /// DECRQM status: 1 set, 2 reset, 4 permanently reset, 0 for a mode
  /// `setMode` does not implement. Status 4 covers the ECMA-48 editing and
  /// transfer modes and DECHCCM, which this terminal can never enter.
  private func modeReport(_ mode: Int, privateMode: Bool) -> Int {
    if privateMode, mode == 2031 { return colorSchemeReports ? 1 : 2 }
    if privateMode, mode == 2027 { return graphemeClustering ? 1 : 2 }
    let enabled: Bool
    if !privateMode {
      switch mode {
      case 4: enabled = insertMode
      case 20: enabled = newlineMode
      case 1, 5, 7, 10, 11, 13...19: return 4
      default: return 0
      }
    } else {
      switch mode {
      case 1: enabled = applicationCursor
      case 5: enabled = reverseVideo
      case 6: enabled = originMode
      case 7: enabled = autoWrap
      case 45: enabled = reverseWrap
      case 41: enabled = cursesTabWrap
      case 1045: enabled = reverseWrapUnlimited
      case 25: enabled = screen.cursorVisible
      case 47, 1047, 1049: enabled = usingAlternate
      case 66: enabled = applicationKeypad
      case 69: enabled = leftRightMargins
      case 80: enabled = sixelDisplayMode
      case 8452: enabled = sixelCursorRight
      case 9, 1000, 1002, 1003: enabled = mouseMode == mode
      case 1004: enabled = focusReporting
      case 1005, 1006, 1015, 1016: enabled = mouseEncoding == mode
      case 2004: enabled = bracketedPaste
      case 2026: enabled = syncDeadline != nil
      case 60: return 4
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
      case 66: applicationKeypad = enabled
      case 6: originMode = enabled; var s = screen; s.cursorRow = enabled ? s.topMargin : 0; s.cursorColumn = enabled ? horizontalMargins.left : 0; s.pendingWrap = false; screen = s; changedActiveScreen = true
      case 7: autoWrap = enabled; if !enabled { var s = screen; s.pendingWrap = false; screen = s }; changedActiveScreen = true
      case 45: reverseWrap = enabled
      case 41: cursesTabWrap = enabled
      case 1045: reverseWrapUnlimited = enabled
      case 25:
        var s = screen; s.cursorVisible = enabled; screen = s
        changedActiveScreen = true
      case 47, 1047, 1049:
        if usingAlternate != enabled {
          resetClusterBoundary()
          advanceSearchGeneration()
          if enabled && mode == 1049 { saveCursor() }
          // 47 and 1047 share the active cursor while retaining independent
          // saved cursor slots and screen contents.
          let previousCursor = (screen.cursorRow, screen.cursorColumn, screen.pendingWrap)
          if !enabled && mode == 1047 {
            alternate.rows = (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }
          }
          usingAlternate = enabled
          if enabled && mode == 1049 {
            let keyboardFlags = alternate.keyboardFlags
            let keyboardStack = alternate.keyboardStack
            let cursorVisible = alternate.cursorVisible
            let cursorShape = alternate.cursorShape
            alternate = TerminalScreen(rows: (0..<rowCount).map { _ in document.eraseRow(eraseStyle()) }, columns: columns)
            alternate.keyboardFlags = keyboardFlags; alternate.keyboardStack = keyboardStack
            alternate.cursorVisible = cursorVisible; alternate.cursorShape = cursorShape
          } else {
            var s = screen
            s.cursorRow = previousCursor.0; s.cursorColumn = previousCursor.1; s.pendingWrap = previousCursor.2
            screen = s
          }
          if !enabled && mode == 1049 { restoreCursor() }
          changedActiveScreen = true
        }
      case 1048:
        if enabled { saveCursor() } else { restoreCursor() }
        changedActiveScreen = true
      case 1004: focusReporting = enabled
      case 80: sixelDisplayMode = enabled
      case 8452: sixelCursorRight = enabled
      case 9, 1000, 1002, 1003:
        if enabled { mouseMode = mode } else if mouseMode == mode { mouseMode = 0 }
      case 1005, 1006, 1015, 1016:
        if enabled { mouseEncoding = mode } else if mouseEncoding == mode { mouseEncoding = 0 }
      case 2004: bracketedPaste = enabled
      case 2027: applyGraphemeClustering(enabled)
      case 2031: colorSchemeReports = enabled
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
    reverseWrap = false; reverseWrapUnlimited = false
    cursesTabWrap = false
    newlineMode = false; protectedOutput = false
    attributes.isoProtected = false
    isoEraseProtection = false
    pen = TerminalStyle(); currentLink = nil; applicationCursor = false; applicationKeypad = false
    bracketedPaste = false; focusReporting = false; reverseVideo = false; mouseMode = 0; mouseEncoding = 0; modifyOtherKeys = 0; syncDeadline = nil
    forgetLastPrinted()
    charsetSpecial = [false, false]; charsetSlot = 0
    var s = screen
    s.topMargin = 0; s.bottomMargin = rowCount - 1
    s.savedRow = 0; s.savedColumn = 0; s.savedPendingWrap = false; s.savedRendition = SavedRendition()
    s.pendingWrap = false; s.cursorVisible = true; s.cursorShape = 0
    screen = s
    primary.leftMargin = 0; primary.rightMargin = columns - 1; alternate.leftMargin = 0; alternate.rightMargin = columns - 1
    primary.keyboardFlags = 0; primary.keyboardStack.removeAll(); alternate.keyboardFlags = 0; alternate.keyboardStack.removeAll()
  }
  // VT220 with Sixel graphics (4) and ANSI color (22).
  static let primaryDeviceAttributes = "\u{1b}[?62;4;22c"
  /// DEC status reports for hardware this terminal does not have. Each answer
  /// is the documented "absent" or "nothing to report" value.
  private static func deviceStatus(_ params: [Int]) -> String? {
    switch params.first {
    case 15: return "\u{1b}[?13n"      // no printer
    case 25: return "\u{1b}[?21n"      // user-defined keys locked
    case 26: return "\u{1b}[?27;1n"    // keyboard: North American
    case 55: return "\u{1b}[?50n"      // no locator
    case 56: return "\u{1b}[?57;0n"    // locator type: none
    case 62: return "\u{1b}[0*{"       // no macro space
    case 63: return "\u{1b}P\(params.count > 1 ? params[1] : 0)!~0000\u{1b}\\"  // memory checksum
    case 75: return "\u{1b}[?70n"      // data integrity: no errors
    case 85: return "\u{1b}[?83n"      // one session
    default: return nil
    }
  }
}

import Foundation

// Swift implementation of the terminal core ABI.  The public C-shaped surface is
// deliberately thin: the state machine owns parsing, grid mutation, history,
// snapshots, and input encoding so neither Session nor the renderer needs to
// duplicate terminal policy.

private struct SwiftStyle {
  var foreground: UInt32 = 0
  var background: UInt32 = 0
  var underline: UInt32 = 0
  var flags: UInt16 = 0
  var underlineKind: UInt8 = 0
}

private struct SwiftCell {
  var text = ""
  var kind: UInt8 = 0 // Empty, Lead1, Lead2, Continuation, WrapSpacer
  var style = SwiftStyle()
  var link: String?
  var flags: UInt8 = 0
}

private struct SwiftRow {
  var cells: [SwiftCell]
  var softWrapped = false
  init(columns: Int) { cells = Array(repeating: SwiftCell(), count: columns) }
}

private struct SwiftScreen {
  var rows: [SwiftRow]
  var cursorRow = 0
  var cursorColumn = 0
  var pendingWrap = false
  var savedRow = 0
  var savedColumn = 0
  init(columns: Int, rows count: Int) { rows = Array(repeating: SwiftRow(columns: columns), count: count) }
}

private enum SwiftParserState { case ground, escape, csi, osc, apc }

private final class SwiftSearchTask {
  let query: String
  init(_ query: String) { self.query = query }
}

private final class SwiftTerminalCore {
  private(set) var columns: Int
  private(set) var rowCount: Int
  private var primary: SwiftScreen
  private var alternate: SwiftScreen
  private var usingAlternate = false
  private var history: [SwiftRow] = []
  private var historyLimit = 10_000
  private var viewOffset = 0
  private var parser = SwiftParserState.ground
  private var textBytes: [UInt8] = []
  private var sequence = ""
  private var pen = SwiftStyle()
  private var currentLink: String?
  private var replies = Data()
  private var title = ""
  private var atPrompt = false
  private var applicationCursor = false
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

  init(columns: Int, rows: Int) {
    self.columns = max(1, min(4096, columns))
    self.rowCount = max(1, min(4096, rows))
    primary = SwiftScreen(columns: self.columns, rows: self.rowCount)
    alternate = SwiftScreen(columns: self.columns, rows: self.rowCount)
  }

  private var screen: SwiftScreen {
    get { usingAlternate ? alternate : primary }
    set { if usingAlternate { alternate = newValue } else { primary = newValue } }
  }
  private func changed(history: Bool = false, geometry: Bool = false) {
    revision &+= 1; documentEpoch &+= 1; screenEpoch &+= 1
    if history { historyEpoch &+= 1 }
    if geometry { geometryEpoch &+= 1 }
  }
  private func flushText() {
    guard !textBytes.isEmpty else { return }
    let value = String(decoding: textBytes, as: UTF8.self)
    textBytes.removeAll(keepingCapacity: true)
    for character in value { put(character) }
  }
  func feed(_ bytes: UnsafePointer<UInt8>?, count: Int) -> Int {
    guard let bytes, count > 0 else { return 0 }
    for byte in UnsafeBufferPointer(start: bytes, count: count) {
      switch parser {
      case .ground:
        switch byte {
        case 0x1b: flushText(); parser = .escape
        case 0x00...0x07: flushText(); if byte == 0x07 { /* bell belongs to host */ }
        case 0x08: flushText(); backspace()
        case 0x09: flushText(); tab()
        case 0x0a, 0x0b, 0x0c: flushText(); lineFeed()
        case 0x0d: flushText(); carriageReturn()
        default: textBytes.append(byte)
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
        default: break
        }
      case .csi:
        if (0x40...0x7e).contains(byte) { handleCSI(sequence, final: Character(UnicodeScalar(byte))); parser = .ground }
        else if sequence.utf8.count < 16_384 { sequence.unicodeScalars.append(UnicodeScalar(byte)) }
        else { parser = .ground; sequence = "" }
      case .osc, .apc:
        if byte == 0x07 { finishString(); parser = .ground }
        else if byte == 0x1b { parser = .escape; sequence.append("\u{1b}") }
        else if sequence.last == "\u{1b}" && byte == 0x5c { sequence.removeLast(); finishString(); parser = .ground }
        else if sequence.utf8.count < 1_048_576 { sequence.unicodeScalars.append(UnicodeScalar(byte)) }
        else { parser = .ground; sequence = "" }
      }
    }
    flushText()
    return count
  }
  private func put(_ character: Character) {
    var s = screen
    if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .enclosingMark }) {
      if s.cursorColumn > 0 { s.rows[s.cursorRow].cells[s.cursorColumn - 1].text.append(character) }
      screen = s; changed(); return
    }
    let width = isWide(character) ? 2 : 1
    if s.pendingWrap { s.rows[s.cursorRow].softWrapped = true; s.cursorColumn = 0; s.pendingWrap = false; advanceLine(&s) }
    if width == 2 && s.cursorColumn == columns - 1 { s.rows[s.cursorRow].softWrapped = true; s.cursorColumn = 0; advanceLine(&s) }
    guard s.cursorRow < s.rows.count, s.cursorColumn < columns else { return }
    s.rows[s.cursorRow].cells[s.cursorColumn] = SwiftCell(text: String(character), kind: width == 2 ? 2 : 1, style: pen, link: currentLink)
    if width == 2 && s.cursorColumn + 1 < columns { s.rows[s.cursorRow].cells[s.cursorColumn + 1] = SwiftCell(text: "", kind: 3, style: pen, link: currentLink) }
    if s.cursorColumn + width >= columns { s.cursorColumn = columns - 1; s.pendingWrap = true }
    else { s.cursorColumn += width }
    screen = s; changed()
  }
  private func isWide(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first?.value else { return false }
    return scalar >= 0x1100 && (scalar <= 0x115f || scalar >= 0x2e80)
  }
  private func advanceLine(_ s: inout SwiftScreen) {
    if s.cursorRow + 1 < rowCount { s.cursorRow += 1; return }
    let removed = s.rows.removeFirst(); s.rows.append(SwiftRow(columns: columns))
    if !usingAlternate { history.append(removed); if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }; historyEpoch &+= 1 }
  }
  private func lineFeed() { var s = screen; s.pendingWrap = false; advanceLine(&s); screen = s; changed(history: !usingAlternate) }
  private func carriageReturn() { var s = screen; s.cursorColumn = 0; s.pendingWrap = false; screen = s; changed() }
  private func backspace() { var s = screen; s.cursorColumn = max(0, s.cursorColumn - 1); s.pendingWrap = false; screen = s; changed() }
  private func tab() { var s = screen; s.cursorColumn = min(columns - 1, ((s.cursorColumn / 8) + 1) * 8); s.pendingWrap = false; screen = s; changed() }
  private func reverseIndex() { var s = screen; if s.cursorRow > 0 { s.cursorRow -= 1 } else { s.rows.insert(SwiftRow(columns: columns), at: 0); _ = s.rows.popLast() }; screen = s; changed() }
  private func saveCursor() { var s = screen; s.savedRow = s.cursorRow; s.savedColumn = s.cursorColumn; screen = s }
  private func restoreCursor() { var s = screen; s.cursorRow = s.savedRow; s.cursorColumn = s.savedColumn; s.pendingWrap = false; screen = s; changed() }
  private func reset() { primary = SwiftScreen(columns: columns, rows: rowCount); alternate = SwiftScreen(columns: columns, rows: rowCount); usingAlternate = false; history.removeAll(); pen = SwiftStyle(); changed(history: true) }
  private func parameters(_ raw: String) -> [Int] { raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 } }
  private func handleCSI(_ raw: String, final: Character) {
    let privateMode = raw.first == "?"
    let params = parameters(privateMode ? String(raw.dropFirst()) : raw)
    let n = max(1, params.first ?? 0)
    var s = screen
    var changedActiveScreen = false
    switch final {
    case "A": s.cursorRow = max(0, s.cursorRow - n)
    case "B": s.cursorRow = min(rowCount - 1, s.cursorRow + n)
    case "C": s.cursorColumn = min(columns - 1, s.cursorColumn + n)
    case "D": s.cursorColumn = max(0, s.cursorColumn - n)
    case "G": s.cursorColumn = min(columns - 1, n - 1)
    case "d": s.cursorRow = min(rowCount - 1, n - 1)
    case "H", "f": s.cursorRow = min(rowCount - 1, max(0, (params.first ?? 1) - 1)); s.cursorColumn = min(columns - 1, max(0, (params.dropFirst().first ?? 1) - 1))
    case "J": eraseDisplay(params.first ?? 0)
    case "K": eraseLine(params.first ?? 0)
    case "m": applySGR(params)
    case "s": saveCursor()
    case "u": restoreCursor()
    case "n": if params.first == 5 { replies.append(contentsOf: "\u{1b}[0n".utf8) } else if params.first == 6 { replies.append(contentsOf: "\u{1b}[\(s.cursorRow + 1);\(s.cursorColumn + 1)R".utf8) }
    case "c": replies.append(contentsOf: "\u{1b}[?62;4c".utf8)
    case "h", "l": changedActiveScreen = setMode(params, enabled: final == "h", privateMode: privateMode)
    default: break
    }
    // DEC alternate-screen modes swap the screen object.  Keeping the swap
    // inside mode ownership prevents this generic CSI epilogue from writing a
    // stale primary copy back into the newly active alternate buffer.
    if !changedActiveScreen { s.pendingWrap = false; screen = s }
    changed()
  }
  private func eraseDisplay(_ mode: Int) { var s = screen; switch mode { case 2, 3: s.rows = Array(repeating: SwiftRow(columns: columns), count: rowCount); if mode == 3 && !usingAlternate { history.removeAll(); historyEpoch &+= 1 }; case 1: for r in 0...s.cursorRow { let end = r == s.cursorRow ? s.cursorColumn : columns - 1; for c in 0...end { s.rows[r].cells[c] = SwiftCell() } }; default: for r in s.cursorRow..<rowCount { let start = r == s.cursorRow ? s.cursorColumn : 0; for c in start..<columns { s.rows[r].cells[c] = SwiftCell() } } }; screen = s }
  private func eraseLine(_ mode: Int) { var s = screen; let range: Range<Int>; switch mode { case 1: range = 0..<(s.cursorColumn + 1); case 2: range = 0..<columns; default: range = s.cursorColumn..<columns }; for c in range { s.rows[s.cursorRow].cells[c] = SwiftCell() }; screen = s }
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
      case 25: cursorVisible = enabled
      case 47, 1047, 1049:
        usingAlternate = enabled
        if enabled { alternate = SwiftScreen(columns: columns, rows: rowCount) }
        viewOffset = 0
        changedActiveScreen = true
      case 1004: focusReporting = enabled
      case 2004: bracketedPaste = enabled
      case 5: reverseVideo = enabled
      default: break
      }
    }
    return changedActiveScreen
  }
  private func finishString() { let payload = sequence; sequence = ""; if parser == .osc { let parts = payload.split(separator: ";", omittingEmptySubsequences: false); guard let command = parts.first else { return }; if command == "0" || command == "2" { title = parts.dropFirst().joined(separator: ";") } else if command == "8" { currentLink = parts.count > 2 ? String(parts.dropFirst(2).joined(separator: ";")) : nil } else if command == "133" { atPrompt = parts.dropFirst().first == "A" } } /* Kitty APC remains explicitly unsupported in this first Swift core. */ }
  func resize(columns nextColumns: Int, rows nextRows: Int) -> Bool { guard (1...4096).contains(nextColumns), (1...4096).contains(nextRows) else { return false }; columns = nextColumns; rowCount = nextRows; primary = resized(primary); alternate = resized(alternate); viewOffset = min(viewOffset, history.count); changed(geometry: true); return true }
  private func resized(_ old: SwiftScreen) -> SwiftScreen { var value = SwiftScreen(columns: columns, rows: rowCount); let start = max(0, old.rows.count - rowCount); for (target, source) in old.rows.suffix(rowCount).enumerated() { var row = SwiftRow(columns: columns); for i in 0..<min(columns, source.cells.count) { row.cells[i] = source.cells[i] }; row.softWrapped = source.softWrapped; value.rows[target] = row }; value.cursorRow = min(rowCount - 1, max(0, old.cursorRow - start)); value.cursorColumn = min(columns - 1, old.cursorColumn); return value }
  func scroll(_ amount: Int) { viewOffset = max(0, min(history.count, viewOffset + amount)); changed() }
  func followTail() { viewOffset = 0; changed() }
  func setHistoryLimit(_ value: Int) { historyLimit = max(0, value); if history.count > historyLimit { history.removeFirst(history.count - historyLimit); historyEpoch &+= 1 }; viewOffset = min(viewOffset, history.count) }
  func clearDisplay() -> UInt32 { if usingAlternate { return 0 }; let action: UInt32 = atPrompt ? 1 : 2; if atPrompt { var s = screen; s.rows[s.cursorRow] = SwiftRow(columns: columns); s.cursorColumn = 0; screen = s } else { history.removeAll(); primary = SwiftScreen(columns: columns, rows: rowCount); viewOffset = 0 }; changed(history: true); return action }
  func input(_ text: String, key: UInt32, modifiers: UInt32, event: UInt32) -> Data? { if key == 1 { guard text.utf8.count <= 1_048_576 else { return nil }; let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\r" || $0 == "\t" }.map(String.init).joined().replacingOccurrences(of: "\n", with: "\r"); return Data((bracketedPaste ? "\u{1b}[200~\(cleaned)\u{1b}[201~" : cleaned).utf8) }; if key == 2 { return focusReporting ? Data((event == 1 ? "\u{1b}[I" : "\u{1b}[O").utf8) : Data() }; if event == 2 { return Data() }; let modifier = 1 + ((modifiers & 1) != 0 ? 1 : 0) + ((modifiers & 2) != 0 ? 2 : 0) + ((modifiers & 4) != 0 ? 4 : 0) + ((modifiers & 8) != 0 ? 8 : 0); let arrows: [UInt32: Character] = [10:"A",11:"B",12:"C",13:"D",14:"H",15:"F"]; if let final = arrows[key] { return Data((modifier == 1 ? "\u{1b}\(applicationCursor ? "O" : "[")\(final)" : "\u{1b}[1;\(modifier)\(final)").utf8) }; let tilde: [UInt32:Int] = [16:5,17:6,18:2,19:3]; if let code = tilde[key] { return Data((modifier == 1 ? "\u{1b}[\(code)~" : "\u{1b}[\(code);\(modifier)~").utf8) }; switch key { case 20: return Data([127]); case 21: return Data((modifiers & 1 != 0 ? "\u{1b}[Z" : "\t").utf8); case 22: return Data([13]); case 23: return Data([27]); case 100...111: let number = [100:1,101:1,102:13,103:1,104:15,105:17,106:18,107:19,108:20,109:21,110:23,111:24][key]!; let final: String = key == 100 ? "P" : key == 101 ? "Q" : key == 103 ? "S" : "~"; return Data((final == "~" ? "\u{1b}[\(number)~" : "\u{1b}O\(final)").utf8); default: break }; if key == 0 || key == 200 { if modifiers & 4 != 0, let scalar = text.unicodeScalars.first, scalar.isASCII { return Data([UInt8(scalar.value & 31)]) }; var output = Data(text.utf8); if modifiers & 2 != 0 { output.insert(27, at: 0) }; return output }; return Data() }
  func takeReplies() -> Data { defer { replies.removeAll(keepingCapacity: true) }; return replies }
  func finish() { flushText() }
  func historyBytes() -> UInt64 { UInt64(history.reduce(0) { $0 + $1.cells.reduce(0) { $0 + $1.text.utf8.count } }) }
  func startSearch(_ task: SwiftSearchTask) -> UInt32 { searchHighlights.removeAll(); for (index, row) in history.enumerated() { let text = row.cells.map(\ .text).joined(); if let range = text.range(of: task.query, options: [.caseInsensitive]) { let start = text.distance(from: text.startIndex, to: range.lowerBound); let end = text.distance(from: text.startIndex, to: range.upperBound); searchHighlights.append(["row": index, "start": start, "end": end]) } }; return searchHighlights.isEmpty ? 4 : 5 }
  private func palette() -> [[Int]] { (0..<256).map { index in if index < 16 { let r = (index & 1) == 0 ? 0 : 205; let g = (index & 2) == 0 ? 0 : 205; let b = (index & 4) == 0 ? 0 : 238; return [r,g,b] }; let v = index < 232 ? [0,95,135,175,215,255][(index - 16) % 6] : 8 + (index - 232) * 10; return [v,v,v] } }
  func snapshotJSON(view: Bool) -> Data {
    let source: [SwiftRow]; let offset: Int
    if view && !usingAlternate && viewOffset > 0 { let all = history + primary.rows; let end = max(rowCount, all.count - viewOffset); source = Array(all[max(0, end - rowCount)..<end]); offset = viewOffset } else { source = screen.rows; offset = 0 }
    let cursor = screen
    let rows: [[String: Any]] = source.map { row in ["soft_wrapped": row.softWrapped, "cells": row.cells.map { cell in ["text": cell.text, "kind": ["Empty","Lead1","Lead2","Continuation","WrapSpacer"][Int(cell.kind)], "style": ["foreground": colorJSON(cell.style.foreground), "background": colorJSON(cell.style.background), "underline_color": colorJSON(cell.style.underline), "underline": Int(cell.style.underlineKind), "bold": cell.style.flags & 1 != 0, "faint": cell.style.flags & 2 != 0, "italic": cell.style.flags & 4 != 0, "inverse": cell.style.flags & 8 != 0, "conceal": cell.style.flags & 16 != 0, "strike": cell.style.flags & 32 != 0, "overline": cell.style.flags & 64 != 0, "blink": cell.style.flags & 128 != 0], "link": cell.link as Any, "flags": Int(cell.flags)] } ] }
    let data: [String: Any] = ["at_prompt":atPrompt,"search":searchHighlights,"images":[],"revision":revision,"geometry_epoch":geometryEpoch,"document_epoch":documentEpoch,"history_epoch":historyEpoch,"screen_epoch":screenEpoch,"scroll_offset":offset,"following_tail":offset == 0,"viewport_clamp_revision":revision,"cols":columns,"rows":rows,"cursor":["row":cursor.cursorRow,"col":cursor.cursorColumn,"pending_wrap":cursor.pendingWrap,"visible":cursorVisible,"shape":0],"modes":["application_cursor":applicationCursor,"bracketed_paste":bracketedPaste,"focus":focusReporting,"mouse":0,"sgr_mouse":false,"reverse_video":reverseVideo],"alternate":usingAlternate,"title":title,"history_rows":history.count,"palette":palette(),"default_fg":[229,229,229],"default_bg":[10,10,12]]
    return (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8)
  }
  private func colorJSON(_ color: UInt32) -> Any { if color >> 24 == 1 { return ["Indexed": Int(color & 255)] }; if color >> 24 == 2 { return ["Rgb": [Int((color >> 16) & 255), Int((color >> 8) & 255), Int(color & 255)]] }; return "Default" }
}

// MARK: C ABI bridge. The app still imports Bridge.h, allowing a mechanical
// replacement of the static Rust archive while all native call sites stay stable.

private func core(_ pointer: OpaquePointer?) -> SwiftTerminalCore? { pointer.map { Unmanaged<SwiftTerminalCore>.fromOpaque(UnsafeMutableRawPointer($0)).takeUnretainedValue() } }
typealias BytesCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void

@_cdecl("terminal_abi_version") func swift_terminal_abi_version() -> UInt32 { 1 }
@_cdecl("terminal_create") func swift_terminal_create(_ cols: UInt32, _ rows: UInt32) -> OpaquePointer? { OpaquePointer(Unmanaged.passRetained(SwiftTerminalCore(columns: Int(cols), rows: Int(rows))).toOpaque()) }
@_cdecl("terminal_destroy") func swift_terminal_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<SwiftTerminalCore>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_feed") func swift_terminal_feed(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ now: UInt64) -> Int { core(pointer)?.feed(bytes, count: count) ?? 0 }
@_cdecl("terminal_resize") func swift_terminal_resize(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows)) ?? false }
@_cdecl("terminal_resize_pixels") func swift_terminal_resize_pixels(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32, _ width: UInt32, _ height: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows)) ?? false }
@_cdecl("terminal_finish") func swift_terminal_finish(_ pointer: OpaquePointer?) { core(pointer)?.finish() }
@_cdecl("terminal_validate") func swift_terminal_validate(_ pointer: OpaquePointer?) -> Bool { core(pointer) != nil }
@_cdecl("terminal_has_work") func swift_terminal_has_work(_ pointer: OpaquePointer?) -> Bool { false }
@_cdecl("terminal_set_history_limit") func swift_terminal_set_history_limit(_ pointer: OpaquePointer?, _ limit: UInt32) { core(pointer)?.setHistoryLimit(Int(limit)) }
@_cdecl("terminal_history_bytes") func swift_terminal_history_bytes(_ pointer: OpaquePointer?) -> UInt64 { core(pointer)?.historyBytes() ?? 0 }
@_cdecl("terminal_snapshot") func swift_terminal_snapshot(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64) -> UnsafeMutablePointer<CChar>? { guard let value = core(pointer) else { return nil }; return strdup(String(data: value.snapshotJSON(view: true), encoding: .utf8) ?? "{}") }
@_cdecl("terminal_string_free") func swift_terminal_string_free(_ value: UnsafeMutablePointer<CChar>?) { if let value { free(value) } }
@_cdecl("terminal_view_scroll") func swift_terminal_view_scroll(_ pointer: OpaquePointer?, _ amount: Int64) { core(pointer)?.scroll(Int(amount)) }
@_cdecl("terminal_view_follow_tail") func swift_terminal_view_follow_tail(_ pointer: OpaquePointer?) { core(pointer)?.followTail() }
@_cdecl("terminal_clear_display") func swift_terminal_clear_display(_ pointer: OpaquePointer?) -> UInt32 { core(pointer)?.clearDisplay() ?? 0 }
@_cdecl("terminal_replies") func swift_terminal_replies(_ pointer: OpaquePointer?, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) { guard let callback, let data = core(pointer)?.takeReplies(), !data.isEmpty else { return }; data.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, data.count) } }
@_cdecl("terminal_input") func swift_terminal_input(_ pointer: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ key: UInt32, _ modifiers: UInt32, _ event: UInt32, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { guard let value = core(pointer)?.input(text.map { String(cString: $0) } ?? "", key: key, modifiers: modifiers, event: event) else { return false }; if let callback, !value.isEmpty { value.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, value.count) } }; return true }
@_cdecl("terminal_image_rgba") func swift_terminal_image_rgba(_ pointer: OpaquePointer?, _ image: UInt32, _ generation: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { false }
@_cdecl("terminal_search_create") func swift_terminal_search_create(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) -> OpaquePointer? { guard let bytes, count > 0, let query = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { return nil }; return OpaquePointer(Unmanaged.passRetained(SwiftSearchTask(query)).toOpaque()) }
@_cdecl("terminal_search_destroy") func swift_terminal_search_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<SwiftSearchTask>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("terminal_search_fill") func swift_terminal_search_fill(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 { 2 }
@_cdecl("terminal_search_step") func swift_terminal_search_step(_ pointer: OpaquePointer?) -> UInt32 { 2 }
@_cdecl("terminal_search_accept") func swift_terminal_search_accept(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 { guard let terminal = core(pointer), let task else { return 4 }; return terminal.startSearch(Unmanaged<SwiftSearchTask>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue()) }

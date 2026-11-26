import Darwin
import Foundation

/// Interactive TUI for manually verifying Helge Terminal features: `dev feature-check --interactive`.
enum FeatureCheck {
  static let command = Command(
    name: "feature-check", usage: "[--interactive]",
    summary: "Interactive TUI for manually verifying terminal features.",
    run: run)

  static func run(_ arguments: [String]) throws {
    let options = try Options(arguments, flags: ["--interactive", "--help", "-h"], values: [], command: command)
    guard options.positionals.isEmpty else { throw Failure.usage(command) }
    if options.flags.contains("--help") || options.flags.contains("-h") {
      printUsage()
      return
    }
    let interactive = options.flags.contains("--interactive")
    if !interactive && (isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0) {
      printUsage()
      return
    }
    try Session().run()
  }

  private static func printUsage() {
    let text = """
      usage: dev feature-check [--interactive]

      Runs an interactive 6-page TUI inside the terminal to manually verify:
        1:Text    — attributes, underline styles/colors, truecolor/256, Unicode & Nerd Fonts
        2:Links   — plain URLs, OSC 8 ids, selection, OSC 52 clipboard, bracketed paste, OSC 1337 download
        3:Mouse   — SGR 1006 / pixel 1016 crosshair, hover/click boxes, scroll wheel
        4:Keys    — Legacy / modifyOtherKeys / Kitty 1 / Kitty 31 inspector, focus, visual bell
        5:Images  — Kitty RGBA/alpha/z-index, Kitty animation & indexed OSC 4, SIXEL, iTerm2 PNG
        6:Resize  — live SIGWINCH border, protocol queries (XTVERSION/DA/OSC/DECRQM), scrollback/find

      Launch in a fresh built app window with:
        just feature-check
      """
    print(text)
  }
}

// MARK: - Interactive Session

private final class Session {
  // Darwin declares TIOCGWINSZ as a C macro Swift cannot import directly.
  private static let tiocgwinsz: UInt = 0x4008_7468
  private static let esc = "\u{1b}"

  enum Page: Int, CaseIterable {
    case text = 1
    case links = 2
    case mouse = 3
    case keys = 4
    case images = 5
    case resize = 6

    var shortLabel: String {
      switch self {
      case .text: "1:Text"
      case .links: "2:Links"
      case .mouse: "3:Mouse"
      case .keys: "4:Keys"
      case .images: "5:Images"
      case .resize: "6:Resize/Query"
      }
    }

    var next: Page {
      Page(rawValue: rawValue == 6 ? 1 : rawValue + 1) ?? .text
    }

    var previous: Page {
      Page(rawValue: rawValue == 1 ? 6 : rawValue - 1) ?? .resize
    }
  }

  enum KeyProtocol: Int, CaseIterable {
    case legacy = 0
    case modifyOtherKeys = 1
    case kitty1 = 2
    case kitty31 = 3

    var label: String {
      switch self {
      case .legacy: "Legacy"
      case .modifyOtherKeys: "ModOtherKeys"
      case .kitty1: "Kitty-1"
      case .kitty31: "Kitty-31"
      }
    }

    var sequence: String {
      switch self {
      case .legacy: "\u{1b}[=0u\u{1b}[>4;0m"
      case .modifyOtherKeys: "\u{1b}[=0u\u{1b}[>4;2m"
      case .kitty1: "\u{1b}[>4;0m\u{1b}[=1u"
      case .kitty31: "\u{1b}[>4;0m\u{1b}[=31u"
      }
    }

    var next: KeyProtocol {
      KeyProtocol(rawValue: (rawValue + 1) % Self.allCases.count) ?? .legacy
    }
  }

  struct WindowSize: Equatable {
    var cols: Int
    var rows: Int
    var pixelWidth: Int
    var pixelHeight: Int
  }

  struct Hitbox {
    let row: Int
    let startCol: Int
    let endCol: Int
    let action: HitAction
  }

  enum HitAction {
    case page(Page)
    case quit
    case keyProtocol(KeyProtocol)
    case bell
  }

  struct Rect {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int

    func contains(col: Int, row: Int) -> Bool {
      col >= left && col <= right && row >= top && row <= bottom
    }
  }

  struct MouseBoxState {
    let label: String
    var hovered = false
    var leftClicks = 0
    var middleClicks = 0
    var rightClicks = 0
    var colorIndex = 0
    var rect = Rect(left: 0, top: 0, right: 0, bottom: 0)
  }

  struct KeyLogEntry {
    let index: Int
    let kind: String
    let decoded: String
    let raw: String
  }

  struct QueryReply {
    let label: String
    let value: String
  }

  private var savedTermios = termios()
  private var rawActive = false
  private var running = true
  private var page: Page = .text
  private var size = WindowSize(cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
  private var resizeCount = 0
  private var hitboxes: [Hitbox] = []

  // Page 2 state
  private var osc52Count = 0
  private var downloadCount = 0
  private var lastPasteText: String?
  private var lastPasteBytes = 0
  private var inBracketedPaste = false
  private var pasteBuffer: [UInt8] = []

  // Page 3 state
  private var mousePixelMode = false
  private var mouseRawX = 0
  private var mouseRawY = 0
  private var mouseCellCol = 0
  private var mouseCellRow = 0
  private var mouseLastEvent = "none"
  private var mouseLastButton = "-"
  private var mouseLastModifiers = "-"
  private var mouseGridRect = Rect(left: 0, top: 0, right: 0, bottom: 0)
  private var mouseBoxes = [
    MouseBoxState(label: "A"),
    MouseBoxState(label: "B"),
    MouseBoxState(label: "C"),
  ]
  private var wheelUpCount = 0
  private var wheelDownCount = 0
  private var lastWheelDirection = "-"

  // Page 4 state
  private var keyProtocol: KeyProtocol = .legacy
  private var keyLog: [KeyLogEntry] = []
  private var keyEventCounter = 0
  private var windowFocused = true
  private var focusTransitions = 0
  private var bellCount = 0

  // Page 5 state
  private var paletteStep = 0
  private var paletteModified = false

  // Page 6 state
  private var queryReplies: [QueryReply] = []
  private var queryRunCount = 0

  // Input buffer for escape sequence parsing
  private var inputBuffer: [UInt8] = []

  func run() throws {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
      throw Failure("feature-check requires an interactive terminal")
    }
    try enterRawMode()
    Interruption.takeOver(resize: true)
    writeAll("\(Self.esc)[?1049h\(Self.esc)[?25l")

    defer {
      cleanupTerminal()
    }

    size = queryWindowSize()
    applyPageModes()
    redraw()

    var readBuf = [UInt8](repeating: 0, count: 4096)
    while running && !Interruption.stopRequested {
      var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pfd, nfds_t(1), 100)

      if Interruption.stopRequested {
        break
      }

      var needsRedraw = false
      let sigwinch = Interruption.takeResize()
      let currentSize = queryWindowSize()
      if sigwinch || currentSize != size {
        size = currentSize
        resizeCount += 1
        needsRedraw = true
      }

      if ready > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
        let count = Darwin.read(STDIN_FILENO, &readBuf, readBuf.count)
        if count > 0 {
          inputBuffer.append(contentsOf: readBuf[0..<count])
          if processInputBuffer() {
            needsRedraw = true
          }
        } else if count == 0 {
          break
        }
      } else if ready < 0 && errno != EINTR {
        break
      }

      if !running || Interruption.stopRequested {
        break
      }
      if needsRedraw {
        redraw()
      }
    }
  }

  // MARK: - Terminal Lifecycle

  private func enterRawMode() throws {
    guard tcgetattr(STDIN_FILENO, &savedTermios) == 0 else {
      throw Failure(SystemFailure("tcgetattr").message)
    }
    var raw = savedTermios
    cfmakeraw(&raw)
    withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
      let minIndex = Int(VMIN)
      let timeIndex = Int(VTIME)
      if minIndex < bytes.count { bytes[minIndex] = 0 }
      if timeIndex < bytes.count { bytes[timeIndex] = 0 }
    }
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
      throw Failure(SystemFailure("tcsetattr").message)
    }
    rawActive = true
  }

  private func cleanupTerminal() {
    var seq = ""
    // Reset keyboard protocols, mouse modes, focus, bracketed paste, Kitty graphics, palette.
    seq += "\(Self.esc)[=0u\(Self.esc)[>4;0m"
    seq += "\(Self.esc)[?1000l\(Self.esc)[?1002l\(Self.esc)[?1003l\(Self.esc)[?1006l\(Self.esc)[?1016l"
    seq += "\(Self.esc)[?1004l\(Self.esc)[?2004l"
    seq += "\(Self.esc)_Ga=d,d=A,q=2;\(Self.esc)\\"
    if paletteModified {
      seq += "\(Self.esc)]104;1\(Self.esc)\\"
      paletteModified = false
    }
    seq += "\(Self.esc)[0m\(Self.esc)[?25h\(Self.esc)[?1049l"
    writeAll(seq)
    if rawActive {
      var restore = savedTermios
      _ = tcsetattr(STDIN_FILENO, TCSANOW, &restore)
      rawActive = false
    }
  }

  private func queryWindowSize() -> WindowSize {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, Self.tiocgwinsz, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
      return WindowSize(
        cols: Int(ws.ws_col),
        rows: Int(ws.ws_row),
        pixelWidth: Int(ws.ws_xpixel),
        pixelHeight: Int(ws.ws_ypixel))
    }
    return WindowSize(cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
  }

  private func writeAll(_ text: String) {
    let bytes = Array(text.utf8)
    writeBytes(bytes)
  }

  private func writeBytes(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    bytes.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), buffer.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }
    }
  }

  // MARK: - Page & Mode Switching

  private func setPage(_ newPage: Page) {
    guard newPage != page else { return }
    if page == .images {
      var clear = "\(Self.esc)_Ga=d,d=A,q=2;\(Self.esc)\\"
      if paletteModified {
        clear += "\(Self.esc)]104;1\(Self.esc)\\"
        paletteModified = false
        paletteStep = 0
      }
      writeAll(clear)
    }
    page = newPage
    applyPageModes()
  }

  private func applyPageModes() {
    var seq = ""
    // Reset all interactive modes first.
    seq += "\(Self.esc)[?1000l\(Self.esc)[?1002l\(Self.esc)[?1003l\(Self.esc)[?1006l\(Self.esc)[?1016l"
    seq += "\(Self.esc)[?1004l\(Self.esc)[?2004l"
    seq += "\(Self.esc)[=0u\(Self.esc)[>4;0m"

    switch page {
    case .links:
      seq += "\(Self.esc)[?2004h"
    case .mouse:
      seq += "\(Self.esc)[?1003h"
      seq += mousePixelMode ? "\(Self.esc)[?1016h" : "\(Self.esc)[?1006h"
    case .keys:
      seq += "\(Self.esc)[?1000h\(Self.esc)[?1006h"
      seq += "\(Self.esc)[?1004h"
      seq += keyProtocol.sequence
    case .text, .images, .resize:
      break
    }
    writeAll(seq)
  }

  // MARK: - Input Parsing

  private func processInputBuffer() -> Bool {
    var changed = false

    while !inputBuffer.isEmpty {
      if inBracketedPaste {
        if let endRange = findSubsequence([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e], in: inputBuffer) {
          pasteBuffer.append(contentsOf: inputBuffer[0..<endRange.lowerBound])
          inputBuffer.removeSubrange(0..<endRange.upperBound)
          lastPasteBytes = pasteBuffer.count
          lastPasteText = String(decoding: pasteBuffer, as: UTF8.self)
          pasteBuffer.removeAll(keepingCapacity: true)
          inBracketedPaste = false
          changed = true
          continue
        } else {
          // Keep up to 5 trailing bytes in case the end marker splits across reads.
          let keep = min(5, inputBuffer.count)
          let flushCount = inputBuffer.count - keep
          if flushCount > 0 {
            pasteBuffer.append(contentsOf: inputBuffer[0..<flushCount])
            inputBuffer.removeSubrange(0..<flushCount)
          }
          break
        }
      }

      guard let token = nextInputToken() else { break }
      if handleToken(token) {
        changed = true
      }
      if !running { break }
    }

    return changed
  }

  private enum InputToken {
    case mouseSGR(button: Int, x: Int, y: Int, release: Bool, raw: [UInt8])
    case focus(Bool, raw: [UInt8])
    case pasteStart
    case sequence([UInt8])
    case singleByte(UInt8)
    case utf8([UInt8])
  }

  private func nextInputToken() -> InputToken? {
    guard !inputBuffer.isEmpty else { return nil }
    let first = inputBuffer[0]

    if first == 0x1b {
      if inputBuffer.count == 1 {
        inputBuffer.removeFirst()
        return .singleByte(0x1b)
      }
      let second = inputBuffer[1]
      // CSI sequence: ESC [
      if second == 0x5b {
        // Scan for final byte 0x40...0x7e
        var idx = 2
        while idx < inputBuffer.count {
          let b = inputBuffer[idx]
          if b >= 0x40 && b <= 0x7e {
            let seq = Array(inputBuffer[0...idx])
            inputBuffer.removeSubrange(0...idx)
            return classifyCSI(seq)
          }
          idx += 1
        }
        // Incomplete CSI; wait only if reasonably short
        if inputBuffer.count < 64 { return nil }
        let seq = inputBuffer
        inputBuffer.removeAll()
        return .sequence(seq)
      }
      // SS3 sequence: ESC O <final>
      if second == 0x4f {
        if inputBuffer.count >= 3 {
          let seq = Array(inputBuffer[0..<3])
          inputBuffer.removeSubrange(0..<3)
          return .sequence(seq)
        }
        return nil
      }
      // Alt + char
      let seq = Array(inputBuffer[0..<2])
      inputBuffer.removeSubrange(0..<2)
      return .sequence(seq)
    }

    // UTF-8 multi-byte sequence
    if first >= 0x80 {
      let expectedLength: Int
      if (first & 0xe0) == 0xc0 { expectedLength = 2 }
      else if (first & 0xf0) == 0xe0 { expectedLength = 3 }
      else if (first & 0xf8) == 0xf0 { expectedLength = 4 }
      else { expectedLength = 1 }

      if inputBuffer.count < expectedLength { return nil }
      let bytes = Array(inputBuffer[0..<expectedLength])
      inputBuffer.removeSubrange(0..<expectedLength)
      return .utf8(bytes)
    }

    inputBuffer.removeFirst()
    return .singleByte(first)
  }

  private func classifyCSI(_ seq: [UInt8]) -> InputToken {
    // Bracketed paste start: ESC [ 2 0 0 ~
    if seq == [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] {
      return .pasteStart
    }
    // Focus in / out: ESC [ I / ESC [ O
    if seq == [0x1b, 0x5b, 0x49] { return .focus(true, raw: seq) }
    if seq == [0x1b, 0x5b, 0x4f] { return .focus(false, raw: seq) }

    // SGR mouse: ESC [ < Pb ; Px ; Py M/m
    if seq.count >= 6, seq[2] == 0x3c, let last = seq.last, (last == 0x4d || last == 0x6d) {
      let body = String(decoding: seq[3..<(seq.count - 1)], as: UTF8.self)
      let parts = body.split(separator: ";").compactMap { Int($0) }
      if parts.count == 3 {
        return .mouseSGR(button: parts[0], x: parts[1], y: parts[2], release: last == 0x6d, raw: seq)
      }
    }

    return .sequence(seq)
  }

  private func handleToken(_ token: InputToken) -> Bool {
    switch token {
    case .pasteStart:
      inBracketedPaste = true
      pasteBuffer.removeAll(keepingCapacity: true)
      return false

    case .focus(let focused, _):
      if windowFocused != focused {
        windowFocused = focused
        focusTransitions += 1
      }
      return true

    case .mouseSGR(let button, let x, let y, let release, _):
      return handleMouseSGR(button: button, rawX: x, rawY: y, release: release)

    case .singleByte(let b):
      return handleKeyBytes([b])

    case .sequence(let bytes):
      return handleKeyBytes(bytes)

    case .utf8(let bytes):
      return handleKeyBytes(bytes)
    }
  }

  private func handleMouseSGR(button: Int, rawX: Int, rawY: Int, release: Bool) -> Bool {
    let cellCol: Int
    let cellRow: Int
    if page == .mouse && mousePixelMode && size.pixelWidth > 0 && size.pixelHeight > 0 {
      let cellW = max(1.0, Double(size.pixelWidth) / Double(max(1, size.cols)))
      let cellH = max(1.0, Double(size.pixelHeight) / Double(max(1, size.rows)))
      cellCol = min(size.cols, max(1, Int(Double(rawX) / cellW) + 1))
      cellRow = min(size.rows, max(1, Int(Double(rawY) / cellH) + 1))
    } else {
      cellCol = rawX
      cellRow = rawY
    }

    let isMotion = (button & 32) != 0
    let isWheel = (button & 64) != 0
    let baseButton = button & 3

    // Check clickable header / page controls on left press.
    if !isMotion && !isWheel && !release && baseButton == 0 {
      for hit in hitboxes where hit.row == cellRow && cellCol >= hit.startCol && cellCol <= hit.endCol {
        switch hit.action {
        case .page(let target):
          setPage(target)
          return true
        case .quit:
          running = false
          return false
        case .keyProtocol(let proto):
          keyProtocol = proto
          applyPageModes()
          return true
        case .bell:
          ringBell()
          return true
        }
      }
    }

    guard page == .mouse else { return false }

    mouseRawX = rawX
    mouseRawY = rawY
    mouseCellCol = cellCol
    mouseCellRow = cellRow

    var mods: [String] = []
    if (button & 4) != 0 { mods.append("Shift") }
    if (button & 8) != 0 { mods.append("Option") }
    if (button & 16) != 0 { mods.append("Ctrl") }
    mouseLastModifiers = mods.isEmpty ? "none" : mods.joined(separator: "+")

    if isWheel {
      mouseLastEvent = "wheel"
      if baseButton == 0 {
        wheelUpCount += 1
        lastWheelDirection = "Up"
        mouseLastButton = "WheelUp"
      } else if baseButton == 1 {
        wheelDownCount += 1
        lastWheelDirection = "Down"
        mouseLastButton = "WheelDown"
      } else {
        mouseLastButton = "Wheel(\(baseButton))"
      }
    } else if isMotion {
      mouseLastEvent = "move"
      mouseLastButton = baseButton == 3 ? "none" : buttonName(baseButton)
    } else if release {
      mouseLastEvent = "release"
      mouseLastButton = buttonName(baseButton)
    } else {
      mouseLastEvent = "press"
      mouseLastButton = buttonName(baseButton)
    }

    // Update hover and click counters on [A], [B], [C].
    for i in mouseBoxes.indices {
      let inside = mouseBoxes[i].rect.contains(col: cellCol, row: cellRow)
      mouseBoxes[i].hovered = inside
      if inside && !isMotion && !isWheel && !release {
        switch baseButton {
        case 0: mouseBoxes[i].leftClicks += 1
        case 1: mouseBoxes[i].middleClicks += 1
        case 2: mouseBoxes[i].rightClicks += 1
        default: break
        }
        mouseBoxes[i].colorIndex = (mouseBoxes[i].colorIndex + 1) % 5
      }
    }

    return true
  }

  private func buttonName(_ base: Int) -> String {
    switch base {
    case 0: "Left"
    case 1: "Middle"
    case 2: "Right"
    default: "None"
    }
  }

  private func handleKeyBytes(_ bytes: [UInt8]) -> Bool {
    if page == .keys {
      return handleKeysPageInput(bytes)
    }

    // Global navigation on pages 1, 2, 3, 5, 6.
    if bytes == [0x03] || bytes == [0x11] || bytes == [UInt8(ascii: "q")] || bytes == [UInt8(ascii: "Q")] {
      running = false
      return false
    }

    if bytes.count == 1 {
      switch bytes[0] {
      case UInt8(ascii: "1"): setPage(.text); return true
      case UInt8(ascii: "2"): setPage(.links); return true
      case UInt8(ascii: "3"): setPage(.mouse); return true
      case UInt8(ascii: "4"): setPage(.keys); return true
      case UInt8(ascii: "5"): setPage(.images); return true
      case UInt8(ascii: "6"): setPage(.resize); return true
      case 0x09, UInt8(ascii: "]"): setPage(page.next); return true
      case UInt8(ascii: "["): setPage(page.previous); return true
      case UInt8(ascii: "c"), UInt8(ascii: "C"):
        if page == .links {
          sendOSC52Clipboard()
          return true
        }
      case UInt8(ascii: "d"), UInt8(ascii: "D"):
        if page == .links {
          sendOSC1337Download()
          return true
        }
      case UInt8(ascii: "x"), UInt8(ascii: "X"):
        if page == .mouse {
          mousePixelMode.toggle()
          applyPageModes()
          return true
        }
      case UInt8(ascii: "p"), UInt8(ascii: "P"):
        if page == .images {
          cycleIndexedPalette()
          return true
        }
      case UInt8(ascii: "r"), UInt8(ascii: "R"):
        if page == .resize {
          runTerminalQueries()
          return true
        }
      case UInt8(ascii: "s"), UInt8(ascii: "S"):
        if page == .resize {
          runScrollbackDemo()
          return true
        }
      default:
        break
      }
    }

    // Left / Right arrows and Shift-Tab
    if bytes == [0x1b, 0x5b, 0x43] || bytes == [0x1b, 0x4f, 0x43] {
      setPage(page.next)
      return true
    }
    if bytes == [0x1b, 0x5b, 0x44] || bytes == [0x1b, 0x4f, 0x44] || bytes == [0x1b, 0x5b, 0x5a] {
      setPage(page.previous)
      return true
    }

    return false
  }

  private func handleKeysPageInput(_ bytes: [UInt8]) -> Bool {
    let parsed = decodeKeyEvent(bytes)

    // Always allow Ctrl-Q to quit, Ctrl-N / Ctrl-P to switch pages, Ctrl-B for bell, F1 to cycle protocol.
    if parsed.kind != "release" {
      if isCtrlKey(bytes, letter: "q", legacyByte: 0x11) {
        running = false
        return false
      }
      if isCtrlKey(bytes, letter: "n", legacyByte: 0x0e) {
        setPage(page.next)
        return true
      }
      if isCtrlKey(bytes, letter: "p", legacyByte: 0x10) {
        setPage(page.previous)
        return true
      }
      if isCtrlKey(bytes, letter: "b", legacyByte: 0x02) {
        ringBell()
      }
      if isF1Key(bytes) {
        keyProtocol = keyProtocol.next
        applyPageModes()
      }
    }

    keyEventCounter += 1
    let entry = KeyLogEntry(
      index: keyEventCounter,
      kind: parsed.kind,
      decoded: parsed.description,
      raw: formatRawBytes(bytes))
    keyLog.append(entry)
    if keyLog.count > 8 {
      keyLog.removeFirst(keyLog.count - 8)
    }
    return true
  }

  private func isCtrlKey(_ bytes: [UInt8], letter: Character, legacyByte: UInt8) -> Bool {
    if bytes == [legacyByte] { return true }
    guard let ascii = letter.asciiValue else { return false }
    let text = String(decoding: bytes, as: UTF8.self)
    // Kitty CSI-u: ESC [ <ascii> ; 5 u  or  ESC [ <ascii> ; 5:1 u
    if text == "\(Self.esc)[\(ascii);5u" || text == "\(Self.esc)[\(ascii);5:1u" { return true }
    // modifyOtherKeys: ESC [ 27 ; 5 ; <ascii> ~
    if text == "\(Self.esc)[27;5;\(ascii)~" { return true }
    return false
  }

  private func isF1Key(_ bytes: [UInt8]) -> Bool {
    if bytes == [0x1b, 0x4f, 0x50] || bytes == [0x1b, 0x5b, 0x31, 0x31, 0x7e] { return true }
    let text = String(decoding: bytes, as: UTF8.self)
    if text == "\(Self.esc)[1;1P" || text == "\(Self.esc)[1;1:1P" || text == "\(Self.esc)[P" { return true }
    if text == "\(Self.esc)[57364u" || text == "\(Self.esc)[57364;1u" || text == "\(Self.esc)[57364;1:1u" { return true }
    return false
  }

  private func ringBell() {
    bellCount += 1
    writeAll("\u{07}")
  }

  // MARK: - Feature Actions (Pages 2, 5, 6)

  private func sendOSC52Clipboard() {
    let payload = "Helge Terminal OSC52 OK"
    let encoded = Data(payload.utf8).base64EncodedString()
    writeAll("\(Self.esc)]52;c;\(encoded)\(Self.esc)\\")
    osc52Count += 1
  }

  private func sendOSC1337Download() {
    let name = Data("helge-check.txt".utf8).base64EncodedString()
    let body = Data("Helge Terminal OSC 1337 download verification.\n".utf8)
    let encoded = body.base64EncodedString()
    writeAll("\(Self.esc)]1337;File=name=\(name);size=\(body.count);inline=0:\(encoded)\u{07}")
    downloadCount += 1
  }

  private func cycleIndexedPalette() {
    paletteStep = (paletteStep + 1) % 3
    let rgb: String
    switch paletteStep {
    case 0: rgb = "ff/33/33"  // Red
    case 1: rgb = "22/dd/ee"  // Cyan
    default: rgb = "ff/dd/22"  // Yellow
    }
    writeAll("\(Self.esc)]4;1;rgb:\(rgb)\(Self.esc)\\")
    paletteModified = true
  }

  private func runTerminalQueries() {
    queryRunCount += 1
    // Drain any pending input first.
    inputBuffer.removeAll()

    let queries =
      "\(Self.esc)[>0q"            // XTVERSION
      + "\(Self.esc)[c"            // DA1
      + "\(Self.esc)[>c"           // DA2
      + "\(Self.esc)[14t"          // Window size in pixels
      + "\(Self.esc)[16t"          // Cell size in pixels
      + "\(Self.esc)[18t"          // Text area size in chars
      + "\(Self.esc)]10;?\(Self.esc)\\"
      + "\(Self.esc)]11;?\(Self.esc)\\"
      + "\(Self.esc)]12;?\(Self.esc)\\"
      + "\(Self.esc)[?996n"        // Color scheme DSR
      + "\(Self.esc)[?2026$p"      // DECRQM 2026 (sync output)
      + "\(Self.esc)[?2027$p"      // DECRQM 2027 (grapheme clustering)
    writeAll(queries)

    // Collect replies for up to 250ms (stopping early after 60ms of silence once bytes arrive).
    var collected: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    let start = Clock.now
    var lastData = start
    while Clock.milliseconds(from: start, to: Clock.now) < 250 {
      var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let timeout: Int32 = collected.isEmpty ? 60 : 30
      let ready = poll(&pfd, nfds_t(1), timeout)
      if ready > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
        let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
        if n > 0 {
          collected.append(contentsOf: buf[0..<n])
          lastData = Clock.now
        }
      } else if !collected.isEmpty && Clock.milliseconds(from: lastData, to: Clock.now) >= 60 {
        break
      }
    }

    queryReplies = parseQueryReplies(collected)
  }

  private func runScrollbackDemo() {
    // Leave alt-screen temporarily and print 200 numbered lines to primary scrollback.
    writeAll("\(Self.esc)[0m\(Self.esc)[?25h\(Self.esc)[?1049l")
    var output = "\r\n=== SCR-1 Primary Scrollback & Find Verification ===\r\n"
    for i in 1...200 {
      let tag = String(format: "FINDME-%03d", i)
      let color = 31 + (i % 6)
      output += "\(Self.esc)[\(color)m\(tag)\(Self.esc)[0m  Scrollback line \(i) of 200 — test trackpad scroll, ⌘F regex 'FINDME-1[0-9]{2}', ⌘K clear.\r\n"
    }
    output += "\r\n\(Self.esc)[1;30;43m SCR-1 \u{1b}[0m Printed FINDME-001..200 to primary scrollback.\r\n"
    output += "Test trackpad fractional scroll, ⌘F find 'FINDME-1[0-9]{2}' (regex), and ⌘K clear.\r\n"
    output += "Press Enter (or q) to return to Feature Check...\r\n"
    writeAll(output)

    var buf = [UInt8](repeating: 0, count: 64)
    while !Interruption.stopRequested {
      var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pfd, nfds_t(1), 100)
      if ready > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
        let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
        if n > 0 {
          let bytes = buf[0..<n]
          if bytes.contains(0x0d) || bytes.contains(0x0a)
            || bytes.contains(UInt8(ascii: "q")) || bytes.contains(0x1b) || bytes.contains(0x03)
          {
            break
          }
        } else if n == 0 {
          running = false
          break
        }
      }
    }

    size = queryWindowSize()
    writeAll("\(Self.esc)[?1049h\(Self.esc)[?25l")
    applyPageModes()
  }

  // MARK: - Rendering

  private func redraw() {
    hitboxes.removeAll(keepingCapacity: true)
    var out = ""
    out += "\(Self.esc)[?2026h"  // Synchronized output begin
    out += "\(Self.esc)[0m\(Self.esc)[2J\(Self.esc)[H"

    if page == .images {
      out += "\(Self.esc)_Ga=d,d=A,q=2;\(Self.esc)\\"
    }

    renderHeader(into: &out)

    switch page {
    case .text: renderPage1Text(into: &out)
    case .links: renderPage2Links(into: &out)
    case .mouse: renderPage3Mouse(into: &out)
    case .keys: renderPage4Keys(into: &out)
    case .images: renderPage5Images(into: &out)
    case .resize: renderPage6Resize(into: &out)
    }

    out += "\(Self.esc)[0m\(Self.esc)[?2026l"  // Synchronized output end
    writeAll(out)
  }

  private func moveTo(row: Int, col: Int) -> String {
    "\(Self.esc)[\(max(1, row));\(max(1, col))H"
  }

  private func badge(_ code: String, title: String, guidance: String, maxWidth: Int? = nil) -> String {
    let limit = maxWidth ?? max(20, size.cols - 3)
    let prefixLen = code.count + 2 + 1 + title.count
    let guideBudget = limit - prefixLen - 2
    if guideBudget <= 4 {
      let clippedTitle = clip(title, to: max(4, limit - code.count - 3))
      return "\(Self.esc)[1;30;43m \(code) \(Self.esc)[0m \(Self.esc)[1m\(clippedTitle)\(Self.esc)[0m"
    }
    let clippedGuide = clip(guidance, to: guideBudget)
    return "\(Self.esc)[1;30;43m \(code) \(Self.esc)[0m \(Self.esc)[1m\(title)\(Self.esc)[0m  \(Self.esc)[36m\(clippedGuide)\(Self.esc)[0m"
  }

  private func renderHeader(into out: inout String) {
    let cols = max(20, size.cols)

    // Row 1: clickable tab bar
    out += moveTo(row: 1, col: 1)
    out += "\(Self.esc)[48;5;235m\(Self.esc)[K"

    var col = 1
    let prefix = " "
    out += "\(Self.esc)[37;48;5;235m\(prefix)"
    col += prefix.count

    for p in Page.allCases {
      let label = "[\(p.shortLabel)]"
      if col + label.count > cols - 7 { break }
      let startCol = col
      let endCol = col + label.count - 1
      hitboxes.append(Hitbox(row: 1, startCol: startCol, endCol: endCol, action: .page(p)))
      if p == page {
        out += "\(Self.esc)[1;30;46m\(label)\(Self.esc)[0;48;5;235m "
      } else {
        out += "\(Self.esc)[37;48;5;236m\(label)\(Self.esc)[0;48;5;235m "
      }
      col += label.count + 1
    }

    let quitLabel = "[Quit]"
    if cols >= quitLabel.count + 2 {
      let quitCol = cols - quitLabel.count
      hitboxes.append(Hitbox(row: 1, startCol: quitCol, endCol: quitCol + quitLabel.count - 1, action: .quit))
      out += moveTo(row: 1, col: quitCol)
      out += "\(Self.esc)[1;97;41m\(quitLabel)\(Self.esc)[0m"
    }

    // Row 2: navigation hint
    out += moveTo(row: 2, col: 1)
    let navText: String
    if page == .keys {
      navText = " Page 4 Keys: Ctrl-N/Ctrl-P or click tabs to switch | Ctrl-Q or click [Quit] | F1 = cycle protocol | \(size.cols)×\(size.rows)"
    } else {
      navText = " Nav: 1-6, ←/→, [/], Tab = switch page | q / Ctrl-C = quit | Grid: \(size.cols)×\(size.rows)"
    }
    out += "\(Self.esc)[38;5;248;48;5;233m\(clip(navText, to: cols))\(Self.esc)[K\(Self.esc)[0m"

    // Row 3: divider
    out += moveTo(row: 3, col: 1)
    out += "\(Self.esc)[38;5;240m\(String(repeating: "─", count: cols))\(Self.esc)[0m"
  }

  // MARK: - Page 1: Text, Colors, Underlines & Unicode

  private func renderPage1Text(into out: inout String) {
    let cols = max(20, size.cols)
    let maxRow = size.rows
    var r = 4

    func put(_ text: String) {
      guard r <= maxRow else { return }
      out += moveTo(row: r, col: 2) + text
      r += 1
    }

    // TXT-1
    put(badge("TXT-1", title: "Text Attributes", guidance: "Verify each style renders distinctly (including blink)."))
    put(
      "\(Self.esc)[1mBold\(Self.esc)[0m  "
      + "\(Self.esc)[3mItalic\(Self.esc)[0m  "
      + "\(Self.esc)[1;3mBold+Italic\(Self.esc)[0m  "
      + "\(Self.esc)[2mFaint\(Self.esc)[0m  "
      + "\(Self.esc)[7mInverse\(Self.esc)[0m  "
      + "\(Self.esc)[9mStrikethrough\(Self.esc)[0m  "
      + "\(Self.esc)[53mOverline\(Self.esc)[0m  "
      + "\(Self.esc)[5mBlink\(Self.esc)[0m")
    r += 1

    // TXT-2
    put(badge("TXT-2", title: "Underline Styles & RGB Colors", guidance: "Expect 5 distinct underline shapes in 5 RGB colors."))
    put(
      "\(Self.esc)[4:1;58:2::255:90:90mSingle(4:1)\(Self.esc)[24;59m   "
      + "\(Self.esc)[4:2;58:2::255:195:60mDouble(4:2)\(Self.esc)[24;59m   "
      + "\(Self.esc)[4:3;58:2::80:225:125mCurly(4:3)\(Self.esc)[24;59m   "
      + "\(Self.esc)[4:4;58:2::95:175:255mDotted(4:4)\(Self.esc)[24;59m   "
      + "\(Self.esc)[4:5;58:2::215:120:255mDashed(4:5)\(Self.esc)[24;59m")
    r += 1

    // CLR-1
    put(badge("CLR-1", title: "24-bit Truecolor & 256-Color Palette", guidance: "Expect smooth RGB gradient + distinct 256-color swatches."))
    let barWidth = max(12, cols - 4)
    var gradient = ""
    for i in 0..<barWidth {
      let hue = Double(i) / Double(max(1, barWidth - 1)) * 360.0
      let (red, green, blue) = hsvToRGB(h: hue, s: 0.9, v: 0.95)
      gradient += "\(Self.esc)[48;2;\(red);\(green);\(blue)m "
    }
    gradient += "\(Self.esc)[0m"
    put(gradient)

    var pal = ""
    let swatchCount = min(barWidth / 2, 32)
    for i in 0..<min(16, swatchCount) {
      pal += "\(Self.esc)[48;5;\(i)m  "
    }
    let remaining = max(0, swatchCount - 16)
    if remaining > 0 {
      for i in 0..<remaining {
        let idx = 16 + (i * 215) / max(1, remaining - 1)
        pal += "\(Self.esc)[48;5;\(idx)m  "
      }
    }
    pal += "\(Self.esc)[0m"
    put(pal)
    r += 1

    // UNI-1
    put(badge("UNI-1", title: "Unicode 18, Wide Glyphs & Nerd Fonts", guidance: "Expect aligned wide CJK/emoji, crisp Nerd icons, seamless box art."))
    put("CJK: 日本語猫漢字   Combining: e\u{0301} a\u{0308} n\u{0303}   ZWJ: 👩🏽‍💻   Flags: 🇳🇴 🇯🇵   Nerd: \u{e0b0} \u{f09b} \u{f120}")

    let innerWidth = min(48, max(26, cols - 8))
    let topBorder = "╭" + String(repeating: "─", count: innerWidth) + "╮"
    let botBorder = "╰" + String(repeating: "─", count: innerWidth) + "╯"
    let title = clip("  ▀▄█ HELGE TERMINAL █▄▀  ░▒▓█▓▒░", to: innerWidth)
    let pad = max(0, innerWidth - displayWidthASCIIish(title))
    put("\(Self.esc)[38;5;81m\(topBorder)\(Self.esc)[0m")
    put("\(Self.esc)[38;5;81m│\(Self.esc)[1;38;5;220m\(title)\(String(repeating: " ", count: pad))\(Self.esc)[0;38;5;81m│\(Self.esc)[0m")
    put("\(Self.esc)[38;5;81m\(botBorder)\(Self.esc)[0m")
  }

  // MARK: - Page 2: Links, Selection, Clipboard, Paste & Downloads

  private func renderPage2Links(into out: inout String) {
    let cols = max(20, size.cols)
    let maxRow = size.rows
    var r = 4

    func put(_ text: String) {
      guard r <= maxRow else { return }
      out += moveTo(row: r, col: 2) + text
      r += 1
    }

    // LNK-1
    put(badge("LNK-1", title: "Plain URLs", guidance: "Hold ⌘ & hover (expect underline + preview), ⌘-click to open."))
    put("  https://example.com    and    https://github.com/HelgeSverre/terminal")
    r += 1

    // LNK-2
    put(badge("LNK-2", title: "OSC 8 Hyperlinks", guidance: "⌘-hover left vs right (expect separate underline highlights)."))
    let leftLink = "\(Self.esc)]8;id=left;https://example.com/same\(Self.esc)\\\(Self.esc)[38;5;75mLeft Link (id=left)\(Self.esc)[0m\(Self.esc)]8;;\(Self.esc)\\"
    let rightLink = "\(Self.esc)]8;id=right;https://example.com/same\(Self.esc)\\\(Self.esc)[38;5;114mRight Link (id=right)\(Self.esc)[0m\(Self.esc)]8;;\(Self.esc)\\"
    let labeledLink = "\(Self.esc)]8;id=repo;https://github.com/HelgeSverre/terminal\(Self.esc)\\\(Self.esc)[38;5;215mHelge Terminal Repo\(Self.esc)[0m\(Self.esc)]8;;\(Self.esc)\\"
    put("  \(leftLink)   \(rightLink)   \(labeledLink)")
    r += 1

    // SEL-1
    put(badge("SEL-1", title: "Selection & Copy", guidance: "Double-click word, triple-click line, ⌥-drag rectangle, ⌘C copy."))
    put("  Alpha-123   日本語テスト   👩🏽‍💻   omega_word   0123456789")
    put("  Beta-456    漢字かな文字   🇳🇴    delta_word   abcdefghij")
    r += 1

    // CLP-1
    put(badge("CLP-1", title: "OSC 52 Clipboard Write", guidance: "Press c, then ⌘V below to verify clipboard updated."))
    if osc52Count > 0 {
      put("  \(Self.esc)[32m[Sent OSC 52 #\(osc52Count): \"Helge Terminal OSC52 OK\"]\(Self.esc)[0m")
    } else {
      put("  \(Self.esc)[2mPress 'c' to write \"Helge Terminal OSC52 OK\" via OSC 52.\(Self.esc)[0m")
    }
    r += 1

    // PST-1
    put(badge("PST-1", title: "Bracketed Paste (?2004h)", guidance: "Paste anything with ⌘V; expect '[BRACKETED PASTE]' + exact text shown."))
    let boxW = max(24, min(cols - 4, 78))
    put("╭" + String(repeating: "─", count: boxW - 2) + "╮")
    let pasteContent: String
    if let text = lastPasteText {
      let escaped = escapeForDisplay(text)
      pasteContent = "[BRACKETED PASTE] (\(lastPasteBytes)B): \"\(escaped)\""
    } else {
      pasteContent = "(waiting for ⌘V paste...)"
    }
    let clippedPaste = clip(pasteContent, to: boxW - 4)
    let pastePad = max(0, (boxW - 4) - clippedPaste.count)
    let pasteStyle = lastPasteText != nil ? "\(Self.esc)[1;32m" : "\(Self.esc)[2m"
    put("│ \(pasteStyle)\(clippedPaste)\(Self.esc)[0m\(String(repeating: " ", count: pastePad)) │")
    put("╰" + String(repeating: "─", count: boxW - 2) + "╯")
    r += 1

    // DLD-1
    put(badge("DLD-1", title: "OSC 1337 Download", guidance: "Press d; expect Save/Dismiss download strip at bottom."))
    if downloadCount > 0 {
      put("  \(Self.esc)[32m[Sent OSC 1337 download #\(downloadCount): helge-check.txt]\(Self.esc)[0m")
    } else {
      put("  \(Self.esc)[2mPress 'd' to emit non-inline OSC 1337 download (helge-check.txt).\(Self.esc)[0m")
    }
  }

  // MARK: - Page 3: Mouse Position, Hover, Buttons & Scroll

  private func renderPage3Mouse(into out: inout String) {
    let cols = max(20, size.cols)
    let maxRow = size.rows
    var r = 4

    // MSE-1
    out += moveTo(row: r, col: 2)
    out += badge("MSE-1", title: "Live Mouse & Crosshair", guidance: "Move/click in grid; press x to toggle SGR 1006 (cells) vs 1016 (pixels).")
    r += 1

    let modeStr = mousePixelMode ? "1016 (pixel-SGR)" : "1006 (cell-SGR)"
    let rawLabel = mousePixelMode ? "px=(\(mouseRawX),\(mouseRawY))" : "cell=(\(mouseRawX),\(mouseRawY))"
    let status = "Mode: \(modeStr) | Raw: \(rawLabel) | Cell: (\(mouseCellCol),\(mouseCellRow)) | Event: \(mouseLastEvent) | Btn: \(mouseLastButton) | Mods: \(mouseLastModifiers)"
    out += moveTo(row: r, col: 2) + clip(status, to: cols - 3)
    r += 1

    // Crosshair grid box
    let gridLeft = 2
    let gridTop = r
    let gridW = min(56, max(20, cols - 4))
    let gridH = min(9, max(5, maxRow - 15))
    let gridRight = gridLeft + gridW - 1
    let gridBottom = gridTop + gridH - 1
    mouseGridRect = Rect(left: gridLeft + 1, top: gridTop + 1, right: gridRight - 1, bottom: gridBottom - 1)

    if gridBottom <= maxRow {
      for y in gridTop...gridBottom {
        out += moveTo(row: y, col: gridLeft)
        if y == gridTop {
          out += "\(Self.esc)[38;5;244m╭" + String(repeating: "─", count: gridW - 2) + "╮\(Self.esc)[0m"
        } else if y == gridBottom {
          out += "\(Self.esc)[38;5;244m╰" + String(repeating: "─", count: gridW - 2) + "╯\(Self.esc)[0m"
        } else {
          out += "\(Self.esc)[38;5;244m│\(Self.esc)[0m" + String(repeating: " ", count: gridW - 2) + "\(Self.esc)[38;5;244m│\(Self.esc)[0m"
        }
      }

      if mouseGridRect.contains(col: mouseCellCol, row: mouseCellRow) {
        // Border tick markers
        out += moveTo(row: gridTop, col: mouseCellCol) + "\(Self.esc)[1;33m┬\(Self.esc)[0m"
        out += moveTo(row: gridBottom, col: mouseCellCol) + "\(Self.esc)[1;33m┴\(Self.esc)[0m"
        out += moveTo(row: mouseCellRow, col: gridLeft) + "\(Self.esc)[1;33m├\(Self.esc)[0m"
        out += moveTo(row: mouseCellRow, col: gridRight) + "\(Self.esc)[1;33m┤\(Self.esc)[0m"
        // Crosshair dot
        out += moveTo(row: mouseCellRow, col: mouseCellCol) + "\(Self.esc)[1;96m◉\(Self.esc)[0m"
      }
      r = gridBottom + 2
    }

    // MSE-2
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("MSE-2", title: "Hover & Click Boxes", guidance: "Hover [A][B][C] to highlight; Left / Middle / Right click to count.")
      r += 1
    }

    let boxColors = [24, 28, 94, 90, 52]
    let boxW = min(20, max(14, (cols - 8) / 3))
    let boxTop = r
    if boxTop + 2 <= maxRow {
      for i in mouseBoxes.indices {
        let left = 2 + i * (boxW + 2)
        let right = left + boxW - 1
        let bottom = boxTop + 2
        mouseBoxes[i].rect = Rect(left: left, top: boxTop, right: right, bottom: bottom)

        let bg = mouseBoxes[i].hovered ? 39 : boxColors[mouseBoxes[i].colorIndex % boxColors.count]
        let fg = mouseBoxes[i].hovered ? 16 : 255
        let counts = "L:\(mouseBoxes[i].leftClicks) M:\(mouseBoxes[i].middleClicks) R:\(mouseBoxes[i].rightClicks)"
        let titleLine = "[\(mouseBoxes[i].label)] \(mouseBoxes[i].hovered ? "HOVER" : "click")"
        let line1 = clip(titleLine, to: boxW - 2)
        let line2 = clip(counts, to: boxW - 2)

        out += moveTo(row: boxTop, col: left)
        out += "\(Self.esc)[38;5;\(fg);48;5;\(bg)m╭" + String(repeating: "─", count: boxW - 2) + "╮\(Self.esc)[0m"
        out += moveTo(row: boxTop + 1, col: left)
        out += "\(Self.esc)[1;38;5;\(fg);48;5;\(bg)m│\(line1)\(String(repeating: " ", count: max(0, boxW - 2 - line1.count)))│\(Self.esc)[0m"
        out += moveTo(row: boxTop + 2, col: left)
        out += "\(Self.esc)[38;5;\(fg);48;5;\(bg)m│\(line2)\(String(repeating: " ", count: max(0, boxW - 2 - line2.count)))│\(Self.esc)[0m"
      }
      r = boxTop + 4
    }

    // MSE-3
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("MSE-3", title: "Scroll Wheel", guidance: "Scroll trackpad/wheel here (expect counts change); hold Shift+scroll to bypass.")
      r += 1
    }
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += "  Wheel Up: \(Self.esc)[1;32m\(wheelUpCount)\(Self.esc)[0m   Wheel Down: \(Self.esc)[1;33m\(wheelDownCount)\(Self.esc)[0m   Last: \(lastWheelDirection)"
    }
  }

  // MARK: - Page 4: Keyboard, Modifiers, Kitty Protocol, Focus & Bell

  private func renderPage4Keys(into out: inout String) {
    let cols = max(20, size.cols)
    let maxRow = size.rows
    var r = 4

    // KEY-2: Protocol selector
    out += moveTo(row: r, col: 2)
    out += badge("KEY-2", title: "Keyboard Protocol", guidance: "Press F1 or click mode; try Tab vs Ctrl-I, Shift-Return, Esc vs Ctrl-[, Option+Arrows, F1-F12.")
    r += 1

    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      var col = 2
      for proto in KeyProtocol.allCases {
        let label = "[\(proto.label)]"
        hitboxes.append(Hitbox(row: r, startCol: col, endCol: col + label.count - 1, action: .keyProtocol(proto)))
        if proto == keyProtocol {
          out += "\(Self.esc)[1;30;42m\(label)\(Self.esc)[0m "
        } else {
          out += "\(Self.esc)[37;48;5;238m\(label)\(Self.esc)[0m "
        }
        col += label.count + 1
      }
      r += 2
    }

    // KEY-3 & KEY-4: Focus & Bell
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("KEY-3", title: "Focus (?1004h)", guidance: "Click outside window then back in (count++).")
      out += "   "
      out += badge("KEY-4", title: "Visual Bell", guidance: "Ctrl-B or click [Bell].")
      r += 1
    }

    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      let focusBadge = windowFocused
        ? "\(Self.esc)[1;30;42m FOCUSED \(Self.esc)[0m"
        : "\(Self.esc)[1;30;43m UNFOCUSED \(Self.esc)[0m"
      let prefixText = "  Focus: "
      let midText = "  Transitions: \(focusTransitions)    "
      out += "\(prefixText)\(focusBadge)\(midText)"

      let bellCol = 2 + prefixText.count + (windowFocused ? 9 : 11) + midText.count
      let bellLabel = "[Bell]"
      hitboxes.append(Hitbox(row: r, startCol: bellCol, endCol: bellCol + bellLabel.count - 1, action: .bell))
      out += "\(Self.esc)[1;97;45m\(bellLabel)\(Self.esc)[0m  Sent: \(bellCount)"
      r += 2
    }

    // KEY-1: Live key event log
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("KEY-1", title: "Live Key Event Log (last 8)", guidance: "Hold a key in Kitty-31 for repeat/release events.")
      r += 1
    }

    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += "\(Self.esc)[1;38;5;248m" + clip("  #   Kind      Decoded Key / Modifiers        Raw Escaped & Hex", to: cols - 3) + "\(Self.esc)[0m"
      r += 1
    }

    if keyLog.isEmpty {
      if r <= maxRow {
        out += moveTo(row: r, col: 2)
        out += "  \(Self.esc)[2m(press any key to inspect raw bytes and decoded modifiers...)\(Self.esc)[0m"
      }
    } else {
      for entry in keyLog {
        guard r <= maxRow else { break }
        let idxStr = String(format: "%3d", entry.index)
        let kindStr = padRight(entry.kind, to: 8)
        let decStr = padRight(clip(entry.decoded, to: 29), to: 30)
        let rawAvail = max(10, cols - 48)
        let rawStr = clip(entry.raw, to: rawAvail)
        let kindColor = entry.kind == "release" ? "33" : (entry.kind == "repeat" ? "36" : "32")
        out += moveTo(row: r, col: 2)
        out += " \(idxStr)  \(Self.esc)[\(kindColor)m\(kindStr)\(Self.esc)[0m  \(decStr) \(Self.esc)[38;5;250m\(rawStr)\(Self.esc)[0m"
        r += 1
      }
    }
  }

  // MARK: - Page 5: Images & Animation (Kitty, SIXEL, iTerm2)

  private func renderPage5Images(into out: inout String) {
    let maxRow = size.rows
    var r = 4

    // IMG-1: Kitty 32-bit RGBA checkerboard + alpha blend + z=-1 / z=1
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("IMG-1", title: "Kitty RGBA, Alpha & Z-Index", guidance: "Checkerboard alpha over blue, 'BEHIND' visible over img, right covered.")
      r += 1
    }
    let img1Row = r
    if img1Row + 3 <= maxRow {
      // Blue cell background under left RGBA alpha image.
      for dy in 0..<3 {
        out += moveTo(row: img1Row + dy, col: 3)
        out += "\(Self.esc)[44m" + String(repeating: " ", count: 10) + "\(Self.esc)[0m"
      }
      // Text for z=-1 (visible in front of image) and z=1 (covered by image).
      out += moveTo(row: img1Row + 1, col: 18) + "\(Self.esc)[1;97mBEHIND\(Self.esc)[0m"
      out += moveTo(row: img1Row + 1, col: 32) + "\(Self.esc)[1;97mHIDDEN\(Self.esc)[0m"

      // Transmit & place left RGBA 64x48 alpha checkerboard (id=10).
      out += moveTo(row: img1Row, col: 3)
      out += kittyTransmit(
        id: 10, format: 32, width: 64, height: 48, extraParams: "C=1",
        data: makeRGBACheckerboard(width: 64, height: 48))

      // Transmit & place middle z=-1 image behind "BEHIND" (id=11).
      out += moveTo(row: img1Row, col: 17)
      out += kittyTransmit(
        id: 11, format: 32, width: 48, height: 32, extraParams: "z=-1,C=1",
        data: makeSolidGradientRGBA(width: 48, height: 32, r0: 20, g0: 140, b0: 170, r1: 210, g1: 110, b1: 30))

      // Transmit & place right z=1 image in front of "HIDDEN" (id=12).
      out += moveTo(row: img1Row, col: 31)
      out += kittyTransmit(
        id: 12, format: 32, width: 48, height: 32, extraParams: "z=1,C=1",
        data: makeSolidGradientRGBA(width: 48, height: 32, r0: 150, g0: 40, b0: 180, r1: 230, g1: 180, b1: 40))

      r = img1Row + 4
    }

    // IMG-2: Kitty 2-frame animation + Kitty indexed (f=8) OSC 4 palette box
    let palNames = ["Red", "Cyan", "Yellow"]
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("IMG-2", title: "Kitty Animation & Indexed (f=8)", guidance: "Left blinks red/green (400ms); press p for OSC 4 slot 1 (\(palNames[paletteStep])).")
      r += 1
    }
    let img2Row = r
    if img2Row + 3 <= maxRow {
      // Animated 48x48 (id=20): frame 1 red, frame 2 green, 400ms loop.
      out += moveTo(row: img2Row, col: 3)
      out += kittyTransmit(
        id: 20, format: 32, width: 48, height: 48, extraParams: "C=1",
        data: makeBorderedBoxRGBA(width: 48, height: 48, r: 220, g: 45, b: 55))
      out += kittyAddFrame(
        id: 20, width: 48, height: 48, gapMs: 400,
        data: makeBorderedBoxRGBA(width: 48, height: 48, r: 45, g: 205, b: 95))
      out += "\(Self.esc)_Ga=a,i=20,r=1,z=400,s=3,v=1,q=2;\(Self.esc)\\"

      // Indexed f=8 48x48 (id=21): palette slot 1 interior, slot 0 border.
      out += moveTo(row: img2Row, col: 17)
      out += kittyTransmit(
        id: 21, format: 8, width: 48, height: 48, extraParams: "C=1",
        data: makeIndexedBox(width: 48, height: 48, fillIndex: 1, borderIndex: 0))

      out += moveTo(row: img2Row + 1, col: 27)
      out += "\(Self.esc)[2m← Indexed f=8 (slot 1: \(palNames[paletteStep]))\(Self.esc)[0m"
      r = img2Row + 4
    }

    // IMG-3: SIXEL 8-color 96x48 banded graphic with transparent holes (P2=1)
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("IMG-3", title: "SIXEL 8-Color + Transparency (P2=1)", guidance: "Expect crisp colored bands with blue background showing through holes.")
      r += 1
    }
    let img3Row = r
    if img3Row + 3 <= maxRow {
      for dy in 0..<3 {
        out += moveTo(row: img3Row + dy, col: 3)
        out += "\(Self.esc)[48;5;19m" + String(repeating: " ", count: 14) + "\(Self.esc)[0m"
      }
      out += moveTo(row: img3Row, col: 3)
      out += makeSixelBands96x48()
      r = img3Row + 4
    }

    // IMG-4: iTerm2 inline 32x32 PNG
    if r <= maxRow {
      out += moveTo(row: r, col: 2)
      out += badge("IMG-4", title: "iTerm2 Inline PNG (OSC 1337)", guidance: "Expect small magenta/gold inline square.")
      r += 1
    }
    if r + 1 <= maxRow {
      out += moveTo(row: r, col: 3)
      let png = makeMinimalPNG32x32()
      let nameB64 = Data("swatch.png".utf8).base64EncodedString()
      out += "\(Self.esc)]1337;File=name=\(nameB64);size=\(png.count);inline=1;width=4;height=2:\(png.base64EncodedString())\u{07}"
    }
  }

  // MARK: - Page 6: Resize, Protocol Queries & Scrollback/Find

  private func renderPage6Resize(into out: inout String) {
    let cols = max(20, size.cols)
    let rows = max(10, size.rows)
    let top = 4
    let bottom = rows

    // RES-1: Full-width/height dynamic box-drawing border
    out += moveTo(row: top, col: 1)
    out += "\(Self.esc)[38;5;75m╭" + String(repeating: "─", count: max(0, cols - 2)) + "╮\(Self.esc)[0m"
    for y in (top + 1)..<bottom {
      out += moveTo(row: y, col: 1) + "\(Self.esc)[38;5;75m│\(Self.esc)[0m"
      out += moveTo(row: y, col: cols) + "\(Self.esc)[38;5;75m│\(Self.esc)[0m"
    }
    out += moveTo(row: bottom, col: 1)
    out += "\(Self.esc)[38;5;75m╰" + String(repeating: "─", count: max(0, cols - 2)) + "╯\(Self.esc)[0m"

    let innerMax = max(10, cols - 4)
    var r = top + 1

    func putInner(_ text: String) {
      guard r < bottom else { return }
      out += moveTo(row: r, col: 3) + text
      r += 1
    }

    putInner(badge("RES-1", title: "Live Resize Border", guidance: "Resize window, split pane (⌘D), change font (⌘+/⌘−); border stays aligned.", maxWidth: innerMax))
    let metrics = "Grid: \(size.cols) × \(size.rows)   Pixels: \(size.pixelWidth) × \(size.pixelHeight)   SIGWINCH count: \(resizeCount)"
    putInner("  \(Self.esc)[1;96m\(clip(metrics, to: innerMax - 2))\(Self.esc)[0m")
    r += 1

    // QRY-1
    putInner(badge("QRY-1", title: "Live Terminal Queries", guidance: "Press r to query XTVERSION, DA1/2, 14t/16t/18t, OSC 10/11/12, 996n, DECRQM.", maxWidth: innerMax))
    if queryReplies.isEmpty {
      putInner("  \(Self.esc)[2m\(clip("Press 'r' to send live queries and display terminal replies.", to: innerMax - 2))\(Self.esc)[0m")
    } else {
      putInner("  \(Self.esc)[32m\(clip("Query run #\(queryRunCount) — \(queryReplies.count) replies received:", to: innerMax - 2))\(Self.esc)[0m")
      for reply in queryReplies {
        guard r < bottom - 3 else { break }
        let line = "  \(padRight(reply.label, to: 12)) \(reply.value)"
        putInner(clip(line, to: innerMax))
      }
    }

    // SCR-1 anchored near bottom inside frame
    let scrRow = max(r + 1, bottom - 3)
    if scrRow + 1 < bottom {
      out += moveTo(row: scrRow, col: 3)
      out += badge("SCR-1", title: "Scrollback & Find", guidance: "Press s → test fractional scroll, ⌘F 'FINDME-1[0-9]{2}' (regex), ⌘K clear.", maxWidth: innerMax)
      out += moveTo(row: scrRow + 1, col: 3)
      out += "  \(Self.esc)[2m\(clip("Exits alt-screen, prints FINDME-001..200 to primary scrollback, waits for Enter.", to: innerMax - 2))\(Self.esc)[0m"
    }
  }

  // MARK: - Key Decoder (Page 4)

  private func decodeKeyEvent(_ bytes: [UInt8]) -> (kind: String, description: String) {
    guard !bytes.isEmpty else { return ("press", "empty") }
    let text = String(decoding: bytes, as: UTF8.self)

    // Kitty CSI-u: ESC [ <codepoint>[:...] [; <mods>[:<event>]] u
    if text.hasPrefix("\(Self.esc)["), text.hasSuffix("u") {
      let body = String(text.dropFirst(2).dropLast())
      let semi = body.split(separator: ";", omittingEmptySubsequences: false)
      let cpPart = semi.first.map { String($0.split(separator: ":").first ?? "") } ?? ""
      let cp = Int(cpPart) ?? 0
      var modsMask = 0
      var eventKind = "press"
      if semi.count >= 2 {
        let modFields = semi[1].split(separator: ":")
        if let m = modFields.first.flatMap({ Int($0) }), m > 0 { modsMask = m - 1 }
        if modFields.count >= 2, let ev = Int(modFields[1]) {
          eventKind = ev == 2 ? "repeat" : (ev == 3 ? "release" : "press")
        }
      }
      return (eventKind, formatModifiers(modsMask) + describeCodepoint(cp))
    }

    // xterm modifyOtherKeys: ESC [ 27 ; <mods> ; <codepoint> ~
    if text.hasPrefix("\(Self.esc)[27;"), text.hasSuffix("~") {
      let body = String(text.dropFirst(2).dropLast())
      let parts = body.split(separator: ";").compactMap { Int($0) }
      if parts.count == 3 {
        return ("press", formatModifiers(max(0, parts[1] - 1)) + describeCodepoint(parts[2]) + " (mok)")
      }
    }

    // CSI functional keys with optional modifiers/event: ESC [ ... A/B/C/D/H/F/P/Q/R/S/~
    if text.hasPrefix("\(Self.esc)["), bytes.count >= 3, let final = text.last {
      let body = String(text.dropFirst(2).dropLast())
      let semi = body.split(separator: ";", omittingEmptySubsequences: false)
      var modsMask = 0
      var eventKind = "press"
      if semi.count >= 2 {
        let modFields = semi[1].split(separator: ":")
        if let m = modFields.first.flatMap({ Int($0) }), m > 0 { modsMask = m - 1 }
        if modFields.count >= 2, let ev = Int(modFields[1]) {
          eventKind = ev == 2 ? "repeat" : (ev == 3 ? "release" : "press")
        }
      }
      if let name = csiKeyName(firstParam: semi.first.map(String.init) ?? "", final: final) {
        return (eventKind, formatModifiers(modsMask) + name)
      }
    }

    // SS3 keys (F1-F4, arrows)
    if bytes.count == 3, bytes[0] == 0x1b, bytes[1] == 0x4f {
      let map: [UInt8: String] = [
        0x50: "F1", 0x51: "F2", 0x52: "F3", 0x53: "F4",
        0x41: "Up", 0x42: "Down", 0x43: "Right", 0x44: "Left",
      ]
      if let name = map[bytes[2]] { return ("press", name) }
    }

    // Alt + char
    if bytes.count == 2, bytes[0] == 0x1b {
      return ("press", "Alt+" + describeCodepoint(Int(bytes[1])))
    }

    // Single ASCII / Control byte
    if bytes.count == 1 {
      let b = bytes[0]
      switch b {
      case 0x00: return ("press", "Ctrl+Space")
      case 0x09: return ("press", "Tab (or Ctrl+I)")
      case 0x0a: return ("press", "LineFeed (Ctrl+J)")
      case 0x0d: return ("press", "Return (Ctrl+M)")
      case 0x1b: return ("press", "Escape (or Ctrl+[)")
      case 0x7f: return ("press", "Backspace")
      case 0x20: return ("press", "Space")
      case 0x01...0x1a:
        let ch = Character(UnicodeScalar(UInt8(ascii: "A") + (b - 1)))
        return ("press", "Ctrl+\(ch)")
      case 0x21...0x7e:
        return ("press", "'\(Character(UnicodeScalar(b)))'")
      default:
        return ("press", String(format: "0x%02X", b))
      }
    }

    // UTF-8 text
    if bytes[0] >= 0x80 {
      return ("press", "UTF-8 '\(text)'")
    }

    return ("press", escapeForDisplay(text))
  }

  private func formatModifiers(_ mask: Int) -> String {
    var parts: [String] = []
    if (mask & 1) != 0 { parts.append("Shift") }
    if (mask & 2) != 0 { parts.append("Alt") }
    if (mask & 4) != 0 { parts.append("Ctrl") }
    if (mask & 8) != 0 { parts.append("Super") }
    return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
  }

  private func describeCodepoint(_ cp: Int) -> String {
    switch cp {
    case 9: return "Tab"
    case 13: return "Return"
    case 27: return "Escape"
    case 32: return "Space"
    case 127: return "Backspace"
    case 57364...57375: return "F\(cp - 57363)"
    case 33...126: return "'\(Character(UnicodeScalar(cp)!))'"
    default:
      if let scalar = UnicodeScalar(cp) { return "U+\(String(format: "%04X", cp)) '\(scalar)'" }
      return "U+\(String(format: "%04X", cp))"
    }
  }

  private func csiKeyName(firstParam: String, final: Character) -> String? {
    switch final {
    case "A": return "Up"
    case "B": return "Down"
    case "C": return "Right"
    case "D": return "Left"
    case "H": return "Home"
    case "F": return "End"
    case "P": return "F1"
    case "Q": return "F2"
    case "R": return "F3"
    case "S": return "F4"
    case "Z": return "Shift+Tab"
    case "~":
      let map: [String: String] = [
        "1": "Home", "2": "Insert", "3": "Delete", "4": "End",
        "5": "PageUp", "6": "PageDown", "11": "F1", "12": "F2", "13": "F3", "14": "F4",
        "15": "F5", "17": "F6", "18": "F7", "19": "F8", "20": "F9", "21": "F10",
        "23": "F11", "24": "F12",
      ]
      return map[firstParam]
    default:
      return nil
    }
  }

  // MARK: - Query Reply Parser (Page 6)

  private func parseQueryReplies(_ bytes: [UInt8]) -> [QueryReply] {
    guard !bytes.isEmpty else {
      return [QueryReply(label: "Result", value: "(no replies received within 250ms)")]
    }
    var replies: [QueryReply] = []
    var i = 0
    while i < bytes.count {
      if bytes[i] == 0x1b, i + 1 < bytes.count {
        let next = bytes[i + 1]
        // DCS: ESC P ... ESC \
        if next == 0x50 {
          if let end = findST(in: bytes, from: i + 2) {
            let body = String(decoding: bytes[(i + 2)..<end.bodyEnd], as: UTF8.self)
            let label = body.hasPrefix(">|") ? "XTVERSION" : "DCS"
            let value = body.hasPrefix(">|") ? String(body.dropFirst(2)) : body
            replies.append(QueryReply(label: label, value: escapeForDisplay(value)))
            i = end.nextIndex
            continue
          }
        }
        // OSC: ESC ] ... (BEL or ESC \)
        if next == 0x5d {
          if let end = findOSCSt(in: bytes, from: i + 2) {
            let body = String(decoding: bytes[(i + 2)..<end.bodyEnd], as: UTF8.self)
            let parts = body.split(separator: ";", maxSplits: 1)
            let oscCode = parts.first.map(String.init) ?? "?"
            let rest = parts.count > 1 ? String(parts[1]) : ""
            replies.append(QueryReply(label: "OSC \(oscCode)", value: escapeForDisplay(rest)))
            i = end.nextIndex
            continue
          }
        }
        // CSI: ESC [ ... final
        if next == 0x5b {
          var j = i + 2
          while j < bytes.count && !(bytes[j] >= 0x40 && bytes[j] <= 0x7e) { j += 1 }
          if j < bytes.count {
            let seq = String(decoding: bytes[i...j], as: UTF8.self)
            let label = labelCSIReply(seq)
            replies.append(QueryReply(label: label, value: escapeForDisplay(seq)))
            i = j + 1
            continue
          }
        }
      }
      i += 1
    }
    if replies.isEmpty {
      replies.append(QueryReply(label: "Raw", value: escapeForDisplay(String(decoding: bytes, as: UTF8.self))))
    }
    return replies
  }

  private func labelCSIReply(_ seq: String) -> String {
    if seq.hasPrefix("\(Self.esc)[?") && seq.hasSuffix("c") { return "DA1" }
    if seq.hasPrefix("\(Self.esc)[>") && seq.hasSuffix("c") { return "DA2" }
    if seq.hasPrefix("\(Self.esc)[4;") && seq.hasSuffix("t") { return "CSI 14t" }
    if seq.hasPrefix("\(Self.esc)[6;") && seq.hasSuffix("t") { return "CSI 16t" }
    if seq.hasPrefix("\(Self.esc)[8;") && seq.hasSuffix("t") { return "CSI 18t" }
    if seq.hasPrefix("\(Self.esc)[?997;") && seq.hasSuffix("n") { return "CSI ?996n" }
    if seq.hasPrefix("\(Self.esc)[?2026;") && seq.hasSuffix("$y") { return "DECRQM 2026" }
    if seq.hasPrefix("\(Self.esc)[?2027;") && seq.hasSuffix("$y") { return "DECRQM 2027" }
    return "CSI"
  }

  private func findST(in bytes: [UInt8], from start: Int) -> (bodyEnd: Int, nextIndex: Int)? {
    var i = start
    while i + 1 < bytes.count {
      if bytes[i] == 0x1b && bytes[i + 1] == 0x5c {
        return (i, i + 2)
      }
      i += 1
    }
    return nil
  }

  private func findOSCSt(in bytes: [UInt8], from start: Int) -> (bodyEnd: Int, nextIndex: Int)? {
    var i = start
    while i < bytes.count {
      if bytes[i] == 0x07 { return (i, i + 1) }
      if bytes[i] == 0x1b, i + 1 < bytes.count, bytes[i + 1] == 0x5c {
        return (i, i + 2)
      }
      i += 1
    }
    return nil
  }

  // MARK: - Graphics Generators (Page 5)

  private func kittyTransmit(id: Int, format: Int, width: Int, height: Int, extraParams: String, data: Data) -> String {
    let b64 = data.base64EncodedString()
    let header = "a=T,f=\(format),s=\(width),v=\(height),i=\(id),q=2" + (extraParams.isEmpty ? "" : ",\(extraParams)")
    return kittyChunked(header: header, base64: b64)
  }

  private func kittyAddFrame(id: Int, width: Int, height: Int, gapMs: Int, data: Data) -> String {
    let b64 = data.base64EncodedString()
    let header = "a=f,f=32,s=\(width),v=\(height),i=\(id),z=\(gapMs),q=2"
    return kittyChunked(header: header, base64: b64)
  }

  private func kittyChunked(header: String, base64: String) -> String {
    let chunkSize = 4096
    let chars = Array(base64.utf8)
    if chars.count <= chunkSize {
      return "\(Self.esc)_G\(header);\(base64)\(Self.esc)\\"
    }
    var result = ""
    var offset = 0
    while offset < chars.count {
      let end = min(chars.count, offset + chunkSize)
      let more = end < chars.count ? 1 : 0
      let slice = String(decoding: chars[offset..<end], as: UTF8.self)
      if offset == 0 {
        result += "\(Self.esc)_G\(header),m=\(more);\(slice)\(Self.esc)\\"
      } else {
        result += "\(Self.esc)_Gm=\(more);\(slice)\(Self.esc)\\"
      }
      offset = end
    }
    return result
  }

  private func makeRGBACheckerboard(width: Int, height: Int) -> Data {
    var data = Data(capacity: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let inCenter = x >= width / 4 && x < (3 * width) / 4 && y >= height / 4 && y < (3 * height) / 4
        let checker = ((x / 8) + (y / 8)) % 2 == 0
        let r = UInt8((x * 255) / max(1, width - 1))
        let g = UInt8((y * 255) / max(1, height - 1))
        let b: UInt8 = checker ? 220 : 60
        let a: UInt8 = inCenter ? 115 : 255
        data.append(contentsOf: [r, g, b, a])
      }
    }
    return data
  }

  private func makeSolidGradientRGBA(
    width: Int, height: Int,
    r0: Int, g0: Int, b0: Int,
    r1: Int, g1: Int, b1: Int
  ) -> Data {
    var data = Data(capacity: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let t = Double(x + y) / Double(max(1, width + height - 2))
        let r = UInt8(Int(Double(r0) + t * Double(r1 - r0)))
        let g = UInt8(Int(Double(g0) + t * Double(g1 - g0)))
        let b = UInt8(Int(Double(b0) + t * Double(b1 - b0)))
        data.append(contentsOf: [r, g, b, 255])
      }
    }
    return data
  }

  private func makeBorderedBoxRGBA(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> Data {
    var data = Data(capacity: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let border = x < 3 || y < 3 || x >= width - 3 || y >= height - 3
        if border {
          data.append(contentsOf: [240, 240, 240, 255])
        } else {
          data.append(contentsOf: [r, g, b, 255])
        }
      }
    }
    return data
  }

  private func makeIndexedBox(width: Int, height: Int, fillIndex: UInt8, borderIndex: UInt8) -> Data {
    var data = Data(capacity: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let border = x < 3 || y < 3 || x >= width - 3 || y >= height - 3
        data.append(border ? borderIndex : fillIndex)
      }
    }
    return data
  }

  /// SIXEL 8-color 96x48 banded graphic with transparent holes (`P2=1`).
  private func makeSixelBands96x48() -> String {
    let palette: [(Int, Int, Int)] = [
      (95, 25, 25),  // 0: red
      (95, 60, 15),  // 1: orange
      (95, 90, 20),  // 2: yellow
      (25, 85, 35),  // 3: green
      (20, 80, 85),  // 4: cyan
      (30, 50, 95),  // 5: blue
      (65, 30, 90),  // 6: purple
      (95, 35, 75),  // 7: magenta
    ]
    var s = "\(Self.esc)P0;1;0q\"1;1;96;48"
    for (idx, (r, g, b)) in palette.enumerated() {
      s += "#\(idx);2;\(r);\(g);\(b)"
    }
    // 8 sixel rows (each 6px tall = 48px total), each 96px wide with two transparent holes.
    for band in 0..<8 {
      s += "#\(band)!24~!16?!16~!16?!24~"
      if band < 7 { s += "-" }
    }
    s += "\(Self.esc)\\"
    return s
  }

  /// Pure-Swift minimal stored-zlib 32x32 RGB PNG encoder (zero external dependencies).
  private func makeMinimalPNG32x32() -> Data {
    let width = 32
    let height = 32
    var raw = Data(capacity: height * (1 + width * 3))
    for y in 0..<height {
      raw.append(0)  // PNG filter type 0 (None)
      for x in 0..<width {
        let border = x < 2 || y < 2 || x >= width - 2 || y >= height - 2
        let diag = ((x + y) / 6) % 2 == 0
        if border {
          raw.append(contentsOf: [255, 215, 70])   // Gold border
        } else if diag {
          raw.append(contentsOf: [215, 45, 165])   // Magenta
        } else {
          raw.append(contentsOf: [245, 185, 45])   // Gold
        }
      }
    }

    // Wrap raw scanlines in RFC 1950 zlib stream with a single uncompressed DEFLATE block.
    var zlib = Data(capacity: 2 + 5 + raw.count + 4)
    zlib.append(contentsOf: [0x78, 0x01])  // Zlib header (CM=8, CINFO=7, no preset dict, FCHECK valid)
    zlib.append(0x01)                      // BFINAL=1, BTYPE=00 (stored)
    let len = UInt16(raw.count)
    let nlen = ~len
    zlib.append(UInt8(len & 0xff))
    zlib.append(UInt8(len >> 8))
    zlib.append(UInt8(nlen & 0xff))
    zlib.append(UInt8(nlen >> 8))
    zlib.append(raw)
    let adler = adler32(raw)
    zlib.append(contentsOf: bigEndian32(adler))

    var ihdr = Data(capacity: 13)
    ihdr.append(contentsOf: bigEndian32(UInt32(width)))
    ihdr.append(contentsOf: bigEndian32(UInt32(height)))
    ihdr.append(contentsOf: [8, 2, 0, 0, 0])  // 8-bit RGB, deflate, standard filter, non-interlaced

    var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    appendPNGChunk(type: "IHDR", payload: ihdr, to: &png)
    appendPNGChunk(type: "IDAT", payload: zlib, to: &png)
    appendPNGChunk(type: "IEND", payload: Data(), to: &png)
    return png
  }

  private func appendPNGChunk(type: String, payload: Data, to png: inout Data) {
    let typeBytes = Data(type.utf8)
    png.append(contentsOf: bigEndian32(UInt32(payload.count)))
    png.append(typeBytes)
    png.append(payload)
    var crcInput = Data(capacity: 4 + payload.count)
    crcInput.append(typeBytes)
    crcInput.append(payload)
    png.append(contentsOf: bigEndian32(crc32(crcInput)))
  }

  private func bigEndian32(_ value: UInt32) -> [UInt8] {
    [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
  }

  private func adler32(_ data: Data) -> UInt32 {
    var s1: UInt32 = 1
    var s2: UInt32 = 0
    for byte in data {
      s1 = (s1 + UInt32(byte)) % 65521
      s2 = (s2 + s1) % 65521
    }
    return (s2 << 16) | s1
  }

  private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        if (crc & 1) != 0 {
          crc = (crc >> 1) ^ 0xedb8_8320
        } else {
          crc >>= 1
        }
      }
    }
    return crc ^ 0xffff_ffff
  }

  // MARK: - Utilities

  private func hsvToRGB(h: Double, s: Double, v: Double) -> (Int, Int, Int) {
    let c = v * s
    let x = c * (1 - abs((h / 60.0).truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let (r1, g1, b1): (Double, Double, Double)
    switch h {
    case ..<60: (r1, g1, b1) = (c, x, 0)
    case ..<120: (r1, g1, b1) = (x, c, 0)
    case ..<180: (r1, g1, b1) = (0, c, x)
    case ..<240: (r1, g1, b1) = (0, x, c)
    case ..<300: (r1, g1, b1) = (x, 0, c)
    default: (r1, g1, b1) = (c, 0, x)
    }
    return (Int((r1 + m) * 255), Int((g1 + m) * 255), Int((b1 + m) * 255))
  }

  private func findSubsequence(_ needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    let limit = haystack.count - needle.count
    for i in 0...limit {
      var matched = true
      for j in 0..<needle.count where haystack[i + j] != needle[j] {
        matched = false
        break
      }
      if matched { return i..<(i + needle.count) }
    }
    return nil
  }

  private func formatRawBytes(_ bytes: [UInt8]) -> String {
    let escaped = bytes.map { b -> String in
      switch b {
      case 0x1b: return "ESC"
      case 0x0d: return "\\r"
      case 0x0a: return "\\n"
      case 0x09: return "\\t"
      case 0x7f: return "DEL"
      case 0x20...0x7e: return String(UnicodeScalar(b))
      default: return String(format: "\\x%02X", b)
      }
    }.joined()
    let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    return "\(escaped)  [\(hex)]"
  }

  private func escapeForDisplay(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x1b: out += "\\e"
      case 0x07: out += "\\a"
      case 0x0a: out += "\\n"
      case 0x0d: out += "\\r"
      case 0x09: out += "\\t"
      case 0x00..<0x20, 0x7f: out += String(format: "\\x%02X", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  private func clip(_ text: String, to maxChars: Int) -> String {
    guard maxChars > 0 else { return "" }
    if text.count <= maxChars { return text }
    if maxChars == 1 { return "…" }
    return String(text.prefix(maxChars - 1)) + "…"
  }

  private func padRight(_ text: String, to width: Int) -> String {
    if text.count >= width { return text }
    return text + String(repeating: " ", count: width - text.count)
  }

  private func displayWidthASCIIish(_ text: String) -> Int {
    text.count
  }
}

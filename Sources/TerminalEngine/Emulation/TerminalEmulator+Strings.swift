import Foundation

extension TerminalEmulator {
  func finishQuery() {
    let payload = String(decoding: sequenceBytes, as: UTF8.self)
    sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
    if payload.hasPrefix("+q") {
      replies.append(contentsOf: TerminalQueries.termcap(String(payload.dropFirst(2)), applicationCursor: applicationCursor).utf8)
    } else if payload.hasPrefix("$q") {
      let s = screen
      replies.append(contentsOf: TerminalQueries.status(String(payload.dropFirst(2)), style: pen, protected: protectedOutput,
        top: s.topMargin, bottom: s.bottomMargin, left: s.leftMargin, right: s.rightMargin, cursorShape: s.cursorShape,
        rows: rowCount).utf8)
    }
  }
  func finishString() {
    if case .osc = parser {
      // OSC bytes are lossy UTF-8 decoded before command dispatch.
      let decoded = String(decoding: sequenceBytes, as: UTF8.self)
      sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
      let parts = decoded.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
      let command = parts.first.map(String.init) ?? ""
      let value = parts.count > 1 ? String(parts[1]) : ""
      if command == "0" || command == "2" {
        title = sanitizedTitle(value); if command == "0" { iconTitle = title }
        changed(document: false, screen: false)
      }
      else if command == "1" { iconTitle = sanitizedTitle(value) }
      else if command == "7" {
        if value.utf8.count <= 8192 { currentDirectory = value }
      }
      else if command == "8" {
        if let parameterSeparator = value.firstIndex(of: ";") {
          let uri = String(value[value.index(after: parameterSeparator)...])
          if uri.utf8.count <= 8192 {
            currentLink = uri.isEmpty ? nil : uri
            if !uri.isEmpty {
              // OSC 8 parameters are colon-separated key=value pairs. Retain
              // only the defined id field; reject overlong/control IDs rather
              // than truncating two distinct identities to the same value.
              let parameters = value[..<parameterSeparator].split(separator: ":", omittingEmptySubsequences: false)
              if let field = parameters.first(where: { $0.hasPrefix("id=") }) {
                let id = String(field.dropFirst(3))
                if !id.isEmpty, id.utf8.count <= 256,
                   !id.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                  attributes.linkID = id
                }
              }
            }
          }
        }
      }
      else if ["4", "5", "6", "10", "11", "12", "104", "105", "106", "110", "111", "112"].contains(command) {
        for reply in palette.applyOSC(command: command, value: value) { replies.append(contentsOf: reply.utf8) }
        refreshGraphicsPalette()
        changed(document: false, screen: false)
      }
      else if command == "133" {
        if !usingAlternate {
          commandHistory.marker(value, row: screen.rows[screen.cursorRow].id, directory: currentDirectory)
        }
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
      else if command == "1337" {
        if value.hasPrefix("MultipartFile=") {
          multipartImage = InlineImageDecoder(multipartHeader: String(value.dropFirst("MultipartFile=".count)))
        } else if value == "FileEnd" {
          let decoder = multipartImage; multipartImage = nil
          if let image = decoder?.finish(download: { [self] in _ = downloads.enqueue(name: $0, data: $1) }) {
            showInlineImage(image.request, width: image.width, height: image.height, rgba: image.rgba, frames: image.frames)
          }
        } else if value == "ReportCellSize" {
          replies.append(Data("\u{1b}]1337;ReportCellSize=\(cellPixelHeight);\(cellPixelWidth)\u{1b}\\".utf8))
        } else if value == "Capabilities" {
          // F is the File capability. Saving received bytes remains an explicit
          // host action; receipt never chooses or writes a filesystem path.
          replies.append(Data("\u{1b}]1337;Capabilities=T3LrBFSyHSx\u{1b}\\".utf8))
        }
      }
      return
    }
    guard case .apc = parser else {
      sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
      return
    }
    let payload = Data(sequenceBytes)
    sequenceBytes.removeAll(keepingCapacity: sequenceBytes.capacity <= 65_536)
    // Printing can move history rows, but the graphics protocol is the only
    // path that needs live anchor membership.  Pruning here keeps ordinary
    // scalar output O(1) while retaining the placement cap semantics.
    pruneGraphicsAnchors()
    if graphicsPaletteStale { refreshGraphicsPalette() }
    let s = screen
    let outcome = graphics.consume(payload, context: KittyGraphicsContext(
      alternate: usingAlternate, row: s.rows[s.cursorRow].id, column: s.cursorColumn,
      cellWidth: cellPixelWidth, cellHeight: cellPixelHeight, screenRows: s.rows.map(\.id),
      rowPositions: graphics.hasRelativePlacements ? graphicsRowPositions(offset: 0) : [:],
      virtualOrigins: virtualParentOrigins(offset: 0)), now: clock)
    applyGraphicsOutcome(outcome)
  }
  func applyGraphicsOutcome(_ outcome: KittyGraphicsOutcome) {
    let s = screen
    if let reply = outcome.reply { replies.append(reply) }
    if let advance = outcome.advance {
      resetClusterBoundary()
      var moved = s
      moved.cursorColumn = min(columns - 1, moved.cursorColumn + advance.0)
      moved.cursorRow = min(rowCount - 1, moved.cursorRow + advance.1)
      moved.pendingWrap = false
      screen = moved
    }
    changed(document: false)
  }
  /// Shows a decoded picture at the cursor and moves the cursor past it.
  /// The screen scrolls as the picture needs, so all of it stays visible
  /// (it is anchored to its first row, which scrolls with the text).
  /// `below` leaves the cursor on the line after the picture, in the column
  /// it began in, as Sixel does; otherwise it ends on the picture's last
  /// row, to its right, as iTerm2's inline images do.
  func showSixel(width: Int, height: Int, rgba: Data) {
    if sixelDisplayMode {
      let s = screen
      _ = graphics.show(width: width, height: height, rgba: rgba, columns: 0, rows: 0,
        context: KittyGraphicsContext(alternate: usingAlternate, row: s.rows[0].id, column: 0,
          cellWidth: cellPixelWidth, cellHeight: cellPixelHeight, screenRows: s.rows.map(\.id)))
      changed()
    } else {
      showPicture(width: width, height: height, rgba: rgba, columns: 0, rows: 0, below: !sixelCursorRight)
    }
  }
  private func showPicture(width: Int, height: Int, rgba: Data, columns wanted: Int, rows wantedRows: Int, below: Bool,
                           frames: [InlineImageDecoder.Frame] = [], stretch: Bool = false) {
    pruneGraphicsAnchors()
    let s = screen
    guard s.rows.indices.contains(s.cursorRow), let cells = graphics.show(
      width: width, height: height, rgba: rgba, columns: wanted, rows: wantedRows,
      context: KittyGraphicsContext(
        alternate: usingAlternate, row: s.rows[s.cursorRow].id, column: s.cursorColumn,
        cellWidth: cellPixelWidth, cellHeight: cellPixelHeight, screenRows: s.rows.map(\.id)), animation: frames, stretch: stretch)
    else { return }
    resetClusterBoundary()
    for _ in 0..<(below ? cells.rows : cells.rows - 1) { index(reverse: false) }
    var moved = screen
    moved.cursorColumn = below ? s.cursorColumn : min(columns - 1, s.cursorColumn + cells.columns)
    moved.pendingWrap = false
    screen = moved
    changed()
  }
  /// Turns an inline image's `width` and `height` into cells. A picture
  /// wider than the room to the right of the cursor is scaled to fit it.
  func showInlineImage(_ request: InlineImageDecoder.Request, width: Int, height: Int, rgba: Data,
                       frames: [InlineImageDecoder.Frame] = []) {
    let cellWidth = max(1, cellPixelWidth), cellHeight = max(1, cellPixelHeight)
    func cells(_ size: InlineImageDecoder.Size, of total: Int, cell: Int) -> Int? {
      switch size {
      case .automatic: return nil
      case .cells(let count): return count
      case .pixels(let pixels): return max(1, (pixels + cell - 1) / cell)
      case .percent(let percent): return max(1, total * percent / 100)
      }
    }
    let room = max(1, columns - screen.cursorColumn)
    var wide = cells(request.width, of: columns, cell: cellWidth) ?? 0
    var tall = cells(request.height, of: rowCount, cell: cellHeight) ?? 0
    if wide == 0, tall == 0 {
      if (width + cellWidth - 1) / cellWidth > room { wide = room }
    } else if wide > 0, tall > 0, request.preservesAspectRatio {
      // The largest size of the picture's shape inside the box asked for.
      let boxWidth = wide * cellWidth, boxHeight = tall * cellHeight
      if boxWidth * height <= boxHeight * width {
        tall = max(1, (boxWidth * height / width + cellHeight - 1) / cellHeight)
      } else {
        wide = max(1, (boxHeight * width / height + cellWidth - 1) / cellWidth)
      }
    }
    showPicture(width: width, height: height, rgba: rgba, columns: min(wide, 4096), rows: min(tall, 4096), below: false,
      frames: frames, stretch: !request.preservesAspectRatio)
  }
  func enqueueClipboard(_ data: Data) {
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
  func sanitizedTitle(_ value: String) -> String {
    var result = ""
    var byteCount = 0
    // Remove direction overrides, isolates and marks that can disguise a
    // host/path. Preserve other format scalars, including ZWJ and WORD JOINER.
    for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control
      && ![0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value) {
      let nextCount = scalar.utf8.count
      guard byteCount + nextCount <= 4096 else { break }
      result.unicodeScalars.append(scalar)
      byteCount += nextCount
    }
    return result
  }
}

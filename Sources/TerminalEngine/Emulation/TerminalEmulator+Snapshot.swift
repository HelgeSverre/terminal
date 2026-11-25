import Foundation
import TerminalInterop

#if SNAPSHOT_ABI_DIAGNOSTICS
// Test-build counters distinguish the direct value path from both C oracles.
// No counter or per-cell instrumentation is compiled into the application.
enum SnapshotABIDiagnostics {
  nonisolated(unsafe) static var borrowedStringAllocations = 0
  nonisolated(unsafe) static var jsonPublications = 0
}
#endif

// Owns byte storage for a synchronous ABI snapshot callback.  The callback
// promise is deliberately narrow: clients copy before return, so storage can
// be released immediately afterwards.
private final class BorrowedSnapshotCells {
  @exclusivity(unchecked) var text: [UnsafeMutablePointer<UInt8>] = []
  @exclusivity(unchecked) var links: [UnsafeMutablePointer<UInt8>] = []
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

extension TerminalEmulator {
  func graphicsRowPositions(offset: Int) -> [UInt64: Int] {
    var positions: [UInt64: Int] = [:]
    let visible = Dictionary(uniqueKeysWithValues: screen.rows.enumerated().map { ($0.element.id, $0.offset) })
    let scroll = usingAlternate ? 0 : min(offset, history.count)
    for id in graphics.anchorRows {
      if let index = visible[id] { positions[id] = index + scroll }
      else if !usingAlternate, let index = history.index(ofRowID: id) { positions[id] = index - history.count + scroll }
    }
    return positions
  }
  func visibleImages(offset: Int, height: Int? = nil) -> [KittyImagePlacement] {
    guard graphics.hasPlacements else { return [] }
    let placeholders = graphics.hasVirtualPlacements ? placeholderImages(offset: offset, presentationHeight: height) : (images: [], origins: [:])
    return graphics.visible(alternate: usingAlternate, positions: graphicsRowPositions(offset: offset), height: height ?? rowCount,
                            virtualOrigins: virtualParentOrigins(offset: offset)) + placeholders.images
  }
  func virtualParentOrigins(offset: Int) -> [UInt64: KittyPlacementOrigin] {
    guard graphics.hasVirtualParents else { virtualOriginCache = nil; return [:] }
    if usingAlternate { return placeholderImages(offset: 0, originsOnly: true).origins }
    let placements = graphics.virtualPlacementIdentities
    var cache = virtualOriginCache ?? VirtualOriginCache(geometry: geometryEpoch, placements: placements)
    if cache.geometry != geometryEpoch || cache.placements != placements
      || cache.tail.map({ history.index(ofRowID: $0) == nil }) == true
      || cache.origins.values.contains(where: {
        history.index(ofRowID: $0.rowID) == nil || history.index(ofRowID: $0.columnRowID) == nil
      }) {
      cache = VirtualOriginCache(geometry: geometryEpoch, placements: placements)
    }
    let first = cache.tail.flatMap { history.index(ofRowID: $0).map { $0 + 1 } } ?? 0
    if first < history.count {
      _ = placeholderImages(offset: 0, originsOnly: true, historyRange: first..<history.count) { serial, origin, rowID, sourceRow in
        let next = HistoryVirtualOrigin(rowID: rowID, rowOffset: origin.row - sourceRow, columnRowID: rowID, column: origin.column)
        if var old = cache.origins[serial] {
          let oldRow = self.history.index(ofRowID: old.rowID)! - self.history.count + old.rowOffset
          if origin.row < oldRow { old.rowID = next.rowID; old.rowOffset = next.rowOffset }
          if origin.column < old.column { old.column = next.column; old.columnRowID = next.columnRowID }
          cache.origins[serial] = old
        } else { cache.origins[serial] = next }
      }
    }
    cache.tail = history.count > 0 ? history[history.count - 1].id : nil
    virtualOriginCache = cache
    var origins = cache.origins.mapValues {
      KittyPlacementOrigin(row: history.index(ofRowID: $0.rowID)! - history.count + $0.rowOffset, column: $0.column)
    }
    for (serial, live) in placeholderImages(offset: 0, originsOnly: true).origins {
      if let old = origins[serial] { origins[serial] = KittyPlacementOrigin(row: min(old.row, live.row), column: min(old.column, live.column)) }
      else { origins[serial] = live }
    }
    let scroll = min(offset, history.count)
    return origins.mapValues { KittyPlacementOrigin(row: $0.row + scroll, column: $0.column) }
  }
  /// The image slices behind the Unicode placeholders on screen. Runs of
  /// placeholder cells that continue one another become one slice each.
  private func placeholderImages(offset: Int, originsOnly: Bool = false, historyRange: Range<Int>? = nil, presentationHeight: Int? = nil,
    recordOrigin: ((UInt64, KittyPlacementOrigin, UInt64, Int) -> Void)? = nil)
    -> (images: [KittyImagePlacement], origins: [UInt64: KittyPlacementOrigin]) {
    let start = usingAlternate ? 0 : history.count - min(offset, history.count)
    let total = usingAlternate ? alternate.rows.count : history.count + primary.rows.count
    // Parents may be above the viewport while their relative children are visible.
    let lower = historyRange?.lowerBound ?? start
    let visibleHeight = presentationHeight ?? rowCount
    let upper = historyRange?.upperBound ?? min(total, start + visibleHeight)
    var result: [KittyImagePlacement] = []
    var origins: [UInt64: KittyPlacementOrigin] = [:]
    for index in lower..<upper {
      let row = usingAlternate ? alternate.rows[index] : index < history.count ? history[index] : primary.rows[index - history.count]
      let rowID = row.id
      let screenRow = index - start
      var run: (cell: KittyPlaceholder.Cell, start: Int, count: Int)?
      var previous: KittyPlaceholder.Cell?
      func flush() {
        guard let current = run, let row = current.cell.row, let column = current.cell.column else { run = nil; return }
        if let anchor = graphics.placeholderOrigin(current.cell, screenRow: screenRow, screenColumn: current.start) {
          recordOrigin?(anchor.serial, anchor.origin, rowID, screenRow)
          if let old = origins[anchor.serial] {
            origins[anchor.serial] = KittyPlacementOrigin(row: min(old.row, anchor.origin.row), column: min(old.column, anchor.origin.column))
          } else { origins[anchor.serial] = anchor.origin }
        }
        if !originsOnly, screenRow >= 0, screenRow < visibleHeight, let slice = graphics.placeholderSlice(
          current.cell, row: row, column: column, count: current.count, screenRow: screenRow,
          screenColumn: current.start, alternate: usingAlternate, cellWidth: cellPixelWidth, cellHeight: cellPixelHeight) {
          result.append(slice)
        }
        run = nil
      }
      for index in 0..<row.count {
        guard row.starts(with: KittyPlaceholder.character, at: index) else { flush(); previous = nil; continue }
        let cell = row.cell(index)
        guard var placeholder = KittyPlaceholder.read(text: cell.text, foreground: cell.style.foreground, underline: cell.style.underline)
        else { flush(); previous = nil; continue }
        // A cell without its row or column continues the one to its left.
        if let left = previous, left.image == placeholder.image, left.placement == placeholder.placement {
          if placeholder.row == nil { placeholder.row = left.row }
          if placeholder.column == nil, placeholder.row == left.row { placeholder.column = left.column.map { $0 + 1 } }
        }
        if placeholder.row == nil { placeholder.row = 0 }
        if placeholder.column == nil { placeholder.column = 0 }
        if let current = run, current.cell.image == placeholder.image, current.cell.placement == placeholder.placement,
           current.cell.row == placeholder.row, let first = current.cell.column,
           placeholder.column == first + current.count, current.start + current.count == index {
          run!.count += 1
        } else {
          flush()
          run = (placeholder, index, 1)
        }
        previous = placeholder
      }
      flush()
    }
    return (result, origins)
  }
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
    var rows: [RowSnapshot] = []
    rows.reserveCapacity(selected.rows.count)
    // At most one adjacent row is projected for smooth viewport presentation.
    // Keep it separate from rows and the advertised geometry.
    var presentationRows = selected.rows
    if !usingAlternate, selected.offset > 0,
      TerminalSnapshot.geometryError(columns: columns, rows: selected.rows.count + 1) == nil {
      let next = history.count + primary.rows.count - selected.offset
      if next < history.count { presentationRows.append(history[next]) }
      else if primary.rows.indices.contains(next - history.count) {
        presentationRows.append(primary.rows[next - history.count])
      }
    }
    for row in presentationRows {
      guard row.count == columns else { return (nil, "Invalid snapshot dimensions or palette") }
      var cells: [CellSnapshot] = []
      cells.reserveCapacity(columns)
      for cell in row.cells {
        guard let kind = CellKind(rawValue: cell.kind) else { return (nil, "Invalid cell kind") }
        let resolved = palette.presentationStyle(cell.style)
        let flags = resolved.flags
        let style = CellStyle(
          foreground: TerminalColor(packed: resolved.foreground),
          background: TerminalColor(packed: resolved.background),
          underline_color: TerminalColor(packed: resolved.underline),
          underline: Int(resolved.underlineKind), bold: flags & 1 != 0, faint: flags & 2 != 0,
          italic: flags & 4 != 0, inverse: flags & 8 != 0, conceal: flags & 16 != 0,
          strike: flags & 32 != 0, overline: flags & 64 != 0, blink: flags & 128 != 0)
        cells.append(CellSnapshot(text: cell.text, kind: kind, style: style,
                                  link: cell.link, linkID: cell.linkID, flags: Int(cell.flags)))
      }
      rows.append(RowSnapshot(cells: cells, soft_wrapped: row.softWrapped, id: row.id, revision: row.revision))
    }
    let highlights = visibleSearchHighlights(in: selected.rows, offset: selected.offset)
    func image(_ value: KittyImagePlacement) -> ImagePlacementSnapshot {
      ImagePlacementSnapshot(image: value.image, generation: value.generation, width: value.width, height: value.height,
        source: value.source, row: value.row, col: value.column, columns: value.columns,
        rows: value.rows, offset: value.offset, natural: value.natural, z: value.z, placement: value.placement,
        extent: value.extent, stretch: value.stretch)
    }
    let images = visibleImages(offset: selected.offset).map(image)
    var snapshot = TerminalSnapshot(
      at_prompt: cursor.atPrompt, input_ready: cursor.inputReady, search: highlights.current, images: images,
      revision: revision, geometry_epoch: geometryEpoch, document_epoch: documentEpoch,
      history_epoch: historyEpoch, screen_epoch: screenEpoch, scroll_offset: selected.offset,
      following_tail: selected.followingTail, viewport_clamp_revision: viewportClampRevision,
      cols: columns, rows: Array(rows.prefix(selected.rows.count)),
      cursor: CursorSnapshot(row: cursor.cursorRow, col: cursor.cursorColumn, pending_wrap: cursor.pendingWrap,
                             visible: cursor.cursorVisible, shape: Int(cursor.cursorShape)),
      modes: ModesSnapshot(application_cursor: applicationCursor, bracketed_paste: bracketedPaste,
                           focus: focusReporting, mouse: mouseMode, sgr_mouse: sgrMouse, mouse_encoding: mouseEncoding,
                           reverse_video: reverseVideo, newline: newlineMode),
      alternate: usingAlternate, title: title, cwd: currentDirectory, history_rows: history.count,
      palette: colors, default_fg: foreground, default_bg: background, cursor_color: palette.cursorRGB,
      selectionPresentation: TerminalSelectionPresentation(snapshotID: selectionSnapshotID,
        documentGeneration: selectionDocumentGeneration, screen: selectionScreen, geometryEpoch: geometryEpoch,
        columns: columns, rows: selected.rows.map { .init(id: $0.id, revision: $0.revision, softWrapped: $0.softWrapped) }),
      selection: selection.snapshot(screen: selectionScreen, rows: selected.rows),
      search_matches: highlights.others)
    if rows.count > selected.rows.count, let guardRow = rows.last {
      let expandedHighlights = visibleSearchHighlights(in: presentationRows, offset: selected.offset)
      snapshot.presentationOverscan = TerminalPresentationOverscan(row: guardRow,
        images: visibleImages(offset: selected.offset, height: rowCount + 1).map(image),
        selection: selection.snapshot(screen: selectionScreen, rows: presentationRows),
        search: expandedHighlights.current, searchMatches: expandedHighlights.others)
    }
    return (snapshot, nil)
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
  func visibleSearchHighlights(in rows: [TerminalRow], offset: Int)
    -> (current: [SearchHighlight], others: [SearchHighlight]) {
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
    var current: [SearchHighlight] = []
    var others: [SearchHighlight] = []
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
        let highlight = SearchHighlight(row: visible, start: span.start, end: span.end)
        if entry.match == hits.current { current.append(highlight) } else { others.append(highlight) }
      }
    }
    return (current, others)
  }
  private func snapshotLinkIDs(_ rows: [TerminalRow]) -> [String: String] {
    var ids: [String: String] = [:]
    for (row, cells) in rows.enumerated() {
      cells.forEachLinkID { column, id in ids[String(row * columns + column)] = id }
    }
    return ids
  }
  func publishBinary(scroll: Int?, now: UInt64, context: UnsafeMutableRawPointer?, callback: SnapshotCallback?) -> Bool {
    tick(now)
    guard !publicationGated else { return false }
    guard let callback else { return false }
    let selected = selectSnapshot(scroll: scroll)
    var metadataObject = snapshotMetadata(cursor: screen, offset: selected.offset,
                                          followingTail: selected.followingTail,
                                          search: visibleSearchHighlights(in: selected.rows, offset: selected.offset))
    metadataObject["link_ids"] = snapshotLinkIDs(selected.rows)
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
        let resolved = palette.presentationStyle(cell.style)
        var view = TerminalCellView()
        view.text = borrowed.copy(cell.text, into: &borrowed.text)
        view.text_len = cell.text.utf8.count
        if let link = cell.link {
          view.link = borrowed.copy(link, into: &borrowed.links)
          view.link_len = link.utf8.count
        }
        view.foreground = resolved.foreground
        view.background = resolved.background
        view.underline_color = resolved.underline
        view.style_flags = resolved.flags
        view.kind = cell.kind
        view.cell_flags = cell.flags
        view.underline = resolved.underlineKind
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
    let rows: [[String: Any]] = source.map { row in ["id": row.id, "revision": row.revision, "soft_wrapped": row.softWrapped, "cells": row.cells.map { cell in let resolved = palette.presentationStyle(cell.style); return ["text": cell.text, "kind": ["Empty","Lead1","Lead2","Continuation","WrapSpacer"][Int(cell.kind)], "style": ["foreground": colorJSON(resolved.foreground), "background": colorJSON(resolved.background), "underline_color": colorJSON(resolved.underline), "underline": Int(resolved.underlineKind), "bold": resolved.flags & 1 != 0, "faint": resolved.flags & 2 != 0, "italic": resolved.flags & 4 != 0, "inverse": resolved.flags & 8 != 0, "conceal": resolved.flags & 16 != 0, "strike": resolved.flags & 32 != 0, "overline": resolved.flags & 64 != 0, "blink": resolved.flags & 128 != 0], "link": cell.link as Any, "linkID": cell.linkID as Any, "flags": Int(cell.flags)] } ] }
    var data = snapshotMetadata(cursor: screen, offset: offset,
                                followingTail: selected.followingTail,
                                search: visibleSearchHighlights(in: source, offset: offset))
    data["rows"] = rows
    return (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8)
  }
  func snapshotMetadata(cursor: TerminalScreen, offset: Int,
                        followingTail: Bool,
                        search: (current: [SearchHighlight], others: [SearchHighlight])) -> [String: Any] {
    let images = visibleImages(offset: offset).map { image in ["image": image.image, "generation": image.generation, "width": image.width, "height": image.height, "source": image.source, "row": image.row, "col": image.column, "columns": image.columns, "rows": image.rows, "offset": image.offset, "natural": image.natural, "z": image.z, "placement": image.placement, "extent": image.extent as Any? ?? NSNull(), "stretch": image.stretch] as [String: Any] }
    let currentSearch = search.current.map { ["row": $0.row, "start": $0.start, "end": $0.end] }
    let otherSearch = search.others.map { ["row": $0.row, "start": $0.start, "end": $0.end] }
    var metadata: [String: Any] = ["at_prompt":cursor.atPrompt,"input_ready":cursor.inputReady,"search":currentSearch,"search_matches":otherSearch,"images":images,"revision":revision,"geometry_epoch":geometryEpoch,"document_epoch":documentEpoch,"history_epoch":historyEpoch,"screen_epoch":screenEpoch,"scroll_offset":offset,"following_tail":followingTail,"viewport_clamp_revision":viewportClampRevision,"cols":columns,"cursor":["row":cursor.cursorRow,"col":cursor.cursorColumn,"pending_wrap":cursor.pendingWrap,"visible":cursor.cursorVisible,"shape":Int(cursor.cursorShape)],"modes":["application_cursor":applicationCursor,"application_keypad":applicationKeypad,"autowrap":autoWrap,"bracketed_paste":bracketedPaste,"focus":focusReporting,"insert":insertMode,"left_right_margins":leftRightMargins,"mouse":mouseMode,"newline":newlineMode,"origin":originMode,"reverse_video":reverseVideo,"sgr_mouse":sgrMouse],"primary_margins":[primary.leftMargin, primary.rightMargin],"alternate_margins":[alternate.leftMargin, alternate.rightMargin],"vertical_margins":[cursor.topMargin, cursor.bottomMargin],"alternate":usingAlternate,"title":title,"history_rows":history.count,"palette":palette.snapshotPalette,"default_fg":palette.snapshotDefaultForeground,"default_bg":palette.snapshotDefaultBackground]
    metadata["cursor_color"] = palette.cursorRGB
    if var modes = metadata["modes"] as? [String: Any] {
      modes["mouse_encoding"] = mouseEncoding
      metadata["modes"] = modes
    }
    metadata["cwd"] = currentDirectory as Any? ?? NSNull()
    return metadata
  }
  private func colorJSON(_ color: UInt32) -> Any { if color >> 24 == 1 { return ["Indexed": Int(color & 255)] }; if color >> 24 == 2 { return ["Rgb": [Int((color >> 16) & 255), Int((color >> 8) & 255), Int(color & 255)]] }; return "Default" }
}

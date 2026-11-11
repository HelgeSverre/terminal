import AppKit
import Foundation
import Testing
@testable import TerminalApp

/// Serialized: the diagnostics counters (`SnapshotABIDiagnostics`) are
/// process-wide, and the test compares them before and after.
@Suite(.serialized) struct SnapshotBridgeTests {
  static func feed(_ core: OpaquePointer, _ text: String) {
    let bytes = Array(text.utf8) + [0]
    bytes.withUnsafeBufferPointer { buffer in
      var offset = 0
      while offset < bytes.count - 1 || terminal_has_work(core) {
        let used = terminal_feed(core, buffer.baseAddress! + offset, bytes.count - 1 - offset, 0)
        offset += used
      }
    }
  }
  static func compare(_ value: TerminalSnapshot, _ legacy: TerminalSnapshot) {
    #expect(value.rows == legacy.rows, "row identity/revision or cell layout/text/color/style/link/wrap mismatch")
    #expect(value.rows.allSatisfy { $0.id != 0 }, "live ABI snapshots must preserve real row identities")
    #expect(value.at_prompt == legacy.at_prompt)
    #expect(value.input_ready == legacy.input_ready)
    #expect(value.search == legacy.search)
    #expect(value.images == legacy.images && value.cursor == legacy.cursor)
    #expect(value.modes == legacy.modes && value.alternate == legacy.alternate)
    #expect(
      value.revision == legacy.revision && value.geometry_epoch == legacy.geometry_epoch)
    #expect(value.document_epoch == legacy.document_epoch)
    #expect(value.history_epoch == legacy.history_epoch && value.screen_epoch == legacy.screen_epoch)
    #expect(value.scroll_offset == legacy.scroll_offset && value.following_tail == legacy.following_tail)
    #expect(value.viewport_clamp_revision == legacy.viewport_clamp_revision)
    #expect(value.cols == legacy.cols && value.history_rows == legacy.history_rows)
    #expect(value.palette == legacy.palette && value.default_fg == legacy.default_fg)
    #expect(value.default_bg == legacy.default_bg && value.title == legacy.title)
    #expect(value.cwd == legacy.cwd)
  }
  static func legacySnapshot(_ core: OpaquePointer, scroll: Int = 0) throws -> TerminalSnapshot {
    let json = try #require(terminal_snapshot(core, scroll, 0), "legacy snapshot")
    defer { terminal_string_free(json) }
    return try JSONDecoder().decode(TerminalSnapshot.self, from: Data(bytes: json, count: strlen(json)))
  }
  @MainActor static func check(_ core: OpaquePointer, scroll: Int = 0) throws -> TerminalSnapshot {
    let legacy = try legacySnapshot(core, scroll: scroll)
    let result = SnapshotBridge.read(core, scroll: scroll, now: 0)
    let value = try #require(result.snapshot, Comment(rawValue: result.error ?? "direct snapshot absent"))
    compare(value, legacy)
    let binary = BinarySnapshotOracle.read(core, scroll: scroll, now: 0)
    let binaryValue = try #require(binary.snapshot, Comment(rawValue: binary.error ?? "binary snapshot absent"))
    compare(binaryValue, legacy)
    return value
  }

  /// The direct Swift snapshot bridge against the independent binary and JSON
  /// C oracles: styles and links, Unicode, search, scroll, images, the sync
  /// gate and owned lifetimes. The blocks share one terminal core.
  @MainActor @Test static func directBridgeMatchesOracles() throws {
    let core = try #require(terminal_create(8, 3), "create core")
    defer { terminal_destroy(core) }
    func feed(_ text: String) { Self.feed(core, text) }
    func check(scroll: Int = 0) throws -> TerminalSnapshot { try Self.check(core, scroll: scroll) }
    #expect(SnapshotBridge.read(nil, scroll: 0, now: 0).snapshot == nil)
    let borrowedBaseline = SnapshotABIDiagnostics.borrowedStringAllocations
    let jsonBaseline = SnapshotABIDiagnostics.jsonPublications
    for _ in 0..<100 {
      #expect(SnapshotBridge.read(core, scroll: 0, now: 0).snapshot != nil)
      #expect(SnapshotBridge.readView(core, now: 0).snapshot != nil)
    }
    #expect(SnapshotABIDiagnostics.borrowedStringAllocations == borrowedBaseline)
    #expect(SnapshotABIDiagnostics.jsonPublications == jsonBaseline)
    _ = try check()
    feed("\u{1b}]7;file://localhost/tmp/project%20%E7%8C%AB%23%25\u{7}")
    let directorySnapshot = try check()
    #expect(directorySnapshot.cwd == "file://localhost/tmp/project%20%E7%8C%AB%23%25")
    feed("\u{1b}c")
    let resetDirectorySnapshot = try check()
    #expect(resetDirectorySnapshot.cwd == directorySnapshot.cwd)
    feed("\u{1b}]4;196;#123456\u{7}\u{1b}]10;#abcdef\u{7}\u{1b}]11;#102030\u{7}")
    let recolored = try check()
    #expect(recolored.palette[196] == [18, 52, 86])
    #expect(recolored.default_fg == [171, 205, 239] && recolored.default_bg == [16, 32, 48])
    feed("\u{1b}]104;196\u{7}\u{1b}]10;#e6e6e6\u{7}\u{1b}]11;#0a0a0b\u{7}")
    // Positive controls: the independent C oracles really exercised their
    // borrowed-string and JSON paths rather than silently using Swift values.
    #expect(SnapshotABIDiagnostics.borrowedStringAllocations > borrowedBaseline)
    #expect(SnapshotABIDiagnostics.jsonPublications >= jsonBaseline + 2)
    let shapeJSON = terminal_snapshot(core, 0, 0)!
    var shapeMetadata = try JSONSerialization.jsonObject(
      with: Data(bytes: shapeJSON, count: strlen(shapeJSON))) as! [String: Any]
    terminal_string_free(shapeJSON)
    for (columns, rows) in [(0, 1), (1, 0), (4097, 1), (1, 4097), (4096, 257), (Int.max, Int.max)] {
      let error = TerminalSnapshot.geometryError(columns: columns, rows: rows)
      #expect(error != nil)
      shapeMetadata["cols"] = columns
      let product = columns.multipliedReportingOverflow(by: rows)
      let old = BinarySnapshotOracle.malformedGeometry(
        metadata: try JSONSerialization.data(withJSONObject: shapeMetadata),
        cellCount: product.overflow ? 0 : product.partialValue, rowCount: rows)
      #expect(old.snapshot == nil && old.error == error)
    }
    #expect(TerminalSnapshot.geometryError(columns: 4096, rows: 256) == nil)
    shapeMetadata["cols"] = 1
    let sentinels = BinarySnapshotOracle.emptyStringSentinels(
      metadata: try JSONSerialization.data(withJSONObject: shapeMetadata)).snapshot!
    #expect(sentinels.rows[0].cells[0].text == "" && sentinels.rows[0].cells[0].link == "")
    #expect(sentinels.rows[0].id == 0 && sentinels.selectionHit(row: 0, boundary: 0) == nil,
      "legacy binary metadata without identity proof must remain non-actionable")
    // Old experimental metadata did not have a readiness field. Preserve that
    // as unknown so automation cannot mistake an old A-only snapshot for B.
    feed("\u{1b}]133;A\u{7}")
    let drawing = try check()
    #expect(drawing.at_prompt && drawing.input_ready == false)
    feed("\u{1b}]133;B\u{7}")
    let inputReady = try check()
    #expect(inputReady.at_prompt && inputReady.input_ready == true)
    guard let readyJSON = terminal_snapshot(core, 0, 0) else { fatalError("ready snapshot") }
    var oldMetadata = try JSONSerialization.jsonObject(
      with: Data(bytes: readyJSON, count: strlen(readyJSON))) as! [String: Any]
    terminal_string_free(readyJSON)
    oldMetadata.removeValue(forKey: "input_ready")
    let oldSnapshot = try JSONDecoder().decode(
      TerminalSnapshot.self, from: JSONSerialization.data(withJSONObject: oldMetadata))
    #expect(oldSnapshot.at_prompt && oldSnapshot.input_ready == nil)
    feed("\u{1b}[1;2;3;4:3;5;7;8;9;53;38;2;12;34;56;48;5;196;58;2;90;80;70m")
    feed("\u{1b}]8;;https://example.test/a\u{1b}\\A👩🏽‍💻é猫")
    let styled = try check()
    let first = styled.rows[0].cells[0]
    #expect(first.style.foreground.rgb == [12, 34, 56])
    #expect(first.style.background.index == 196)
    #expect(first.style.underline_color.rgb == [90, 80, 70])
    #expect(first.style.bold && first.style.faint && first.style.italic)
    #expect(first.style.underline == 3)
    #expect(first.style.inverse && first.style.conceal && first.style.strike)
    #expect(first.style.overline && first.style.blink)
    #expect(first.link == "https://example.test/a")
    let projection = AccessibilityProjection(snapshot: styled)
    let emoji = "👩🏽‍💻"
    let emojiRange = (projection.text as NSString).range(of: emoji)
    #expect(emojiRange.location == 1 && emojiRange.length == emoji.utf16.count)
    for index in emojiRange.location..<NSMaxRange(emojiRange) {
      #expect(projection.range(for: index) == emojiRange)
    }
    #expect(projection.gridRange(for: emojiRange) == 1..<3)
    #expect(projection.textRange(gridStart: 2, gridEnd: 3) == emojiRange)
    #expect(projection.string(in: NSRange(location: NSNotFound, length: 0)) == nil)
    #expect(projection.string(in: NSRange(location: 1, length: Int.max)) == nil)
    #expect(projection.line(for: 0) == 0 && projection.range(forLine: 0).location == 0)
    let bounded = AccessibilityProjection(snapshot: styled, limit: 2)
    #expect(bounded.text == "A" && bounded.truncated)
    let empty = AccessibilityProjection(snapshot: styled, limit: 0)
    #expect(empty.length == 0 && empty.spans(for: NSRange(location: 0, length: 0)).count == 1)
    let parent = NSView(frame: .zero)
    let allText = NSRange(location: 0, length: projection.length)
    let attributed = projection.attributedString(in: allText, fontSize: 14, parent: parent)!
    #expect(attributed.string == projection.text)
    let attributes = attributed.attributes(at: 0, effectiveRange: nil)
    let font = attributes[.accessibilityFont] as! [String: Any]
    #expect(!(font[NSAccessibility.FontAttributeKey.fontName.rawValue] as! String).isEmpty)
    #expect((font[NSAccessibility.FontAttributeKey.fontSize.rawValue] as! NSNumber).doubleValue == 14)
    #expect((attributes[.accessibilityUnderline] as! NSNumber).intValue > 0)
    #expect((attributes[.accessibilityStrikethrough] as! NSNumber).boolValue)
    let linked = attributes[.accessibilityLink] as! AccessibleTerminalLink
    #expect(linked.accessibilityURL()?.absoluteString == first.link)
    #expect(linked.accessibilityRole() == .link)
    #expect((linked.accessibilityParent() as? NSView) === parent)
    #expect(!linked.isAccessibilityEnabled() && !linked.accessibilityPerformPress())
    // A remote AX client receives a weak element reference after this query's
    // attributed string has been released. The projection must own the link.
    var linkProjection: AccessibilityProjection? = AccessibilityProjection(snapshot: styled)
    weak var exportedLink: AccessibleTerminalLink?
    autoreleasepool {
      let transient = linkProjection!.attributedString(in: allText, fontSize: 14, parent: parent)!
      exportedLink = transient.attribute(.accessibilityLink, at: 0, effectiveRange: nil) as? AccessibleTerminalLink
    }
    #expect(exportedLink != nil && exportedLink?.accessibilityRole() == .link)
    linkProjection = nil
    #expect(exportedLink == nil)
    let concealedForeground = attributes[.accessibilityForegroundColor] as! CGColor
    let concealedBackground = attributes[.accessibilityBackgroundColor] as! CGColor
    #expect(concealedForeground == concealedBackground)
    let colors = CellPalette(snapshot: styled).resolve(first.style)
    // Indexed red background becomes the foreground under inverse, then dims
    // in linear light. Accessibility and rendering consume this same resolver.
    #expect(abs(colors.foreground.x - 0.65) < 0.00001)
    #expect(colors.foreground.y == 0 && colors.foreground.z == 0)
    let underline = colors.underline(matching: SIMD4(0, 0, 0, 0))
    let underlineColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
      components: [CGFloat(underline.x), CGFloat(underline.y), CGFloat(underline.z), 1])!
    let srgbUnderline = NSColor(cgColor: underlineColor)!.usingColorSpace(.sRGB)!
    #expect(abs(srgbUnderline.redComponent - 90.0 / 255) < 0.00001)
    #expect(abs(srgbUnderline.greenComponent - 80.0 / 255) < 0.00001)
    #expect(projection.attributedString(in: emojiRange, fontSize: 18, parent: parent)?.string == emoji)
    let newline = NSMaxRange(projection.range(forLine: 0)) - 1
    #expect(attributed.attributes(at: newline, effectiveRange: nil).isEmpty)
    #expect(projection.styleRange(for: emojiRange.location) == NSRange(location: 0, length: newline))
    #expect(projection.styleRange(for: newline) == NSRange(
      location: newline, length: projection.length - newline))
    #expect(projection.styleRange(for: projection.length).location == NSNotFound)
    #expect(projection.attributedString(in: NSRange(location: 1, length: Int.max), fontSize: 14, parent: parent) == nil)
    #expect(projection.attributedString(in: allText, fontSize: .nan, parent: parent) == nil)
    #expect(empty.attributedString(in: NSRange(location: 0, length: 0), fontSize: 14, parent: parent)?.length == 0)
    #expect(bounded.attributedString(in: NSRange(location: 0, length: 1), fontSize: 14, parent: parent)?.string == "A")
    #expect(VisibleLinkProjection.openableURL(for: "file:///tmp/example") == nil)
    #expect(VisibleLinkProjection.openableURL(for: "javascript:alert(1)") == nil)
    #expect(VisibleLinkProjection.openableURL(for: "HTTPS://example.test") != nil)
    feed("\u{1b}]8;;\u{1b}\\\u{1b}[0m\r\nplain\r\nmore\r\nlast\r\n")
    _ = try check()
    _ = try check(scroll: 2)
    terminal_view_scroll(core, 2)
    let anchored = SnapshotBridge.readView(core, now: 0).snapshot!
    compare(anchored, BinarySnapshotOracle.readView(core, now: 0).snapshot!)
    #expect(!anchored.following_tail && anchored.scroll_offset == 2)
    feed("\r\nnew\r\noutput")
    let retained = SnapshotBridge.readView(core, now: 0).snapshot!
    compare(retained, BinarySnapshotOracle.readView(core, now: 0).snapshot!)
    #expect(retained.rows == anchored.rows && retained.scroll_offset == 4)
    terminal_view_follow_tail(core)
    #expect(SnapshotBridge.readView(core, now: 0).snapshot!.following_tail)
    feed("\u{1b}]2;Bridge title\u{7}\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?1006h")
    feed("\u{1b}[?1002h\u{1b}[20h\u{1b}[?25l\u{1b}[4 q")
    feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=1,C=1;AQID\u{1b}\\")
    let image = try check()
    #expect(image.images.count == 1 && image.title == "Bridge title")
    #expect(image.modes.mouse == 1002 && image.modes.sgr_mouse && image.modes.newline == true)
    #expect(!image.cursor.visible && image.cursor.shape == 4)
    feed("\u{1b}[?1049hAlternate")
    let alternate = try check()
    #expect(alternate.alternate)
    #expect(alternate.cursor.visible && alternate.cursor.shape == 0)
    feed("\u{1b}[?2026hhidden")
    #expect(SnapshotBridge.read(core, scroll: 0, now: 0).snapshot == nil)
    #expect(BinarySnapshotOracle.read(core, scroll: 0, now: 0).snapshot == nil)
    // The direct seam owns the same deadline tick as either C endpoint.
    let expired = SnapshotBridge.read(core, scroll: 0, now: 151).snapshot!
    compare(expired, BinarySnapshotOracle.read(core, scroll: 0, now: 151).snapshot!)
    feed("\u{1b}[?2026l\u{1b}[?1049l")
    _ = try check()
    feed("\u{1b}[2J\u{1b}[H1234567猫")
    let wrapped = try check()
    #expect(wrapped.rows[0].cells[7].kind == "WrapSpacer")
    #expect(wrapped.rows[1].cells[1].kind == "Continuation")
    feed("\u{1b}[2J\u{1b}[1;6H")
    let blank = try check()
    let caretProjection = AccessibilityProjection(snapshot: blank)
    #expect(caretProjection.text.hasPrefix("     \n"))
    let caretRange = caretProjection.textRange(gridStart: 5, gridEnd: 5)
    #expect(caretRange == NSRange(location: 5, length: 0))
    #expect(caretProjection.spans(for: caretRange).first?.column == 5)
    feed("\u{1b}cneedle")
    let query = Array("needle".utf8)
    let task = query.withUnsafeBufferPointer { terminal_search_create(core, $0.baseAddress, $0.count) }!
    var searchStatus: UInt32 = 0
    for _ in 0..<100 {
      searchStatus = terminal_search_fill(core, task)
      if searchStatus == 0 { _ = terminal_search_step(task) }
      else if searchStatus == 2 { searchStatus = terminal_search_accept(core, task); break }
      else { Issue.record("unexpected search status"); break }
    }
    terminal_search_destroy(task)
    #expect(searchStatus == 5)
    let searched = try check()
    #expect(!searched.search.isEmpty)
    feed("\u{1b}c")
    #expect(terminal_resize(core, 1, 3))
    feed("猫")
    let clipped = try check()
    #expect(clipped.rows[0].cells[0].flags & 1 != 0)
    feed("\u{1b}c\u{1b}]8;;\u{1b}\\a" + String(repeating: "\u{301}", count: 70))
    let capped = try check()
    #expect(capped.rows[0].cells[0].flags & 4 != 0)
    // OSC 8's empty URI closes a link. The non-nil zero-length ABI sentinel
    // remains a distinct value and is covered separately above.
    #expect(capped.rows[0].cells[0].link == nil && capped.rows[1].cells[0].link == nil)
    // Owned Swift values must survive mutation, screen changes, and actor destruction.
    #expect(styled.rows[0].cells[0] == first && image.images.count == 1)
  }

  /// Alternating styles exercise both ends of the sorted run index.
  @MainActor @Test static func stripedStyleRuns() throws {
    // Alternating styles exercise both ends of the sorted run index and
    // ranges crossing a synthetic newline without asking for the full grid.
    let parent = NSView(frame: .zero)
    let stripedCore = terminal_create(128, 64)!
    let stripes = Data((0..<8_191).map { "\u{1b}[\($0.isMultiple(of: 2) ? 31 : 32)mX" }.joined().utf8)
    stripes.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var offset = 0
      while offset < bytes.count || terminal_has_work(stripedCore) {
        offset += terminal_feed(stripedCore, bytes.baseAddress! + offset, bytes.count - offset, 0)
      }
    }
    let striped = AccessibilityProjection(snapshot: SnapshotBridge.read(stripedCore, scroll: 0, now: 0).snapshot!)
    terminal_destroy(stripedCore)
    #expect(striped.length == 8_191 + 63)
    for index in 0..<striped.length {
      #expect(striped.styleRange(for: index) == NSRange(location: index, length: 1))
    }
    for index in [0, 127, 129, 32 * 129, striped.length - 1] {
      let single = striped.attributedString(in: NSRange(location: index, length: 1), fontSize: 14, parent: parent)!
      #expect(single.string == "X" && single.attribute(.accessibilityForegroundColor, at: 0, effectiveRange: nil) != nil)
    }
    let crossLine = striped.attributedString(in: NSRange(location: 127, length: 3), fontSize: 14, parent: parent)!
    #expect(crossLine.string == "X\nX")
    #expect(crossLine.attributes(at: 1, effectiveRange: nil).isEmpty)
    #expect(crossLine.attribute(.accessibilityForegroundColor, at: 0, effectiveRange: nil) as! CGColor
      != crossLine.attribute(.accessibilityForegroundColor, at: 2, effectiveRange: nil) as! CGColor)
    #expect(striped.styleRange(for: -1).location == NSNotFound)
    #expect(striped.styleRange(for: striped.length).location == NSNotFound)
    #expect(striped.attributedString(in: NSRange(location: striped.length, length: 0), fontSize: 14, parent: parent)?.length == 0)
  }

  /// History is a displayed viewport and must match both C oracles.
  @MainActor @Test static func historyViewport() throws {
    // History is a displayed viewport: the live cursor must not manufacture
    // padding in an unrelated historical row. The projection owns that rule.
    let historyCore = terminal_create(8, 3)!
    let historyInput = Data("\r\n\r\n\r\n\u{1b}[1;6H".utf8)
    historyInput.withUnsafeBytes {
      _ = terminal_feed(historyCore, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count, 0)
    }
    terminal_view_scroll(historyCore, 1)
    let historyView = SnapshotBridge.readView(historyCore, now: 0).snapshot!
    compare(historyView, BinarySnapshotOracle.readView(historyCore, now: 0).snapshot!)
    #expect(!historyView.following_tail)
    #expect(AccessibilityProjection(snapshot: historyView).text == "\n\n")
    // Legacy numeric offsets and the binary bridge must select the same
    // explicit viewport; this is deliberately distinct from the owner view.
    for scroll in [0, 1, Int.max] {
      let legacy = try legacySnapshot(historyCore, scroll: scroll)
      compare(SnapshotBridge.read(historyCore, scroll: scroll, now: 0).snapshot!, legacy)
      compare(BinarySnapshotOracle.read(historyCore, scroll: scroll, now: 0).snapshot!, legacy)
    }
    #expect(terminal_resize(historyCore, 8, 5))
    let primaryAnchor = SnapshotBridge.readView(historyCore, now: 0).snapshot!
    #expect(primaryAnchor.scroll_offset == 0 && !primaryAnchor.following_tail)
    compare(primaryAnchor, BinarySnapshotOracle.readView(historyCore, now: 0).snapshot!)
    terminal_destroy(historyCore)
  }
}

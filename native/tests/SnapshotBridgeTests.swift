import AppKit

@main struct SnapshotBridgeTests {
  @MainActor static func main() throws {
    guard let core = terminal_create(8, 3) else { fatalError("create core") }
    func feed(_ text: String) {
      let bytes = Array(text.utf8) + [0]
      bytes.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < bytes.count - 1 || terminal_has_work(core) {
          let used = terminal_feed(core, buffer.baseAddress! + offset, bytes.count - 1 - offset, 0)
          offset += used
        }
      }
    }
    func check(scroll: Int = 0) throws -> TerminalSnapshot {
      guard let json = terminal_snapshot(core, scroll, 0) else { fatalError("legacy snapshot") }
      let legacy = try JSONDecoder().decode(
        TerminalSnapshot.self, from: Data(bytes: json, count: strlen(json)))
      terminal_string_free(json)
      let result = SnapshotBridge.read(core, scroll: scroll, now: 0)
      guard let value = result.snapshot else {
        fatalError(result.error ?? "binary snapshot absent")
      }
      precondition(value.rows == legacy.rows, "cell layout/text/color/style/link/wrap mismatch")
      precondition(value.at_prompt == legacy.at_prompt)
      precondition(value.input_ready == legacy.input_ready)
      precondition(value.search == legacy.search)
      precondition(value.images == legacy.images && value.cursor == legacy.cursor)
      precondition(value.modes == legacy.modes && value.alternate == legacy.alternate)
      precondition(
        value.revision == legacy.revision && value.geometry_epoch == legacy.geometry_epoch)
      precondition(value.document_epoch == legacy.document_epoch)
      precondition(value.history_epoch == legacy.history_epoch && value.screen_epoch == legacy.screen_epoch)
      precondition(value.scroll_offset == legacy.scroll_offset && value.following_tail == legacy.following_tail)
      precondition(value.viewport_clamp_revision == legacy.viewport_clamp_revision)
      precondition(value.cols == legacy.cols && value.history_rows == legacy.history_rows)
      precondition(value.palette == legacy.palette && value.default_fg == legacy.default_fg)
      precondition(value.default_bg == legacy.default_bg && value.title == legacy.title)
      return value
    }
    _ = try check()
    // Old experimental metadata did not have a readiness field. Preserve that
    // as unknown so automation cannot mistake an old A-only snapshot for B.
    feed("\u{1b}]133;A\u{7}")
    let drawing = try check()
    precondition(drawing.at_prompt && drawing.input_ready == false)
    feed("\u{1b}]133;B\u{7}")
    let inputReady = try check()
    precondition(inputReady.at_prompt && inputReady.input_ready == true)
    guard let readyJSON = terminal_snapshot(core, 0, 0) else { fatalError("ready snapshot") }
    var oldMetadata = try JSONSerialization.jsonObject(
      with: Data(bytes: readyJSON, count: strlen(readyJSON))) as! [String: Any]
    terminal_string_free(readyJSON)
    oldMetadata.removeValue(forKey: "input_ready")
    let oldSnapshot = try JSONDecoder().decode(
      TerminalSnapshot.self, from: JSONSerialization.data(withJSONObject: oldMetadata))
    precondition(oldSnapshot.at_prompt && oldSnapshot.input_ready == nil)
    feed("\u{1b}[1;2;3;4:3;5;7;8;9;53;38;2;12;34;56;48;5;196;58;2;90;80;70m")
    feed("\u{1b}]8;;https://example.test/a\u{1b}\\A👩🏽‍💻é猫")
    let styled = try check()
    let first = styled.rows[0].cells[0]
    precondition(first.style.foreground.rgb == [12, 34, 56])
    precondition(first.style.background.index == 196)
    precondition(first.style.underline_color.rgb == [90, 80, 70])
    precondition(first.style.bold && first.style.faint && first.style.italic)
    precondition(first.style.underline == 3)
    precondition(first.style.inverse && first.style.conceal && first.style.strike)
    precondition(first.style.overline && first.style.blink)
    precondition(first.link == "https://example.test/a")
    let projection = AccessibilityProjection(snapshot: styled)
    let emoji = "👩🏽‍💻"
    let emojiRange = (projection.text as NSString).range(of: emoji)
    precondition(emojiRange.location == 1 && emojiRange.length == emoji.utf16.count)
    for index in emojiRange.location..<NSMaxRange(emojiRange) {
      precondition(projection.range(for: index) == emojiRange)
    }
    precondition(projection.gridRange(for: emojiRange) == 1..<3)
    precondition(projection.textRange(gridStart: 2, gridEnd: 3) == emojiRange)
    precondition(projection.string(in: NSRange(location: NSNotFound, length: 0)) == nil)
    precondition(projection.string(in: NSRange(location: 1, length: Int.max)) == nil)
    precondition(projection.line(for: 0) == 0 && projection.range(forLine: 0).location == 0)
    let bounded = AccessibilityProjection(snapshot: styled, limit: 2)
    precondition(bounded.text == "A" && bounded.truncated)
    let empty = AccessibilityProjection(snapshot: styled, limit: 0)
    precondition(empty.length == 0 && empty.spans(for: NSRange(location: 0, length: 0)).count == 1)
    let parent = NSView(frame: .zero)
    let allText = NSRange(location: 0, length: projection.length)
    let attributed = projection.attributedString(in: allText, fontSize: 14, parent: parent)!
    precondition(attributed.string == projection.text)
    let attributes = attributed.attributes(at: 0, effectiveRange: nil)
    let font = attributes[.accessibilityFont] as! [String: Any]
    precondition(!(font[NSAccessibility.FontAttributeKey.fontName.rawValue] as! String).isEmpty)
    precondition((font[NSAccessibility.FontAttributeKey.fontSize.rawValue] as! NSNumber).doubleValue == 14)
    precondition((attributes[.accessibilityUnderline] as! NSNumber).intValue > 0)
    precondition((attributes[.accessibilityStrikethrough] as! NSNumber).boolValue)
    let linked = attributes[.accessibilityLink] as! AccessibleTerminalLink
    precondition(linked.accessibilityURL()?.absoluteString == first.link)
    precondition(linked.accessibilityRole() == .link)
    precondition((linked.accessibilityParent() as? NSView) === parent)
    precondition(!linked.isAccessibilityEnabled() && !linked.accessibilityPerformPress())
    // A remote AX client receives a weak element reference after this query's
    // attributed string has been released. The projection must own the link.
    var linkProjection: AccessibilityProjection? = AccessibilityProjection(snapshot: styled)
    weak var exportedLink: AccessibleTerminalLink?
    autoreleasepool {
      let transient = linkProjection!.attributedString(in: allText, fontSize: 14, parent: parent)!
      exportedLink = transient.attribute(.accessibilityLink, at: 0, effectiveRange: nil) as? AccessibleTerminalLink
    }
    precondition(exportedLink != nil && exportedLink?.accessibilityRole() == .link)
    linkProjection = nil
    precondition(exportedLink == nil)
    let concealedForeground = attributes[.accessibilityForegroundColor] as! CGColor
    let concealedBackground = attributes[.accessibilityBackgroundColor] as! CGColor
    precondition(concealedForeground == concealedBackground)
    let colors = CellPalette(snapshot: styled).resolve(first.style)
    // Indexed red background becomes the foreground under inverse, then dims
    // in linear light. Accessibility and rendering consume this same resolver.
    precondition(abs(colors.foreground.x - 0.65) < 0.00001)
    precondition(colors.foreground.y == 0 && colors.foreground.z == 0)
    let underline = colors.underline(matching: SIMD4(0, 0, 0, 0))
    let underlineColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
      components: [CGFloat(underline.x), CGFloat(underline.y), CGFloat(underline.z), 1])!
    let srgbUnderline = NSColor(cgColor: underlineColor)!.usingColorSpace(.sRGB)!
    precondition(abs(srgbUnderline.redComponent - 90.0 / 255) < 0.00001)
    precondition(abs(srgbUnderline.greenComponent - 80.0 / 255) < 0.00001)
    precondition(projection.attributedString(in: emojiRange, fontSize: 18, parent: parent)?.string == emoji)
    let newline = NSMaxRange(projection.range(forLine: 0)) - 1
    precondition(attributed.attributes(at: newline, effectiveRange: nil).isEmpty)
    precondition(projection.styleRange(for: emojiRange.location) == NSRange(location: 0, length: newline))
    precondition(projection.styleRange(for: newline) == NSRange(
      location: newline, length: projection.length - newline))
    precondition(projection.styleRange(for: projection.length).location == NSNotFound)
    precondition(projection.attributedString(in: NSRange(location: 1, length: Int.max), fontSize: 14, parent: parent) == nil)
    precondition(projection.attributedString(in: allText, fontSize: .nan, parent: parent) == nil)
    precondition(empty.attributedString(in: NSRange(location: 0, length: 0), fontSize: 14, parent: parent)?.length == 0)
    precondition(bounded.attributedString(in: NSRange(location: 0, length: 1), fontSize: 14, parent: parent)?.string == "A")
    precondition(AccessibleTerminalLink.url("file:///tmp/example") == nil)
    precondition(AccessibleTerminalLink.url("javascript:alert(1)") == nil)
    precondition(AccessibleTerminalLink.url("HTTPS://example.test") != nil)
    // Alternating styles exercise both ends of the sorted run index and
    // ranges crossing a synthetic newline without asking for the full grid.
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
    precondition(striped.length == 8_191 + 63)
    for index in 0..<striped.length {
      precondition(striped.styleRange(for: index) == NSRange(location: index, length: 1))
    }
    for index in [0, 127, 129, 32 * 129, striped.length - 1] {
      let single = striped.attributedString(in: NSRange(location: index, length: 1), fontSize: 14, parent: parent)!
      precondition(single.string == "X" && single.attribute(.accessibilityForegroundColor, at: 0, effectiveRange: nil) != nil)
    }
    let crossLine = striped.attributedString(in: NSRange(location: 127, length: 3), fontSize: 14, parent: parent)!
    precondition(crossLine.string == "X\nX")
    precondition(crossLine.attributes(at: 1, effectiveRange: nil).isEmpty)
    precondition(crossLine.attribute(.accessibilityForegroundColor, at: 0, effectiveRange: nil) as! CGColor
      != crossLine.attribute(.accessibilityForegroundColor, at: 2, effectiveRange: nil) as! CGColor)
    precondition(striped.styleRange(for: -1).location == NSNotFound)
    precondition(striped.styleRange(for: striped.length).location == NSNotFound)
    precondition(striped.attributedString(in: NSRange(location: striped.length, length: 0), fontSize: 14, parent: parent)?.length == 0)
    feed("\u{1b}]8;;\u{1b}\\\u{1b}[0m\r\nplain\r\nmore\r\nlast\r\n")
    _ = try check()
    _ = try check(scroll: 2)
    terminal_view_scroll(core, 2)
    let anchored = SnapshotBridge.readView(core, now: 0).snapshot!
    precondition(!anchored.following_tail && anchored.scroll_offset == 2)
    feed("\r\nnew\r\noutput")
    let retained = SnapshotBridge.readView(core, now: 0).snapshot!
    precondition(retained.rows == anchored.rows && retained.scroll_offset == 4)
    terminal_view_follow_tail(core)
    precondition(SnapshotBridge.readView(core, now: 0).snapshot!.following_tail)
    feed("\u{1b}]2;Bridge title\u{7}\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?1006h")
    feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=1,C=1;AQID\u{1b}\\")
    let image = try check()
    precondition(image.images.count == 1 && image.title == "Bridge title")
    feed("\u{1b}[?1049hAlternate")
    let alternate = try check()
    precondition(alternate.alternate)
    feed("\u{1b}[?2026hhidden")
    precondition(SnapshotBridge.read(core, scroll: 0, now: 0).snapshot == nil)
    feed("\u{1b}[?2026l\u{1b}[?1049l")
    _ = try check()
    feed("\u{1b}[2J\u{1b}[H1234567猫")
    let wrapped = try check()
    precondition(wrapped.rows[0].cells[7].kind == "WrapSpacer")
    precondition(wrapped.rows[1].cells[1].kind == "Continuation")
    feed("\u{1b}[2J\u{1b}[1;6H")
    let blank = try check()
    let caretProjection = AccessibilityProjection(snapshot: blank)
    precondition(caretProjection.text.hasPrefix("     \n"))
    let caretRange = caretProjection.textRange(gridStart: 5, gridEnd: 5)
    precondition(caretRange == NSRange(location: 5, length: 0))
    precondition(caretProjection.spans(for: caretRange).first?.column == 5)
    // History is a displayed viewport: the live cursor must not manufacture
    // padding in an unrelated historical row. The projection owns that rule.
    let historyCore = terminal_create(8, 3)!
    let historyInput = Data("\r\n\r\n\r\n\u{1b}[1;6H".utf8)
    historyInput.withUnsafeBytes {
      _ = terminal_feed(historyCore, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count, 0)
    }
    terminal_view_scroll(historyCore, 1)
    let historyView = SnapshotBridge.readView(historyCore, now: 0).snapshot!
    precondition(!historyView.following_tail)
    precondition(AccessibilityProjection(snapshot: historyView).text == "\n\n")
    // Legacy numeric offsets and the binary bridge must select the same
    // explicit viewport; this is deliberately distinct from the owner view.
    for scroll in [0, 1, Int.max] {
      let raw = terminal_snapshot(historyCore, scroll, 0)!
      let legacy = try JSONDecoder().decode(
        TerminalSnapshot.self, from: Data(bytes: raw, count: strlen(raw)))
      terminal_string_free(raw)
      let binary = SnapshotBridge.read(historyCore, scroll: scroll, now: 0).snapshot!
      precondition(binary.rows == legacy.rows && binary.cursor == legacy.cursor)
      precondition(binary.scroll_offset == legacy.scroll_offset && binary.following_tail == legacy.following_tail)
      precondition(binary.history_rows == legacy.history_rows && binary.revision == legacy.revision)
    }
    terminal_destroy(historyCore)
    feed("\u{1b}c")
    precondition(terminal_resize(core, 1, 3))
    feed("猫")
    let clipped = try check()
    precondition(clipped.rows[0].cells[0].flags & 1 != 0)
    terminal_destroy(core)
    // Owned Swift values must survive mutation, screen changes, and actor destruction.
    precondition(styled.rows[0].cells[0] == first && image.images.count == 1)
    print(
      "PASS binary snapshot bridge: exact legacy equivalence, colors/styles/links, Unicode, scroll, images, sync gate, owned lifetimes"
    )
  }
}

import Foundation

@main struct SnapshotBridgeTests {
  static func main() throws {
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
    feed("\u{1b}[1;2;3;4:3;5;7;8;9;53;38;2;12;34;56;48;5;196;58;2;90;80;70m")
    feed("\u{1b}]8;;https://example.test/a\u{1b}\\A👩🏽‍💻é猫")
    let styled = try check()
    let first = styled.rows[0].cells[0]
    precondition(first.style.foreground.rgb == [12, 34, 56])
    precondition(first.style.background.index == 196)
    precondition(first.style.underline_color.rgb == [90, 80, 70])
    precondition(first.style.bold && first.style.faint && first.style.italic)
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
    precondition(AccessibilityProjection(snapshot: blank, includeCursor: false).text == "\n\n")
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

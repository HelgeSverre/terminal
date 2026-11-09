import AppKit

@MainActor private final class LinkOwner: NSView {
  var projection: AccessibilityProjection
  init(_ projection: AccessibilityProjection) {
    self.projection = projection
    super.init(frame: .zero)
    setAccessibilityElement(true)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    projection.attributedString(in: range, fontSize: 14, parent: self)
  }
}

@main @MainActor enum VisibleLinkProjectionTests {
  private static let plainStyle = CellStyle(
    foreground: TerminalColor(packed: 0), background: TerminalColor(packed: 0),
    underline_color: TerminalColor(packed: 0), underline: 0, bold: false, faint: false,
    italic: false, inverse: false, conceal: false, strike: false, overline: false, blink: false)

  private static func cell(_ text: String, _ kind: String = "Lead1", link: String? = nil) -> CellSnapshot {
    CellSnapshot(text: text, kind: kind, style: plainStyle, link: link, flags: 0)
  }

  private static func row(_ cells: [CellSnapshot], columns: Int, soft: Bool = false) -> RowSnapshot {
    RowSnapshot(cells: cells + Array(repeating: cell("", "Empty"), count: max(0, columns - cells.count)), soft_wrapped: soft)
  }

  private static func snapshot(_ rows: [RowSnapshot], columns: Int, revision: UInt64 = 1) -> TerminalSnapshot {
    TerminalSnapshot(
      at_prompt: false, input_ready: nil, search: [], images: [], revision: revision,
      geometry_epoch: 1, document_epoch: revision, history_epoch: 1, screen_epoch: revision,
      scroll_offset: 0, following_tail: true, viewport_clamp_revision: 1, cols: columns,
      rows: rows, cursor: CursorSnapshot(row: 0, col: 0, pending_wrap: false, visible: true, shape: 0),
      modes: ModesSnapshot(application_cursor: false, bracketed_paste: false, focus: false,
                           mouse: 0, sgr_mouse: false, reverse_video: false, newline: false),
      alternate: false, title: "", cwd: nil, history_rows: 0,
      palette: Array(repeating: [0, 0, 0], count: 256), default_fg: [230, 230, 230],
      default_bg: [10, 10, 11])
  }

  private static func cells(_ text: String, link: String? = nil) -> [CellSnapshot] {
    text.map { cell(String($0), link: link) }
  }

  private static func plainURLCrossesSoftWrapAndKeepsCellMapping() {
    let columns = 8
    let value = snapshot([
      row(cells("http://l"), columns: columns, soft: true),
      row(cells("ocalhost"), columns: columns, soft: true),
      row(cells(":3000/a_"), columns: columns, soft: true),
      row(cells("(b)). ok"), columns: columns),
    ], columns: columns)
    let projection = VisibleLinkProjection(snapshot: value)
    guard let link = projection.occurrence(atGrid: 0) else { fatalError("plain URL was not detected") }
    precondition(link.target.absoluteString == "http://localhost:3000/a_(b)")
    precondition(link.label == "http://localhost:3000/a_(b)")
    precondition(link.gridSegments == [0..<27])
    precondition(projection.occurrence(atGrid: 26) == link)
    precondition(projection.occurrence(atGrid: 27) == nil)
  }

  private static func unicodeAndHardBreakBoundaries() {
    let columns = 10
    let emoji = [cell("👩🏽‍💻", "Lead2"), cell("", "Continuation")]
    let value = snapshot([
      row(emoji + cells("https://"), columns: columns),
      row(cells("example.te"), columns: columns),
      row(cells("st"), columns: columns),
    ], columns: columns)
    let projection = VisibleLinkProjection(snapshot: value)
    // A hard physical row is a detector barrier, even though the preceding
    // emoji is one multi-scalar, two-cell grapheme.
    precondition(projection.occurrences.isEmpty)

    let wrapped = snapshot([
      row(emoji + cells("https://"), columns: columns, soft: true),
      row(cells("example.te"), columns: columns, soft: true),
      row(cells("st"), columns: columns),
    ], columns: columns)
    let link = VisibleLinkProjection(snapshot: wrapped).occurrence(atGrid: 2)!
    precondition(link.label == "https://example.test")
    precondition(link.gridSegments == [2..<22])
  }

  private static func osc8WinsAndInvalidOSC8BlocksFallback() {
    let columns = 24
    let explicit = cells("https://shown.test", link: "https://target.test/real")
    let invalid = cells("https://blocked.test", link: "javascript:alert(1)")
    let plain = cells("https://plain.test")
    let value = snapshot([
      row(explicit, columns: columns),
      row(invalid, columns: columns),
      row(plain, columns: columns),
    ], columns: columns)
    let links = VisibleLinkProjection(snapshot: value).occurrences
    precondition(links.count == 2)
    precondition(links[0].target.absoluteString == "https://target.test/real")
    precondition(links[0].label == "https://shown.test")
    precondition(links[1].target.absoluteString == "https://plain.test")
    precondition(!links.contains { $0.label.contains("blocked") })
  }

  private static func policyRejectsUnsafeOrAmbiguousTargets() {
    precondition(VisibleLinkProjection.openableURL(for: "HTTPS://localhost:5173/") != nil)
    precondition(VisibleLinkProjection.openableURL(for: "mailto:dev@example.test") != nil)
    let unicode = "https://localhost:5173/猫👩🏽‍💻"
    precondition(VisibleLinkProjection.openableURL(for: unicode) != nil)
    let unicodeProjection = VisibleLinkProjection(snapshot: snapshot([
      row(cells(unicode), columns: unicode.count),
    ], columns: unicode.count))
    precondition(unicodeProjection.occurrences.count == 1 && unicodeProjection.occurrences[0].label == unicode)
    let prose = "<https://localhost:5173/a> \"http://a\""
    let proseLinks = VisibleLinkProjection(snapshot: snapshot([
      row(cells(prose), columns: prose.count),
    ], columns: prose.count)).occurrences
    precondition(proseLinks.map(\.label) == ["https://localhost:5173/a", "http://a"])
    for unsafe in ["www.example.test", "file:///tmp/x", "javascript:alert(1)", "https:", "https://exa mple.test"] {
      precondition(VisibleLinkProjection.openableURL(for: unsafe) == nil, unsafe)
    }
    let invalid = snapshot([row(cells("http://x"), columns: 8)], columns: 0)
    precondition(VisibleLinkProjection(snapshot: invalid).occurrences.isEmpty)
  }

  private static func capsDenseCandidatesWithoutDroppingValidEarlyLinks() {
    let columns = 20
    let dense = row(cells("http://a http://b"), columns: columns)
    let value = snapshot(Array(repeating: dense, count: 4_096), columns: columns)
    let projection = VisibleLinkProjection(snapshot: value)
    precondition(projection.occurrences.count == 4_096)
    precondition(projection.occurrence(atGrid: 0)?.target.absoluteString == "http://a")
    precondition(projection.occurrence(atGrid: columns * 4_095 + 9) == nil)
  }

  private static func maximumGeometryStreamingDiagnostic() {
    // 256 × 4096 is the publication maximum.  Every row is soft-wrapped so
    // this catches a regression to accumulating a whole logical line.  The
    // same immutable blank-cell storage is shared by fixture rows; timing is
    // only the projection, not fixture construction.
    let columns = 256
    let rowCount = 4_096
    let blanks = Array(repeating: cell("", "Empty"), count: columns)
    var rows = Array(repeating: RowSnapshot(cells: blanks, soft_wrapped: true), count: rowCount)
    let finalURL = cells("http://bottom.test")
      + Array(repeating: cell("", "Empty"), count: columns - "http://bottom.test".count)
    rows[rowCount - 1] = RowSnapshot(cells: finalURL, soft_wrapped: false)
    let value = snapshot(rows, columns: columns)
    let started = ProcessInfo.processInfo.systemUptime
    let projection = VisibleLinkProjection(snapshot: value)
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    let finalStart = columns * (rowCount - 1)
    precondition(projection.occurrences.count == 1)
    precondition(projection.occurrence(atGrid: finalStart)?.target.absoluteString == "http://bottom.test")
    precondition(projection.occurrence(atGrid: columns * rowCount - 1) == nil)
    // The only grid-proportional storage in the projection is its compact
    // Int32 index; unresolved plain/OSC tokens are capped at 8 KiB.
    let latency = String(format: "%.2f", elapsedMilliseconds)
    print("INFO visible-links max-grid cells=1048576 index-bytes=4194304 candidate-max-utf16=8192 elapsed-ms=\(latency)")
  }

  private static func nonDelimitedMaximumGeometryStaysLinear() {
    // There is no whitespace in the first 1m cells. The final slash creates a
    // real URL boundary, so this catches both a quadratic carry scan and
    // incorrectly discarding a valid URL after an overlong non-URL prefix.
    let columns = 256
    let rowCount = 4_096
    let xs = Array(repeating: cell("x"), count: columns)
    var rows = Array(repeating: RowSnapshot(cells: xs, soft_wrapped: true), count: rowCount)
    let tail = String(repeating: "x", count: 230) + "/http://tail.test"
    rows[rowCount - 1] = row(cells(tail), columns: columns)
    let started = ProcessInfo.processInfo.systemUptime
    let projection = VisibleLinkProjection(snapshot: snapshot(rows, columns: columns))
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    precondition(projection.occurrences.map(\.target.absoluteString) == ["http://tail.test"])

    let oversized = snapshot(Array(repeating: RowSnapshot(cells: xs, soft_wrapped: true), count: 33), columns: columns)
    precondition(VisibleLinkProjection(snapshot: oversized).occurrences.isEmpty)
    let latency = String(format: "%.2f", elapsedMilliseconds)
    print("INFO visible-links non-delimited cells=1048576 elapsed-ms=\(latency)")
  }

  private static func denseAXMappingsStayIndexed() {
    let columns = 20
    let dense = row(cells("http://a http://b"), columns: columns)
    let value = snapshot(Array(repeating: dense, count: 4_096), columns: columns)
    let started = ProcessInfo.processInfo.systemUptime
    let projection = AccessibilityProjection(snapshot: value)
    let buildMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    let owner = LinkOwner(projection)
    let queryStarted = ProcessInfo.processInfo.systemUptime
    let attributed = projection.attributedString(in: NSRange(location: 0, length: 7), fontSize: 14, parent: owner)!
    let children = projection.linkElements(parent: owner)
    let queryMilliseconds = (ProcessInfo.processInfo.systemUptime - queryStarted) * 1_000
    precondition(children.count == 4_096)
    precondition((attributed.attribute(.accessibilityLink, at: 0, effectiveRange: nil) as? AccessibleTerminalLink) === children[0])
    let buildLatency = String(format: "%.2f", buildMilliseconds)
    let queryLatency = String(format: "%.2f", queryMilliseconds)
    print("INFO visible-links dense-ax links=4096 build-ms=\(buildLatency) query-and-children-ms=\(queryLatency)")
  }

  private static func ordinaryGridDiagnostic() {
    let columns = 100
    let value = snapshot(Array(repeating: row(cells("prompt output http://ordinary.test/path and ordinary terminal text"), columns: columns), count: 30), columns: columns)
    let started = ProcessInfo.processInfo.systemUptime
    let projection = VisibleLinkProjection(snapshot: value)
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    precondition(projection.occurrences.count == 30)
    let latency = String(format: "%.2f", elapsedMilliseconds)
    print("INFO visible-links ordinary-grid cells=3000 urls=30 elapsed-ms=\(latency)")
  }

  private static func accessibilityUsesOneLinkAcrossSoftWrapAndRejectsStalePress() {
    let columns = 8
    let first = snapshot([
      row(cells("http://l"), columns: columns, soft: true),
      row(cells("ocalhost"), columns: columns, soft: true),
      row(cells(":3000/x"), columns: columns),
    ], columns: columns, revision: 1)
    let projection = AccessibilityProjection(snapshot: first)
    let owner = LinkOwner(projection)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1, height: 1),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = owner
    defer { window.contentView = nil; window.close() }
    let children = projection.linkElements(parent: owner)
    precondition(children.count == 1)
    // A clipped UTF-16 projection may style a visible prefix, but must not
    // publish it as a tree child that claims to represent the whole link.
    let clipped = AccessibilityProjection(snapshot: first, limit: 5)
    precondition(clipped.linkElements(parent: owner).isEmpty)
    let all = NSRange(location: 0, length: projection.length)
    let attributed = projection.attributedString(in: all, fontSize: 14, parent: owner)!
    let newlines = attributed.string.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset : nil }
    var exported: AccessibleTerminalLink?
    for index in 0..<attributed.length {
      let link = attributed.attribute(.accessibilityLink, at: index, effectiveRange: nil) as? AccessibleTerminalLink
      if newlines.contains(index) { precondition(link == nil) }
      else if link != nil {
        if let exported { precondition(link === exported) }
        else { exported = link }
      }
    }
    guard let old = exported else { fatalError("plain URL missing AXLink") }
    precondition(children[0] === old)
    precondition(old.accessibilityLabel() == "http://localhost:3000/x")
    owner.projection = AccessibilityProjection(snapshot: snapshot([
      row(cells("http://l"), columns: columns, soft: true),
      row(cells("ocalhost"), columns: columns, soft: true),
      row(cells(":3000/x"), columns: columns),
    ], columns: columns, revision: 2))
    // A cached AX object must reject after a new snapshot rather than opening
    // a target at stale grid coordinates.
    precondition(!old.accessibilityPerformPress())
  }

  static func main() {
    _ = NSApplication.shared
    plainURLCrossesSoftWrapAndKeepsCellMapping()
    unicodeAndHardBreakBoundaries()
    osc8WinsAndInvalidOSC8BlocksFallback()
    policyRejectsUnsafeOrAmbiguousTargets()
    capsDenseCandidatesWithoutDroppingValidEarlyLinks()
    maximumGeometryStreamingDiagnostic()
    nonDelimitedMaximumGeometryStaysLinear()
    denseAXMappingsStayIndexed()
    ordinaryGridDiagnostic()
    accessibilityUsesOneLinkAcrossSoftWrapAndRejectsStalePress()
    print("PASS visible links: plain/OSC8 priority, wraps, UTF-16 cells, AX consistency and stale rejection")
  }
}

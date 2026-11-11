import AppKit
import Testing
@testable import TerminalApp

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

@Suite @MainActor enum VisibleLinkProjectionTests {
  private static let plainStyle = CellStyle(
    foreground: TerminalColor(packed: 0), background: TerminalColor(packed: 0),
    underline_color: TerminalColor(packed: 0), underline: 0, bold: false, faint: false,
    italic: false, inverse: false, conceal: false, strike: false, overline: false, blink: false)

  private static func cell(_ text: String, _ kind: String = "Lead1", link: String? = nil) -> CellSnapshot {
    CellSnapshot(text: text, kind: kind, style: plainStyle, link: link, flags: 0)
  }

  private static func row(
    _ cells: [CellSnapshot], columns: Int, soft: Bool = false, id: UInt64 = 0, revision: UInt64 = 0
  ) -> RowSnapshot {
    RowSnapshot(
      cells: cells + Array(repeating: cell("", "Empty"), count: max(0, columns - cells.count)),
      soft_wrapped: soft, id: id, revision: revision)
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

  private static func projectedSnapshot(
    _ rows: [RowSnapshot], columns: Int, revision: UInt64 = 1,
    selection: TerminalSelectionSnapshot = .none
  ) -> TerminalSnapshot {
    var value = snapshot(rows, columns: columns, revision: revision)
    value.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: revision, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: value.geometry_epoch, columns: columns,
      rows: rows.map { .init(id: $0.id, revision: $0.revision, softWrapped: $0.soft_wrapped) })
    value.selection = selection
    return value
  }

  @Test static func plainURLCrossesSoftWrapAndKeepsCellMapping() {
    let columns = 8
    let value = snapshot([
      row(cells("http://l"), columns: columns, soft: true),
      row(cells("ocalhost"), columns: columns, soft: true),
      row(cells(":3000/a_"), columns: columns, soft: true),
      row(cells("(b)). ok"), columns: columns),
    ], columns: columns)
    let projection = VisibleLinkProjection(snapshot: value)
    guard let link = projection.occurrence(atGrid: 0) else { Issue.record("plain URL was not detected"); return }
    #expect(link.target.absoluteString == "http://localhost:3000/a_(b)")
    #expect(link.label == "http://localhost:3000/a_(b)")
    #expect(link.gridSegments == [0..<27])
    #expect(projection.occurrence(atGrid: 26) == link)
    #expect(projection.occurrence(atGrid: 27) == nil)
  }

  @Test static func unicodeAndHardBreakBoundaries() {
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
    #expect(projection.occurrences.isEmpty)

    let wrapped = snapshot([
      row(emoji + cells("https://"), columns: columns, soft: true),
      row(cells("example.te"), columns: columns, soft: true),
      row(cells("st"), columns: columns),
    ], columns: columns)
    let link = VisibleLinkProjection(snapshot: wrapped).occurrence(atGrid: 2)!
    #expect(link.label == "https://example.test")
    #expect(link.gridSegments == [2..<22])
  }

  @Test static func osc8WinsAndInvalidOSC8BlocksFallback() {
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
    #expect(links.count == 2)
    #expect(links[0].target.absoluteString == "https://target.test/real")
    #expect(links[0].label == "https://shown.test")
    #expect(links[1].target.absoluteString == "https://plain.test")
    #expect(!links.contains { $0.label.contains("blocked") })
  }

  @Test static func activationCarriesOnlyValidatedPresentedRows() {
    let target = "https://target.test/"
    let rows = [
      row(cells("abcd", link: target), columns: 4, soft: true, id: 71, revision: 5),
      row(cells("efgh", link: target), columns: 4, id: 72, revision: 6),
    ]
    let value = projectedSnapshot(rows, columns: 4, revision: 19)
    guard let activation = VisibleLinkProjection(snapshot: value).occurrences.first?.activation else {
      Issue.record("presented OSC 8 link lacked activation proof"); return
    }
    #expect(activation.target.absoluteString == target)
    #expect(activation.content.presentation == value.selectionPresentation)
    #expect(activation.content.rows == [
      .init(row: 0, columns: 0..<4), .init(row: 1, columns: 0..<4),
    ])

    // Old persisted metadata can be visible/readable, but never supplies a
    // link activation without current row identity and revision proof.
    let legacy = snapshot(rows, columns: 4)
    #expect(VisibleLinkProjection(snapshot: legacy).occurrences.first?.activation == nil)
    var stale = value
    stale.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: 9, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: value.geometry_epoch, columns: value.cols,
      rows: [.init(id: 71, revision: 4, softWrapped: true),
             .init(id: 72, revision: 6, softWrapped: false)])
    #expect(VisibleLinkProjection(snapshot: stale).occurrences.first?.activation == nil)
  }

  @Test static func policyRejectsUnsafeOrAmbiguousTargets() {
    #expect(VisibleLinkProjection.openableURL(for: "HTTPS://localhost:5173/") != nil)
    #expect(VisibleLinkProjection.openableURL(for: "mailto:dev@example.test") != nil)
    let unicode = "https://localhost:5173/猫👩🏽‍💻"
    #expect(VisibleLinkProjection.openableURL(for: unicode) != nil)
    let unicodeProjection = VisibleLinkProjection(snapshot: snapshot([
      row(cells(unicode), columns: unicode.count),
    ], columns: unicode.count))
    #expect(unicodeProjection.occurrences.count == 1 && unicodeProjection.occurrences[0].label == unicode)
    let prose = "<https://localhost:5173/a> \"http://a\""
    let proseLinks = VisibleLinkProjection(snapshot: snapshot([
      row(cells(prose), columns: prose.count),
    ], columns: prose.count)).occurrences
    #expect(proseLinks.map(\.label) == ["https://localhost:5173/a", "http://a"])
    for unsafe in ["www.example.test", "file:///tmp/x", "javascript:alert(1)", "https:", "https://exa mple.test"] {
      #expect(VisibleLinkProjection.openableURL(for: unsafe) == nil, "\(unsafe)")
    }
    let invalid = snapshot([row(cells("http://x"), columns: 8)], columns: 0)
    #expect(VisibleLinkProjection(snapshot: invalid).occurrences.isEmpty)
  }

  @Test static func capsDenseCandidatesWithoutDroppingValidEarlyLinks() {
    let columns = 20
    let dense = row(cells("http://a http://b"), columns: columns)
    let value = snapshot(Array(repeating: dense, count: 4_096), columns: columns)
    let projection = VisibleLinkProjection(snapshot: value)
    #expect(projection.occurrences.count == 4_096)
    #expect(projection.occurrence(atGrid: 0)?.target.absoluteString == "http://a")
    #expect(projection.occurrence(atGrid: columns * 4_095 + 9) == nil)
  }

  @Test static func maximumGeometryStreamingDiagnostic() {
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
    #expect(projection.occurrences.count == 1)
    #expect(projection.occurrence(atGrid: finalStart)?.target.absoluteString == "http://bottom.test")
    #expect(projection.occurrence(atGrid: columns * rowCount - 1) == nil)
    // The only grid-proportional storage in the projection is its compact
    // Int32 index; unresolved plain/OSC tokens are capped at 8 KiB.
    let latency = String(format: "%.2f", elapsedMilliseconds)
    print("INFO visible-links max-grid cells=1048576 index-bytes=4194304 candidate-max-utf16=8192 elapsed-ms=\(latency)")
  }

  @Test static func nonDelimitedMaximumGeometryStaysLinear() {
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
    #expect(projection.occurrences.map(\.target.absoluteString) == ["http://tail.test"])

    let oversized = snapshot(Array(repeating: RowSnapshot(cells: xs, soft_wrapped: true), count: 33), columns: columns)
    #expect(VisibleLinkProjection(snapshot: oversized).occurrences.isEmpty)
    let latency = String(format: "%.2f", elapsedMilliseconds)
    print("INFO visible-links non-delimited cells=1048576 elapsed-ms=\(latency)")
  }

  @Test static func denseAXMappingsStayIndexed() {
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
    #expect(children.count == 4_096)
    #expect((attributed.attribute(.accessibilityLink, at: 0, effectiveRange: nil) as? AccessibleTerminalLink) === children[0])
    let buildLatency = String(format: "%.2f", buildMilliseconds)
    let queryLatency = String(format: "%.2f", queryMilliseconds)
    print("INFO visible-links dense-ax links=4096 build-ms=\(buildLatency) query-and-children-ms=\(queryLatency)")
  }

  @Test static func ordinaryGridDiagnostic() {
    let columns = 100
    let value = snapshot(Array(repeating: row(cells("prompt output http://ordinary.test/path and ordinary terminal text"), columns: columns), count: 30), columns: columns)
    let started = ProcessInfo.processInfo.systemUptime
    let projection = VisibleLinkProjection(snapshot: value)
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    #expect(projection.occurrences.count == 30)
    let latency = String(format: "%.2f", elapsedMilliseconds)
    print("INFO visible-links ordinary-grid cells=3000 urls=30 elapsed-ms=\(latency)")
  }

  @Test static func accessibilityUsesOneLinkAcrossSoftWrapAndRejectsStalePress() {
    _ = NSApplication.shared
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
    // The window is owned by this scope; AppKit must not also release it on close.
    window.isReleasedWhenClosed = false
    window.contentView = owner
    defer { window.contentView = nil; window.close() }
    let children = projection.linkElements(parent: owner)
    #expect(children.count == 1)
    // A clipped UTF-16 projection may style a visible prefix, but must not
    // publish it as a tree child that claims to represent the whole link.
    let clipped = AccessibilityProjection(snapshot: first, limit: 5)
    #expect(clipped.linkElements(parent: owner).isEmpty)
    let all = NSRange(location: 0, length: projection.length)
    let attributed = projection.attributedString(in: all, fontSize: 14, parent: owner)!
    let newlines = attributed.string.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset : nil }
    var exported: AccessibleTerminalLink?
    for index in 0..<attributed.length {
      let link = attributed.attribute(.accessibilityLink, at: index, effectiveRange: nil) as? AccessibleTerminalLink
      if newlines.contains(index) { #expect(link == nil) }
      else if link != nil {
        if let exported { #expect(link === exported) }
        else { exported = link }
      }
    }
    guard let old = exported else { Issue.record("plain URL missing AXLink"); return }
    #expect(children[0] === old)
    #expect(old.accessibilityLabel() == "http://localhost:3000/x")
    owner.projection = AccessibilityProjection(snapshot: snapshot([
      row(cells("http://l"), columns: columns, soft: true),
      row(cells("ocalhost"), columns: columns, soft: true),
      row(cells(":3000/x"), columns: columns),
    ], columns: columns, revision: 2))
    // A cached AX object must reject after a new snapshot rather than opening
    // a target at stale grid coordinates.
    #expect(!old.accessibilityPerformPress())
  }

  @Test static func accessibilityPressForwardsProjectionActivation() {
    _ = NSApplication.shared
    let value = projectedSnapshot([
      row(cells("https://ax.test"), columns: 16, id: 81, revision: 2),
    ], columns: 16)
    let projection = AccessibilityProjection(snapshot: value)
    let owner = LinkOwner(projection)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1, height: 1),
                          styleMask: .borderless, backing: .buffered, defer: false)
    // The window is owned by this scope; AppKit must not also release it on close.
    window.isReleasedWhenClosed = false
    window.contentView = owner
    defer { window.contentView = nil; window.close() }
    var received: VisibleLinkProjection.Activation?
    guard let link = projection.linkElements(parent: owner, activate: { activation in
      received = activation
      return true
    }).first else { Issue.record("presented AX link missing"); return }
    #expect(link.accessibilityPerformPress())
    #expect(received?.target.absoluteString == "https://ax.test")
    #expect(received?.content.rows == [.init(row: 0, columns: 0..<15)])
  }

  @Test static func selectionProjectionPreservesClustersAndDisjointCells() {
    let wide = TerminalSelectionSnapshot(
      revision: 1, phase: .committed, mode: .linear,
      segments: [.init(row: 0, start: 1, end: 2)])
    let wideAndCombining = projectedSnapshot([
      row([
        cell("a"), cell("界", "Lead2"), cell("", "Continuation"), cell("e\u{301}"),
      ], columns: 4, id: 11, revision: 4),
    ], columns: 4, selection: wide)
    let projection = AccessibilityProjection(snapshot: wideAndCombining)
    // A half-wide-cell segment is rounded to the single complete AX grapheme.
    #expect(projection.selectedRanges() == [NSRange(location: 1, length: 1)])
    #expect(projection.selectedText() == "界")
    guard let wideHit = projection.presentedRange(for: [NSRange(location: 1, length: 1)]) else {
      Issue.record("wide AX range did not produce owner hit"); return
    }
    #expect(wideHit.start.row == 0 && wideHit.start.boundary == 1 && wideHit.start.affinity == .before)
    #expect(wideHit.end.row == 0 && wideHit.end.boundary == 3 && wideHit.end.affinity == .after)

    let combining = TerminalSelectionSnapshot(
      revision: 2, phase: .committed, mode: .linear,
      segments: [.init(row: 0, start: 3, end: 4)])
    let combiningSnapshot = projectedSnapshot([
      row([
        cell("a"), cell("界", "Lead2"), cell("", "Continuation"), cell("e\u{301}"),
      ], columns: 4, id: 11, revision: 4),
    ], columns: 4, selection: combining)
    let combiningProjection = AccessibilityProjection(snapshot: combiningSnapshot)
    #expect(combiningProjection.selectedText() == "e\u{301}")
    // UTF-16 interior positions cannot split a composed cell into terminal hits.
    #expect(combiningProjection.presentedRange(for: [NSRange(location: 3, length: 1)]) == nil)

    let rectangles = projectedSnapshot([
      row(cells("abcd"), columns: 4, id: 21, revision: 3),
      row(cells("ABCD"), columns: 4, id: 22, revision: 3),
    ], columns: 4, selection: TerminalSelectionSnapshot(
      revision: 3, phase: .committed, mode: .rectangular,
      // Deliberately unsorted: projection normalizes snapshot segment order.
      segments: [.init(row: 1, start: 3, end: 4), .init(row: 0, start: 3, end: 4),
                 .init(row: 1, start: 0, end: 1), .init(row: 0, start: 0, end: 1)]))
    let rectangularProjection = AccessibilityProjection(snapshot: rectangles)
    let ranges = rectangularProjection.selectedRanges()
    #expect(ranges == [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1),
                            NSRange(location: 5, length: 1), NSRange(location: 8, length: 1)])
    #expect(rectangularProjection.selectedText() == "adAD")
    #expect(AccessibilityProjection(snapshot: projectedSnapshot([
      row(cells("abcd"), columns: 4, id: 21, revision: 3),
    ], columns: 4)).selectedRanges().isEmpty)
    guard let rectangle = rectangularProjection.presentedRange(
      for: [NSRange(location: 5, length: 1), NSRange(location: 0, length: 1)]
    ) else { Issue.record("physical AX rectangle did not produce owner hits"); return }
    #expect(rectangle.mode == .rectangular && rectangle.start.row == 0 && rectangle.start.boundary == 0)
    #expect(rectangle.end.row == 1 && rectangle.end.boundary == 1)
    // Two legitimate but unequal row ranges are not a rectangle and must not
    // be widened into a selection containing omitted cells.
    #expect(rectangularProjection.presentedRange(
      for: [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)]
    ) == nil)
  }

  @Test static func linearSelectionIncludesPhysicalBreaksAndBlankRows() {
    func linear(_ segments: [TerminalSelectionSnapshot.Segment]) -> TerminalSelectionSnapshot {
      TerminalSelectionSnapshot(revision: 8, phase: .committed, mode: .linear, segments: segments)
    }
    func selectedText(_ rows: [RowSnapshot], _ segments: [TerminalSelectionSnapshot.Segment]) -> (String?, [NSRange]) {
      let value = projectedSnapshot(rows, columns: 4, selection: linear(segments))
      let projection = AccessibilityProjection(snapshot: value)
      return (projection.selectedText(), projection.selectedRanges())
    }

    let ordinary = selectedText([
      row(cells("abcd"), columns: 4, id: 41, revision: 1),
      row(cells("wxyz"), columns: 4, id: 42, revision: 1),
    ], [.init(row: 0, start: 1, end: 4), .init(row: 1, start: 0, end: 3)])
    #expect(ordinary.0 == "bcd\nwxy")
    #expect(ordinary.1 == [NSRange(location: 1, length: 7)])

    let interior = selectedText([
      row(cells("abcd"), columns: 4, id: 43, revision: 1),
      row([], columns: 4, id: 44, revision: 1),
      row(cells("wxyz"), columns: 4, id: 45, revision: 1),
    ], [.init(row: 0, start: 2, end: 4), .init(row: 1, start: 0, end: 4),
        .init(row: 2, start: 0, end: 2)])
    #expect(interior.0 == "cd\n\nwx")
    #expect(interior.1 == [NSRange(location: 2, length: 6)])

    let leading = selectedText([
      row([], columns: 4, id: 46, revision: 1),
      row(cells("abcd"), columns: 4, id: 47, revision: 1),
    ], [.init(row: 0, start: 0, end: 4), .init(row: 1, start: 0, end: 2)])
    #expect(leading.0 == "\nab")
    #expect(leading.1 == [NSRange(location: 0, length: 3)])

    let trailing = selectedText([
      row(cells("abcd"), columns: 4, id: 48, revision: 1),
      row([], columns: 4, id: 49, revision: 1),
      row([], columns: 4, id: 50, revision: 1),
    ], [.init(row: 0, start: 2, end: 4), .init(row: 1, start: 0, end: 4),
        .init(row: 2, start: 0, end: 4)])
    #expect(trailing.0 == "cd\n\n")
    #expect(trailing.1 == [NSRange(location: 2, length: 4)])

    let allBlank = selectedText([
      row([], columns: 4, id: 51, revision: 1),
      row([], columns: 4, id: 52, revision: 1),
      row([], columns: 4, id: 53, revision: 1),
    ], [.init(row: 0, start: 0, end: 4), .init(row: 1, start: 0, end: 4),
        .init(row: 2, start: 0, end: 4)])
    #expect(allBlank.0 == "\n\n")
    #expect(allBlank.1 == [NSRange(location: 0, length: 2)])

    let softWrapped = selectedText([
      row(cells("abcd"), columns: 4, soft: true, id: 54, revision: 1),
      row(cells("wxyz"), columns: 4, id: 55, revision: 1),
    ], [.init(row: 0, start: 1, end: 4), .init(row: 1, start: 0, end: 2)])
    // AX text is a physical-row projection, so a soft wrap remains a newline
    // here even though terminal clipboard serialization joins it.
    #expect(softWrapped.0 == "bcd\nwx")
    #expect(softWrapped.1 == [NSRange(location: 1, length: 6)])

    let clippedValue = projectedSnapshot([
      row(cells("abcd"), columns: 4, id: 56, revision: 1),
      row(cells("wxyz"), columns: 4, id: 57, revision: 1),
      row(cells("QRST"), columns: 4, id: 58, revision: 1),
    ], columns: 4, selection: linear([
      .init(row: 0, start: 1, end: 4), .init(row: 1, start: 0, end: 4),
      .init(row: 2, start: 0, end: 2),
    ]))
    let clipped = AccessibilityProjection(snapshot: clippedValue, limit: 5)
    #expect(clipped.truncated)
    // The last selected row is outside the bounded projection. Its visible
    // prefix still remains a single linear AX range, including row zero's
    // physical break, rather than degrading to disjoint selected cells.
    #expect(clipped.selectedText() == "bcd\n")
    #expect(clipped.selectedRanges() == [NSRange(location: 1, length: 4)])

    let boundaryRows = [
      row(cells("abcd"), columns: 4, id: 59, revision: 1),
      row(cells("wxyz"), columns: 4, id: 60, revision: 1),
    ]
    let setterSnapshot = projectedSnapshot(boundaryRows, columns: 4)
    let setterProjection = AccessibilityProjection(snapshot: setterSnapshot)
    guard let setter = setterProjection.presentedRange(for: [NSRange(location: 0, length: 5)]) else {
      Issue.record("physical first-line AX range did not produce owner hits"); return
    }
    #expect(setter.mode == .linear && setter.start.row == 0 && setter.start.boundary == 0)
    #expect(setter.end.row == 1 && setter.end.boundary == 0)

    let boundary = AccessibilityProjection(snapshot: projectedSnapshot(
      boundaryRows, columns: 4, selection: linear([
        .init(row: 0, start: 0, end: 4), .init(row: 1, start: 0, end: 0),
      ])))
    #expect(boundary.selectedText() == "abcd\n")
    #expect(boundary.selectedRanges() == [NSRange(location: 0, length: 5)])

    let newlineOnly = AccessibilityProjection(snapshot: projectedSnapshot(
      boundaryRows, columns: 4, selection: linear([
        .init(row: 0, start: 4, end: 4), .init(row: 1, start: 0, end: 0),
      ])))
    #expect(newlineOnly.selectedText() == "\n")
    #expect(newlineOnly.selectedRanges() == [NSRange(location: 4, length: 1)])

    let emptyFirstRows = [
      row([], columns: 4, id: 61, revision: 1),
      row(cells("abcd"), columns: 4, id: 62, revision: 1),
    ]
    let emptyFirstSetter = AccessibilityProjection(snapshot: projectedSnapshot(emptyFirstRows, columns: 4))
    guard let emptyFirst = emptyFirstSetter.presentedRange(for: [NSRange(location: 0, length: 1)]) else {
      Issue.record("empty first-row newline did not produce owner hits"); return
    }
    #expect(emptyFirst.mode == .linear && emptyFirst.start.row == 0 && emptyFirst.start.boundary == 4)
    #expect(emptyFirst.end.row == 1 && emptyFirst.end.boundary == 0)

    let allBlankRows = [
      row([], columns: 4, id: 63, revision: 1),
      row([], columns: 4, id: 64, revision: 1),
      row([], columns: 4, id: 65, revision: 1),
    ]
    let allBlankSetter = AccessibilityProjection(snapshot: projectedSnapshot(allBlankRows, columns: 4))
    guard let allBlank = allBlankSetter.presentedRange(for: [NSRange(location: 0, length: 2)]) else {
      Issue.record("all-blank physical newlines did not produce owner hits"); return
    }
    #expect(allBlank.mode == .linear && allBlank.start.row == 0 && allBlank.start.boundary == 4)
    #expect(allBlank.end.row == 2 && allBlank.end.boundary == 0)

    let soleZero = AccessibilityProjection(snapshot: projectedSnapshot(
      boundaryRows, columns: 4, selection: linear([.init(row: 0, start: 2, end: 2)])))
    #expect(soleZero.selectedRanges().isEmpty && soleZero.selectedText() == nil)
    let rectangleZero = AccessibilityProjection(snapshot: projectedSnapshot(
      boundaryRows, columns: 4, selection: TerminalSelectionSnapshot(
        revision: 9, phase: .committed, mode: .rectangular,
        segments: [.init(row: 0, start: 4, end: 4), .init(row: 1, start: 0, end: 0)])))
    #expect(rectangleZero.selectedRanges().isEmpty && rectangleZero.selectedText() == nil)
  }

  @Test static func selectionSetterRejectsClippingAndStalePresentation() {
    let rows = [row(cells("abcdef"), columns: 6, id: 31, revision: 9)]
    let current = projectedSnapshot(rows, columns: 6, revision: 7)
    let clipped = AccessibilityProjection(snapshot: current, limit: 4)
    #expect(clipped.truncated)
    #expect(clipped.presentedRange(for: [NSRange(location: 0, length: 3)]) != nil)
    // Reaching clipped output would let the host silently claim an unseen
    // terminal endpoint, so only the complete prefix above is accepted.
    #expect(clipped.presentedRange(for: [NSRange(location: 0, length: 4)]) == nil)

    let visible = AccessibilityProjection(snapshot: current)
    #expect(visible.presentedRange(for: []) == nil)
    #expect(visible.presentedRange(for: [NSRange(location: 0, length: 0)]) == nil)

    var independentSelectionRevision = projectedSnapshot(rows, columns: 6, revision: 191)
    independentSelectionRevision.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: 4, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: independentSelectionRevision.geometry_epoch, columns: independentSelectionRevision.cols,
      rows: rows.map { .init(id: $0.id, revision: $0.revision, softWrapped: $0.soft_wrapped) })
    #expect(AccessibilityProjection(snapshot: independentSelectionRevision).presentedRange(
      for: [NSRange(location: 0, length: 1)]) != nil)

    var missingPresentationID = current
    missingPresentationID.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: 0, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: current.geometry_epoch, columns: current.cols,
      rows: rows.map { .init(id: $0.id, revision: $0.revision, softWrapped: $0.soft_wrapped) })
    #expect(AccessibilityProjection(snapshot: missingPresentationID).presentedRange(
      for: [NSRange(location: 0, length: 1)]) == nil)

    var missingIdentity = current
    missingIdentity.selectionPresentation = nil
    #expect(AccessibilityProjection(snapshot: missingIdentity).presentedRange(for: [NSRange(location: 0, length: 1)]) == nil)

    var staleID = current
    staleID.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: current.revision, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: current.geometry_epoch, columns: current.cols,
      rows: [.init(id: 999, revision: 9, softWrapped: false)])
    #expect(AccessibilityProjection(snapshot: staleID).presentedRange(for: [NSRange(location: 0, length: 1)]) == nil)

    var staleWrap = current
    staleWrap.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: current.revision, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: current.geometry_epoch, columns: current.cols,
      rows: [.init(id: 31, revision: 9, softWrapped: true)])
    #expect(AccessibilityProjection(snapshot: staleWrap).presentedRange(for: [NSRange(location: 0, length: 1)]) == nil)

    var staleRevision = current
    staleRevision.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: 4, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: current.geometry_epoch, columns: current.cols,
      rows: [.init(id: 31, revision: 8, softWrapped: false)])
    #expect(AccessibilityProjection(snapshot: staleRevision).presentedRange(for: [NSRange(location: 0, length: 1)]) == nil)
  }

  @Test static func delimiterPolicyMatchesUnicodeReference() {
    // Independent spelling of the established public policy. This deliberately
    // uses Foundation classification even for ASCII to guard the fast path.
    func reference(_ text: String) -> URL? {
      guard !text.isEmpty, text.utf8.count <= 8192,
        !text.unicodeScalars.contains(where: {
          $0.properties.generalCategory == .control || CharacterSet.whitespacesAndNewlines.contains($0)
        }), let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
        let url = parts.url else { return nil }
      switch scheme {
      case "http", "https": guard parts.host?.isEmpty == false else { return nil }
      case "mailto": guard !parts.path.isEmpty else { return nil }
      default: return nil
      }
      return url
    }
    var scalars = (0..<128).map { Unicode.Scalar($0)! }
    scalars += [0x80, 0x85, 0x9f, 0xa0, 0x1680, 0x2000, 0x2007, 0x200b,
                0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff].map { Unicode.Scalar($0)! }
    var seed: UInt64 = 0x417fe9
    for _ in 0..<1024 {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      if let scalar = Unicode.Scalar(UInt32((seed >> 32) % 0x110000)) { scalars.append(scalar) }
    }
    for scalar in scalars {
      for text in ["https://example.test/\(scalar)tail", "mailto:a\(scalar)@example.test", "\(scalar)https://example.test"] {
        #expect(VisibleLinkProjection.openableURL(for: text) == reference(text), "URL delimiter policy changed for U+\(String(scalar.value, radix: 16))")
      }
    }
    // Punctuation is a plain-token boundary, but remains governed separately
    // by URLComponents inside explicit OSC 8 targets.
    for delimiter in ["\u{0}", "\t", "\n", " ", "\u{7f}", "\u{85}", "\u{a0}", "\u{2028}", "\u{3000}", "\"", "'", "<", ">"] {
      let parts = cells("https://a.test/" + delimiter + "https://b.test/")
      let value = snapshot([row(parts, columns: parts.count)], columns: parts.count)
      let result = VisibleLinkProjection(snapshot: value)
      #expect(result.occurrences.map { $0.target.absoluteString } == ["https://a.test/", "https://b.test/"])
    }
  }
}

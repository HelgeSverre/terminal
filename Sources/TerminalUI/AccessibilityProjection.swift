import AppKit
import TerminalEngine
import TerminalHost

package typealias TerminalLinkActivationHandler = @MainActor (VisibleLinkProjection.Activation) -> Bool

/// A bounded UTF-16 projection of the displayed immutable grid. No terminal-owner or GPU calls.
package struct AccessibilityProjection {
  private struct StyledRange {
    package var range: NSRange
    package let style: CellStyle?
  }
  package struct Span {
    package let range: NSRange
    package let row: Int
    package let column: Int
    package let cells: Int
    package let gridStart: Int
    package let gridEnd: Int
  }
  package let text: String
  package let lines: [NSRange]
  package let spans: [Span]
  package let columns: Int
  package let gridCount: Int
  package let truncated: Bool
  private let palette: CellPalette
  private let styles: [StyledRange]
  private let characters: NSString
  private let cachedSelectedRanges: [NSRange]
  /// Proof captured from the exact snapshot that produced this text. Keeping
  /// it here prevents a caller from combining one projection with a newer or
  /// legacy snapshot when submitting an AX setter range.
  private let selectionPresentation: TerminalSelectionPresentation?
  private let visibleLinks: VisibleLinkProjection
  private struct LinkMapping {
    package let occurrence: VisibleLinkProjection.Occurrence
    package let ranges: [NSRange]
    package let fullyProjected: Bool
  }
  /// Ordered once at construction, so AX queries do not rescan every span for
  /// every visible URL.
  private let linkMappings: [LinkMapping]
  private let links = Links()
  package var length: Int { characters.length }
  package init(snapshot: TerminalSnapshot, limit: Int = 262_144) {
    columns = snapshot.cols
    gridCount = snapshot.cols * snapshot.rows.count
    selectionPresentation = Self.validSelectionPresentation(in: snapshot)
    palette = CellPalette(snapshot: snapshot)
    let projection = VisibleLinkProjection(snapshot: snapshot)
    visibleLinks = projection
    var output = ""
    var offsets: [NSRange] = []
    var mapping: [Span] = []
    var styling: [StyledRange] = []
    func style(_ range: NSRange, _ value: CellStyle?) {
      guard range.length > 0 else { return }
      if let last = styling.last, NSMaxRange(last.range) == range.location,
        last.style == value {
        styling[styling.count - 1].range.length += range.length
      } else {
        styling.append(StyledRange(range: range, style: value))
      }
    }
    var count = 0
    var clipped = false
    for (row, value) in snapshot.rows.enumerated() {
      let start = count
      var end =
        value.cells.lastIndex { $0.kind != "Empty" && $0.kind != "WrapSpacer" }.map { $0 + 1 } ?? 0
      if snapshot.following_tail && row == snapshot.cursor.row {
        end = max(end, min(value.cells.count, snapshot.cursor.col))
      }
      for column in 0..<end {
        let cell = value.cells[column]
        if cell.kind == "Continuation" || cell.kind == "WrapSpacer" { continue }
        let string = cell.kind == "Empty" ? " " : cell.text
        let size = string.utf16.count
        if count + size > max(0, limit) {
          clipped = true
          break
        }
        let width = cell.kind == "Lead2" ? 2 : 1
        mapping.append(
          Span(
            range: NSRange(location: count, length: size), row: row, column: column,
            cells: width, gridStart: row * columns + column,
            gridEnd: row * columns + column + width))
        output.append(string)
        style(NSRange(location: count, length: size), cell.style)
        count += size
      }
      if !clipped && row + 1 < snapshot.rows.count {
        if count < max(0, limit) {
          mapping.append(
            Span(
              range: NSRange(location: count, length: 1), row: row, column: end,
              cells: 0, gridStart: row * columns + end, gridEnd: (row + 1) * columns))
          output.append("\n")
          style(NSRange(location: count, length: 1), nil)
          count += 1
        } else {
          clipped = true
        }
      }
      offsets.append(NSRange(location: start, length: count - start))
      if clipped { break }
    }
    text = output
    characters = output as NSString
    lines = offsets
    spans = mapping
    truncated = clipped
    styles = styling
    cachedSelectedRanges = Self.selectedRanges(
      for: snapshot.selection, columns: snapshot.cols,
      gridCount: snapshot.cols * snapshot.rows.count, spans: mapping, lines: offsets, length: count)
    linkMappings = projection.occurrences.compactMap { occurrence in
      let item = Self.linkMapping(for: occurrence, spans: mapping)
      return item.ranges.isEmpty ? nil : item
    }
  }
  package func valid(_ range: NSRange) -> Bool {
    range.location != NSNotFound && range.location >= 0 && range.length >= 0
      && range.location <= length && range.length <= length - range.location
  }
  package func string(in range: NSRange) -> String? {
    guard valid(range) else { return nil }
    return characters.substring(with: range)
  }

  /// The UTF-16 ranges corresponding to the concrete selected grid cells.
  ///
  /// A rectangular selection can have holes in an AX line.  Keep those holes
  /// as separate ranges instead of taking their enclosing union: AX selected
  /// text must never imply that an unselected cell was selected.  The core
  /// owns capture/validation; this is only the bounded, displayed projection.
  package func selectedRanges() -> [NSRange] {
    cachedSelectedRanges
  }
  private static func selectedRanges(
    for selection: TerminalSelectionSnapshot, columns: Int, gridCount: Int, spans: [Span], lines: [NSRange],
    length: Int
  ) -> [NSRange] {
    guard selection.phase != .none, columns > 0 else { return [] }
    let rowCount = gridCount / columns
    let segments = normalizedSegments(
      selection.segments, mode: selection.mode, columns: columns, rowCount: rowCount)
    guard !segments.isEmpty else { return [] }

    // Linear terminal selection is continuous through physical rows. The AX
    // projection represents those rows with newline spans, including blank
    // ones, so expose one equally continuous UTF-16 range. Rectangles keep
    // their individual cells/ranges below and therefore retain their gaps.
    if selection.mode == .linear, segments.count > 1,
      segments.enumerated().allSatisfy({ item in
        item.element.row == segments[0].row + item.offset
      }),
      let first = segments.first, let last = segments.last,
      let start = textOffset(row: first.row, boundary: first.start, start: true,
                             columns: columns, spans: spans, lines: lines)
    {
      let end = last.row < lines.count
        ? textOffset(row: last.row, boundary: last.end, start: false,
                     columns: columns, spans: spans, lines: lines)
        : length
      guard let end, end >= start else { return [] }
      return end > start ? [NSRange(location: start, length: end - start)] : []
    }

    var result: [NSRange] = []
    for segment in segments {
      let lower = segment.row * columns + segment.start
      let upper = segment.row * columns + segment.end
      var index = Self.firstSpanIndex(endingAfter: lower, spans: spans)
      while index < spans.count, spans[index].gridStart < upper {
        let span = spans[index]
        index += 1
        // Newline spans bridge grid rows but are not selected terminal cells.
        // Intersecting a Lead2 span deliberately rounds an invalid half-cell
        // boundary out to its complete grapheme cluster.
        guard span.cells > 0, span.gridEnd > lower, span.gridStart < upper else { continue }
        appendSelectedRange(span.range, to: &result)
      }
    }
    return result
  }

  private static func normalizedSegments(
    _ source: [TerminalSelectionSnapshot.Segment], mode: TerminalSelectionMode, columns: Int, rowCount: Int
  ) -> [TerminalSelectionSnapshot.Segment] {
    var segments = source.compactMap { segment -> TerminalSelectionSnapshot.Segment? in
      guard (0..<rowCount).contains(segment.row),
        (0...columns).contains(segment.start), (0...columns).contains(segment.end),
        segment.start <= segment.end,
        mode == .linear || segment.start < segment.end
      else { return nil }
      return segment
    }
    segments.sort {
      $0.row != $1.row ? $0.row < $1.row
        : ($0.start != $1.start ? $0.start < $1.start : $0.end < $1.end)
    }
    // A core linear gesture can end (or begin) at the next physical row's
    // zero boundary. Retain that endpoint so AX preserves the intervening
    // newline. A lone zero remains empty, and zero rectangle spans remain
    // excluded above; malformed interior zero spans cannot imply content.
    for index in segments.indices where segments[index].start == segments[index].end {
      guard mode == .linear,
        (index == segments.startIndex || index == segments.index(before: segments.endIndex))
      else { return [] }
    }
    return segments
  }

  /// Finds the physical AX insertion point for one terminal row boundary.
  /// Trailing/entirely blank cells have no individual text spans, so their
  /// corresponding newline span supplies the before-break position.
  private static func textOffset(
    row: Int, boundary: Int, start: Bool, columns: Int, spans: [Span], lines: [NSRange]
  ) -> Int? {
    guard lines.indices.contains(row), (0...columns).contains(boundary) else { return nil }
    let line = lines[row]
    let beforeBreak = NSMaxRange(line) - (row + 1 < lines.count ? 1 : 0)
    guard boundary < columns else { return beforeBreak }
    let grid = row * columns + boundary
    var index = firstSpanIndex(endingAfter: grid, spans: spans)
    while index < spans.count {
      let span = spans[index]
      guard span.row == row else { break }
      index += 1
      guard span.gridStart <= grid, grid < span.gridEnd else { continue }
      guard span.cells > 0 else { return span.range.location }
      return start || grid == span.gridStart ? span.range.location : NSMaxRange(span.range)
    }
    return beforeBreak
  }

  /// AX's selected-text value is the concatenation of its selected character
  /// ranges.  In particular, it is not a substring spanning rectangular gaps.
  package func selectedText() -> String? {
    let ranges = selectedRanges()
    guard !ranges.isEmpty else { return nil }
    return ranges.compactMap { string(in: $0) }.joined()
  }

  /// Converts AX UTF-16 selection ranges into owner-validated terminal
  /// endpoints. A single range is linear. Several ranges are accepted only
  /// when they are the rows of one physical rectangle; unsupported disjoint
  /// shapes are rejected instead of enclosing unselected terminal cells.
  package func presentedRange(
    for ranges: [NSRange]
  ) -> (start: TerminalSelectionHit, end: TerminalSelectionHit, mode: TerminalSelectionMode)? {
    guard !ranges.isEmpty, ranges.allSatisfy({ $0.length > 0 && valid($0) }),
      selectionPresentation != nil
    else { return nil }

    let ordered = ranges.sorted {
      $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length
    }
    for index in ordered.indices.dropFirst() {
      guard NSMaxRange(ordered[index - 1]) < ordered[index].location else { return nil }
    }
    // The final UTF-16 boundary of a clipped projection has no proof that it
    // is the real terminal endpoint. Earlier complete displayed ranges remain
    // useful, but setters may never claim to reach unseen text.
    guard !truncated || !ordered.contains(where: { NSMaxRange($0) == length }) else { return nil }
    let endpoints = ordered.compactMap { range -> (TerminalSelectionHit, TerminalSelectionHit)? in
      guard let start = hit(atUTF16Boundary: range.location, start: true),
        let end = hit(atUTF16Boundary: NSMaxRange(range), start: false)
      else { return nil }
      return (start, end)
    }
    guard endpoints.count == ordered.count, let first = endpoints.first, let last = endpoints.last else { return nil }
    guard endpoints.count > 1 else { return (first.0, first.1, .linear) }

    // AppKit's multi-range selection represents a physical rectangular block
    // here: one complete range per successive displayed row, all sharing the
    // same terminal boundaries. Do not infer a rectangle from arbitrary AX
    // disjoint ranges, because that would include cells the caller omitted.
    let startColumn = first.0.boundary
    let endColumn = first.1.boundary
    guard startColumn < endColumn,
      endpoints.enumerated().allSatisfy({ item in
        let (offset, endpoint) = item
        return endpoint.0.row == endpoint.1.row
          && endpoint.0.row == first.0.row + offset
          && endpoint.0.boundary == startColumn
          && endpoint.1.boundary == endColumn
      })
    else { return nil }
    return (first.0, last.1, .rectangular)
  }

  private static func validSelectionPresentation(
    in snapshot: TerminalSnapshot
  ) -> TerminalSelectionPresentation? {
    guard let presentation = snapshot.selectionPresentation,
      presentation.snapshotID != 0,
      presentation.geometryEpoch == snapshot.geometry_epoch,
      presentation.columns == snapshot.cols,
      presentation.rows.count == snapshot.rows.count,
      presentation.screen == (snapshot.alternate ? .alternate : .primary),
      zip(snapshot.rows, presentation.rows).allSatisfy({ row, proof in
        row.id != 0 && row.id == proof.id && row.revision == proof.revision
          && row.soft_wrapped == proof.softWrapped
      })
    else { return nil }
    return presentation
  }

  private static func appendSelectedRange(_ next: NSRange, to ranges: inout [NSRange]) {
    guard next.length > 0 else { return }
    if let last = ranges.last, next.location <= NSMaxRange(last) {
      ranges[ranges.count - 1].length = max(NSMaxRange(last), NSMaxRange(next)) - last.location
    } else {
      ranges.append(next)
    }
  }

  private func hit(
    atUTF16Boundary offset: Int, start: Bool
  ) -> TerminalSelectionHit? {
    guard (0...length).contains(offset) else { return nil }
    let firstAfter = Self.firstSpanIndex(endingAfterText: offset, spans: spans)
    let previous = firstAfter > 0 ? spans[firstAfter - 1] : nil
    let next = firstAfter < spans.count ? spans[firstAfter] : nil

    // A boundary inside a composed scalar or wide-cell span cannot be
    // represented as a terminal cell boundary.
    if let next, next.range.location < offset, offset < NSMaxRange(next.range) { return nil }

    let chosen: (Span, Int, TerminalSelectionAffinity)?
    if start, let next, next.cells == 0, next.range.location == offset {
      // Physical AX newlines have no terminal cell. Their leading UTF-16
      // boundary is the preceding row's terminal boundary, including a
      // completely blank row whose only projected character is this newline.
      chosen = (next, columns, .after)
    } else if !start, let previous, previous.cells == 0, NSMaxRange(previous.range) == offset {
      // The newline's trailing boundary is the next physical row at column
      // zero. This remains valid even when that next row is blank.
      return selectionPresentation?.hit(row: previous.row + 1, boundary: 0, affinity: .before)
    } else if start, let next, next.cells > 0, next.range.location == offset {
      chosen = (next, next.column, .before)
    } else if let previous, previous.cells > 0, NSMaxRange(previous.range) == offset {
      chosen = (previous, previous.column + previous.cells, .after)
    } else if let next, next.cells > 0, next.range.location == offset {
      chosen = (next, next.column, .before)
    } else {
      chosen = nil
    }
    guard let (span, boundary, affinity) = chosen else { return nil }
    return selectionPresentation?.hit(row: span.row, boundary: boundary, affinity: affinity)
  }
  /// First run whose end follows the index. The end index is a valid result
  /// for empty projections and queries at the end of the text.
  private func styleIndex(at index: Int) -> Int {
    var lower = 0
    var upper = styles.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if NSMaxRange(styles[middle].range) <= index {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }
  package func styleRange(for index: Int) -> NSRange {
    guard index >= 0, index < length else { return NSRange(location: NSNotFound, length: 0) }
    let offset = styleIndex(at: index)
    return offset < styles.count ? styles[offset].range : NSRange(location: NSNotFound, length: 0)
  }
  @MainActor
  package func attributedString(
    in range: NSRange, fontSize: CGFloat, parent: NSView, activate: @escaping TerminalLinkActivationHandler
  ) -> NSAttributedString? {
    guard let value = string(in: range), fontSize.isFinite, fontSize > 0 else { return nil }
    let result = NSMutableAttributedString(string: value)
    var fonts: [Int: [String: Any]] = [:]
    for run in styles[styleIndex(at: range.location)...] {
      if run.range.location >= NSMaxRange(range) { break }
      let overlap = NSIntersectionRange(run.range, range)
      guard overlap.length > 0, let style = run.style else { continue }
      let colors = palette.resolve(style)
      let foreground = style.conceal ? colors.background : colors.foreground
      let traits = (style.bold ? 1 : 0) | (style.italic ? 2 : 0)
      if fonts[traits] == nil {
        let font = TerminalFont.core(size: fontSize, bold: style.bold, italic: style.italic) as NSFont
        fonts[traits] = [
          NSAccessibility.FontAttributeKey.fontName.rawValue: font.fontName,
          NSAccessibility.FontAttributeKey.fontFamily.rawValue: font.familyName ?? font.fontName,
          NSAccessibility.FontAttributeKey.visibleName.rawValue: font.displayName ?? font.fontName,
          NSAccessibility.FontAttributeKey.fontSize.rawValue: fontSize
        ]
      }
      var attributes: [NSAttributedString.Key: Any] = [
        .accessibilityFont: fonts[traits]!,
        .accessibilityForegroundColor: Self.color(foreground),
        .accessibilityBackgroundColor: Self.color(colors.background)
      ]
      if style.underline > 0 {
        let underline: NSUnderlineStyle
        switch style.underline {
        case 2: underline = .double
        case 4: underline = [.single, .patternDot]
        case 5: underline = [.single, .patternDash]
        default: underline = .single
        }
        attributes[.accessibilityUnderline] = underline.rawValue
        attributes[.accessibilityUnderlineColor] = Self.color(
          style.conceal ? colors.background : colors.underline(matching: foreground))
      }
      if style.strike {
        attributes[.accessibilityStrikethrough] = true
        attributes[.accessibilityStrikethroughColor] = Self.color(foreground)
      }
      result.addAttributes(attributes, range: NSRange(
        location: overlap.location - range.location, length: overlap.length))
    }
    var mappingIndex = linkMappingIndex(after: range.location)
    while mappingIndex < linkMappings.count {
      let mapping = linkMappings[mappingIndex]
      guard let first = mapping.ranges.first, first.location < NSMaxRange(range) else { break }
      let link = links.element(occurrence: mapping.occurrence, ranges: mapping.ranges, parent: parent, activate: activate)
      for textRange in mapping.ranges {
        let overlap = NSIntersectionRange(textRange, range)
        guard overlap.length > 0 else { continue }
        result.addAttribute(.accessibilityLink, value: link, range: NSRange(
          location: overlap.location - range.location, length: overlap.length))
      }
      mappingIndex += 1
    }
    return result.copy() as? NSAttributedString
  }
  /// Pure formatting callers get inert AX links; Canvas supplies the only
  /// handler that can enqueue an owner-validated activation.
  @MainActor
  package func attributedString(in range: NSRange, fontSize: CGFloat, parent: NSView) -> NSAttributedString? {
    attributedString(in: range, fontSize: fontSize, parent: parent, activate: { _ in false })
  }
  /// Virtual children for the AX tree.  They deliberately use the same cache
  /// as attributed text so an agent can resolve a child and a character-range
  /// link to the identical AX object.
  @MainActor
  package func linkElements(parent: NSView, activate: @escaping TerminalLinkActivationHandler) -> [AccessibleTerminalLink] {
    linkMappings.compactMap { mapping in
      guard mapping.fullyProjected else { return nil }
      return links.element(occurrence: mapping.occurrence, ranges: mapping.ranges, parent: parent, activate: activate)
    }
  }
  @MainActor
  package func linkElements(parent: NSView) -> [AccessibleTerminalLink] {
    linkElements(parent: parent, activate: { _ in false })
  }
  /// AppKit exports weak AX references. Keep virtual links alive for the
  /// projection's lifetime, including after the attributed query is returned.
  @MainActor private final class Links {
    private weak var parent: NSView?
    private var elements: [Int: AccessibleTerminalLink] = [:]
    nonisolated init() {}

    package func element(
      occurrence: VisibleLinkProjection.Occurrence, ranges: [NSRange], parent: NSView,
      activate: @escaping TerminalLinkActivationHandler
    ) -> AccessibleTerminalLink {
      if self.parent !== parent {
        elements.removeAll()
        self.parent = parent
      }
      let key = occurrence.gridSegments.first?.lowerBound ?? -1
      if let element = elements[key] { return element }
      let element = AccessibleTerminalLink(occurrence: occurrence, ranges: ranges, parent: parent, activate: activate)
      elements[key] = element
      return element
    }
  }
  private static func color(_ value: SIMD4<Float>) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
      components: [CGFloat(value.x), CGFloat(value.y), CGFloat(value.z), CGFloat(value.w)])!
  }
  package func range(for index: Int) -> NSRange {
    guard index >= 0, index < length else { return NSRange(location: NSNotFound, length: 0) }
    return spans.first { NSLocationInRange(index, $0.range) }?.range
      ?? NSRange(location: NSNotFound, length: 0)
  }
  package func line(for index: Int) -> Int {
    guard index >= 0, index <= length else { return -1 }
    if index == length { return max(0, lines.count - 1) }
    return lines.firstIndex { NSLocationInRange(index, $0) } ?? -1
  }
  package func range(forLine line: Int) -> NSRange {
    guard lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
    return lines[line]
  }
  package func textRange(gridStart: Int, gridEnd: Int) -> NSRange {
    let lower = max(0, min(gridStart, gridEnd))
    let upper = min(gridCount, max(gridStart, gridEnd))
    let a = spans.first { $0.gridEnd > lower }?.range.location ?? length
    if lower == upper { return NSRange(location: a, length: 0) }
    let b = spans.last { $0.gridStart < upper }.map { NSMaxRange($0.range) } ?? a
    return NSRange(location: a, length: max(0, b - a))
  }
  package func gridRange(for range: NSRange) -> Range<Int>? {
    guard valid(range) else { return nil }
    let first = spans.first { NSMaxRange($0.range) > range.location }
    let a = first?.gridStart ?? gridCount
    if range.length == 0 { return a..<a }
    let last = spans.last { $0.range.location < NSMaxRange(range) }
    return a..<max(a, last?.gridEnd ?? a)
  }
  package func spans(for range: NSRange) -> [Span] {
    guard valid(range) else { return [] }
    if range.length == 0 {
      if let span = spans.first(where: { NSMaxRange($0.range) > range.location }) { return [span] }
      if let last = spans.last {
        let row = last.cells == 0 ? last.row + 1 : last.row
        let column = last.cells == 0 ? 0 : last.column + last.cells
        return [
          Span(
            range: range, row: row, column: column, cells: 0,
            gridStart: last.gridEnd, gridEnd: last.gridEnd)
        ]
      }
      return [Span(range: range, row: 0, column: 0, cells: 0, gridStart: 0, gridEnd: 0)]
    }
    return spans.filter { NSIntersectionRange($0.range, range).length > 0 }
  }
  package func occurrence(atGrid index: Int) -> VisibleLinkProjection.Occurrence? {
    visibleLinks.occurrence(atGrid: index)
  }
  private static func linkMapping(
    for occurrence: VisibleLinkProjection.Occurrence, spans: [Span]
  ) -> LinkMapping {
    var result: [NSRange] = []
    var complete = true
    for segment in occurrence.gridSegments {
      var covered = segment.lowerBound
      var index = firstSpanIndex(endingAfter: covered, spans: spans)
      while index < spans.count, spans[index].gridStart < segment.upperBound {
        let span = spans[index]
        index += 1
        guard span.cells > 0, span.gridEnd > covered else { continue }
        guard span.gridStart <= covered else { complete = false; break }
        if let last = result.last, NSMaxRange(last) == span.range.location {
          result[result.count - 1].length += span.range.length
        } else {
          result.append(span.range)
        }
        covered = min(segment.upperBound, span.gridEnd)
        if covered == segment.upperBound { break }
      }
      if covered != segment.upperBound { complete = false }
    }
    return LinkMapping(occurrence: occurrence, ranges: result, fullyProjected: complete)
  }
  private static func firstSpanIndex(endingAfter grid: Int, spans: [Span]) -> Int {
    var lower = 0
    var upper = spans.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if spans[middle].gridEnd <= grid {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }
  private static func firstSpanIndex(endingAfterText offset: Int, spans: [Span]) -> Int {
    var lower = 0
    var upper = spans.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if NSMaxRange(spans[middle].range) <= offset {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }
  private func linkMappingIndex(after location: Int) -> Int {
    var lower = 0
    var upper = linkMappings.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if let last = linkMappings[middle].ranges.last, NSMaxRange(last) <= location {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }
}

/// A link reference in an AX attributed string. It remains a lightweight AX
/// object; only Canvas may enqueue its immutable activation with the owner.
@MainActor
package final class AccessibleTerminalLink: NSAccessibilityElement {
  package let occurrence: VisibleLinkProjection.Occurrence
  private let ranges: [NSRange]
  private weak var owner: NSView?
  private let activate: TerminalLinkActivationHandler

  package init(
    occurrence: VisibleLinkProjection.Occurrence, ranges: [NSRange], parent: NSView,
    activate: @escaping TerminalLinkActivationHandler
  ) {
    self.occurrence = occurrence
    self.ranges = ranges
    owner = parent
    self.activate = activate
    super.init()
    setAccessibilityElement(true)
    setAccessibilityRole(.link)
    setAccessibilityLabel(occurrence.label)
    setAccessibilityURL(occurrence.target)
  }
  package override func accessibilityParent() -> Any? { owner }
  package override func accessibilityFrame() -> NSRect {
    guard let owner else { return .zero }
    let frame = ranges.reduce(into: NSRect.null) { $0 = $0.union(owner.accessibilityFrame(for: $1)) }
    return frame.isNull ? .zero : frame
  }
  package override func isAccessibilityEnabled() -> Bool { owner?.window != nil }
  package override func accessibilityPerformPress() -> Bool {
    guard let owner, owner.window != nil, !ranges.isEmpty, let activation = occurrence.activation else { return false }
    return activate(activation)
  }
}

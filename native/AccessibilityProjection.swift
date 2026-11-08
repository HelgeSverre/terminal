import AppKit

/// A bounded UTF-16 projection of the displayed immutable grid. No terminal-owner or GPU calls.
struct AccessibilityProjection {
  private struct StyledRange {
    var range: NSRange
    let style: CellStyle?
    let link: String?
  }
  struct Span {
    let range: NSRange
    let row: Int
    let column: Int
    let cells: Int
    let gridStart: Int
    let gridEnd: Int
  }
  let text: String
  let lines: [NSRange]
  let spans: [Span]
  let columns: Int
  let gridCount: Int
  let truncated: Bool
  private let palette: CellPalette
  private let styles: [StyledRange]
  private let characters: NSString
  private let links = Links()
  var length: Int { characters.length }
  init(snapshot: TerminalSnapshot, limit: Int = 262_144) {
    columns = snapshot.cols
    gridCount = snapshot.cols * snapshot.rows.count
    palette = CellPalette(snapshot: snapshot)
    var output = ""
    var offsets: [NSRange] = []
    var mapping: [Span] = []
    var styling: [StyledRange] = []
    func style(_ range: NSRange, _ value: CellStyle?, link: String? = nil) {
      guard range.length > 0 else { return }
      if let last = styling.last, NSMaxRange(last.range) == range.location,
        last.style == value && last.link == link {
        styling[styling.count - 1].range.length += range.length
      } else {
        styling.append(StyledRange(range: range, style: value, link: link))
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
        style(NSRange(location: count, length: size), cell.style, link: cell.link)
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
  }
  func valid(_ range: NSRange) -> Bool {
    range.location != NSNotFound && range.location >= 0 && range.length >= 0
      && range.location <= length && range.length <= length - range.location
  }
  func string(in range: NSRange) -> String? {
    guard valid(range) else { return nil }
    return characters.substring(with: range)
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
  func styleRange(for index: Int) -> NSRange {
    guard index >= 0, index < length else { return NSRange(location: NSNotFound, length: 0) }
    let offset = styleIndex(at: index)
    return offset < styles.count ? styles[offset].range : NSRange(location: NSNotFound, length: 0)
  }
  @MainActor
  func attributedString(in range: NSRange, fontSize: CGFloat, parent: NSView) -> NSAttributedString? {
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
      if let url = AccessibleTerminalLink.url(run.link) {
        attributes[.accessibilityLink] = links.element(
          url: url, range: run.range, label: characters.substring(with: run.range), parent: parent)
      }
      result.addAttributes(attributes, range: NSRange(
        location: overlap.location - range.location, length: overlap.length))
    }
    return result.copy() as? NSAttributedString
  }
  /// AppKit exports weak AX references. Keep virtual links alive for the
  /// projection's lifetime, including after the attributed query is returned.
  @MainActor private final class Links {
    private weak var parent: NSView?
    private var elements: [Int: AccessibleTerminalLink] = [:]
    nonisolated init() {}

    func element(url: URL, range: NSRange, label: String, parent: NSView) -> AccessibleTerminalLink {
      if self.parent !== parent {
        elements.removeAll()
        self.parent = parent
      }
      if let element = elements[range.location] { return element }
      let element = AccessibleTerminalLink(url: url, range: range, label: label, parent: parent)
      elements[range.location] = element
      return element
    }
  }
  private static func color(_ value: SIMD4<Float>) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
      components: [CGFloat(value.x), CGFloat(value.y), CGFloat(value.z), CGFloat(value.w)])!
  }
  func range(for index: Int) -> NSRange {
    guard index >= 0, index < length else { return NSRange(location: NSNotFound, length: 0) }
    return spans.first { NSLocationInRange(index, $0.range) }?.range
      ?? NSRange(location: NSNotFound, length: 0)
  }
  func line(for index: Int) -> Int {
    guard index >= 0, index <= length else { return -1 }
    if index == length { return max(0, lines.count - 1) }
    return lines.firstIndex { NSLocationInRange(index, $0) } ?? -1
  }
  func range(forLine line: Int) -> NSRange {
    guard lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
    return lines[line]
  }
  func textRange(gridStart: Int, gridEnd: Int) -> NSRange {
    let lower = max(0, min(gridStart, gridEnd))
    let upper = min(gridCount, max(gridStart, gridEnd))
    let a = spans.first { $0.gridEnd > lower }?.range.location ?? length
    if lower == upper { return NSRange(location: a, length: 0) }
    let b = spans.last { $0.gridStart < upper }.map { NSMaxRange($0.range) } ?? a
    return NSRange(location: a, length: max(0, b - a))
  }
  func gridRange(for range: NSRange) -> Range<Int>? {
    guard valid(range) else { return nil }
    let first = spans.first { NSMaxRange($0.range) > range.location }
    let a = first?.gridStart ?? gridCount
    if range.length == 0 { return a..<a }
    let last = spans.last { $0.range.location < NSMaxRange(range) }
    return a..<max(a, last?.gridEnd ?? a)
  }
  func spans(for range: NSRange) -> [Span] {
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
}

/// A link reference in an AX attributed string. It owns URL validation and
/// revalidates against the current projection before acting on a cached link.
@MainActor
final class AccessibleTerminalLink: NSAccessibilityElement {
  private let target: URL
  private let range: NSRange
  private weak var owner: NSView?

  static func url(_ text: String?) -> URL? {
    guard let text, let url = URL(string: text),
      ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
  }
  init(url: URL, range: NSRange, label: String, parent: NSView) {
    target = url
    self.range = range
    owner = parent
    super.init()
    setAccessibilityElement(true)
    setAccessibilityRole(.link)
    setAccessibilityLabel(label)
    setAccessibilityURL(url)
  }
  override func accessibilityParent() -> Any? { owner }
  override func accessibilityFrame() -> NSRect { owner?.accessibilityFrame(for: range) ?? .zero }
  override func isAccessibilityEnabled() -> Bool { owner?.window != nil }
  override func accessibilityPerformPress() -> Bool {
    guard let owner, owner.window != nil, range.length > 0,
      let current = owner.accessibilityAttributedString(for: range), current.length > 0 else { return false }
    var matches = true
    current.enumerateAttribute(.accessibilityLink, in: NSRange(location: 0, length: current.length)) {
      value, _, stop in
      guard let link = value as? AccessibleTerminalLink, link.target == target else {
        matches = false
        stop.pointee = true
        return
      }
    }
    guard matches else { return false }
    return NSWorkspace.shared.open(target)
  }
}

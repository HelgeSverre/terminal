#if os(macOS)
import AppKit
import TerminalEngine

/// A retained page, fetched only by an explicit AX action. Live snapshots do
/// not rebuild this text or invalidate the reader's current position.
@MainActor
final class AccessibleHistory: NSAccessibilityElement {
  private weak var owner: NSView?
  private(set) var page: TerminalHistoryPage
  private var text: NSString
  private var lines: [NSRange] = []
  private var selected = NSRange(location: 0, length: 0)
  private let navigate: (TerminalHistoryPageRequest) -> Bool
  init(page: TerminalHistoryPage, parent: NSView,
       navigate: @escaping (TerminalHistoryPageRequest) -> Bool) {
    self.page = page
    text = page.text as NSString
    owner = parent
    self.navigate = navigate
    super.init()
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    update(page)
  }
  func update(_ page: TerminalHistoryPage) {
    self.page = page
    text = page.text as NSString
    var offset = 0
    lines = page.rows.enumerated().map { index, row in
      let length = row.text.utf16.count + (index + 1 < page.rows.count ? 1 : 0)
      defer { offset += length }
      return NSRange(location: offset, length: length)
    }
    selected = NSRange(location: 0, length: 0)
    let clipped = page.rows.contains(where: \.truncated) ? "; long row clipped" : ""
    setAccessibilityLabel("Terminal output history; \(page.rows.count) rows\(clipped)")
  }
  override func accessibilityParent() -> Any? { owner }
  override func accessibilityFrame() -> NSRect { owner?.accessibilityFrame() ?? .zero }
  override func accessibilityValue() -> Any? { text as String }
  override func accessibilityNumberOfCharacters() -> Int { text.length }
  override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: text.length) }
  override func accessibilitySelectedTextRange() -> NSRange { selected }
  override func setAccessibilitySelectedTextRange(_ range: NSRange) {
    guard valid(range) else { return }
    selected = range
    NSAccessibility.post(element: self, notification: .selectedTextChanged)
  }
  override func accessibilitySelectedText() -> String? { text.substring(with: selected) }
  override func accessibilityString(for range: NSRange) -> String? { valid(range) ? text.substring(with: range) : nil }
  override func accessibilityRange(forLine line: Int) -> NSRange {
    lines.indices.contains(line) ? lines[line] : NSRange(location: NSNotFound, length: 0)
  }
  override func accessibilityLine(for index: Int) -> Int {
    guard index >= 0, index <= text.length else { return -1 }
    if index == text.length { return max(0, lines.count - 1) }
    return lines.firstIndex(where: { NSLocationInRange(index, $0) }) ?? -1
  }
  override func accessibilityRange(for index: Int) -> NSRange {
    guard index >= 0, index < text.length else { return NSRange(location: NSNotFound, length: 0) }
    return text.rangeOfComposedCharacterSequence(at: index)
  }
  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    var actions: [NSAccessibilityCustomAction] = []
    if page.hasOlder, let first = page.rows.first {
      actions.append(NSAccessibilityCustomAction(name: "Read older output", handler: { [weak self] in
        self?.navigate(.older(first.cursor)) ?? false
      }))
    }
    if page.hasNewer, let last = page.rows.last {
      actions.append(NSAccessibilityCustomAction(name: "Read newer output", handler: { [weak self] in
        self?.navigate(.newer(last.cursor)) ?? false
      }))
    }
    actions.append(NSAccessibilityCustomAction(name: "Read latest output", handler: { [weak self] in
      self?.navigate(.latest) ?? false
    }))
    return actions
  }
  override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if selector == NSSelectorFromString("setAccessibilityValue:")
      || selector == NSSelectorFromString("setAccessibilitySelectedText:") { return false }
    return super.isAccessibilitySelectorAllowed(selector)
  }
  private func valid(_ range: NSRange) -> Bool {
    range.location != NSNotFound && range.location >= 0 && range.length >= 0
      && range.location <= text.length && range.length <= text.length - range.location
  }
}
#endif

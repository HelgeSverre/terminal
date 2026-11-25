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
  private nonisolated func onMain<T>(_ body: @MainActor (AccessibleHistory) -> T) -> T {
    nonisolated(unsafe) let this = self
    nonisolated(unsafe) var result: T!
    MainActor.assumeIsolated { result = body(this) }
    return result
  }
  nonisolated override func accessibilityParent() -> Any? { onMain { $0.owner } }
  nonisolated override func accessibilityFrame() -> NSRect { onMain { $0.owner?.accessibilityFrame() ?? .zero } }
  nonisolated override func accessibilityValue() -> Any? { onMain { $0.text as String } }
  nonisolated override func accessibilityNumberOfCharacters() -> Int { onMain { $0.text.length } }
  nonisolated override func accessibilityVisibleCharacterRange() -> NSRange {
    onMain { NSRange(location: 0, length: $0.text.length) }
  }
  nonisolated override func accessibilitySelectedTextRange() -> NSRange { onMain { $0.selected } }
  nonisolated override func setAccessibilitySelectedTextRange(_ range: NSRange) {
    onMain {
      guard Self.valid(range, length: $0.text.length) else { return }
      $0.selected = range
      NSAccessibility.post(element: $0, notification: .selectedTextChanged)
    }
  }
  nonisolated override func accessibilitySelectedText() -> String? {
    onMain { $0.text.substring(with: $0.selected) }
  }
  nonisolated override func accessibilityString(for range: NSRange) -> String? {
    onMain { Self.valid(range, length: $0.text.length) ? $0.text.substring(with: range) : nil }
  }
  nonisolated override func accessibilityRange(forLine line: Int) -> NSRange {
    onMain { $0.lines.indices.contains(line) ? $0.lines[line] : NSRange(location: NSNotFound, length: 0) }
  }
  nonisolated override func accessibilityLine(for index: Int) -> Int {
    onMain {
      guard index >= 0, index <= $0.text.length else { return -1 }
      if index == $0.text.length { return max(0, $0.lines.count - 1) }
      return $0.lines.firstIndex(where: { NSLocationInRange(index, $0) }) ?? -1
    }
  }
  nonisolated override func accessibilityRange(for index: Int) -> NSRange {
    onMain {
      guard index >= 0, index < $0.text.length else { return NSRange(location: NSNotFound, length: 0) }
      return $0.text.rangeOfComposedCharacterSequence(at: index)
    }
  }
  nonisolated override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    onMain { history in
      var actions: [NSAccessibilityCustomAction] = []
      if history.page.hasOlder, let first = history.page.rows.first {
        actions.append(NSAccessibilityCustomAction(name: "Read older output", handler: { [weak history] in
          MainActor.assumeIsolated { history?.navigate(.older(first.cursor)) ?? false }
        }))
      }
      if history.page.hasNewer, let last = history.page.rows.last {
        actions.append(NSAccessibilityCustomAction(name: "Read newer output", handler: { [weak history] in
          MainActor.assumeIsolated { history?.navigate(.newer(last.cursor)) ?? false }
        }))
      }
      actions.append(NSAccessibilityCustomAction(name: "Read latest output", handler: { [weak history] in
        MainActor.assumeIsolated { history?.navigate(.latest) ?? false }
      }))
      return actions
    }
  }
  nonisolated override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if selector == NSSelectorFromString("setAccessibilityValue:")
      || selector == NSSelectorFromString("setAccessibilitySelectedText:") { return false }
    return super.isAccessibilitySelectorAllowed(selector)
  }
  nonisolated private static func valid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound && range.location >= 0 && range.length >= 0
      && range.location <= length && range.length <= length - range.location
  }
}
#endif

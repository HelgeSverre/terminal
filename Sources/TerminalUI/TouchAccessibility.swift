#if os(iOS)
import UIKit
import TerminalHost

private final class TouchAccessibleElement: UIAccessibilityElement {
  var activate: (() -> Bool)?
  override func accessibilityActivate() -> Bool { activate?() ?? false }
}

extension TerminalCanvasView {
  /// The presented viewport only, capped by row, element and UTF-16 budgets.
  /// Older history is fetched by a session scroll, never an AX-thread core read.
  func buildAccessibilityElements() -> [UIAccessibilityElement] {
    guard let snapshot else { return [emptyTerminalElement()] }
    var elements: [UIAccessibilityElement] = [], remaining = 65_536
    let rowLimit = min(256, snapshot.rows.count)
    for row in 0..<rowLimit {
      guard remaining > 0 else { break }
      var text = ""
      for cell in snapshot.rows[row].cells where cell.kind != .continuation && cell.kind != .wrapSpacer {
        let value = cell.text.isEmpty ? " " : cell.text
        let count = value.utf16.count
        guard count <= remaining else { break }
        text.append(value); remaining -= count
      }
      let label = text.trimmingCharacters(in: .whitespaces)
      guard !label.isEmpty else { continue }
      let element = TouchAccessibleElement(accessibilityContainer: self)
      element.accessibilityLabel = label
      element.accessibilityTraits = .staticText
      element.accessibilityHint = "Double tap to type. Scroll to read older or newer output."
      element.accessibilityFrameInContainerSpace = CGRect(x: CGFloat(insetPixels) / scale,
        y: CGFloat(insetPixels + row * cellHeight) / scale,
        width: CGFloat(snapshot.cols * cellWidth) / scale, height: CGFloat(cellHeight) / scale)
      element.activate = { [weak self] in self?.becomeFirstResponder() ?? false }
      element.accessibilityCustomActions = [
        UIAccessibilityCustomAction(name: "Older output") { [weak self] _ in self?.accessibilityScroll(.up) ?? false },
        UIAccessibilityCustomAction(name: "Newer output") { [weak self] _ in self?.accessibilityScroll(.down) ?? false },
        UIAccessibilityCustomAction(name: "Find") { [weak self] _ in self?.showFind(); return self != nil },
        UIAccessibilityCustomAction(name: "Select visible output") { [weak self] _ in self?.selectAll(nil); return self != nil },
      ]
      if hasSelection {
        element.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "Copy selection") { [weak self] _ in
          self?.copy(nil); return self != nil
        })
      }
      elements.append(element)
    }
    // Keep links independently actionable and retain the exact visible proof.
    for link in VisibleLinkProjection(snapshot: snapshot).occurrences.prefix(128) {
      guard let activation = link.activation, let first = link.gridSegments.first else { continue }
      let element = TouchAccessibleElement(accessibilityContainer: self)
      element.accessibilityLabel = String(link.label.prefix(512))
      element.accessibilityValue = link.target.absoluteString
      element.accessibilityTraits = .link
      element.accessibilityFrameInContainerSpace = CGRect(
        x: CGFloat(insetPixels + first.lowerBound % snapshot.cols * cellWidth) / scale,
        y: CGFloat(insetPixels + first.lowerBound / snapshot.cols * cellHeight) / scale,
        width: CGFloat(min(snapshot.cols, first.count) * cellWidth) / scale,
        height: CGFloat(cellHeight) / scale)
      element.activate = { [weak self] in self?.activateLink(activation); return self != nil }
      elements.append(element)
    }
    if rowLimit < snapshot.rows.count || remaining == 0 {
      let notice = UIAccessibilityElement(accessibilityContainer: self)
      notice.accessibilityLabel = "Visible output truncated for accessibility. Scroll or use Find to navigate."
      notice.accessibilityTraits = .staticText
      notice.accessibilityFrameInContainerSpace = bounds
      elements.append(notice)
    }
    // A cleared or initially blank screen still needs an entry point for
    // typing, Find and history navigation when the canvas is a container.
    return elements.isEmpty ? [emptyTerminalElement()] : elements
  }
  private func emptyTerminalElement() -> UIAccessibilityElement {
    let element = TouchAccessibleElement(accessibilityContainer: self)
    element.accessibilityLabel = "Terminal"
    element.accessibilityValue = "No visible output"
    element.accessibilityTraits = .button
    element.accessibilityHint = "Double tap to type. Use actions to find or navigate output."
    element.accessibilityFrameInContainerSpace = bounds
    element.activate = { [weak self] in self?.becomeFirstResponder() ?? false }
    element.accessibilityCustomActions = [
      UIAccessibilityCustomAction(name: "Older output") { [weak self] _ in self?.accessibilityScroll(.up) ?? false },
      UIAccessibilityCustomAction(name: "Newer output") { [weak self] _ in self?.accessibilityScroll(.down) ?? false },
      UIAccessibilityCustomAction(name: "Find") { [weak self] _ in self?.showFind(); return self != nil },
    ]
    return element
  }
  public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
    guard let snapshot, direction == .up || direction == .down else { return false }
    session.scroll((direction == .up ? 1 : -1) * max(1, snapshot.rows.count - 1))
    UIAccessibility.post(notification: .pageScrolled, argument: direction == .up ? "Older output" : "Newer output")
    return true
  }
}
#endif

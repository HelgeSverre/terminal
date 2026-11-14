import AppKit

/// What the count label beside the query reports.
enum FindBarResult: Equatable {
  case idle
  case searching
  /// One-based position from the newest match.
  case matches(index: Int, total: Int, capped: Bool)
  case noMatches
  case failed(String)
}

/// The find bar docked over the top of a pane. It owns presentation and key
/// handling only; the pane's canvas runs the search and reports each result.
package final class FindBarView: NSView, NSTextFieldDelegate {
  package static let height: CGFloat = 30

  private final class QueryField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
      let accepted = super.becomeFirstResponder()
      if accepted {
        (currentEditor() as? NSTextView)?.insertionPointColor = TerminalTheme.color(TerminalTheme.accent)
        onFocusChange?(true)
      }
      return accepted
    }
  }

  private let glass = NSImageView()
  private let field = QueryField()
  private let count = NSTextField(labelWithString: "")
  private let previous = NSButton(title: "", target: nil, action: nil)
  private let next = NSButton(title: "", target: nil, action: nil)
  private let close = NSButton(title: "", target: nil, action: nil)
  private var fieldFocused = false
  private var searchingNotice = 0
  private(set) var result = FindBarResult.idle

  /// The query changed; empty means the highlights should be cleared.
  var onQuery: ((String) -> Void)?
  /// `older` is the Return direction: away from the newest match.
  var onStep: ((_ older: Bool) -> Void)?
  var onClose: (() -> Void)?

  var query: String { field.stringValue }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isHidden = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Find")
    setAccessibilityIdentifier("no.helgesverre.terminal.find")

    glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    glass.contentTintColor = TerminalTheme.color(TerminalTheme.muted)
    glass.setAccessibilityElement(false)
    addSubview(glass)

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.textColor = TerminalTheme.color(TerminalTheme.text)
    field.placeholderAttributedString = NSAttributedString(
      string: "Find in scrollback",
      attributes: [
        .foregroundColor: TerminalTheme.color(TerminalTheme.muted), .font: NSFont.systemFont(ofSize: 13),
      ])
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.cell?.usesSingleLineMode = true
    field.delegate = self
    field.onFocusChange = { [weak self] focused in self?.setFieldFocused(focused) }
    field.setAccessibilityLabel("Find in scrollback")
    field.setAccessibilityIdentifier("no.helgesverre.terminal.find.query")
    addSubview(field)

    count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    count.alignment = .right
    count.lineBreakMode = .byClipping
    count.setAccessibilityIdentifier("no.helgesverre.terminal.find.count")
    addSubview(count)

    configure(previous, symbol: "chevron.up", label: "Previous match", hint: "Previous match (⇧ Return)",
      identifier: "previous", action: #selector(stepNewer(_:)))
    configure(next, symbol: "chevron.down", label: "Next match", hint: "Next match (Return)",
      identifier: "next", action: #selector(stepOlder(_:)))
    configure(close, symbol: "xmark", label: "Close find bar", hint: "Close (Esc)",
      identifier: "close", action: #selector(closeBar(_:)))
    apply(.idle)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  package override var isFlipped: Bool { true }

  private func configure(_ button: NSButton, symbol: String, label: String, hint: String,
    identifier: String, action: Selector) {
    button.bezelStyle = .shadowlessSquare
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    button.contentTintColor = TerminalTheme.color(TerminalTheme.secondary)
    button.target = self
    button.action = action
    button.toolTip = hint
    button.refusesFirstResponder = true
    button.setAccessibilityLabel(label)
    button.setAccessibilityIdentifier("no.helgesverre.terminal.find." + identifier)
    addSubview(button)
  }

  /// Shows the bar and puts the caret in the query, selecting any earlier
  /// query so typing replaces it.
  func open() {
    isHidden = false
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  func dismiss() {
    searchingNotice += 1
    isHidden = true
    apply(.idle)
  }

  /// Reports a search outcome. `.searching` appears only if the search is
  /// still running shortly after, so fast searches do not flash the label.
  func show(_ result: FindBarResult) {
    searchingNotice += 1
    guard result == .searching else { apply(result); return }
    let notice = searchingNotice
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self, self.searchingNotice == notice else { return }
      self.apply(.searching)
    }
  }

  private func apply(_ result: FindBarResult) {
    self.result = result
    var text = ""
    var failed = false
    var navigable = false
    switch result {
    case .idle: break
    case .searching: text = "Searching…"
    case .matches(let index, let total, let capped):
      text = "\(index)/\(total)\(capped ? "+" : "")"
      navigable = true
    case .noMatches:
      text = "No matches"
      failed = true
    case .failed(let message):
      text = message
      failed = true
    }
    count.stringValue = text
    count.isHidden = text.isEmpty
    count.textColor = TerminalTheme.color(failed ? TerminalTheme.danger : TerminalTheme.muted)
    previous.isEnabled = navigable
    next.isEnabled = navigable
    needsLayout = true
  }

  private func setFieldFocused(_ focused: Bool) {
    guard fieldFocused != focused else { return }
    fieldFocused = focused
    needsDisplay = true
  }

  package override func layout() {
    super.layout()
    let side: CGFloat = 22
    var right = bounds.width - 4
    for button in [close, next, previous] {
      right -= side
      button.frame = NSRect(x: right, y: (bounds.height - side) / 2, width: side, height: side)
      right -= 2
    }
    // One point of separator plus its margins sits between count and arrows.
    right -= 5
    let countSize = count.isHidden ? .zero : count.intrinsicContentSize
    let countWidth = min(ceil(countSize.width) + 2, max(0, right - 120))
    count.frame = NSRect(x: right - countWidth - 6, y: round((bounds.height - countSize.height) / 2),
      width: countWidth, height: countSize.height)
    let glassSide: CGFloat = 14
    glass.frame = NSRect(x: 8, y: (bounds.height - glassSide) / 2, width: glassSide, height: glassSide)
    let fieldHeight = ceil(field.cell?.cellSize.height ?? 17)
    let fieldX = glass.frame.maxX + 6
    let fieldEnd = count.isHidden ? right - 6 : count.frame.minX - 8
    field.frame = NSRect(x: fieldX, y: round((bounds.height - fieldHeight) / 2),
      width: max(0, fieldEnd - fieldX), height: fieldHeight)
  }

  package override func draw(_ dirtyRect: NSRect) {
    TerminalTheme.color(TerminalTheme.raised).setFill()
    bounds.fill()
    TerminalTheme.color(TerminalTheme.border).setFill()
    NSRect(x: previous.frame.minX - 4, y: (bounds.height - 14) / 2, width: 1, height: 14).fill()
    TerminalTheme.color(fieldFocused ? TerminalTheme.accent : TerminalTheme.border).setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
  }

  // The bar covers the canvas; a click on its chrome belongs to the query.
  package override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

  package func controlTextDidChange(_ notification: Notification) { onQuery?(field.stringValue) }
  package func controlTextDidEndEditing(_ notification: Notification) { setFieldFocused(false) }

  package func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch NSStringFromSelector(selector) {
    case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:":
      onStep?(!(NSApp?.currentEvent?.modifierFlags.contains(.shift) ?? false))
      return true
    case "cancelOperation:":
      onClose?()
      return true
    default: return false
    }
  }

  @objc private func stepOlder(_ sender: Any?) { onStep?(true) }
  @objc private func stepNewer(_ sender: Any?) { onStep?(false) }
  @objc private func closeBar(_ sender: Any?) { onClose?() }

  // Menu commands reach the bar while its query has focus; the canvas answers
  // the same selectors otherwise.
  @objc func find(_ sender: Any?) { open() }
  @objc func findNext(_ sender: Any?) { onStep?(true) }
  @objc func findPrevious(_ sender: Any?) { onStep?(false) }
}

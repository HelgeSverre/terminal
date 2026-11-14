import AppKit
import TerminalUI

final class TerminalPanePresentationView: NSView {
  static let headerHeight: CGFloat = 20
  static let terminalMinimum = NSSize(width: 200, height: 120)

  let canvas: NSView
  /// Docked over the top rows of the canvas rather than above it: opening the
  /// bar must not resize the grid, which would reflow and drop the matches.
  let findBar = FindBarView()
  private let header = PaneHeaderView()
  private var tracking: NSTrackingArea?
  private var showsHeader = false
  private var isActive = false
  private var isHovered = false
  private var inactiveDim: PaneInactiveDim = .five
  private var title = "Terminal"
  /// Chosen for this pane from its header; nil follows the preference.
  private var chosenColor: PaneChromeColor?
  private var defaultColor = PaneChromeColor.standard
  var color: PaneChromeColor { chosenColor ?? defaultColor }
  private let colorPopover = PaneColorPopover()
  /// The pane's own color when the popover opened; Escape puts it back.
  private var colorBeforePopover: PaneChromeColor?

  var onSelect: (() -> Void)?
  var onClose: (() -> Void)?

  init(canvas: NSView) {
    self.canvas = canvas
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Terminal pane")
    let canvasIdentifier = canvas.accessibilityIdentifier()
    setAccessibilityIdentifier(canvasIdentifier + ".presentation")
    addSubview(canvas)
    addSubview(findBar)
    addSubview(header)
    header.onSelect = { [weak self] in self?.onSelect?() }
    header.onChooseColor = { [weak self] point in self?.showColorPopover(at: point) }
    header.onClose = { [weak self] in self?.onClose?() }
    colorPopover.onChoose = { [weak self] color in self?.choose(color) }
    colorPopover.onCommit = { [weak self] in self?.onSelect?() }
    colorPopover.onCancel = { [weak self] in self?.restoreColorBeforePopover() }
    updateHeader()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override var isFlipped: Bool { true }

  /// The pane whose canvas or chrome holds `responder`. Focus in a pane is
  /// not always its canvas: the find bar's query field belongs to it too.
  static func enclosing(_ responder: NSResponder?) -> TerminalPanePresentationView? {
    var view = responder as? NSView
    // The window shares one field editor; its delegate is the control it edits.
    if let editor = view as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
      view = control
    }
    while let current = view {
      if let presentation = current as? TerminalPanePresentationView { return presentation }
      view = current.superview
    }
    return nil
  }

  var minimumSize: NSSize {
    NSSize(width: Self.terminalMinimum.width,
      height: Self.terminalMinimum.height + (showsHeader ? Self.headerHeight : 0))
  }

  func configure(showHeader: Bool, active: Bool, inactiveDim: PaneInactiveDim,
    defaultColor: PaneChromeColor) {
    let changed = showsHeader != showHeader
    let presentationChanged = changed || isActive != active || self.inactiveDim != inactiveDim
      || self.defaultColor != defaultColor
    self.defaultColor = defaultColor
    showsHeader = showHeader
    isActive = active
    self.inactiveDim = inactiveDim
    header.isHidden = !showHeader
    // Only a header that goes away takes its anchored popover with it; one
    // opened from the keyboard on a single pane is anchored to the canvas.
    if changed && !showHeader { colorPopover.dismiss() }
    guard presentationChanged else { return }
    updateHeader()
    if changed {
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
  }

  func setTitle(_ title: String) {
    let resolved = title.isEmpty ? "Terminal" : title
    guard self.title != resolved else { return }
    self.title = resolved
    updateHeader()
  }

  override func viewWillMove(toSuperview newSuperview: NSView?) {
    if newSuperview == nil { colorPopover.dismiss() }
    super.viewWillMove(toSuperview: newSuperview)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { colorPopover.dismiss() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func layout() {
    super.layout()
    let height = showsHeader ? Self.headerHeight : 0
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
    canvas.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    findBar.frame = NSRect(x: 0, y: height, width: bounds.width, height: FindBarView.height)
  }

  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero,
      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updateHeader()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateHeader()
  }

  /// Gives this pane its own color; it no longer follows the preference.
  func choose(_ color: PaneChromeColor) {
    guard self.color != color else { return }
    chosenColor = color
    updateHeader()
  }

  /// Makes this pane follow the default color preference again.
  func resetColor() {
    guard chosenColor != nil else { return }
    chosenColor = nil
    updateHeader()
  }

  private func restoreColorBeforePopover() {
    chosenColor = colorBeforePopover
    updateHeader()
  }

  private func updateHeader() {
    let fullOpacity = isActive || isHovered
    let alpha = fullOpacity ? 1 : inactiveDim.alpha
    if canvas.alphaValue != alpha { canvas.alphaValue = alpha }
    if header.alphaValue != alpha { header.alphaValue = alpha }
    header.configure(title: title, color: color)
  }

  /// Opens the color popover with keyboard focus on the current color. It
  /// points at `point` (header coordinates) after a right-click, and at the
  /// header's center when opened from the menu. Without a header it hangs
  /// from the top of the canvas.
  func showColorPopover(at point: NSPoint? = nil) {
    onSelect?()
    colorBeforePopover = chosenColor
    if header.isHidden {
      let anchor = NSRect(x: canvas.bounds.midX, y: canvas.bounds.minY, width: 1, height: 1)
      colorPopover.present(from: canvas, anchor: anchor, selected: color)
    } else {
      let x = min(max(point?.x ?? header.bounds.midX, header.bounds.minX), header.bounds.maxX - 1)
      let anchor = NSRect(x: x, y: header.bounds.minY, width: 1, height: header.bounds.height)
      colorPopover.present(from: header, anchor: anchor, selected: color)
    }
  }

}

private final class PaneHeaderView: NSView {
  private let titleField = NSTextField(labelWithString: "Terminal")
  private let closeButton = NSButton(title: "", target: nil, action: nil)
  private var color = PaneChromeColor.standard
  var onSelect: (() -> Void)?
  /// Called with the right-click location in header coordinates, or nil
  /// when opened through accessibility.
  var onChooseColor: ((NSPoint?) -> Void)?
  var onClose: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    titleField.font = .systemFont(ofSize: 11, weight: .medium)
    titleField.lineBreakMode = .byTruncatingTail
    titleField.setAccessibilityLabel("Pane title")
    titleField.setAccessibilityIdentifier("no.helgesverre.terminal.pane-title")
    addSubview(titleField)
    closeButton.bezelStyle = .shadowlessSquare
    closeButton.isBordered = false
    closeButton.imagePosition = .imageOnly
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    closeButton.target = self
    closeButton.action = #selector(closePane(_:))
    closeButton.setAccessibilityLabel("Close pane")
    closeButton.setAccessibilityIdentifier("no.helgesverre.terminal.pane.close")
    closeButton.toolTip = "Close pane"
    addSubview(closeButton)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Pane header")
    setAccessibilityIdentifier("no.helgesverre.terminal.pane.header")
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(name: "Choose Pane Color") { [weak self] in
        self?.onChooseColor?(nil)
        return self?.onChooseColor != nil
      },
      NSAccessibilityCustomAction(name: "Close Pane") { [weak self] in
        self?.onClose?()
        return self?.onClose != nil
      },
    ])
  }

  /// VoiceOver's "show menu" (VO-Shift-M) opens the color popover, as a right-click does.
  override func accessibilityPerformShowMenu() -> Bool {
    guard let onChooseColor else { return false }
    onChooseColor(nil)
    return true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override var isFlipped: Bool { true }

  func configure(title: String, color: PaneChromeColor) {
    guard titleField.stringValue != title || self.color != color else { return }
    self.color = color
    titleField.stringValue = title
    setAccessibilityValue(title)
    titleField.textColor = color.readableForeground
    closeButton.contentTintColor = color.readableForeground.withAlphaComponent(0.72)
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    // Center on the label's own line height; a fixed origin sits the text high.
    let buttonSide: CGFloat = 16
    closeButton.frame = NSRect(x: bounds.width - buttonSide - 4, y: (bounds.height - buttonSide) / 2,
      width: buttonSide, height: buttonSide)
    let textHeight = ceil(titleField.cell?.cellSize.height ?? 14)
    titleField.frame = NSRect(x: 8, y: round((bounds.height - textHeight) / 2),
      width: max(0, closeButton.frame.minX - 12), height: textHeight)
  }

  override func draw(_ dirtyRect: NSRect) {
    color.nsColor.setFill()
    bounds.fill()
  }

  /// A click on an unfocused window's pane header focuses that pane.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    onSelect?()
    super.mouseDown(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    onSelect?()
    onChooseColor?(convert(event.locationInWindow, from: nil))
  }

  /// Middle (scroll-wheel) click closes the pane, like a browser tab. It
  /// closes on release, and only if the pointer is still over the header.
  override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
      return super.otherMouseUp(with: event)
    }
    onClose?()
  }

  @objc private func closePane(_ sender: Any?) { onClose?() }
}

private final class PaneColorPopover {
  private let popover = NSPopover()
  private let palette = PaneColorPaletteView()
  var onChoose: ((PaneChromeColor) -> Void)?
  /// A color was kept, or Escape undid the preview; focus goes back to the pane.
  var onCommit: (() -> Void)?
  /// Escape: put back the color the pane had when the popover opened.
  var onCancel: (() -> Void)?

  init() {
    popover.behavior = .transient
    popover.animates = false
    palette.onPreview = { [weak self] color in self?.onChoose?(color) }
    palette.onPick = { [weak self] color in
      guard let self else { return }
      onChoose?(color)
      popover.close()
      onCommit?()
    }
    palette.onCancel = { [weak self] in
      guard let self else { return }
      onCancel?()
      popover.close()
      onCommit?()
    }
    palette.closeKeyViewLoop()
    popover.contentViewController = NSViewController()
    popover.contentViewController?.view = palette
    popover.contentSize = palette.frame.size
  }

  /// Opens below `anchor` in `view` and moves keyboard focus into the grid.
  func present(from view: NSView, anchor: NSRect, selected: PaneChromeColor) {
    palette.selected = selected
    popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    guard let window = palette.window else { return }
    window.makeKey()
    palette.focusSelection()
  }

  func dismiss() {
    popover.close()
  }
}

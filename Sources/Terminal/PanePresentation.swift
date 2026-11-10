import AppKit

/// The complete visual policy for a pane lives here: its ephemeral color,
/// readable foreground, title header geometry, and inactive presentation.
/// Nothing in this type is persisted, so reopening a session starts with the
/// neutral charcoal header even when regular preferences are restored.
struct PaneChromeColor: Equatable, Hashable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  static let charcoal = PaneChromeColor(hex: "#36383C")!

  init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  init?(hex: String) {
    let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.first == "#" else { return nil }
    let digits = String(value.dropFirst())
    let expanded: String
    switch digits.count {
    case 3:
      expanded = digits.reduce(into: "") { $0.append($1); $0.append($1) }
    case 6:
      expanded = digits
    default:
      return nil
    }
    guard expanded.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF".unicodeScalars.contains($0) }),
      let value = UInt32(expanded, radix: 16)
    else { return nil }
    self.init(red: UInt8((value >> 16) & 0xff), green: UInt8((value >> 8) & 0xff), blue: UInt8(value & 0xff))
  }

  var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
  var nsColor: NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
  }

  private var relativeLuminance: CGFloat {
    func linear(_ channel: UInt8) -> CGFloat {
      let value = CGFloat(channel) / 255
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// Choose the higher-contrast system-independent foreground for every custom
  /// value rather than assuming a light or dark user-supplied color.
  var readableForeground: NSColor {
    let whiteContrast = 1.05 / (relativeLuminance + 0.05)
    let blackContrast = (relativeLuminance + 0.05) / 0.05
    return whiteContrast >= blackContrast ? .white : .black
  }
}

struct PaneColorChoice: Equatable {
  let name: String
  let color: PaneChromeColor

  static let palette: [PaneColorChoice] = [
    .init(name: "Onyx", color: .init(hex: "#18191C")!),
    .init(name: "Graphite", color: .init(hex: "#26272B")!),
    .init(name: "Charcoal", color: .charcoal),
    .init(name: "Slate", color: .init(hex: "#4A5568")!),
    .init(name: "Steel", color: .init(hex: "#3F5E72")!),
    .init(name: "Ocean", color: .init(hex: "#2E6376")!),
    .init(name: "Teal", color: .init(hex: "#2B6A65")!),
    .init(name: "Pine", color: .init(hex: "#41684F")!),
    .init(name: "Moss", color: .init(hex: "#697044")!),
    .init(name: "Olive", color: .init(hex: "#766B3C")!),
    .init(name: "Ochre", color: .init(hex: "#826334")!),
    .init(name: "Amber", color: .init(hex: "#8A5430")!),
    .init(name: "Rust", color: .init(hex: "#82483A")!),
    .init(name: "Brick", color: .init(hex: "#7C4145")!),
    .init(name: "Berry", color: .init(hex: "#713F5D")!),
    .init(name: "Plum", color: .init(hex: "#5F466E")!),
    .init(name: "Violet", color: .init(hex: "#554F7A")!),
    .init(name: "Indigo", color: .init(hex: "#45547C")!),
  ]
}

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
  private var color = PaneChromeColor.charcoal
  private let colorPopover = PaneColorPopover()

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
    header.onChooseColor = { [weak self] in self?.showColorPopover() }
    header.onClose = { [weak self] in self?.onClose?() }
    colorPopover.onChoose = { [weak self] color in self?.setColor(color) }
    colorPopover.onCommit = { [weak self] in self?.onSelect?() }
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

  func configure(showHeader: Bool, active: Bool, inactiveDim: PaneInactiveDim) {
    let changed = showsHeader != showHeader
    let presentationChanged = changed || isActive != active || self.inactiveDim != inactiveDim
    showsHeader = showHeader
    isActive = active
    self.inactiveDim = inactiveDim
    header.isHidden = !showHeader
    if !showHeader { colorPopover.dismiss() }
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

  private func setColor(_ color: PaneChromeColor) {
    guard self.color != color else { return }
    self.color = color
    updateHeader()
  }

  private func updateHeader() {
    let fullOpacity = isActive || isHovered
    let alpha = fullOpacity ? 1 : inactiveDim.alpha
    if canvas.alphaValue != alpha { canvas.alphaValue = alpha }
    if header.alphaValue != alpha { header.alphaValue = alpha }
    header.configure(title: title, color: color)
  }

  private func showColorPopover() {
    onSelect?()
    colorPopover.present(from: header, selected: color)
  }

}

private final class PaneHeaderView: NSView {
  private let titleField = NSTextField(labelWithString: "Terminal")
  private let closeButton = NSButton(title: "", target: nil, action: nil)
  private var color = PaneChromeColor.charcoal
  var onSelect: (() -> Void)?
  var onChooseColor: (() -> Void)?
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
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override var isFlipped: Bool { true }

  func configure(title: String, color: PaneChromeColor) {
    guard titleField.stringValue != title || self.color != color else { return }
    self.color = color
    titleField.stringValue = title
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
    onChooseColor?()
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

/// The swatch grid and custom-hex row shown in the pane color popover. Its
/// size is whatever the swatches need, so the popover has no slack around them.
final class PaneColorPaletteView: NSView, NSTextFieldDelegate {
  static let columns = 6
  static let swatchSide: CGFloat = 24
  static let swatchSpacing: CGFloat = 6
  static let padding: CGFloat = 12

  private let hexInput = NSTextField(string: "")
  /// A valid hex was typed; the choice is not final yet.
  var onPreview: ((PaneChromeColor) -> Void)?
  /// A swatch was clicked or a valid hex was committed with Return.
  var onPick: ((PaneChromeColor) -> Void)?

  var hex: String {
    get { hexInput.stringValue }
    set { hexInput.stringValue = newValue }
  }

  init() {
    super.init(frame: .zero)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Self.swatchSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
    ])
    let palette = PaneColorChoice.palette
    for start in stride(from: 0, to: palette.count, by: Self.columns) {
      let row = NSStackView()
      row.orientation = .horizontal
      row.spacing = Self.swatchSpacing
      for choice in palette[start..<min(start + Self.columns, palette.count)] {
        let swatch = NSButton(title: "", target: self, action: #selector(selectSwatch(_:)))
        swatch.identifier = NSUserInterfaceItemIdentifier(choice.color.hex)
        swatch.bezelStyle = .shadowlessSquare
        swatch.isBordered = false
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = choice.color.nsColor.cgColor
        swatch.layer?.cornerRadius = 4
        // The darkest neutrals sit close to the popover's own background.
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        swatch.widthAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        swatch.setAccessibilityLabel("\(choice.name) pane color")
        swatch.setAccessibilityIdentifier("no.helgesverre.terminal.pane.color.\(choice.name.lowercased())")
        swatch.toolTip = choice.name
        row.addArrangedSubview(swatch)
      }
      stack.addArrangedSubview(row)
    }
    let customLabel = NSTextField(labelWithString: "Custom hex")
    customLabel.font = .systemFont(ofSize: 11)
    customLabel.textColor = TerminalTheme.color(TerminalTheme.secondary)
    customLabel.setContentHuggingPriority(.required, for: .horizontal)
    let custom = NSStackView(views: [customLabel, hexInput])
    custom.orientation = .horizontal
    custom.alignment = .centerY
    custom.spacing = 8
    // The field takes whatever the swatch grid leaves, so both share one edge.
    hexInput.setContentHuggingPriority(.defaultLow, for: .horizontal)
    hexInput.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hexInput.placeholderString = "#RRGGBB"
    hexInput.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    hexInput.delegate = self
    hexInput.target = self
    hexInput.action = #selector(commitCustomHex(_:))
    hexInput.setAccessibilityLabel("Custom pane color hex")
    hexInput.setAccessibilityIdentifier("no.helgesverre.terminal.pane.color.hex")
    stack.addArrangedSubview(custom)
    stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    let gridWidth = CGFloat(Self.columns) * Self.swatchSide + CGFloat(Self.columns - 1) * Self.swatchSpacing
    NSLayoutConstraint.activate([
      stack.widthAnchor.constraint(equalToConstant: gridWidth),
      custom.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    setFrameSize(fittingSize)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

  @objc private func selectSwatch(_ sender: NSButton) {
    guard let value = sender.identifier?.rawValue, let color = PaneChromeColor(hex: value) else { return }
    onPick?(color)
  }

  @objc private func commitCustomHex(_ sender: Any?) {
    // Invalid text stays editable without forwarding Return to the terminal or
    // emitting its input-rejection beep. A valid custom color applies exactly
    // once and restores the canvas as the first responder.
    guard let color = PaneChromeColor(hex: hexInput.stringValue) else { return }
    onPick?(color)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let color = PaneChromeColor(hex: hexInput.stringValue) else { return }
    onPreview?(color)
  }
}

private final class PaneColorPopover {
  private let popover = NSPopover()
  private let palette = PaneColorPaletteView()
  var onChoose: ((PaneChromeColor) -> Void)?
  var onCommit: (() -> Void)?

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
    popover.contentViewController = NSViewController()
    popover.contentViewController?.view = palette
    popover.contentSize = palette.frame.size
  }

  func present(from view: NSView, selected: PaneChromeColor) {
    palette.hex = selected.hex
    popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
  }

  func dismiss() {
    popover.close()
  }
}

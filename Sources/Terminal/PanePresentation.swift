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
    addSubview(header)
    header.onSelect = { [weak self] in self?.onSelect?() }
    header.onChooseColor = { [weak self] in self?.showColorPopover() }
    colorPopover.onChoose = { [weak self] color in self?.setColor(color) }
    colorPopover.onCommit = { [weak self] in self?.onSelect?() }
    updateHeader()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override var isFlipped: Bool { true }

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
  private let colorButton = NSButton(title: "", target: nil, action: nil)
  private var color = PaneChromeColor.charcoal
  var onSelect: (() -> Void)?
  var onChooseColor: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    titleField.font = .systemFont(ofSize: 11, weight: .medium)
    titleField.lineBreakMode = .byTruncatingTail
    titleField.setAccessibilityLabel("Pane title")
    titleField.setAccessibilityIdentifier("no.helgesverre.terminal.pane-title")
    addSubview(titleField)
    colorButton.bezelStyle = .shadowlessSquare
    colorButton.isBordered = false
    colorButton.target = self
    colorButton.action = #selector(chooseColor(_:))
    colorButton.setAccessibilityLabel("Choose pane color")
    colorButton.setAccessibilityIdentifier("no.helgesverre.terminal.pane.choose-color")
    colorButton.toolTip = "Choose pane color"
    colorButton.wantsLayer = true
    colorButton.layer?.cornerRadius = 4
    addSubview(colorButton)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override var isFlipped: Bool { true }

  func configure(title: String, color: PaneChromeColor) {
    guard titleField.stringValue != title || self.color != color else { return }
    self.color = color
    titleField.stringValue = title
    titleField.textColor = color.readableForeground
    colorButton.layer?.backgroundColor = color.readableForeground.withAlphaComponent(0.72).cgColor
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    colorButton.frame = NSRect(x: 6, y: 4, width: 12, height: 12)
    titleField.frame = NSRect(x: 24, y: 2, width: max(0, bounds.width - 30), height: 16)
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

  @objc private func chooseColor(_ sender: Any?) { onChooseColor?() }
}

private final class PaneColorPopover: NSObject, NSTextFieldDelegate {
  private let popover = NSPopover()
  private let hexInput = NSTextField(string: "")
  var onChoose: ((PaneChromeColor) -> Void)?
  var onCommit: (() -> Void)?

  override init() {
    super.init()
    popover.behavior = .transient
    popover.animates = true
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 208, height: 150))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])
    for choices in stride(from: 0, to: PaneColorChoice.palette.count, by: 4) {
      let row = NSStackView()
      row.orientation = .horizontal
      row.spacing = 6
      for choice in PaneColorChoice.palette[choices..<min(choices + 4, PaneColorChoice.palette.count)] {
        let swatch = NSButton(title: "", target: self, action: #selector(selectSwatch(_:)))
        swatch.identifier = NSUserInterfaceItemIdentifier(choice.color.hex)
        swatch.bezelStyle = .shadowlessSquare
        swatch.isBordered = false
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = choice.color.nsColor.cgColor
        swatch.layer?.cornerRadius = 4
        swatch.widthAnchor.constraint(equalToConstant: 38).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
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
    let custom = NSStackView(views: [customLabel, hexInput])
    custom.orientation = .horizontal
    custom.alignment = .centerY
    custom.spacing = 8
    hexInput.widthAnchor.constraint(equalToConstant: 92).isActive = true
    hexInput.placeholderString = "#RRGGBB"
    hexInput.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    hexInput.delegate = self
    hexInput.target = self
    hexInput.action = #selector(commitCustomHex(_:))
    hexInput.setAccessibilityLabel("Custom pane color hex")
    hexInput.setAccessibilityIdentifier("no.helgesverre.terminal.pane.color.hex")
    stack.addArrangedSubview(custom)
    popover.contentViewController = NSViewController()
    popover.contentViewController?.view = content
    popover.contentSize = content.bounds.size
  }

  func present(from view: NSView, selected: PaneChromeColor) {
    hexInput.stringValue = selected.hex
    popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
  }

  func dismiss() {
    popover.close()
  }

  @objc private func selectSwatch(_ sender: NSButton) {
    guard let value = sender.identifier?.rawValue, let color = PaneChromeColor(hex: value) else { return }
    onChoose?(color)
    popover.close()
    onCommit?()
  }

  @objc private func commitCustomHex(_ sender: Any?) {
    // Invalid text stays editable without forwarding Return to the terminal or
    // emitting its input-rejection beep. A valid custom color applies exactly
    // once and restores the canvas as the first responder.
    guard let color = PaneChromeColor(hex: hexInput.stringValue) else { return }
    onChoose?(color)
    popover.close()
    onCommit?()
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let color = PaneChromeColor(hex: hexInput.stringValue) else { return }
    onChoose?(color)
  }
}

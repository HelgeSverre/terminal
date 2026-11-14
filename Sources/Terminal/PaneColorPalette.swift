import AppKit
import TerminalUI

extension PaneChromeColor {
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

/// One color in the palette grid. The grid is a single Tab stop: only the
/// swatch marked `isTabStop` takes keyboard focus from Tab, whatever the
/// system's Keyboard Navigation setting, and arrows move between swatches.
final class PaneColorSwatch: NSButton {
  enum Move { case previous, next, up, down, first, last }

  var isTabStop = false
  var onMove: ((Move) -> Void)?
  /// Escape; nil passes the key on, so a window's Cancel button still gets it.
  var onCancel: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { isTabStop && !isHiddenOrHasHiddenAncestor }
  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
  }

  override func keyDown(with event: NSEvent) {
    let moves: [UInt16: Move] = [123: .previous, 124: .next, 126: .up, 125: .down, 115: .first, 119: .last]
    if let move = moves[event.keyCode], let onMove {
      onMove(move)
    } else if [36, 49, 76].contains(event.keyCode) {  // Return, Space, keypad Enter
      performClick(nil)
    } else if event.keyCode == 53, let onCancel {
      onCancel()
    } else {
      super.keyDown(with: event)
    }
  }
}

/// The swatch grid and custom-hex row for choosing a pane color, shown in the
/// pane color popover and in Settings. Its size is whatever the swatches need,
/// so a container has no slack around them.
final class PaneColorPaletteView: NSView, NSTextFieldDelegate {
  static let columns = 6
  static let swatchSide: CGFloat = 24
  static let swatchSpacing: CGFloat = 6
  static let padding: CGFloat = 12

  private let hexInput = NSTextField(string: "")
  private(set) var swatches: [PaneColorSwatch] = []
  /// A valid hex was typed or an arrow key moved to a swatch; the choice is not final yet.
  var onPreview: ((PaneChromeColor) -> Void)?
  /// A swatch was clicked or a valid hex was committed with Return.
  var onPick: ((PaneChromeColor) -> Void)?
  /// Escape in the grid or the hex field. Nil leaves Escape to the window.
  var onCancel: (() -> Void)? {
    didSet { for swatch in swatches { swatch.onCancel = onCancel } }
  }

  /// The current choice: ringed if it is a palette color, and always shown
  /// as hex. Picking a swatch or entering a valid hex updates it.
  var selected: PaneChromeColor? {
    didSet {
      if let selected, PaneChromeColor(hex: hexInput.stringValue) != selected {
        hexInput.stringValue = selected.hex
      }
      markSelection()
    }
  }

  /// `padding` surrounds the grid; a host that supplies its own margins passes zero.
  init(padding: CGFloat = PaneColorPaletteView.padding) {
    super.init(frame: .zero)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
    ])
    let grid = NSStackView()
    grid.orientation = .vertical
    grid.alignment = .leading
    grid.spacing = Self.swatchSpacing
    grid.setAccessibilityElement(true)
    grid.setAccessibilityRole(.radioGroup)
    grid.setAccessibilityLabel("Pane color")
    let palette = PaneColorChoice.palette
    for start in stride(from: 0, to: palette.count, by: Self.columns) {
      let row = NSStackView()
      row.orientation = .horizontal
      row.spacing = Self.swatchSpacing
      for choice in palette[start..<min(start + Self.columns, palette.count)] {
        let swatch = PaneColorSwatch(title: "", target: self, action: #selector(selectSwatch(_:)))
        swatch.identifier = NSUserInterfaceItemIdentifier(choice.color.hex)
        swatch.bezelStyle = .shadowlessSquare
        swatch.isBordered = false
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = choice.color.nsColor.cgColor
        swatch.layer?.cornerRadius = 4
        swatch.widthAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        swatch.setAccessibilityRole(.radioButton)
        swatch.setAccessibilityLabel("\(choice.name) pane color")
        swatch.setAccessibilityIdentifier("no.helgesverre.terminal.pane.color.\(choice.name.lowercased())")
        swatch.toolTip = choice.name
        swatch.onMove = { [weak self, weak swatch] move in
          guard let self, let swatch else { return }
          self.move(move, from: swatch)
        }
        row.addArrangedSubview(swatch)
        swatches.append(swatch)
      }
      grid.addArrangedSubview(row)
    }
    stack.addArrangedSubview(grid)
    let customLabel = NSTextField(labelWithString: "Custom HEX")
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
    let gridWidth = CGFloat(Self.columns) * Self.swatchSide + CGFloat(Self.columns - 1) * Self.swatchSpacing
    NSLayoutConstraint.activate([
      stack.widthAnchor.constraint(equalToConstant: gridWidth),
      custom.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    // Tab order runs through every swatch and on to the hex field; only the
    // grid's stop can take focus, so Tab visits the grid once. A loop built
    // by the window would link only the stop it saw at that moment.
    for (swatch, next) in zip(swatches, swatches.dropFirst()) { swatch.nextKeyView = next }
    swatches.last?.nextKeyView = hexInput
    markSelection()
    setFrameSize(fittingSize)
  }

  /// Where Tab enters the palette from the view before it: the grid. Only
  /// the grid's stop takes focus, so AppKit skips on to it.
  var firstKeyView: NSView { swatches.first ?? hexInput }
  /// The palette's last key view, whose `nextKeyView` continues the host's loop.
  var lastKeyView: NSView { hexInput }

  /// For a palette that is the whole window, as in the popover: Tab from the
  /// hex field returns to the grid.
  func closeKeyViewLoop() { lastKeyView.nextKeyView = firstKeyView }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

  /// The swatch Tab lands on: the selected palette color, else the first.
  var tabStop: PaneColorSwatch? { swatches.first(where: \.isTabStop) ?? swatches.first }

  /// Puts keyboard focus on the grid's Tab stop.
  @discardableResult
  func focusSelection() -> Bool {
    guard let window, let tabStop else { return false }
    return window.makeFirstResponder(tabStop)
  }

  private func markSelection() {
    let chosenIndex = selected.flatMap { color in swatches.firstIndex { $0.identifier?.rawValue == color.hex } }
    // A custom color keeps the previous Tab stop; there is no swatch for it.
    let stopIndex = chosenIndex ?? swatches.firstIndex(where: \.isTabStop) ?? 0
    for (index, swatch) in swatches.enumerated() {
      let chosen = index == chosenIndex
      // Unselected swatches keep a faint outline: the darkest neutrals sit
      // close to the background they are shown on.
      swatch.layer?.borderWidth = chosen ? 2 : 1
      swatch.layer?.borderColor = chosen
        ? TerminalTheme.color(TerminalTheme.accent).cgColor
        : NSColor.white.withAlphaComponent(0.14).cgColor
      swatch.setAccessibilityValue(NSNumber(value: chosen))
      swatch.isTabStop = index == stopIndex
    }
  }

  /// Arrow keys walk the grid in reading order and stop at its edges. Each
  /// step previews its color; Return or Space keeps it.
  private func move(_ move: PaneColorSwatch.Move, from swatch: PaneColorSwatch) {
    guard let index = swatches.firstIndex(where: { $0 === swatch }) else { return }
    let last = swatches.count - 1
    let target = switch move {
    case .previous: max(0, index - 1)
    case .next: min(last, index + 1)
    case .up: index >= Self.columns ? index - Self.columns : index
    case .down: index + Self.columns <= last ? index + Self.columns : index
    case .first: 0
    case .last: last
    }
    let destination = swatches[target]
    guard let value = destination.identifier?.rawValue, let color = PaneChromeColor(hex: value) else { return }
    selected = color
    window?.makeFirstResponder(destination)
    onPreview?(color)
  }

  @objc private func selectSwatch(_ sender: NSButton) {
    guard let value = sender.identifier?.rawValue, let color = PaneChromeColor(hex: value) else { return }
    selected = color
    onPick?(color)
  }

  @objc private func commitCustomHex(_ sender: Any?) {
    // Invalid text stays editable without forwarding Return to the terminal or
    // emitting its input-rejection beep. A valid custom color applies exactly
    // once and restores the canvas as the first responder.
    guard let color = PaneChromeColor(hex: hexInput.stringValue) else { return }
    selected = color
    onPick?(color)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let color = PaneChromeColor(hex: hexInput.stringValue) else { return }
    selected = color
    onPreview?(color)
  }

  /// Escape in the hex field reaches the field editor first; hand it to the host.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)), let onCancel else { return false }
    onCancel()
    return true
  }
}

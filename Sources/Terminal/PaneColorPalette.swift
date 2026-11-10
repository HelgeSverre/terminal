import AppKit

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

/// The swatch grid and custom-hex row for choosing a pane color, shown in the
/// pane color popover and in Settings. Its size is whatever the swatches need,
/// so a container has no slack around them.
final class PaneColorPaletteView: NSView, NSTextFieldDelegate {
  static let columns = 6
  static let swatchSide: CGFloat = 24
  static let swatchSpacing: CGFloat = 6
  static let padding: CGFloat = 12

  private let hexInput = NSTextField(string: "")
  private var swatches: [NSButton] = []
  /// A valid hex was typed; the choice is not final yet.
  var onPreview: ((PaneChromeColor) -> Void)?
  /// A swatch was clicked or a valid hex was committed with Return.
  var onPick: ((PaneChromeColor) -> Void)?

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
    stack.spacing = Self.swatchSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
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
        swatch.widthAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        swatch.setAccessibilityLabel("\(choice.name) pane color")
        swatch.setAccessibilityIdentifier("no.helgesverre.terminal.pane.color.\(choice.name.lowercased())")
        swatch.toolTip = choice.name
        row.addArrangedSubview(swatch)
        swatches.append(swatch)
      }
      stack.addArrangedSubview(row)
    }
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
    stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    let gridWidth = CGFloat(Self.columns) * Self.swatchSide + CGFloat(Self.columns - 1) * Self.swatchSpacing
    NSLayoutConstraint.activate([
      stack.widthAnchor.constraint(equalToConstant: gridWidth),
      custom.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    markSelection()
    setFrameSize(fittingSize)
  }

  private func markSelection() {
    for swatch in swatches {
      let chosen = selected.map { $0.hex == swatch.identifier?.rawValue } ?? false
      // Unselected swatches keep a faint outline: the darkest neutrals sit
      // close to the background they are shown on.
      swatch.layer?.borderWidth = chosen ? 2 : 1
      swatch.layer?.borderColor = chosen
        ? TerminalTheme.color(TerminalTheme.accent).cgColor
        : NSColor.white.withAlphaComponent(0.14).cgColor
      swatch.setAccessibilityValue(chosen ? "selected" : "")
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

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
}

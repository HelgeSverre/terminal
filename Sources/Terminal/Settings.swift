import AppKit

// A separate native utility window keeps the terminal usable while editing settings.
final class TerminalSettingsWindow: NSWindowController, NSTextFieldDelegate {
  private let fontSize = FontSizeInput()
  private let familyName = NSTextField(labelWithString: "Obel Mono")
  private let historyRows = SettingsTextField(value: "")
  private let startingDirectory = SettingsTextField(value: "")
  private let wordCharacters = SettingsTextField(value: "")
  private let option = NSButton(
    checkboxWithTitle: "Option key sends Escape", target: nil, action: nil)
  private let followTail = NSButton(
    checkboxWithTitle: "Scroll to bottom when typing", target: nil, action: nil)
  private let showPaneTitles = NSButton(
    checkboxWithTitle: "Show pane titles when split", target: nil, action: nil)
  private let inactivePaneDim = SettingsSegmentedControl(
    labels: PaneInactiveDim.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
  private let defaultPaneColor = PaneColorPaletteView(padding: 0)
  private let error = NSTextField(wrappingLabelWithString: "")
  private let apply = SettingsActionButton(title: "Apply", primary: true, target: nil, action: nil)
  private let onApply: (TerminalPreferences) -> Void
  init(onApply: @escaping (TerminalPreferences) -> Void) {
    self.onApply = onApply
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Settings"
    window.setAccessibilityIdentifier("no.helgesverre.terminal.settings")
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    TerminalTheme.apply(to: window)
    window.backgroundColor = TerminalTheme.color(TerminalTheme.Settings.surface)
    fontSize.onChange = { [weak self] in self?.validate() }
    defaultPaneColor.onPick = { [weak self] _ in self?.validate() }
    defaultPaneColor.onPreview = { [weak self] _ in self?.validate() }
    let content = NSView()
    window.contentView = content
    let sidebar = NSStackView()
    sidebar.orientation = .vertical
    sidebar.alignment = .leading
    sidebar.spacing = 2
    sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 8, bottom: 12, right: 8)
    let heading = label("Settings", size: 17, weight: .medium)
    let headingRow = NSView()
    headingRow.addSubview(heading)
    heading.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: headingRow.leadingAnchor, constant: 12),
      heading.topAnchor.constraint(equalTo: headingRow.topAnchor),
      heading.bottomAnchor.constraint(equalTo: headingRow.bottomAnchor, constant: -12),
    ])
    sidebar.addArrangedSubview(headingRow)
    let main = NSView()
    let divider = NSBox()
    divider.boxType = .separator
    for view in [sidebar, divider, main] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      sidebar.topAnchor.constraint(equalTo: content.topAnchor),
      sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      sidebar.widthAnchor.constraint(equalToConstant: TerminalTheme.Settings.sidebarWidth),
      divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      divider.topAnchor.constraint(equalTo: content.topAnchor),
      divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      divider.widthAnchor.constraint(equalToConstant: 1),
      main.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
      main.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      main.topAnchor.constraint(equalTo: content.topAnchor),
      main.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      headingRow.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16),
    ])
    for (index, section) in sections.enumerated() {
      let button = SettingsNavigationButton(title: section.title, target: self, action: #selector(selectSection(_:)))
      button.setButtonType(.radio)
      button.tag = index
      button.image = NSImage(systemSymbolName: section.icon, accessibilityDescription: nil)
      button.imagePosition = .imageLeading
      button.imageHugsTitle = true
      button.setAccessibilityElement(true)
      button.setAccessibilityRole(.radioButton)
      button.setAccessibilityLabel(section.title)
      button.setAccessibilityIdentifier("no.helgesverre.terminal.settings.section.\(section.id)")
      button.onMove = { [weak self] offset in
        guard let self else { return }
        let next = min(self.navigation.count - 1, max(0, index + offset))
        self.showSection(next)
        self.window?.makeFirstResponder(self.navigation[next])
      }
      navigation.append(button)
      sidebar.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true
      button.heightAnchor.constraint(equalToConstant: 36).isActive = true
      let pane = NSStackView()
      pane.orientation = .vertical
      pane.alignment = .leading
      pane.spacing = 4
      pane.addArrangedSubview(label(section.title, size: 17, weight: .medium))
      let subtitle = label(section.subtitle, size: 12, color: TerminalTheme.Settings.muted)
      pane.addArrangedSubview(subtitle)
      pane.setCustomSpacing(16, after: subtitle)
      for field in section.fields {
        let row = render(field)
        pane.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
      }
      pane.translatesAutoresizingMaskIntoConstraints = false
      main.addSubview(pane)
      NSLayoutConstraint.activate([
        pane.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
        pane.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
        pane.topAnchor.constraint(equalTo: main.topAnchor, constant: 20),
      ])
      panes.append(pane)
    }
    sidebar.addArrangedSubview(NSView())
    error.font = .systemFont(ofSize: 12)
    error.textColor = TerminalTheme.color(TerminalTheme.danger)
    error.setAccessibilityLabel("Settings validation")
    error.setAccessibilityIdentifier("no.helgesverre.terminal.settings.validation")
    let cancel = SettingsActionButton(title: "Cancel", target: self, action: #selector(Self.cancel(_:)))
    cancel.setAccessibilityIdentifier("no.helgesverre.terminal.settings.cancel")
    cancel.keyEquivalent = "\u{1b}"
    apply.setAccessibilityIdentifier("no.helgesverre.terminal.settings.apply")
    apply.keyEquivalent = "\r"
    apply.target = self
    apply.action = #selector(save(_:))
    let buttons = NSStackView(views: [cancel, apply])
    buttons.spacing = 8
    for view in [error, buttons] {
      view.translatesAutoresizingMaskIntoConstraints = false
      main.addSubview(view)
    }
    NSLayoutConstraint.activate([
      buttons.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
      buttons.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -16),
      error.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
      error.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
      error.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
      error.heightAnchor.constraint(equalToConstant: 32),
    ])
    for pane in panes {
      pane.bottomAnchor.constraint(lessThanOrEqualTo: error.topAnchor, constant: -16).isActive = true
    }
    showSection(0)
    window.initialFirstResponder = navigation.first
    window.center()
  }
  // Controls are the draft: created once, retained while panes are hidden, and read
  // together by value(). A section or existing field type needs only a schema entry.
  private struct Section {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let fields: [Field]
  }
  private struct Presentation {
    let id: String
    let accessibilityLabel: String
    var hint: String? = nil
    var width: CGFloat? = nil
    func apply(to view: NSView) {
      view.setAccessibilityIdentifier("no.helgesverre.terminal.settings.\(id)")
      view.setAccessibilityLabel(accessibilityLabel)
      view.toolTip = hint
      if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
    }
  }
  private enum Field {
    case text(String, String?, NSTextField, Presentation, chooseDirectory: Bool)
    case number(String, String?, NSView, Presentation, suffix: String)
    case check(String, NSButton, Presentation)
    case segment(String, NSSegmentedControl, Presentation)
    case readOnly(String, NSTextField)
    case palette(String, String?, PaneColorPaletteView, Presentation)
    case note(String)
  }
  private var navigation: [SettingsNavigationButton] = []
  private var panes: [NSStackView] = []
  private lazy var sections: [Section] = [
    Section(id: "general", icon: "folder", title: "General", subtitle: "Startup and default directory.", fields: [
      .text("Startup directory", "Folder to open on launch", startingDirectory,
        Presentation(id: "starting-directory", accessibilityLabel: "Starting directory",
          hint: "Blank uses your home directory. Existing shells keep their current directory.", width: 150), chooseDirectory: true),
      .note("Leave blank to use your home directory. Existing shells keep their current directory."),
    ]),
    Section(id: "text", icon: "textformat", title: "Text", subtitle: "Font and word selection.", fields: [
      .readOnly("Font", familyName),
      .number("Size", nil, fontSize,
        Presentation(id: "font-size", accessibilityLabel: "Font size in points",
          hint: "8–40 pt. Use Up and Down to adjust by one point.", width: 76), suffix: "pt"),
      .text("Word characters", "Extra characters treated as word characters", wordCharacters,
        Presentation(id: "word-characters", accessibilityLabel: "Extra word characters",
          hint: "Additional characters included when selecting words. Blank uses Unicode word boundaries.", width: 180), chooseDirectory: false),
    ]),
    Section(id: "scrollback", icon: "clock.arrow.circlepath", title: "Scrollback", subtitle: "How much output is kept per session.", fields: [
      .number("Scrollback", "Up to 50,000 rows or 64 MiB per session", historyRows,
        Presentation(id: "scrollback-rows", accessibilityLabel: "Scrollback rows", hint: "0–50,000 rows", width: 100), suffix: "rows"),
      .check("Scroll to bottom when typing", followTail,
        Presentation(id: "follow-tail-on-input", accessibilityLabel: "Scroll to bottom when typing")),
    ]),
    Section(id: "panes", icon: "rectangle.split.2x1", title: "Panes", subtitle: "Split panes and focus behavior.", fields: [
      .check("Show pane titles when split", showPaneTitles,
        Presentation(id: "show-pane-titles", accessibilityLabel: "Show pane titles when split")),
      .segment("Inactive dim", inactivePaneDim,
        Presentation(id: "inactive-pane-dim", accessibilityLabel: "Inactive pane dimming")),
      .palette("Default color", "Header color of panes without their own", defaultPaneColor,
        Presentation(id: "default-pane-color", accessibilityLabel: "Default pane color")),
    ]),
    Section(id: "keyboard", icon: "keyboard", title: "Keyboard", subtitle: "Key mapping.", fields: [
      .check("Option key sends Escape", option,
        Presentation(id: "option-sends-escape", accessibilityLabel: "Option key sends Escape",
          hint: "Off uses native Option characters. Option arrows always move by word.")),
      .note("Off uses native Option characters. Option arrows always move by word."),
    ]),
  ]
  private func configure(_ field: NSTextField, presentation: Presentation) {
    field.delegate = self
    presentation.apply(to: field)
  }
  private func label(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .regular,
                     color: UInt32 = TerminalTheme.Settings.text) -> NSTextField {
    let result = NSTextField(wrappingLabelWithString: text)
    result.font = .systemFont(ofSize: size, weight: weight)
    result.textColor = TerminalTheme.color(color)
    return result
  }
  private func render(_ field: Field) -> NSView {
    let title: String
    var helper: String?
    let control: NSView
    switch field {
    case let .text(name, hint, input, presentation, choose):
      title = name; helper = hint
      configure(input, presentation: presentation)
      if choose {
        let button = SettingsActionButton(title: "Choose…", target: self, action: #selector(chooseDirectory(_:)))
        button.setAccessibilityLabel("Choose starting directory")
        button.setAccessibilityIdentifier("no.helgesverre.terminal.settings.choose-directory")
        let group = NSStackView(views: [input, button])
        group.spacing = 8
        control = group
      } else { control = input }
    case let .number(name, hint, input, presentation, suffix):
      title = name; helper = hint
      if let number = input as? FontSizeInput {
        presentation.apply(to: number.textField)
      } else if let text = input as? NSTextField {
        configure(text, presentation: presentation)
        text.alignment = .right
      }
      let group = NSStackView(views: [input, label(suffix, size: 13, color: TerminalTheme.Settings.muted)])
      group.spacing = 8
      control = group
    case let .check(name, input, presentation):
      title = name; control = input
      input.title = ""
      input.contentTintColor = TerminalTheme.color(TerminalTheme.Settings.text)
      presentation.apply(to: input)
    case let .segment(name, input, presentation):
      title = name; control = input
      presentation.apply(to: input)
      input.controlSize = .large
      input.font = .systemFont(ofSize: 13)
      input.segmentStyle = .rounded
      input.selectedSegmentBezelColor = TerminalTheme.color(TerminalTheme.Settings.text)
      for index in 0..<input.segmentCount { input.setWidth(48, forSegment: index) }
      input.heightAnchor.constraint(equalToConstant: 32).isActive = true
    case let .palette(name, hint, input, presentation):
      title = name; helper = hint; control = input
      presentation.apply(to: input)
      input.setAccessibilityElement(true)
      input.setAccessibilityRole(.group)
    case let .readOnly(name, input):
      title = name; control = input
      input.font = .systemFont(ofSize: 14)
      input.textColor = TerminalTheme.color(TerminalTheme.Settings.text)
    case let .note(text):
      title = ""
      control = label(text, size: 12, color: TerminalTheme.Settings.muted)
    }
    let row = NSView()
    let separator = NSView()
    separator.wantsLayer = true
    separator.layer?.backgroundColor = TerminalTheme.color(TerminalTheme.Settings.border).cgColor
    let labels = NSStackView()
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 3
    labels.addArrangedSubview(label(title, color: TerminalTheme.Settings.secondary))
    if let helper { labels.addArrangedSubview(label(helper, size: 12, color: TerminalTheme.Settings.muted)) }
    for view in labels.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
    }
    for view in [separator, labels, control] {
      view.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(view)
    }
    let bottom = control.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10)
    bottom.priority = .defaultHigh
    NSLayoutConstraint.activate([
      separator.topAnchor.constraint(equalTo: row.topAnchor),
      separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
      labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      labels.widthAnchor.constraint(equalToConstant: TerminalTheme.Settings.labelWidth),
      labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
      labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
      labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      control.leadingAnchor.constraint(equalTo: labels.trailingAnchor, constant: 16),
      control.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
      control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
      control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
      control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48), bottom,
    ])
    return row
  }
  @objc private func selectSection(_ sender: NSButton) { showSection(sender.tag) }
  private func showSection(_ index: Int) {
    // End field editing before hiding its pane so an editor never floats over a new section.
    guard window?.makeFirstResponder(nil) != false else { return }
    for (item, pane) in panes.enumerated() {
      pane.isHidden = item != index
      navigation[item].state = item == index ? .on : .off
      navigation[item].setAccessibilityValue(NSNumber(value: item == index))
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  func reload() {
    window?.endEditing(for: nil)
    let prefs = TerminalPreferences.load()
    fontSize.stringValue = String(format: "%g", Double(prefs.fontSize))
    familyName.stringValue = TerminalFont.appKit(size: prefs.fontSize).familyName ?? "Menlo"
    historyRows.stringValue = String(prefs.historyRows)
    option.state = prefs.optionSendsEscape ? .on : .off
    followTail.state = prefs.followTailOnInput ? .on : .off
    showPaneTitles.state = prefs.showPaneTitles ? .on : .off
    inactivePaneDim.selectedSegment = PaneInactiveDim.allCases.firstIndex(of: prefs.inactivePaneDim) ?? 1
    defaultPaneColor.selected = prefs.defaultPaneColor
    startingDirectory.stringValue = prefs.startingDirectoryText
    wordCharacters.stringValue = prefs.selectionWordProfile.punctuation
    validate()
  }
  func present() {
    if window?.isVisible != true { reload() }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
  func controlTextDidChange(_ notification: Notification) { validate() }
  private func value() throws -> TerminalPreferences {
    let dimIndex = inactivePaneDim.selectedSegment
    let dim = PaneInactiveDim.allCases.indices.contains(dimIndex)
      ? PaneInactiveDim.allCases[dimIndex] : .five
    return try TerminalPreferences.edited(
      fontSize: fontSize.stringValue, historyRows: historyRows.stringValue,
      optionSendsEscape: option.state == .on, followTailOnInput: followTail.state == .on,
      startingDirectory: startingDirectory.stringValue,
      selectionWordCharacters: wordCharacters.stringValue,
      showPaneTitles: showPaneTitles.state == .on,
      inactivePaneDim: dim, defaultPaneColor: defaultPaneColor.selected ?? .standard)
  }
  private func validate() {
    do {
      _ = try value()
      apply.isEnabled = true
      error.stringValue = ""
    } catch {
      apply.isEnabled = false
      self.error.stringValue = error.localizedDescription
    }
  }
  @objc private func cancel(_ sender: Any?) { close() }
  @objc func closePane(_ sender: Any?) { close() }
  @objc private func save(_ sender: Any?) {
    guard let prefs = try? value() else {
      validate()
      return
    }
    onApply(prefs)
    close()
  }
  @objc private func chooseDirectory(_ sender: Any?) {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = startingDirectory.stringValue.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser
      : URL(fileURLWithPath: (startingDirectory.stringValue as NSString).expandingTildeInPath)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      startingDirectory.stringValue = url.path
      validate()
    }
  }
}

// The field editor delivers arrow commands to its delegate. Keeping that here
// makes typing, stepper clicks and keyboard increments share one bounded value.
private final class FontSizeInput: NSStackView, NSTextFieldDelegate {
  private let field = SettingsTextField(value: "14")
  private let stepper = NSStepper()
  var textField: NSTextField { field }
  var onChange: (() -> Void)?
  var stringValue: String {
    get { field.stringValue }
    set {
      field.stringValue = newValue
      if let value = Double(newValue), value.isFinite { stepper.doubleValue = value }
    }
  }
  init() {
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 4
    field.alignment = .right
    field.delegate = self
    stepper.minValue = 8
    stepper.maxValue = 40
    stepper.increment = 1
    stepper.valueWraps = false
    stepper.target = self
    stepper.action = #selector(stepped(_:))
    stepper.setAccessibilityLabel("Adjust font size")
    stepper.setAccessibilityIdentifier("no.helgesverre.terminal.settings.font-size-stepper")
    addArrangedSubview(field)
    addArrangedSubview(stepper)
    widthAnchor.constraint(equalTo: field.widthAnchor,
      constant: stepper.intrinsicContentSize.width + spacing).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  func controlTextDidChange(_ notification: Notification) {
    if let value = Double(field.stringValue), value.isFinite { stepper.doubleValue = value }
    onChange?()
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    let name = NSStringFromSelector(selector)
    guard name == "moveUp:" || name == "moveDown:" else { return false }
    let parsed = Double(field.stringValue)
    let value = parsed?.isFinite == true ? parsed! : stepper.doubleValue
    stepper.doubleValue = min(40, max(8, value + (name == "moveUp:" ? 1 : -1)))
    stepped(stepper)
    textView.string = field.stringValue
    textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
    return true
  }
  @objc private func stepped(_ sender: NSStepper) {
    field.stringValue = String(format: "%g", stepper.doubleValue)
    onChange?()
  }
}

// Native buttons retain standard AX actions and keyboard activation; only their
// fill and typography are drawn here to avoid the system accent in this surface.
private class SettingsActionButton: NSButton {
  private let primary: Bool
  init(title: String, primary: Bool = false, target: AnyObject?, action: Selector?) {
    self.primary = primary
    super.init(frame: .zero)
    self.title = title
    self.target = target
    self.action = action
    isBordered = false
    focusRingType = .exterior
    font = .systemFont(ofSize: 13, weight: primary ? .medium : .regular)
    setButtonType(.momentaryPushIn)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override var intrinsicContentSize: NSSize {
    NSSize(width: max(68, (title as NSString).size(withAttributes: [.font: font!]).width + 28), height: 30)
  }
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    let fill = primary ? TerminalTheme.accent : TerminalTheme.Settings.surface
    TerminalTheme.color(isHighlighted && !primary ? TerminalTheme.Settings.selected : fill)
      .withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
    shape.fill()
    if !primary {
      TerminalTheme.color(TerminalTheme.Settings.border).setStroke()
      shape.stroke()
    }
    let color = primary ? TerminalTheme.Settings.background : TerminalTheme.Settings.text
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font!, .foregroundColor: TerminalTheme.color(color).withAlphaComponent(isEnabled ? 1 : 0.4),
    ]
    let size = (title as NSString).size(withAttributes: attributes)
    (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
  }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
  }
  override var focusRingMaskBounds: NSRect { bounds }
}

private final class SettingsNavigationButton: NSButton {
  var onMove: ((Int) -> Void)?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    setButtonType(.radio)
    focusRingType = .exterior
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    performClick(nil)
    return true
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 125 { onMove?(1) }
    else if event.keyCode == 126 { onMove?(-1) }
    else { super.keyDown(with: event) }
  }
  override func draw(_ dirtyRect: NSRect) {
    if state == .on || isHighlighted {
      TerminalTheme.color(TerminalTheme.Settings.selected).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    let color = TerminalTheme.color(state == .on ? TerminalTheme.Settings.text : TerminalTheme.Settings.secondary)
    if let image {
      let iconColor = state == .on ? TerminalTheme.color(TerminalTheme.accent) : color
      let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [iconColor]))
      let symbol = image.withSymbolConfiguration(configuration) ?? image
      symbol.draw(in: NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16))
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: state == .on ? .medium : .regular),
      .foregroundColor: color,
    ]
    let size = (title as NSString).size(withAttributes: attributes)
    (title as NSString).draw(at: NSPoint(x: 36, y: (bounds.height - size.height) / 2), withAttributes: attributes)
  }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
  }
  override var focusRingMaskBounds: NSRect { bounds }
}

// The native field editor still owns input, selection, keyboard commands and AX.
// Only the surrounding rounded surface and text insets are settings-specific.
private final class SettingsTextField: NSTextField {
  init(value: String) {
    super.init(frame: .zero)
    cell = SettingsTextFieldCell(textCell: "")
    isEditable = true
    isSelectable = true
    isBezeled = false
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    textColor = TerminalTheme.color(TerminalTheme.Settings.text)
    font = .systemFont(ofSize: 14)
    stringValue = value
    heightAnchor.constraint(equalToConstant: 32).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override func draw(_ dirtyRect: NSRect) {
    let focused = currentEditor() != nil
    let inset: CGFloat = focused ? 1 : 0.5
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 8, yRadius: 8)
    TerminalTheme.color(TerminalTheme.Settings.surface).setFill()
    shape.fill()
    TerminalTheme.color(focused ? TerminalTheme.accent : TerminalTheme.Settings.border).setStroke()
    shape.lineWidth = focused ? 2 : 1
    shape.stroke()
    super.draw(dirtyRect)
  }
  override func textDidBeginEditing(_ notification: Notification) {
    super.textDidBeginEditing(notification)
    if let editor = currentEditor() as? NSTextView {
      editor.drawsBackground = false
      editor.insertionPointColor = TerminalTheme.color(TerminalTheme.accent)
    }
    needsDisplay = true
  }
  override func textDidEndEditing(_ notification: Notification) {
    super.textDidEndEditing(notification)
    needsDisplay = true
  }
}
private final class SettingsTextFieldCell: NSTextFieldCell {
  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    var result = rect.insetBy(dx: 10, dy: 0)
    let height = min(result.height, cellSize(forBounds: result).height)
    result.origin.y += (result.height - height) / 2
    result.size.height = height
    return result
  }
  override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, start selStart: Int, length selLength: Int) {
    super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
      delegate: delegate, start: selStart, length: selLength)
  }
}

// Keep NSSegmentedControl's native tracking, keyboard and AX radio children.
// Drawing the segments avoids appearance-dependent system accent substitution.
private final class SettingsSegmentedControl: NSSegmentedControl {
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    TerminalTheme.color(TerminalTheme.Settings.surface).setFill()
    shape.fill()
    TerminalTheme.color(TerminalTheme.Settings.border).setStroke()
    shape.stroke()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let segmentWidth = bounds.width / CGFloat(max(1, segmentCount))
    for index in 0..<segmentCount {
      let rect = NSRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
      if index == selectedSegment {
        TerminalTheme.color(TerminalTheme.accent).setFill()
        rect.fill()
      }
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: index == selectedSegment ? .medium : .regular),
        .foregroundColor: TerminalTheme.color(index == selectedSegment ? TerminalTheme.Settings.background : TerminalTheme.Settings.secondary),
      ]
      let title = (label(forSegment: index) ?? "") as NSString
      let size = title.size(withAttributes: attributes)
      title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}

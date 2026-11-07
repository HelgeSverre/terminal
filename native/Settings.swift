import AppKit

// A separate native utility window keeps the terminal usable while editing settings.
final class TerminalSettingsWindow: NSWindowController, NSTextFieldDelegate {
  private let fontSize = FontSizeInput()
  private let familyName = NSTextField(labelWithString: "Obel Mono")
  private let historyRows = NSTextField(string: "")
  private let startingDirectory = NSTextField(string: "")
  private let option = NSButton(
    checkboxWithTitle: "Option key sends Escape", target: nil, action: nil)
  private let followTail = NSButton(
    checkboxWithTitle: "Scroll to bottom when typing", target: nil, action: nil)
  private let error = NSTextField(wrappingLabelWithString: "")
  private let apply = NSButton(title: "Apply", target: nil, action: nil)
  private let onApply: (TerminalPreferences) -> Void
  init(onApply: @escaping (TerminalPreferences) -> Void) {
    self.onApply = onApply
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Settings"
    window.setAccessibilityIdentifier("no.helgesverre.terminal.settings")
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    TerminalTheme.apply(to: window)
    window.backgroundColor = TerminalTheme.color(TerminalTheme.background)
    let content = NSView()
    window.contentView = content
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: content.leadingAnchor, constant: TerminalTheme.windowInset),
      stack.trailingAnchor.constraint(
        equalTo: content.trailingAnchor, constant: -TerminalTheme.windowInset),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: TerminalTheme.windowInset),
    ])
    func label(_ value: String, secondary: Bool = false) -> NSTextField {
      let field = NSTextField(labelWithString: value)
      field.font = .systemFont(ofSize: 13)
      field.textColor = TerminalTheme.color(
        secondary ? TerminalTheme.secondary : TerminalTheme.text)
      return field
    }
    func section(_ title: String) {
      let field = label(title)
      field.font = .systemFont(ofSize: 12, weight: .semibold)
      stack.addArrangedSubview(field)
      stack.setCustomSpacing(12, after: field)
    }
    func row(_ title: String, control: NSView, unit: String) -> NSStackView {
      let name = label(title)
      name.widthAnchor.constraint(equalToConstant: 112).isActive = true
      let units = label(unit, secondary: true)
      let value = NSStackView(views: [name, control, units])
      value.orientation = .horizontal
      value.alignment = .firstBaseline
      value.spacing = 8
      return value
    }
    section("Startup")
    startingDirectory.widthAnchor.constraint(equalToConstant: 180).isActive = true
    startingDirectory.setAccessibilityLabel("Starting directory")
    startingDirectory.setAccessibilityIdentifier("no.helgesverre.terminal.settings.starting-directory")
    startingDirectory.toolTip = "Blank uses your home directory. Existing shells keep their current directory."
    startingDirectory.delegate = self
    let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDirectory(_:)))
    choose.bezelStyle = .rounded
    choose.setAccessibilityLabel("Choose starting directory")
    choose.setAccessibilityIdentifier("no.helgesverre.terminal.settings.choose-directory")
    let directoryControls = NSStackView(views: [startingDirectory, choose])
    directoryControls.spacing = 8
    let directoryRow = row("Directory", control: directoryControls, unit: "")
    stack.addArrangedSubview(directoryRow)
    stack.setCustomSpacing(24, after: directoryRow)
    section("Text")
    familyName.font = .systemFont(ofSize: 13)
    familyName.textColor = TerminalTheme.color(TerminalTheme.text)
    let family = row("Font", control: familyName, unit: "")
    stack.addArrangedSubview(family)
    stack.setCustomSpacing(12, after: family)
    fontSize.onChange = { [weak self] in self?.validate() }
    let sizeRow = row("Size", control: fontSize, unit: "pt")
    stack.addArrangedSubview(sizeRow)
    stack.setCustomSpacing(24, after: sizeRow)
    section("Scrollback")
    historyRows.widthAnchor.constraint(equalToConstant: 100).isActive = true
    historyRows.alignment = .right
    historyRows.setAccessibilityLabel("Scrollback rows")
    historyRows.setAccessibilityIdentifier("no.helgesverre.terminal.settings.scrollback-rows")
    historyRows.toolTip = "0–50,000 rows"
    historyRows.delegate = self
    let historyRow = row("Scrollback", control: historyRows, unit: "rows")
    stack.addArrangedSubview(historyRow)
    stack.setCustomSpacing(6, after: historyRow)
    let historyHint = label("Up to 50,000 rows or 64 MiB per session.", secondary: true)
    historyHint.font = .systemFont(ofSize: 12)
    stack.addArrangedSubview(historyHint)
    stack.setCustomSpacing(12, after: historyHint)
    followTail.font = .systemFont(ofSize: 13)
    followTail.setAccessibilityIdentifier("no.helgesverre.terminal.settings.follow-tail-on-input")
    stack.addArrangedSubview(followTail)
    stack.setCustomSpacing(24, after: followTail)
    section("Keyboard")
    option.font = .systemFont(ofSize: 13)
    option.setAccessibilityIdentifier("no.helgesverre.terminal.settings.option-sends-escape")
    option.toolTip = "Off uses native Option characters. Option arrows always move by word."
    stack.addArrangedSubview(option)
    stack.setCustomSpacing(12, after: option)
    error.font = .systemFont(ofSize: 12)
    error.textColor = TerminalTheme.color(TerminalTheme.danger)
    error.setAccessibilityLabel("Settings validation")
    error.setAccessibilityIdentifier("no.helgesverre.terminal.settings.validation")
    stack.addArrangedSubview(error)
    error.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    error.heightAnchor.constraint(equalToConstant: 30).isActive = true
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(Self.cancel(_:)))
    cancel.bezelStyle = .rounded
    cancel.setAccessibilityIdentifier("no.helgesverre.terminal.settings.cancel")
    cancel.keyEquivalent = "\u{1b}"
    apply.bezelStyle = .rounded
    apply.setAccessibilityIdentifier("no.helgesverre.terminal.settings.apply")
    apply.bezelColor = TerminalTheme.color(TerminalTheme.accent)
    apply.contentTintColor = TerminalTheme.color(TerminalTheme.background)
    apply.keyEquivalent = "\r"
    apply.target = self
    apply.action = #selector(save(_:))
    let spacer = NSView()
    let buttons = NSStackView(views: [spacer, cancel, apply])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    stack.addArrangedSubview(buttons)
    buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    NSLayoutConstraint.activate([
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: content.bottomAnchor, constant: -TerminalTheme.windowInset)
    ])
    window.initialFirstResponder = fontSize
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  func present() {
    if window?.isVisible != true {
      let prefs = TerminalPreferences.load()
      fontSize.stringValue = String(format: "%g", Double(prefs.fontSize))
      familyName.stringValue = TerminalFont.appKit(size: prefs.fontSize).familyName ?? "Menlo"
      historyRows.stringValue = String(prefs.historyRows)
      option.state = prefs.optionSendsEscape ? .on : .off
      followTail.state = prefs.followTailOnInput ? .on : .off
      startingDirectory.stringValue = prefs.startingDirectoryText
      validate()
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
  func controlTextDidChange(_ notification: Notification) { validate() }
  private func value() throws -> TerminalPreferences {
    try TerminalPreferences.edited(
      fontSize: fontSize.stringValue, historyRows: historyRows.stringValue,
      optionSendsEscape: option.state == .on, followTailOnInput: followTail.state == .on,
      startingDirectory: startingDirectory.stringValue)
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
    panel.directoryURL = URL(fileURLWithPath: (startingDirectory.stringValue as NSString).expandingTildeInPath)
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
  private let field = NSTextField(string: "14")
  private let stepper = NSStepper()
  var onChange: (() -> Void)?
  var stringValue: String {
    get { field.stringValue }
    set { field.stringValue = newValue; stepper.doubleValue = Double(newValue) ?? 14 }
  }
  init() {
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 4
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.allowsFloats = true
    formatter.minimum = 8
    formatter.maximum = 40
    formatter.maximumFractionDigits = 2
    field.formatter = formatter
    field.alignment = .right
    field.delegate = self
    field.toolTip = "8–40 pt. Use Up and Down to adjust by one point."
    field.setAccessibilityLabel("Font size in points")
    field.setAccessibilityIdentifier("no.helgesverre.terminal.settings.font-size")
    field.widthAnchor.constraint(equalToConstant: 76).isActive = true
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
    if let value = Double(field.stringValue) { stepper.doubleValue = value }
    onChange?()
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    let name = NSStringFromSelector(selector)
    guard name == "moveUp:" || name == "moveDown:" else { return false }
    let value = Double(field.stringValue) ?? stepper.doubleValue
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

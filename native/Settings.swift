import AppKit

// A separate native utility window keeps the terminal usable while editing settings.
final class TerminalSettingsWindow: NSWindowController, NSTextFieldDelegate {
  private let fontSize = NSTextField(string: "")
  private let familyName = NSTextField(labelWithString: "Obel Mono")
  private let historyRows = NSTextField(string: "")
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
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Settings"
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
    section("Text")
    familyName.font = .systemFont(ofSize: 13)
    familyName.textColor = TerminalTheme.color(TerminalTheme.text)
    let family = row("Font", control: familyName, unit: "")
    stack.addArrangedSubview(family)
    stack.setCustomSpacing(12, after: family)
    fontSize.widthAnchor.constraint(equalToConstant: 76).isActive = true
    fontSize.alignment = .right
    fontSize.setAccessibilityLabel("Font size in points")
    fontSize.toolTip = "8–40 pt"
    fontSize.delegate = self
    let sizeRow = row("Size", control: fontSize, unit: "pt")
    stack.addArrangedSubview(sizeRow)
    stack.setCustomSpacing(24, after: sizeRow)
    section("Scrollback")
    historyRows.widthAnchor.constraint(equalToConstant: 100).isActive = true
    historyRows.alignment = .right
    historyRows.setAccessibilityLabel("Scrollback rows")
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
    stack.addArrangedSubview(followTail)
    stack.setCustomSpacing(24, after: followTail)
    section("Keyboard")
    option.font = .systemFont(ofSize: 13)
    option.toolTip = "Off uses native Option characters. Option arrows always move by word."
    stack.addArrangedSubview(option)
    stack.setCustomSpacing(12, after: option)
    error.font = .systemFont(ofSize: 12)
    error.textColor = TerminalTheme.color(TerminalTheme.danger)
    error.setAccessibilityLabel("Settings validation")
    stack.addArrangedSubview(error)
    error.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    error.heightAnchor.constraint(equalToConstant: 30).isActive = true
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(Self.cancel(_:)))
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1b}"
    apply.bezelStyle = .rounded
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
      validate()
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
  func controlTextDidChange(_ notification: Notification) { validate() }
  private func value() -> TerminalPreferences? {
    TerminalPreferences.edited(
      fontSize: fontSize.stringValue, historyRows: historyRows.stringValue,
      optionSendsEscape: option.state == .on, followTailOnInput: followTail.state == .on)
  }
  private func validate() {
    apply.isEnabled = value() != nil
    error.stringValue =
      apply.isEnabled ? "" : "Enter a size from 8–40 pt and a row limit from 0–50,000."
  }
  @objc private func cancel(_ sender: Any?) { close() }
  @objc func closePane(_ sender: Any?) { close() }
  @objc private func save(_ sender: Any?) {
    guard let prefs = value() else {
      validate()
      return
    }
    onApply(prefs)
    close()
  }
}

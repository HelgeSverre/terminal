import AppKit
import TerminalHost
import UniformTypeIdentifiers

/// A native, bounded JSON editor for the parts of configuration that are lists
/// or palettes. The owning Settings window keeps the validated draft until Apply.
final class DesktopSettingsEditor: NSWindowController {
  private let text = NSTextView()
  private let message = NSTextField(wrappingLabelWithString: "")
  private let accept: (DesktopConfiguration) -> Void
  init(value: DesktopConfiguration, accept: @escaping (DesktopConfiguration) -> Void) {
    self.accept = accept
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Profiles, Shortcuts & Theme"
    panel.isReleasedWhenClosed = false
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    panel.contentView = stack
    let hint = NSTextField(wrappingLabelWithString:
      "Edit or import JSON. Profiles use executable + arguments (no shell expansion). Shortcuts use an action, a lowercase key and modifiers including command. Theme colors use #RRGGBB; ansi has sixteen entries. Null cursorStyle follows applications; 1–6 chooses blinking/steady block, underline or bar.")
    stack.addArrangedSubview(hint)
    let tools = NSStackView()
    for (title, action) in [("Add Shell Profile", #selector(addProfile)), ("Add Shortcuts", #selector(addShortcuts)),
      ("Add Theme", #selector(addTheme)), ("Import…", #selector(importFile))] {
      tools.addArrangedSubview(NSButton(title: title, target: self, action: action))
    }
    stack.addArrangedSubview(tools)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    text.isRichText = false
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.isVerticallyResizable = true
    text.textContainer?.widthTracksTextView = true
    text.autoresizingMask = [.width]
    text.setAccessibilityLabel("Desktop configuration JSON")
    scroll.documentView = text
    stack.addArrangedSubview(scroll)
    stack.addArrangedSubview(message)
    let save = NSButton(title: "Use Configuration", target: self, action: #selector(save))
    save.keyEquivalent = "\r"
    stack.addArrangedSubview(save)
    for view in [hint, tools, scroll, message] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    message.textColor = .systemRed
    show(value)
    panel.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  private func show(_ value: DesktopConfiguration) {
    text.string = (try? value.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    message.stringValue = ""
  }
  private func edit(_ change: (inout DesktopConfiguration) -> Void) {
    do {
      var value = try DesktopConfiguration.decode(Data(text.string.utf8))
      change(&value)
      try value.validate()
      show(value)
    } catch { message.stringValue = error.localizedDescription }
  }
  @objc private func addProfile() {
    edit { value in
      let id = UUID().uuidString
      value.profiles.append(TerminalLaunchProfile(id: id, name: "Login Shell", executable: LaunchSpec.loginShellPath,
        arguments: ["-l"], directory: "", environment: [:]))
    }
  }
  @objc private func addShortcuts() {
    edit { value in
      for shortcut in TerminalShortcut.defaults where !value.shortcuts.contains(where: { $0.action == shortcut.action }) {
        value.shortcuts.append(shortcut)
      }
    }
  }
  @objc private func addTheme() { edit { $0.theme = $0.theme ?? TerminalUserTheme() } }
  @objc private func importFile() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }
      do {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= DesktopConfiguration.maximumBytes else {
          throw DesktopConfiguration.Invalid.value("Configuration must be smaller than 128 KiB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: DesktopConfiguration.maximumBytes + 1) ?? Data()
        show(try DesktopConfiguration.decode(data))
      } catch { message.stringValue = error.localizedDescription }
    }
  }
  @objc private func save() {
    do {
      let value = try DesktopConfiguration.decode(Data(text.string.utf8))
      accept(value)
      close()
    } catch { message.stringValue = error.localizedDescription }
  }
}

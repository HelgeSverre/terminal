import AppKit

final class TerminalWindow: NSWindowController, NSWindowDelegate {
  let automationID = UUID().uuidString
  private(set) var panes: [TerminalCanvasView] = []
  private let container = NSView()
  private var root: NSView?
  private var initialLaunch: LaunchSpec?
  private let diagnosticSplitLaunch: LaunchSpec?
  init(launch: LaunchSpec? = nil) {
    initialLaunch = launch
    diagnosticSplitLaunch = CommandLine.arguments.contains("--resize-smoke") ? launch : nil
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    TerminalTheme.apply(to: window)
    window.title = "Terminal"
    window.setAccessibilityIdentifier("no.helgesverre.terminal.window." + automationID)
    window.minSize = NSSize(width: 320, height: 180)
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "HelgeTerminal"
    window.delegate = self
    container.wantsLayer = true
    window.contentView = container
    let pane = makePane()
    root = pane
    container.addSubview(pane)
    pane.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
    pane.autoresizingMask = [.width, .height]
    window.center()
    window.makeFirstResponder(pane)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  private func makePane() -> TerminalCanvasView {
    let pane = TerminalCanvasView(
      frame: .zero, session: Session(launch: initialLaunch ?? diagnosticSplitLaunch))
    initialLaunch = nil
    pane.onStatus = { [weak self, weak pane] text in
      NSLog("Session: %@", text)
      pane?.setAccessibilityHelp(text)
      if text.localizedCaseInsensitiveContains("busy")
        || text.localizedCaseInsensitiveContains("rejected")
      {
        NSSound.beep()
      }
      if text.hasPrefix("Launch") && text.contains("failed"), let window = self?.window,
        window.isVisible
      {
        let alert = NSAlert()
        alert.messageText = "Unable to start the shell"
        alert.informativeText = text
        alert.beginSheetModal(for: window)
      }
      if text == "Session finished" {
        self?.window?.title = "Terminal — Finished"
        if CommandLine.arguments.contains("--exit-after-command") {
          let arguments = Array(CommandLine.arguments.prefix { $0 != "--execute" })
          if let index = arguments.firstIndex(of: "--session-statistics-file"), index + 1 < arguments.count, let pane {
            let path = arguments[index + 1]
            pane.session.statistics { statistics in
              do {
                try JSONSerialization.data(withJSONObject: statistics, options: [.prettyPrinted, .sortedKeys])
                  .write(to: URL(fileURLWithPath: path), options: .atomic)
                NSApp.terminate(nil)
              } catch {
                NSLog("Session diagnostic write failed: %@", String(describing: error))
                exit(1)
              }
            }
          } else { NSApp.terminate(nil) }
        }
      }
    }
    pane.onTitle = { [weak self] title in if !title.isEmpty { self?.window?.title = title } }
    panes.append(pane)
    return pane
  }
  @objc func splitVertical(_ sender: Any?) { split(vertical: true) }
  @objc func splitHorizontal(_ sender: Any?) { split(vertical: false) }
  private func split(vertical: Bool) {
    guard let current = window?.firstResponder as? TerminalCanvasView,
      let parent = current.superview
    else { return }
    let frame = current.frame
    let mask = current.autoresizingMask
    let split = TerminalSplitView(frame: frame)
    split.wantsLayer = true
    split.isVertical = vertical
    split.dividerStyle = .thin
    parent.replaceSubview(current, with: split)
    split.autoresizingMask = mask
    if root === current { root = split }
    current.frame = split.bounds
    current.autoresizingMask = [.width, .height]
    split.addArrangedSubview(current)
    let pane = makePane()
    pane.frame = split.bounds
    split.addArrangedSubview(pane)
    let extent = vertical ? split.bounds.width : split.bounds.height
    split.setPosition((extent - split.dividerThickness) / 2, ofDividerAt: 0)
    split.adjustSubviews()
    if let root { window?.contentMinSize = minimumSize(root) }
    window?.makeFirstResponder(pane)
    panes.forEach { $0.updateFocus() }
  }
  private func minimumSize(_ view: NSView) -> NSSize {
    guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2 else {
      return NSSize(width: 200, height: 120)
    }
    let a = minimumSize(split.arrangedSubviews[0])
    let b = minimumSize(split.arrangedSubviews[1])
    return split.isVertical
      ? NSSize(
        width: a.width + b.width + split.dividerThickness, height: max(a.height, b.height))
      : NSSize(
        width: max(a.width, b.width), height: a.height + b.height + split.dividerThickness)
  }
  @objc func closePane(_ sender: Any?) {
    guard panes.count > 1, let pane = window?.firstResponder as? TerminalCanvasView,
      let split = pane.superview as? NSSplitView
    else {
      window?.performClose(sender)
      return
    }
    pane.session.close()
    pane.detachRenderingSurface()
    panes.removeAll { $0 === pane }
    pane.removeFromSuperview()
    if split.arrangedSubviews.count == 1, let survivor = split.arrangedSubviews.first,
      let parent = split.superview
    {
      let frame = split.frame
      survivor.removeFromSuperview()
      parent.replaceSubview(split, with: survivor)
      survivor.frame = frame
      survivor.autoresizingMask = [.width, .height]
      if root === split { root = survivor }
    }
    if let root { window?.contentMinSize = minimumSize(root) }
    window?.makeFirstResponder(panes.last)
    panes.forEach { $0.updateFocus() }
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    panes.forEach {
      $0.updateFocus()
      $0.refresh()
    }
  }
  func windowDidResignKey(_ notification: Notification) { panes.forEach { $0.updateFocus() } }
  func windowDidDeminiaturize(_ notification: Notification) { panes.forEach { $0.refresh() } }
  func windowWillClose(_ notification: Notification) {
    panes.forEach {
      $0.session.close()
      $0.detachRenderingSurface()
    }
    (NSApp.delegate as? AppDelegate)?.remove(self)
  }
  func windowDidBecomeKey(_ notification: Notification) {
    panes.forEach { $0.updateFocus() }
    if !(window?.firstResponder is TerminalCanvasView) { window?.makeFirstResponder(panes.first) }
    if let pane = window?.firstResponder as? TerminalCanvasView {
      (NSApp.delegate as? AppDelegate)?.rememberFocus(pane)
    }
  }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  var windows: [TerminalWindow] = []
  let rendering: TerminalRendering?
  let renderingError: String?
  let clipboardAccess = ClipboardAccess()
  private var preferencesWindow: TerminalSettingsWindow?
  private weak var lastFocusedPane: TerminalCanvasView?
  private var terminationRequested = false
  override init() {
    do {
      rendering = try TerminalRendering()
      renderingError = nil
    } catch {
      rendering = nil
      renderingError = String(describing: error)
    }
    super.init()
  }
  var acceptsAutomation: Bool { !terminationRequested }
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let renderingError { NSLog("Metal initialization failed: %@", renderingError) }
    NSApp.setActivationPolicy(.regular)
    menu()
    if CommandLine.arguments.contains("--resize-smoke") {
      let fixtureDirectory = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/ShellIntegration/ResizeSmokeZsh").path
      setenv("ZDOTDIR", fixtureDirectory, 1)
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(
        executable: "/bin/zsh", arguments: ["/bin/zsh", "-i"], cwd: shell.cwd, launcher: shell.launcher)
      let window = TerminalWindow(launch: launch)
      windows.append(window)
      window.showWindow(nil)
      window.window?.makeKeyAndOrderFront(nil)
    } else if CommandLine.arguments.contains("--glyph-smoke") {
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(executable: "/bin/sh", arguments: ["/bin/sh", "-c",
        "stty raw -echo; printf 'GLYPH_READY'; exec /bin/cat"], cwd: shell.cwd, launcher: shell.launcher)
      let window = TerminalWindow(launch: launch)
      windows.append(window)
      window.showWindow(nil)
      window.window?.makeKeyAndOrderFront(nil)
    } else if let index = CommandLine.arguments.firstIndex(of: "--execute"),
      CommandLine.arguments.count > index + 1
    {
      let argv = Array(CommandLine.arguments.dropFirst(index + 1))
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(
        executable: argv[0], arguments: argv, cwd: shell.cwd, launcher: shell.launcher)
      let window = TerminalWindow(launch: launch)
      windows.append(window)
      window.showWindow(nil)
      window.window?.makeKeyAndOrderFront(nil)
    } else {
      newWindow(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    if let columns = TerminalPreferences.launchInteger("--columns", within: 10...4096),
      let rows = TerminalPreferences.launchInteger("--rows", within: 4...4096),
      let window = windows.first, let pane = window.panes.first
    {
      window.window?.setContentSize(pane.contentSize(columns: columns, rows: rows))
    }
    if let index = CommandLine.arguments.firstIndex(of: "--self-test"),
      CommandLine.arguments.count > index + 1, let window = windows.first
    {
      NativeSmokeTest.start(window: window, path: CommandLine.arguments[index + 1])
    }
    if let index = CommandLine.arguments.firstIndex(of: "--editing-smoke"),
      CommandLine.arguments.count > index + 1, let window = windows.first {
      EditingSmokeTest.start(window: window, path: CommandLine.arguments[index + 1])
    }
    if let index = CommandLine.arguments.firstIndex(of: "--glyph-smoke"),
      CommandLine.arguments.count > index + 1, let window = windows.first {
      GlyphSmokeTest.start(window: window, path: CommandLine.arguments[index + 1])
    }
    if let index = CommandLine.arguments.firstIndex(of: "--close-smoke"),
      CommandLine.arguments.count > index + 1, let window = windows.first {
      CloseSmokeTest.start(window: window, path: CommandLine.arguments[index + 1])
    }
    if let index = CommandLine.arguments.firstIndex(of: "--demo-smoke"),
      CommandLine.arguments.count > index + 1, let window = windows.first
    {
      DemoSmokeTest.start(window: window, path: CommandLine.arguments[index + 1])
    }
    if let index = CommandLine.arguments.firstIndex(of: "--cat-smoke"),
      CommandLine.arguments.count > index + 2, let window = windows.first,
      let bytes = UInt64(CommandLine.arguments[index + 2])
    {
      CatSmokeTest.start(window: window, path: CommandLine.arguments[index + 1], bytes: bytes)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--resize-smoke"),
      CommandLine.arguments.count > index + 1, let window = windows.first
    {
      ResizeSmokeTest.start(window: window, path: CommandLine.arguments[index + 1])
    }
  }
  @objc func newWindow(_ sender: Any?) {
    let window = TerminalWindow()
    windows.append(window)
    window.showWindow(nil)
    window.window?.makeKeyAndOrderFront(nil)
  }
  @objc func newTab(_ sender: Any?) {
    let previous = (NSApp.keyWindow?.windowController as? TerminalWindow)?.window
      ?? intendedPane()?.window
    let window = TerminalWindow()
    windows.append(window)
    if let tab = window.window {
      previous?.addTabbedWindow(tab, ordered: .above)
      tab.makeKeyAndOrderFront(nil)
    }
  }
  @objc func settings(_ sender: Any?) {
    if preferencesWindow == nil {
      preferencesWindow = TerminalSettingsWindow { [weak self] prefs in
        self?.applyPreferences(prefs)
      }
    }
    preferencesWindow?.present()
  }
  func rememberFocus(_ pane: TerminalCanvasView) {
    guard pane.window?.firstResponder === pane,
      windows.contains(where: { $0.panes.contains { $0 === pane } })
    else { return }
    lastFocusedPane = pane
  }
  func intendedPane() -> TerminalCanvasView? {
    if let current = NSApp.keyWindow?.firstResponder as? TerminalCanvasView {
      rememberFocus(current)
      if current === lastFocusedPane { return current }
    }
    guard let pane = lastFocusedPane, pane.window != nil,
      windows.contains(where: { $0.panes.contains { $0 === pane } })
    else { return nil }
    return pane
  }
  func applyPreferences(_ preferences: TerminalPreferences) {
    preferences.save()
    windows.lazy.flatMap(\.panes).forEach { $0.applyPreferences() }
    preferencesWindow?.reload()
  }
  func remove(_ window: TerminalWindow) { windows.removeAll { $0 === window } }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { newWindow(nil) }
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationRequested else { return .terminateLater }
    terminationRequested = true
    windows.forEach { $0.close() }
    // AppKit's terminate-later loop runs in modalPanel mode, so a default-mode
    // dispatch callback can remain blocked by the very termination it resolves.
    let reply = Timer(timeInterval: 3, repeats: false) { _ in
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    RunLoop.main.add(reply, forMode: .modalPanel)
    RunLoop.main.add(reply, forMode: .default)
    return .terminateLater
  }
  private func menu() {
    let bar = NSMenu()
    NSApp.mainMenu = bar
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let m = NSMenu(title: title)
      item.submenu = m
      bar.addItem(item)
      return m
    }
    func item(
      _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
      _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil
    ) {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
      i.keyEquivalentModifierMask = modifiers
      i.target = target
      menu.addItem(i)
    }
    let app = submenu("Terminal")
    item(app, "About Terminal", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
    item(app, "Settings…", #selector(settings(_:)), ",", target: self)
    app.addItem(.separator())
    item(app, "Quit Terminal", #selector(NSApplication.terminate(_:)), "q")
    let shell = submenu("Shell")
    item(shell, "New Window", #selector(newWindow(_:)), "n", target: self)
    item(shell, "New Tab", #selector(newTab(_:)), "t", target: self)
    item(shell, "Split Right", #selector(TerminalWindow.splitVertical(_:)), "d")
    item(
      shell, "Split Below", #selector(TerminalWindow.splitHorizontal(_:)), "d", [.command, .shift])
    item(shell, "Close Pane", #selector(TerminalWindow.closePane(_:)), "w")
    let edit = submenu("Edit")
    item(edit, "Copy", #selector(TerminalCanvasView.copy(_:)), "c")
    item(edit, "Paste", #selector(TerminalCanvasView.paste(_:)), "v")
    item(edit, "Select All", #selector(TerminalCanvasView.selectAll(_:)), "a")
    item(edit, "Find", #selector(TerminalCanvasView.find(_:)), "f")
    item(edit, "Cancel Paste", #selector(TerminalCanvasView.cancelPaste(_:)), ".")
    let view = submenu("View")
    item(view, "Clear Screen", #selector(TerminalCanvasView.clearScreen(_:)), "k")
    item(view, "Increase Font Size", #selector(TerminalCanvasView.increaseFont(_:)), "+")
    item(view, "Decrease Font Size", #selector(TerminalCanvasView.decreaseFont(_:)), "-")
    item(view, "Reset Font Size", #selector(TerminalCanvasView.resetFont(_:)), "0")
    let window = submenu("Window")
    NSApp.windowsMenu = window
    item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    item(window, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control])
    item(
      window, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t",
      [.control, .shift])
  }
}
let catalogArguments = Array(CommandLine.arguments.prefix { $0 != "--execute" })
if let index = catalogArguments.firstIndex(of: "--font-catalog"),
  catalogArguments.count > index + 1 {
  do {
    let path = CommandLine.arguments[index + 1]
    try FontCatalog.write(to: path)
    let report = FontCatalog.inspect()
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path + ".json"), options: .atomic)
    exit(report["passed"] as? Bool == true ? 0 : 1)
  } catch { fputs("Font catalog failed: \(error)\n", stderr); exit(1) }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()

final class TerminalSplitView: NSSplitView, NSSplitViewDelegate {
  override func drawDivider(in rect: NSRect) {
    TerminalTheme.color(TerminalTheme.border).setFill()
    NSBezierPath(rect: rect).fill()
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    delegate = self
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
  func splitView(
    _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat { max(proposedMinimumPosition, isVertical ? 100 : 60) }
  func splitView(
    _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    min(
      proposedMaximumPosition, (isVertical ? bounds.width : bounds.height) - (isVertical ? 100 : 60)
    )
  }
}

import AppKit

/// A smoke run must never observe or mutate the user's clipboard. The report
/// path already belongs to the fixture, so it is a stable private-board scope.
func selectionSmokeReportPath() -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: "--selection-smoke"),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.path
}

func paneLifecycleSmokeReportPath() -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: "--pane-lifecycle-smoke"),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.path
}

private func terminalMinimumSize(_ view: NSView) -> NSSize {
  if let pane = view as? TerminalPanePresentationView { return pane.minimumSize }
  guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2 else {
    return TerminalPanePresentationView.terminalMinimum
  }
  let first = terminalMinimumSize(split.arrangedSubviews[0])
  let second = terminalMinimumSize(split.arrangedSubviews[1])
  return split.isVertical
    ? NSSize(
      width: first.width + second.width + split.dividerThickness,
      height: max(first.height, second.height))
    : NSSize(
      width: max(first.width, second.width), height: first.height + second.height + split.dividerThickness)
}

func selectionSmokePasteboardName(reportPath: String) -> NSPasteboard.Name {
  var hash: UInt64 = 0xcbf29ce484222325
  for byte in reportPath.utf8 {
    hash ^= UInt64(byte)
    hash &*= 0x100000001b3
  }
  return NSPasteboard.Name("no.helgesverre.terminal.selection-smoke.\(String(hash, radix: 16))")
}

final class TerminalWindow: NSWindowController, NSWindowDelegate {
  private struct PaneTitle {
    var reported = ""
    var finished = false

    var windowTitle: String {
      if finished { return "Terminal — Finished" }
      return reported.isEmpty ? "Terminal" : reported
    }
  }

  let automationID = UUID().uuidString
  private(set) var panes: [TerminalCanvasView] = []
  private let container = NSView()
  private var root: NSView?
  private var initialLaunch: LaunchSpec?
  private let diagnosticSplitLaunch: LaunchSpec?
  private var reconcilingLayout = false
  private weak var activePane: TerminalCanvasView?
  private var paneTitles: [ObjectIdentifier: PaneTitle] = [:]
  private var panePresentations: [ObjectIdentifier: TerminalPanePresentationView] = [:]
  init(launch: LaunchSpec? = nil) {
    initialLaunch = launch
    diagnosticSplitLaunch =
      CommandLine.arguments.contains("--resize-smoke") || paneLifecycleSmokeReportPath() != nil
      ? launch : nil
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    TerminalTheme.apply(to: window)
    window.setAccessibilityIdentifier("no.helgesverre.terminal.window." + automationID)
    window.minSize = NSSize(width: 320, height: 180)
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "HelgeTerminal"
    window.delegate = self
    container.wantsLayer = true
    window.contentView = container
    let pane = makePane()
    let presentation = panePresentation(for: pane)!
    root = presentation
    container.addSubview(presentation)
    presentation.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
    presentation.autoresizingMask = [.width, .height]
    window.center()
    selectActivePane(pane)
    window.makeFirstResponder(pane)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

  /// A window's title belongs to its most recently active pane.  AppKit can
  /// temporarily give another control first responder status (for example a
  /// find field), so responder state is intentionally not consulted here.
  private func publishWindowTitle() {
    let title = activePane.flatMap { paneTitles[ObjectIdentifier($0)]?.windowTitle } ?? "Terminal"
    if window?.title != title { window?.title = title }
  }

  private func selectActivePane(_ pane: TerminalCanvasView?) {
    activePane = pane
    publishWindowTitle()
    updatePanePresentation()
  }

  private func recordTitle(_ title: String, from pane: TerminalCanvasView) {
    guard panes.contains(where: { $0 === pane }) else { return }
    var state = paneTitles[ObjectIdentifier(pane)] ?? PaneTitle()
    state.reported = title
    paneTitles[ObjectIdentifier(pane)] = state
    panePresentation(for: pane)?.setTitle(state.windowTitle)
    publishWindowTitle()
  }

  private func recordSessionFinished(for pane: TerminalCanvasView) {
    guard panes.contains(where: { $0 === pane }) else { return }
    var state = paneTitles[ObjectIdentifier(pane)] ?? PaneTitle()
    state.finished = true
    paneTitles[ObjectIdentifier(pane)] = state
    panePresentation(for: pane)?.setTitle(state.windowTitle)
    publishWindowTitle()
  }

  func paneDidBecomeActive(_ pane: TerminalCanvasView) {
    guard panes.contains(where: { $0 === pane }) else { return }
    selectActivePane(pane)
  }

  private func makePane(launch: LaunchSpec? = nil) -> TerminalCanvasView {
    let pane = TerminalCanvasView(
      frame: .zero, session: Session(launch: initialLaunch ?? diagnosticSplitLaunch ?? launch))
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
        if let pane { self?.recordSessionFinished(for: pane) }
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
    pane.onTitle = { [weak self, weak pane] title in
      if let pane { self?.recordTitle(title, from: pane) }
    }
    pane.onActivated = { [weak self, weak pane] in
      if let pane { self?.paneDidBecomeActive(pane) }
    }
    panes.append(pane)
    let presentation = TerminalPanePresentationView(canvas: pane)
    presentation.onSelect = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.selectActivePane(pane)
      self.window?.makeFirstResponder(pane)
    }
    panePresentations[ObjectIdentifier(pane)] = presentation
    return pane
  }

  private func panePresentation(for pane: TerminalCanvasView) -> TerminalPanePresentationView? {
    panePresentations[ObjectIdentifier(pane)]
  }

  /// Header visibility is a window-layout concern: it changes leaf minima, so
  /// update it before every reconciliation rather than drawing over a canvas.
  @discardableResult
  func updatePanePresentation(_ preferences: TerminalPreferences = .load()) -> Bool {
    let previousMinimum = root.map(terminalMinimumSize)
    let showHeader = preferences.showPaneTitles && panes.count > 1
    for pane in panes {
      let title = paneTitles[ObjectIdentifier(pane)]?.windowTitle ?? "Terminal"
      panePresentation(for: pane)?.setTitle(title)
      panePresentation(for: pane)?.configure(
        showHeader: showHeader, active: pane === activePane, inactiveDim: preferences.inactivePaneDim)
    }
    guard let previousMinimum, let root else { return false }
    let currentMinimum = terminalMinimumSize(root)
    return abs(previousMinimum.width - currentMinimum.width) > 0.5
      || abs(previousMinimum.height - currentMinimum.height) > 0.5
  }

  /// Preference changes can grow a nested leaf by a header height. Reconcile
  /// immediately so neither the content minimum nor a divider keeps the old
  /// smaller allocation.
  func applyPanePresentationPreferences(_ preferences: TerminalPreferences) {
    if updatePanePresentation(preferences) { reconcileLayout() }
  }
  @objc func splitVertical(_ sender: Any?) { split(vertical: true) }
  @objc func splitHorizontal(_ sender: Any?) { split(vertical: false) }
  private func split(vertical: Bool) {
    guard let current = window?.firstResponder as? TerminalCanvasView,
      let currentPresentation = panePresentation(for: current), let parent = currentPresentation.superview
    else { return }
    let frame = currentPresentation.frame
    let mask = currentPresentation.autoresizingMask
    let split = TerminalSplitView(frame: frame)
    split.wantsLayer = true
    split.isVertical = vertical
    split.dividerStyle = .thin
    parent.replaceSubview(currentPresentation, with: split)
    split.autoresizingMask = mask
    if root === currentPresentation { root = split }
    currentPresentation.frame = split.bounds
    currentPresentation.autoresizingMask = [.width, .height]
    split.addArrangedSubview(currentPresentation)
    let pane = makePane(launch: current.session.siblingLaunch)
    guard let presentation = panePresentation(for: pane) else { return }
    presentation.frame = split.bounds
    presentation.autoresizingMask = [.width, .height]
    split.addArrangedSubview(presentation)
    // Divider constraints depend on valid child frames. Establish tiling before
    // selecting the initial midpoint, as a user drag would.
    split.adjustSubviews()
    selectActivePane(pane)
    // A new nested split can raise an ancestor's minimum. Allocate that space
    // before computing this split's midpoint so it never starts clipped.
    reconcileLayout()
    let extent = vertical ? split.bounds.width : split.bounds.height
    split.setPosition((extent - split.dividerThickness) / 2, ofDividerAt: 0)
    reconcileLayout()
    window?.makeFirstResponder(pane)
    panes.forEach { $0.updateFocus() }
  }
  private func reconcileLayout() {
    guard !reconcilingLayout, let root else { return }
    reconcilingLayout = true
    defer { reconcilingLayout = false }
    let minimum = terminalMinimumSize(root)
    window?.contentMinSize = minimum
    if let window, let contentView = window.contentView,
      contentView.bounds.width < minimum.width || contentView.bounds.height < minimum.height
    {
      window.setContentSize(NSSize(
        width: max(contentView.bounds.width, minimum.width),
        height: max(contentView.bounds.height, minimum.height)))
      window.contentView?.layoutSubtreeIfNeeded()
    }
    reconcileSplit(root)
  }
  private func reconcileSplit(_ view: NSView) {
    guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2 else { return }
    split.adjustSubviews()
    let first = split.arrangedSubviews[0]
    let second = split.arrangedSubviews[1]
    let firstMinimum = terminalMinimumSize(first)
    let secondMinimum = terminalMinimumSize(second)
    let extent = split.isVertical ? split.bounds.width : split.bounds.height
    let available = max(0, extent - split.dividerThickness)
    let current = split.isVertical ? first.frame.width : first.frame.height
    let minimum = split.isVertical ? firstMinimum.width : firstMinimum.height
    let maximum = max(0, available - (split.isVertical ? secondMinimum.width : secondMinimum.height))
    let position = min(max(current, minimum), maximum)
    if abs(position - current) > 0.5 { split.setPosition(position, ofDividerAt: 0) }
    split.arrangedSubviews.forEach(reconcileSplit)
  }
  @objc func closePane(_ sender: Any?) {
    guard panes.count > 1, let pane = window?.firstResponder as? TerminalCanvasView,
      let presentation = panePresentation(for: pane), let split = presentation.superview as? NSSplitView
    else {
      window?.performClose(sender)
      return
    }
    pane.session.close()
    pane.detachRenderingSurface()
    panes.removeAll { $0 === pane }
    paneTitles[ObjectIdentifier(pane)] = nil
    panePresentations[ObjectIdentifier(pane)] = nil
    presentation.removeFromSuperview()
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
    selectActivePane(panes.last)
    reconcileLayout()
    window?.makeFirstResponder(panes.last)
    panes.forEach { $0.updateFocus() }
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    panes.forEach {
      $0.updateFocus()
      $0.refresh()
    }
  }
  func windowDidResize(_ notification: Notification) { reconcileLayout() }
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
    publishWindowTitle()
  }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  var windows: [TerminalWindow] = []
  let rendering: TerminalRendering?
  let renderingError: String?
  let clipboardAccess: ClipboardAccess
  private var preferencesWindow: TerminalSettingsWindow?
  private weak var lastFocusedPane: TerminalCanvasView?
  private var terminationRequested = false
  override init() {
    if let path = selectionSmokeReportPath() {
      let pasteboard = NSPasteboard(name: selectionSmokePasteboardName(reportPath: path))
      clipboardAccess = ClipboardAccess(pasteboard: pasteboard)
    } else {
      clipboardAccess = ClipboardAccess()
    }
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
    if let _ = paneLifecycleSmokeReportPath() {
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", "stty raw -echo; exec /bin/cat"],
        cwd: shell.cwd, launcher: shell.launcher)
      let window = TerminalWindow(launch: launch)
      windows.append(window)
      window.showWindow(nil)
      window.window?.makeKeyAndOrderFront(nil)
    } else if CommandLine.arguments.contains("--resize-smoke") {
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
    if let path = selectionSmokeReportPath(), let window = windows.first {
      SelectionSmokeTest.start(window: window, path: path)
    }
    if let path = paneLifecycleSmokeReportPath(), let window = windows.first {
      PaneLifecycleSmokeTest.start(window: window, path: path)
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
    windows.lazy.flatMap(\.panes).forEach { $0.applyPreferences(preferences) }
    windows.forEach { $0.applyPanePresentationPreferences(preferences) }
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
  ) -> CGFloat {
    guard arrangedSubviews.indices.contains(dividerIndex) else { return proposedMinimumPosition }
    let minimum = terminalMinimumSize(arrangedSubviews[dividerIndex])
    return max(proposedMinimumPosition, isVertical ? minimum.width : minimum.height)
  }
  func splitView(
    _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    guard arrangedSubviews.indices.contains(dividerIndex + 1) else { return proposedMaximumPosition }
    let minimum = terminalMinimumSize(arrangedSubviews[dividerIndex + 1])
    let extent = isVertical ? bounds.width : bounds.height
    return min(
      proposedMaximumPosition, extent - dividerThickness - (isVertical ? minimum.width : minimum.height)
    )
  }
}

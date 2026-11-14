import AppKit
import TerminalInterop
import TerminalSession
import TerminalView

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
        || CommandLine.arguments.contains(IntenseResizeSmokeTest.flag)
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
    let delegate = NSApp.delegate as? AppDelegate
    let pane = TerminalCanvasView(
      frame: .zero,
      session: Session(launch: initialLaunch ?? diagnosticSplitLaunch ?? launch ?? .shell, startsAtFirstGrid: true),
      rendering: delegate?.rendering, clipboard: delegate?.clipboardAccess,
      configuration: TerminalPreferences.load().view)
    pane.onFocused = { [weak pane] in
      guard let pane else { return }
      (NSApp.delegate as? AppDelegate)?.rememberFocus(pane)
    }
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
    pane.attach(findBar: presentation.findBar)
    presentation.onSelect = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.selectActivePane(pane)
      self.window?.makeFirstResponder(pane)
    }
    presentation.onClose = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.window?.makeFirstResponder(pane)
      self.closePane(nil)
    }
    panePresentations[ObjectIdentifier(pane)] = presentation
    pane.session.onEnd = { [weak self, weak pane] end in
      guard let self, let pane, end.closesPane, self.panes.contains(where: { $0 === pane }) else { return }
      self.close(pane)
    }
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
        showHeader: showHeader, active: pane === activePane, inactiveDim: preferences.inactivePaneDim,
        defaultColor: preferences.defaultPaneColor)
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
  /// The pane that pane commands act on: the one holding keyboard focus,
  /// whether in its canvas or in its find bar. Casting the first responder
  /// to a canvas misses the latter, and Close Pane then closed the window.
  private var focusedPane: TerminalCanvasView? {
    guard let presentation = TerminalPanePresentationView.enclosing(window?.firstResponder) else { return nil }
    return panes.first { $0 === presentation.canvas }
  }
  @objc func splitVertical(_ sender: Any?) { split(vertical: true) }
  @objc func splitHorizontal(_ sender: Any?) { split(vertical: false) }
  private func split(vertical: Bool) {
    guard let current = focusedPane,
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
    guard panes.count > 1, let pane = focusedPane else {
      window?.performClose(sender)
      return
    }
    close(pane)
  }
  /// Shell > Pane Color…: the header's color popover, opened from the keyboard.
  @objc func choosePaneColor(_ sender: Any?) {
    guard let pane = focusedPane else { return }
    panePresentation(for: pane)?.showColorPopover()
  }
  /// Closes `pane`, and the window with it when it is the only one.
  private func close(_ pane: TerminalCanvasView) {
    guard panes.count > 1,
      let presentation = panePresentation(for: pane), let split = presentation.superview as? NSSplitView
    else {
      window?.close()
      return
    }
    // A shell can end in a pane that is not the active one; focus then stays put.
    let wasActive = activePane === pane || activePane == nil
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
    let next = wasActive ? panes.last : activePane
    selectActivePane(next)
    reconcileLayout()
    window?.makeFirstResponder(next)
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
/// Builds the renderer on another thread while AppKit finishes launching:
/// Metal setup takes about 10 ms. It must be created after the application
/// object, never before it.
final class RenderingSetup: @unchecked Sendable {
  private var outcome: Result<TerminalRendering, Error>?
  private let finished = DispatchSemaphore(value: 0)
  init() {
    DispatchQueue.global(qos: .userInteractive).async { [self] in
      outcome = Result { try TerminalRendering() }
      finished.signal()
    }
  }
  /// Blocks until the renderer is built or has failed.
  func wait() -> Result<TerminalRendering, Error> {
    finished.wait()
    defer { finished.signal() }
    return outcome!
  }
}
/// Answers AppKit's terminate-later request, once. It is created and used on
/// the main thread; the queue that learns the last child has ended only hands
/// it back to the main run loop.
private final class TerminationReply: @unchecked Sendable {
  private var sent = false
  func send() {
    guard !sent else { return }
    sent = true
    NSApp.reply(toApplicationShouldTerminate: true)
  }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  private lazy var tabNavigation = TerminalTabNavigation { [weak self] in
    (NSApp.keyWindow?.windowController as? TerminalWindow)?.window
      ?? self?.intendedPane()?.window
  }
  var windows: [TerminalWindow] = []
  // The renderer is collected at first use, when the app has finished
  // launching, so that building it overlaps AppKit's own launch work.
  private let renderingSetup: RenderingSetup
  private lazy var renderingOutcome = renderingSetup.wait()
  var rendering: TerminalRendering? { try? renderingOutcome.get() }
  var renderingError: String? {
    if case .failure(let error) = renderingOutcome { return String(describing: error) }
    return nil
  }
  let clipboardAccess: ClipboardAccess
  private var preferencesWindow: TerminalSettingsWindow?
  private weak var lastFocusedPane: TerminalCanvasView?
  private var terminationRequested = false
  init(rendering setup: RenderingSetup) {
    if let path = selectionSmokeReportPath() {
      let pasteboard = NSPasteboard(name: selectionSmokePasteboardName(reportPath: path))
      clipboardAccess = ClipboardAccess(pasteboard: pasteboard)
    } else {
      clipboardAccess = ClipboardAccess()
    }
    renderingSetup = setup
    super.init()
  }
  var acceptsAutomation: Bool { !terminationRequested }
  /// The login shell the first window will run, when it is safe to start it
  /// before the app: its startup then overlaps the app's own. A command given
  /// with `--execute` is not started early. Until the first pane has measured
  /// its font the PTY has no pixel size, and a program that reads the window
  /// size once as it starts, as the benchmark driver does, would see none; a
  /// shell asks again whenever the size changes. The smoke modes that build
  /// their own fixture launch are left to do so.
  static func firstLaunch() -> LaunchSpec? {
    let arguments = CommandLine.arguments
    if paneLifecycleSmokeReportPath() != nil || arguments.contains("--resize-smoke")
      || arguments.contains(IntenseResizeSmokeTest.flag)
      || arguments.contains("--glyph-smoke") || arguments.contains("--execute") { return nil }
    return .shell
  }
  /// `--background` opens the launch window behind other apps and leaves
  /// focus where it is, for measurement runs on a desktop in use.
  private let launchesInBackground = CommandLine.arguments.prefix { $0 != "--execute" }.contains("--background")
  @objc func checkForUpdates(_ sender: Any?) {
    MainActor.assumeIsolated { Updates.shared.check(sender) }
  }
  /// The item is dimmed in a copy that does not update itself, such as a local build.
  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard item.action == #selector(checkForUpdates(_:)) else { return true }
    return MainActor.assumeIsolated { Updates.shared.isEnabled }
  }
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
    } else if CommandLine.arguments.contains(IntenseResizeSmokeTest.flag) {
      IntenseResizeSmokeTest.seedNextStream(0)
      let window = TerminalWindow(launch: IntenseResizeSmokeTest.launch(from: .shell))
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
      // A measurement run can ask to stay behind whatever the user is doing.
      if launchesInBackground {
        window.window?.orderBack(nil)
      } else {
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
      }
    } else {
      newWindow(nil)
    }
    if !launchesInBackground { NSApp.activate(ignoringOtherApps: true) }
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
    if let index = CommandLine.arguments.firstIndex(of: IntenseResizeSmokeTest.flag),
      CommandLine.arguments.count > index + 1, let window = windows.first
    {
      IntenseResizeSmokeTest.start(window: window, path: CommandLine.arguments[index + 1])
    }
    MainActor.assumeIsolated { Updates.shared.checkAtLaunch() }
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
    windows.lazy.flatMap(\.panes).forEach { $0.apply(preferences.view) }
    windows.forEach { $0.applyPanePresentationPreferences(preferences) }
    preferencesWindow?.reload()
  }
  func remove(_ window: TerminalWindow) { windows.removeAll { $0 === window } }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    // A reopen can arrive during launch, before the first window is on
    // screen and counted as visible. Opening another then gives two windows,
    // so the test is whether any window exists. AppKit brings a minimised
    // one back itself.
    if windows.isEmpty { newWindow(nil) }
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationRequested else { return .terminateLater }
    terminationRequested = true
    windows.forEach { $0.close() }
    // Closing hangs every child up. The app leaves as soon as the last one
    // has been reaped, which for a shell at its prompt is a few milliseconds.
    // That includes children of panes closed earlier: closing the last window
    // is what brings the app here. A child that ignores the hang-up is killed
    // by its session after two seconds; the timer is the limit for anything
    // that outlasts even that.
    let reply = TerminationReply()
    // AppKit's terminate-later loop runs in modalPanel mode, so a default-mode
    // dispatch callback can remain blocked by the very termination it resolves.
    let modes: [RunLoop.Mode] = [.modalPanel, .default]
    LiveChildren.whenNoneRemain {
      RunLoop.main.perform(inModes: modes) { reply.send() }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    let limit = Timer(timeInterval: 3, repeats: false) { _ in reply.send() }
    modes.forEach { RunLoop.main.add(limit, forMode: $0) }
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
    let app = submenu("Helge Terminal")
    item(app, "About Helge Terminal", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
    item(app, "Check for Updates…", #selector(checkForUpdates(_:)), "", target: self)
    item(app, "Settings…", #selector(settings(_:)), ",", target: self)
    app.addItem(.separator())
    item(app, "Quit Helge Terminal", #selector(NSApplication.terminate(_:)), "q")
    let shell = submenu("Shell")
    item(shell, "New Window", #selector(newWindow(_:)), "n", target: self)
    item(shell, "New Tab", #selector(newTab(_:)), "t", target: self)
    item(shell, "Split Right", #selector(TerminalWindow.splitVertical(_:)), "d")
    item(
      shell, "Split Below", #selector(TerminalWindow.splitHorizontal(_:)), "d", [.command, .shift])
    item(shell, "Close Pane", #selector(TerminalWindow.closePane(_:)), "w")
    shell.addItem(.separator())
    item(shell, "Pane Color…", #selector(TerminalWindow.choosePaneColor(_:)), "", [])
    let edit = NSMenuItem()
    edit.submenu = TerminalEditMenu.make()
    bar.addItem(edit)
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
    window.addItem(.separator())
    tabNavigation.addMenuItems(to: window)
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
SmokeStream.runIfRequested()
// Children are told which version of this terminal they run in.
terminal_set_program_version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
if let launch = AppDelegate.firstLaunch() {
  let columns = TerminalPreferences.launchInteger("--columns", within: 10...4096)
  let rows = TerminalPreferences.launchInteger("--rows", within: 4...4096)
  EarlyChild.start(launch, grid: columns.flatMap { columns in rows.map { (columns, $0) } })
}
// The libraries take their measurement switches from the app; they do not
// read its command line.
do {
  let arguments = Array(CommandLine.arguments.prefix { $0 != "--execute" })
  SessionDiagnostics.collectsStreamStatistics = arguments.contains("--session-statistics-file")
  RenderingDiagnostics.atlasPressure = CommandLine.arguments.contains("--atlas-pressure-smoke")
  RenderingDiagnostics.atlasFallbackBudget = CommandLine.arguments.contains("--atlas-fallback-budget-smoke")
  if let index = arguments.firstIndex(of: "--first-frame-file"), index + 1 < arguments.count {
    RenderingDiagnostics.firstFrameFile = arguments[index + 1]
  }
}
let application = NSApplication.shared
// Started only now: touching Metal before the application object exists
// leaves the first window unable to become key when the app is launched
// without coming to the front, and its first click is then spent on focus.
let delegate = AppDelegate(rendering: RenderingSetup())
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

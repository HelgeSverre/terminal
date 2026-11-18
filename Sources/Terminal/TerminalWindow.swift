import AppKit
import TerminalHost
import TerminalUI

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

final class TerminalWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
  struct PaneTitle {
    var reported = ""
    var finished = false

    var windowTitle: String {
      if finished { return "Terminal — Finished" }
      return reported.isEmpty ? "Terminal" : reported
    }
  }

  let automationID: String
  private(set) var panes: [TerminalCanvasView] = []
  let container = NSView()
  var root: NSView?
  private var initialLaunch: LaunchSpec?
  private var initialPaneID: PaneID?
  private let diagnosticSplitLaunch: LaunchSpec?
  private var reconcilingLayout = false
  private(set) weak var activePane: TerminalCanvasView?
  var paneTitles: [ObjectIdentifier: PaneTitle] = [:]
  var panePresentations: [ObjectIdentifier: TerminalPanePresentationView] = [:]
  var paneZoom: PaneZoomState?
  private var visualBellEnabled = TerminalPreferences.current.desktop.visualBell
  struct PaneTransfer {
    let pane: TerminalCanvasView
    let presentation: TerminalPanePresentationView
    let title: PaneTitle
  }
  init(launch: LaunchSpec? = nil, layout: WindowLayout? = nil, adopting transfer: PaneTransfer? = nil, paneID: PaneID? = nil) {
    automationID = layout?.id.uuidString ?? UUID().uuidString
    initialLaunch = launch
    initialPaneID = paneID
    #if TERMINAL_DIAGNOSTICS
    diagnosticSplitLaunch =
      CommandLine.arguments.contains("--resize-smoke") || paneLifecycleSmokeReportPath() != nil
        || CommandLine.arguments.contains(IntenseResizeSmokeTest.flag)
      ? launch : nil
    #else
    diagnosticSplitLaunch = nil
    #endif
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
    let content: NSView
    if let transfer {
      panes = [transfer.pane]
      paneTitles[ObjectIdentifier(transfer.pane)] = transfer.title
      panePresentations[ObjectIdentifier(transfer.pane)] = transfer.presentation
      content = transfer.presentation
      window.center()
    } else if let layout {
      content = restoreTree(layout.root, states: Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.id, $0) }))
      let frame = WindowLayout.clampedFrame(layout.frame, to: NSScreen.screens.map(\.visibleFrame))
      window.setFrame(frame, display: false)
    } else {
      content = panePresentation(for: makePane())!
      window.center()
    }
    root = content
    container.addSubview(content)
    content.frame = container.bounds
    content.autoresizingMask = [.width, .height]
    reconcileLayout()
    if let layout { applyRatios(layout.root, to: content); reconcileLayout() }
    let pane = layout.flatMap { saved in panes.first { $0.automationID == saved.activePane.string } } ?? panes[0]
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

  func selectActivePane(_ pane: TerminalCanvasView?) {
    if let zoom = paneZoom, pane !== zoom.pane { endPaneZoom() }
    activePane = pane
    publishWindowTitle()
    updatePanePresentation()
    recoveryChanged()
  }

  private func recordTitle(_ title: String, from pane: TerminalCanvasView) {
    guard panes.contains(where: { $0 === pane }) else { return }
    var state = paneTitles[ObjectIdentifier(pane)] ?? PaneTitle()
    // Every snapshot reports its title; only a new one is a change to save.
    guard state.reported != title else { return }
    state.reported = title
    paneTitles[ObjectIdentifier(pane)] = state
    panePresentation(for: pane)?.setTitle(state.windowTitle)
    publishWindowTitle()
    recoveryChanged()
  }

  private func recordSessionFinished(for pane: TerminalCanvasView) {
    guard panes.contains(where: { $0 === pane }) else { return }
    var state = paneTitles[ObjectIdentifier(pane)] ?? PaneTitle()
    state.finished = true
    paneTitles[ObjectIdentifier(pane)] = state
    panePresentation(for: pane)?.setTitle(state.windowTitle)
    panePresentation(for: pane)?.downloadOffer.dismiss()
    publishWindowTitle()
  }

  func paneDidBecomeActive(_ pane: TerminalCanvasView) {
    guard panes.contains(where: { $0 === pane }) else { return }
    selectActivePane(pane)
  }

  private func makePane(launch: LaunchSpec? = nil, state: PaneState? = nil) -> TerminalCanvasView {
    let delegate = NSApp.delegate as? AppDelegate
    let id = state?.id ?? initialPaneID ?? PaneID()
    initialPaneID = nil
    let baseLaunch = state.map { LaunchSpec.recoveryShell(inheriting: URL(fileURLWithPath: $0.directory).absoluteString) }
      ?? initialLaunch ?? diagnosticSplitLaunch ?? launch ?? .shell
    let launch = baseLaunch.withResumeFile(delegate?.recovery?.resumeFile(id))
    let session: TerminalSession
    if let state, let adoption = delegate?.takeAdoption(state.id) {
      // The program is already running; nothing is started.
      session = TerminalSession(adopting: adoption.handoff, launch: adoption.launch)
    } else if let state, let store = delegate?.recovery {
      let checkpoint = store.scrollback(id)
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd HH:mm"
      var marker = "Restored · saved \(formatter.string(from: checkpoint.capturedAt))"
      if checkpoint.unavailable { marker += " · history unavailable" }
      if launch.cwd != state.directory { marker += " · directory unavailable: \(state.directory)" }
      session = TerminalSession(recovering: launch, text: checkpoint.text + "\n" + marker + "\n", startsAtFirstGrid: true)
    } else { session = TerminalSession(launch: launch, startsAtFirstGrid: true) }
    let pane = TerminalCanvasView(
      frame: .zero,
      session: session,
      rendering: delegate?.rendering, clipboard: delegate?.clipboardAccess,
      configuration: TerminalPreferences.current.view, automationID: id.string)
    if delegate?.recovery != nil {
      session.onRecoveryActivity = { [weak delegate, weak pane] in
        if let pane { delegate?.recoveryOutput(pane) }
      }
      session.onRecoveryMetadata = { [weak pane] in
        (pane?.window?.windowController as? TerminalWindow)?.recoveryChanged()
      }
      session.onRecoveryReady = { [weak delegate] in delegate?.recoveryPaneReady(id.string) }
    }
    pane.onFocused = { [weak pane] in
      guard let pane else { return }
      (NSApp.delegate as? AppDelegate)?.rememberFocus(pane)
    }
    initialLaunch = nil
    pane.onStatus = { [weak pane] text in
      let owner = pane?.window?.windowController as? TerminalWindow
      NSLog("Session: %@", text)
      pane?.setAccessibilityHelp(text)
      if text.localizedCaseInsensitiveContains("busy")
        || text.localizedCaseInsensitiveContains("rejected")
      {
        NSSound.beep()
      }
      if text.hasPrefix("Launch") && text.contains("failed"), let window = owner?.window,
        window.isVisible
      {
        let alert = NSAlert()
        alert.messageText = "Unable to start the shell"
        alert.informativeText = text
        alert.beginSheetModal(for: window)
      }
      if text == "Session finished" {
        if let pane { owner?.recordSessionFinished(for: pane) }
        #if TERMINAL_DIAGNOSTICS
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
        #endif
      }
    }
    pane.onTitle = { [weak pane] title in
      if let pane { (pane.window?.windowController as? TerminalWindow)?.recordTitle(title, from: pane) }
    }
    pane.onActivated = { [weak pane] in
      if let pane { (pane.window?.windowController as? TerminalWindow)?.paneDidBecomeActive(pane) }
    }
    panes.append(pane)
    let presentation = TerminalPanePresentationView(canvas: pane)
    presentation.onColorChanged = { [weak pane] in
      (pane?.window?.windowController as? TerminalWindow)?.recoveryChanged()
    }
    if let state {
      if let color = state.color.flatMap(PaneChromeColor.init(hex:)) { presentation.choose(color) }
      paneTitles[ObjectIdentifier(pane)] = PaneTitle(reported: state.title)
      if let record = state.resume, let rule = delegate?.resumeRules.rule(record.rule),
        let arguments = rule.arguments(for: record) {
        presentation.resumeStrip.offer(label: rule.label, exact: record.session != nil, warned: record.warned) { [weak pane] in
          guard let pane else { return false }
          let accepted = pane.session.send(text: ResumeRules.shellCommand(arguments) + "\r")
          if accepted {
            let owner = pane.window?.windowController as? TerminalWindow
            owner?.window?.makeFirstResponder(pane)
            owner?.recoveryChanged()
          }
          return accepted
        }
      }
    }
    pane.attach(findBar: presentation.findBar)
    presentation.onSelect = { [weak pane] in
      guard let pane, let owner = pane.window?.windowController as? TerminalWindow else { return }
      owner.selectActivePane(pane)
      owner.window?.makeFirstResponder(pane)
    }
    presentation.onClose = { [weak pane] in
      guard let pane, let owner = pane.window?.windowController as? TerminalWindow else { return }
      owner.window?.makeFirstResponder(pane)
      owner.closePane(nil)
    }
    panePresentations[ObjectIdentifier(pane)] = presentation
    pane.session.onEnd = { [weak pane] end in
      guard let pane, end.closesPane, let owner = pane.window?.windowController as? TerminalWindow,
        owner.panes.contains(where: { $0 === pane }) else { return }
      owner.close(pane)
    }
    pane.session.onBell = { [weak pane] in
      guard let pane, let owner = pane.window?.windowController as? TerminalWindow, owner.visualBellEnabled else { return }
      owner.panePresentation(for: pane)?.indicateBell()
    }
    pane.session.onDownload = { [weak pane] request in
      guard let pane, let owner = pane.window?.windowController as? TerminalWindow,
        let presentation = owner.panePresentation(for: pane) else { request.dismiss(); return }
      presentation.downloadOffer.offer(request)
    }
    return pane
  }

  func panePresentation(for pane: TerminalCanvasView) -> TerminalPanePresentationView? {
    panePresentations[ObjectIdentifier(pane)]
  }

  /// Header visibility is a window-layout concern: it changes leaf minima, so
  /// update it before every reconciliation rather than drawing over a canvas.
  @discardableResult
  func updatePanePresentation(_ preferences: TerminalPreferences = .current) -> Bool {
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
    visualBellEnabled = preferences.desktop.visualBell
    if updatePanePresentation(preferences) { reconcileLayout() }
  }
  /// The pane that pane commands act on: the one holding keyboard focus,
  /// whether in its canvas or in its find bar. Casting the first responder
  /// to a canvas misses the latter, and Close Pane then closed the window.
  var focusedPane: TerminalCanvasView? {
    guard let presentation = TerminalPanePresentationView.enclosing(window?.firstResponder) else { return nil }
    return panes.first { $0 === presentation.canvas }
  }
  @objc func splitVertical(_ sender: Any?) { split(vertical: true) }
  @objc func splitHorizontal(_ sender: Any?) { split(vertical: false) }
  private func split(vertical: Bool) {
    endPaneZoom()
    guard let current = focusedPane,
      let currentPresentation = panePresentation(for: current), let parent = currentPresentation.superview
    else { return }
    let frame = currentPresentation.frame
    let mask = currentPresentation.autoresizingMask
    let split = TerminalSplitView(frame: frame, vertical: vertical)
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
  func reconcileLayout() {
    guard !reconcilingLayout, let root else { return }
    if let zoom = paneZoom {
      zoom.presentation.frame = container.bounds
      window?.contentMinSize = zoom.presentation.minimumSize
      return
    }
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
  /// Takes a pane out of the tree and the window's records, leaving its split's
  /// other child in the split's place. Returns the title the pane had.
  @discardableResult
  private func detach(
    _ pane: TerminalCanvasView, _ presentation: TerminalPanePresentationView, from split: NSSplitView
  ) -> PaneTitle {
    let title = paneTitles[ObjectIdentifier(pane)] ?? PaneTitle()
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
    return title
  }
  /// Closes `pane`, and the window with it when it is the only one.
  private func close(_ pane: TerminalCanvasView) {
    endPaneZoom()
    panePresentation(for: pane)?.downloadOffer.dismiss()
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
    detach(pane, presentation, from: split)
    let next = wasActive ? panes.last : activePane
    selectActivePane(next)
    reconcileLayout()
    window?.makeFirstResponder(next)
    panes.forEach { $0.updateFocus() }
    recoveryChanged()
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    panes.forEach {
      $0.updateFocus()
      $0.refresh()
    }
  }
  func windowDidResize(_ notification: Notification) { reconcileLayout(); recoveryChanged() }
  func windowDidMove(_ notification: Notification) { recoveryChanged() }
  func windowDidResignKey(_ notification: Notification) { panes.forEach { $0.updateFocus() } }
  func windowDidDeminiaturize(_ notification: Notification) { panes.forEach { $0.refresh() } }
  func windowWillClose(_ notification: Notification) {
    panes.forEach {
      panePresentation(for: $0)?.downloadOffer.dismiss()
      $0.session.close()
      $0.detachRenderingSurface()
    }
    (NSApp.delegate as? AppDelegate)?.remove(self)
  }
  func windowDidBecomeKey(_ notification: Notification) {
    panes.forEach { $0.updateFocus() }
    publishWindowTitle()
    recoveryChanged()
  }

  func recoveryChanged() { (NSApp.delegate as? AppDelegate)?.recoveryChanged() }

  func layout() -> WindowLayout? {
    guard let window, let root, let tree = paneZoom?.tree ?? layoutTree(root),
      let active = activePane ?? panes.first, let activeID = UUID(uuidString: active.automationID),
      let id = UUID(uuidString: automationID) else { return nil }
    let tabs = window.tabbedWindows ?? [window]
    let first = tabs.compactMap { ($0.windowController as? TerminalWindow)?.automationID }.first ?? automationID
    return WindowLayout(id: id, frame: window.frame, root: tree, activePane: PaneID(activeID),
      panes: panes.map { pane in
        PaneState(id: PaneID(UUID(uuidString: pane.automationID)!),
          directory: pane.session.workingDirectory?.path ?? pane.session.launchDirectory ?? pane.session.siblingLaunch.cwd,
          title: paneTitles[ObjectIdentifier(pane)]?.reported ?? "", color: panePresentation(for: pane)?.savedColor)
      }, tabGroup: UUID(uuidString: first) ?? id,
      tabIndex: tabs.firstIndex(of: window) ?? 0,
      selectedTab: window.tabGroup?.selectedWindow === window || tabs.count == 1,
      zoomed: window.isZoomed, fullScreen: window.styleMask.contains(.fullScreen))
  }
  private func layoutTree(_ view: NSView) -> PaneLayout? {
    if let presentation = view as? TerminalPanePresentationView,
      let pane = presentation.canvas as? TerminalCanvasView, let id = UUID(uuidString: pane.automationID) {
      return .pane(PaneID(id))
    }
    guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2,
      let first = layoutTree(split.arrangedSubviews[0]), let second = layoutTree(split.arrangedSubviews[1]) else { return nil }
    let extent = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
    let size = split.isVertical ? split.arrangedSubviews[0].frame.width : split.arrangedSubviews[0].frame.height
    return .split(vertical: split.isVertical, ratio: PaneLayout.boundedRatio(extent > 0 ? size / extent : 0.5), first: first, second: second)
  }
  private func restoreTree(_ tree: PaneLayout, states: [PaneID: PaneState]) -> NSView {
    switch tree {
    case .pane(let id): return panePresentation(for: makePane(state: states[id]))!
    case .split(let vertical, _, let first, let second):
      let split = TerminalSplitView(vertical: vertical)
      for child in [restoreTree(first, states: states), restoreTree(second, states: states)] {
        child.autoresizingMask = [.width, .height]
        split.addArrangedSubview(child)
      }
      return split
    }
  }
  private func applyRatios(_ tree: PaneLayout, to view: NSView) {
    guard case .split(_, let ratio, let first, let second) = tree,
      let split = view as? NSSplitView, split.arrangedSubviews.count == 2 else { return }
    split.adjustSubviews()
    let extent = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
    split.setPosition(max(0, extent) * PaneLayout.boundedRatio(ratio), ofDividerAt: 0)
    // The children take their new sizes now: a nested split measures its
    // own ratio against them.
    split.layoutSubtreeIfNeeded()
    applyRatios(first, to: split.arrangedSubviews[0]); applyRatios(second, to: split.arrangedSubviews[1])
  }

  @objc func togglePaneZoom(_ sender: Any?) {
    if paneZoom != nil { endPaneZoom(); return }
    guard panes.count > 1, let pane = focusedPane, let presentation = panePresentation(for: pane),
      let root, let tree = layoutTree(root), let parent = presentation.superview else { return }
    let placeholder = NSView(frame: presentation.frame)
    placeholder.autoresizingMask = presentation.autoresizingMask
    parent.replaceSubview(presentation, with: placeholder)
    paneZoom = PaneZoomState(pane: pane, presentation: presentation, placeholder: placeholder, tree: tree)
    root.isHidden = true
    container.addSubview(presentation)
    presentation.frame = container.bounds
    presentation.autoresizingMask = [.width, .height]
    reconcileLayout()
    window?.makeFirstResponder(pane)
  }

  func endPaneZoom() {
    guard let zoom = paneZoom else { return }
    paneZoom = nil
    let frame = zoom.placeholder.frame
    zoom.presentation.removeFromSuperview()
    zoom.placeholder.superview?.replaceSubview(zoom.placeholder, with: zoom.presentation)
    zoom.presentation.frame = frame
    zoom.presentation.autoresizingMask = [.width, .height]
    root?.isHidden = false
    reconcileLayout()
    if let root { applyRatios(zoom.tree, to: root); reconcileLayout() }
    window?.makeFirstResponder(zoom.pane)
    panes.forEach { $0.refresh() }
  }

  /// Reparent the existing canvas/session. Callback routing follows the pane's
  /// current window, so title, exit, BEL and recovery events keep their owner.
  @objc func movePaneToWindow(_ sender: Any?) {
    endPaneZoom()
    guard panes.count > 1, let pane = focusedPane, let presentation = panePresentation(for: pane),
      let split = presentation.superview as? NSSplitView, let delegate = NSApp.delegate as? AppDelegate else { return }
    let transfer = PaneTransfer(pane: pane, presentation: presentation, title: detach(pane, presentation, from: split))
    selectActivePane(panes.last)
    reconcileLayout()
    window?.makeFirstResponder(panes.last)
    delegate.show(TerminalWindow(adopting: transfer))
    panes.forEach { $0.updateFocus() }
    recoveryChanged()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(togglePaneZoom(_:)) {
      item.state = paneZoom == nil ? .off : .on
      return panes.count > 1 && focusedPane != nil
    }
    if item.action == #selector(movePaneToWindow(_:)) { return panes.count > 1 && focusedPane != nil }
    if [#selector(focusLeft(_:)), #selector(focusRight(_:)), #selector(focusUp(_:)), #selector(focusDown(_:))]
      .contains(item.action) { return panes.count > 1 }
    return true
  }
}

final class TerminalSplitView: NSSplitView, NSSplitViewDelegate {
  override func drawDivider(in rect: NSRect) {
    TerminalTheme.color(TerminalTheme.border).setFill()
    NSBezierPath(rect: rect).fill()
  }
  init(frame: NSRect = .zero, vertical: Bool) {
    super.init(frame: frame)
    delegate = self
    wantsLayer = true
    isVertical = vertical
    dividerStyle = .thin
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

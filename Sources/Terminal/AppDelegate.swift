import AppKit
import TerminalHost
import TerminalUI

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
  var isSent: Bool { sent }
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
  private var terminationReply: TerminationReply?
  private var finishedLaunching = false
  private var pendingFileLaunches: [LaunchSpec] = []
  private let startupFiles = StartupTerminalFileFilter(arguments: CommandLine.arguments,
    currentDirectory: FileManager.default.currentDirectoryPath)
  let recovery: SessionStateStore?
  private var recoveryLayoutWork: DispatchWorkItem?
  private var recoveryCheckpointWork: DispatchWorkItem?
  private var recoveryPending: [String: (pane: TerminalCanvasView, due: Date)] = [:]
  private var recoveryCaptureInFlight = false
  private var recoverySleepFlush = false
  private var recoveryReadyPanes: Set<String> = []
  private var recoveryObservers: [NSObjectProtocol] = []
  private var initialPaneID: PaneID?
  private var recoveryLayoutRevision: UInt64 = 0
  private var recoveryLayoutPendingSince: DispatchTime?
  private var resumeRecords: [PaneID: ResumeRecord] = [:]
  private lazy var restoredResumeRecords: [PaneID: ResumeRecord] = Dictionary(
    (recovery?.restored?.windows.flatMap(\.panes) ?? []).compactMap { pane in pane.resume.map { (pane.id, $0) } },
    uniquingKeysWith: { first, _ in first })
  private var resumeSampling = false
  private var resumePending: (layout: SessionLayout, restoring: Bool, revision: UInt64)?
  lazy var resumeRules = ResumeRules.load(Bundle.main.url(forResource: "ResumeRules", withExtension: "json"))
  private lazy var resumeSampler = ResumeSampler(rules: resumeRules, home: FileManager.default.homeDirectoryForCurrentUser)
  /// Where running programs are left for the app that replaces this one, or
  /// nil when this copy does not hand off.
  let handoffDirectory: URL?
  /// The windows a replaced app left, until they are rebuilt.
  private var claimedLayout: SessionLayout?
  private var adoptions: [PaneID: SessionHandoffCoordinator.Adoption]
  private var handingOff = false
  init(rendering setup: RenderingSetup, recovery: SessionStateStore? = nil, paneID: PaneID? = nil,
       handoffDirectory: URL? = nil, handoff: SessionHandoffCoordinator.Claimed? = nil) {
    self.recovery = recovery
    self.handoffDirectory = handoffDirectory
    claimedLayout = handoff?.layout
    adoptions = handoff?.adoptions ?? [:]
    initialPaneID = handoff == nil ? paneID : nil
    #if TERMINAL_DIAGNOSTICS
    if let path = selectionSmokeReportPath() {
      let pasteboard = NSPasteboard(name: selectionSmokePasteboardName(reportPath: path))
      clipboardAccess = ClipboardAccess(pasteboard: pasteboard)
    } else {
      clipboardAccess = ClipboardAccess()
    }
    #else
    clipboardAccess = ClipboardAccess()
    #endif
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
    #if TERMINAL_DIAGNOSTICS
    let arguments = CommandLine.arguments
    if paneLifecycleSmokeReportPath() != nil || arguments.contains("--resize-smoke")
      || arguments.contains(IntenseResizeSmokeTest.flag)
      || arguments.contains("--glyph-smoke") || arguments.contains("--execute") { return nil }
    #endif
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
    if item.action == #selector(resumeAll(_:)) {
      return windows.contains { controller in controller.panes.contains { controller.panePresentation(for: $0)?.resumeStrip.isOffered == true } }
    }
    guard item.action == #selector(checkForUpdates(_:)) else { return true }
    return MainActor.assumeIsolated { Updates.shared.isEnabled }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let renderingError { NSLog("Metal initialization failed: %@", renderingError) }
    SidePulse.shared.configure(enabled: TerminalPreferences.load().sidePulseEnabled)
    NSApp.setActivationPolicy(.regular)
    menu()
    finishedLaunching = true
    // Saved windows come back even when a file launched the app; skipping
    // them would let the next save discard their state.
    let adopted = claimedLayout != nil
    if let layout = claimedLayout {
      claimedLayout = nil
      restoreWindows(layout)
      // A program whose pane was not rebuilt has no terminal any more.
      for adoption in adoptions.values { Darwin.close(adoption.handoff.descriptor) }
      adoptions.removeAll()
      // Rebuilding passes each pane through sizes it does not keep. Once the
      // windows are laid out, the programs may be told the size that stayed.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        windows.forEach { $0.window?.layoutIfNeeded() }
        windows.flatMap(\.panes).forEach { $0.session.finishAdoption() }
      }
    } else if let layout = recovery?.restored { restoreWindows(layout) }
    if !pendingFileLaunches.isEmpty {
      let launches = pendingFileLaunches
      pendingFileLaunches.removeAll()
      launches.forEach { openTerminalWindow(launch: $0) }
    } else if recovery?.restored == nil, !adopted {
      #if TERMINAL_DIAGNOSTICS
      if !openDiagnosticWindow() { newWindow(nil) }
      #else
      newWindow(nil)
      #endif
    }
    if !launchesInBackground { NSApp.activate(ignoringOtherApps: true) }
    if let columns = TerminalPreferences.launchInteger("--columns", within: 10...4096),
      let rows = TerminalPreferences.launchInteger("--rows", within: 4...4096),
      let window = windows.first, let pane = window.panes.first
    {
      window.window?.setContentSize(pane.contentSize(columns: columns, rows: rows))
    }
    #if TERMINAL_DIAGNOSTICS
    startDiagnostics()
    MainActor.assumeIsolated { HandoffSmoke.startIfRequested(self, adopted: adopted) }
    #endif
    MainActor.assumeIsolated { Updates.shared.checkAtLaunch() }
    if recovery != nil {
      recoveryObservers.append(NotificationCenter.default.addObserver(
        forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.recoveryChanged() })
      recoveryObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.checkpointBeforeSleep() })
      recoveryChanged()
    }
  }

  private func restoreWindows(_ layout: SessionLayout) {
    for saved in layout.windows {
      let controller = TerminalWindow(layout: saved)
      windows.append(controller)
    }
    let groups = Dictionary(grouping: layout.windows, by: \.tabGroup)
    for group in groups.values {
      let ordered = group.sorted { $0.tabIndex < $1.tabIndex }
      let controllers = ordered.compactMap { saved in windows.first { $0.automationID == saved.id.uuidString } }
      guard let first = controllers.first?.window else { continue }
      for controller in controllers.dropFirst() {
        if let tab = controller.window { first.addTabbedWindow(tab, ordered: .above) }
      }
      for controller in controllers { controller.showWindow(nil) }
      if let selected = ordered.first(where: \.selectedTab),
        let window = windows.first(where: { $0.automationID == selected.id.uuidString })?.window {
        window.tabGroup?.selectedWindow = window
      }
    }
    for saved in layout.windows {
      guard let window = windows.first(where: { $0.automationID == saved.id.uuidString })?.window else { continue }
      if saved.zoomed && !window.isZoomed { window.zoom(nil) }
      if saved.fullScreen { window.toggleFullScreen(nil) }
    }
    if let key = layout.keyWindow, let controller = windows.first(where: { $0.automationID == key.uuidString }) {
      if launchesInBackground { controller.window?.orderBack(nil) }
      else { controller.window?.makeKeyAndOrderFront(nil) }
    }
  }

  /// The running program a replaced app left for this pane, once.
  func takeAdoption(_ id: PaneID) -> SessionHandoffCoordinator.Adoption? { adoptions.removeValue(forKey: id) }

  /// Leaves every running program with a keeper, then ends this app. With
  /// `relaunch`, the app at this bundle's path starts once this one is gone
  /// and takes them over; without, whatever starts next does, as after an
  /// update that replaced the bundle. An updater that ends the app itself
  /// passes `terminates: false`. `completion` hears whether the programs
  /// were handed off.
  @MainActor func handOffSessions(relaunch: Bool, terminates: Bool = true, completion: (@MainActor (Bool) -> Void)? = nil) {
    guard let handoffDirectory, !handingOff, !terminationRequested else { completion?(false); return }
    handingOff = true
    SessionHandoffCoordinator.handOff(windows: windows, directory: handoffDirectory) { [weak self] outcome in
      guard let self else { return }
      handingOff = false
      completion?(outcome == .handedOff)
      // With the sessions lost the windows show programs that are gone, so
      // the app still ends or relaunches as it was asked to.
      if outcome != .handedOff { NSSound.beep() }
      guard outcome != .unchanged else { return }
      if relaunch {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.05; done; shift; exec /usr/bin/open -n "$@""#,
          "sh", String(getpid()), Bundle.main.bundlePath]
          + (CommandLine.arguments.count > 1 ? ["--args"] + CommandLine.arguments.dropFirst() : [])
        try? waiter.run()
      }
      if terminates { NSApp.terminate(nil) }
    }
  }
  @objc func relaunchKeepingSessions(_ sender: Any?) {
    MainActor.assumeIsolated { handOffSessions(relaunch: true) }
  }

  func recoveryChanged() {
    guard recovery != nil, !terminationRequested else { return }
    recoveryLayoutRevision &+= 1
    recoveryLayoutWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.saveRecoveryLayout() }
    recoveryLayoutWork = work
    // One second after the last change, and never more than five after the
    // first: steady changes must not postpone the save indefinitely.
    let now = DispatchTime.now()
    let first = recoveryLayoutPendingSince ?? now
    recoveryLayoutPendingSince = first
    DispatchQueue.main.asyncAfter(deadline: min(now + 1, first + 5), execute: work)
  }
  /// The layout as it is saved: each pane with the resume record sampling last
  /// found for it, or with the restored offer it still shows.
  private func withResumeRecords(_ layout: SessionLayout) -> SessionLayout {
    var offered: Set<String> = []
    for controller in windows {
      for pane in controller.panes where controller.panePresentation(for: pane)?.resumeStrip.isOffered == true {
        offered.insert(pane.automationID)
      }
    }
    var layout = layout
    for window in layout.windows.indices {
      for pane in layout.windows[window].panes.indices {
        let id = layout.windows[window].panes[pane].id
        layout.windows[window].panes[pane].resume = resumeRecords[id]
          ?? (offered.contains(id.string) ? restoredResumeRecords[id] : nil)
      }
    }
    return layout
  }
  private func saveRecoveryLayout() {
    recoveryLayoutWork = nil
    recoveryLayoutPendingSince = nil
    guard let recovery, !terminationRequested else { return }
    let saved = windows.compactMap { $0.layout() }
    guard !saved.isEmpty else { return }
    let key = (NSApp.keyWindow?.windowController as? TerminalWindow).flatMap { UUID(uuidString: $0.automationID) }
    let layout = withResumeRecords(SessionLayout(
      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      windows: saved, keyWindow: key))
    guard layout.isValid else { return }
    let restoring = recovery.restored != nil && !windows.flatMap(\.panes).allSatisfy { recoveryReadyPanes.contains($0.automationID) }
    recovery.save(layout, restoring: restoring)
    resumePending = (layout, restoring, recoveryLayoutRevision)
    sampleNextResume()
  }
  private func sampleNextResume() {
    guard !resumeSampling, !terminationRequested, let recovery, !resumeRules.rules.isEmpty,
      let pending = resumePending else { return }
    resumePending = nil
    resumeSampling = true
    let group = DispatchGroup()
    var requests: [ResumeSampler.Pane] = []
    for pane in windows.flatMap(\.panes) {
      guard let raw = UUID(uuidString: pane.automationID) else { continue }
      let id = PaneID(raw)
      group.enter()
      pane.session.foregroundProcessIdentifier { [weak pane] pid in
        // A shell at its prompt is its own foreground group; no rule matches it.
        if let pid, pid != pane?.session.processIdentifier {
          requests.append(ResumeSampler.Pane(id: id, pid: pid, hook: recovery.resumeFile(id)))
        }
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      guard !terminationRequested else { resumeSampling = false; return }
      resumeSampler.sample(requests) { [weak self] records in
        guard let self else { return }
        resumeSampling = false
        // Kept for every later save; a layout change during sampling brings one.
        let changed = records != resumeRecords
        resumeRecords = records
        if changed, !terminationRequested, pending.revision == recoveryLayoutRevision {
          recovery.save(withResumeRecords(pending.layout), restoring: pending.restoring)
        }
        sampleNextResume()
      }
    }
  }
  func recoveryPaneReady(_ id: String) { recoveryReadyPanes.insert(id); recoveryChanged() }
  func recoveryOutput(_ pane: TerminalCanvasView) {
    guard recovery != nil, !terminationRequested else { return }
    recoveryPending[pane.automationID] = (pane, Date().addingTimeInterval(2))
    scheduleRecoveryCheckpoint()
  }
  private func scheduleRecoveryCheckpoint() {
    recoveryCheckpointWork?.cancel()
    recoveryCheckpointWork = nil
    if recoveryPending.isEmpty && !recoveryCaptureInFlight { recoverySleepFlush = false }
    guard !terminationRequested, !recoveryCaptureInFlight,
      let next = recoveryPending.values.map(\.due).min() else { return }
    let work = DispatchWorkItem { [weak self] in self?.captureNextRecoveryPane() }
    recoveryCheckpointWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next.timeIntervalSinceNow), execute: work)
  }
  private func captureNextRecoveryPane(force: Bool = false) {
    recoveryCheckpointWork = nil
    guard !terminationRequested, !recoveryCaptureInFlight,
      let entry = recoveryPending.min(by: { $0.value.due < $1.value.due }) else { return }
    let pane = entry.value.pane
    recoveryPending[entry.key] = nil
    guard windows.contains(where: { $0.panes.contains(where: { $0 === pane }) }) else {
      scheduleRecoveryCheckpoint(); return
    }
    recoveryCaptureInFlight = true
    pane.session.recoveryCheckpoint(force: force || recoverySleepFlush) { [weak self, weak pane] text, rows, delay in
      guard let self else { return }
      recoveryCaptureInFlight = false
      if let pane, !terminationRequested,
        windows.contains(where: { $0.panes.contains(where: { $0 === pane }) }) {
        if let text, let uuid = UUID(uuidString: pane.automationID) {
          recovery?.saveScrollback(text, rows: rows, pane: PaneID(uuid))
          recoveryChanged()
        } else if let delay { recoveryPending[pane.automationID] = (pane, Date().addingTimeInterval(delay)) }
      }
      scheduleRecoveryCheckpoint()
    }
  }
  private func checkpointBeforeSleep() {
    recoveryLayoutWork?.cancel()
    saveRecoveryLayout()
    recoverySleepFlush = true
    for entry in recoveryPending { recoveryPending[entry.key]?.due = .distantPast }
    captureNextRecoveryPane(force: true)
  }
  #if TERMINAL_DIAGNOSTICS
  @MainActor private func openDiagnosticWindow() -> Bool {
    if let _ = paneLifecycleSmokeReportPath() {
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", "stty raw -echo; exec /bin/cat"],
        cwd: shell.cwd, launcher: shell.launcher)
      show(TerminalWindow(launch: launch))
    } else if CommandLine.arguments.contains("--resize-smoke") {
      let fixtureDirectory = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/ShellIntegration/ResizeSmokeZsh").path
      setenv("ZDOTDIR", fixtureDirectory, 1)
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(
        executable: "/bin/zsh", arguments: ["/bin/zsh", "-i"], cwd: shell.cwd, launcher: shell.launcher)
      show(TerminalWindow(launch: launch))
    } else if CommandLine.arguments.contains(IntenseResizeSmokeTest.flag) {
      IntenseResizeSmokeTest.seedNextStream(0)
      show(TerminalWindow(launch: IntenseResizeSmokeTest.launch(from: .shell)))
    } else if CommandLine.arguments.contains("--glyph-smoke") {
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(executable: "/bin/sh", arguments: ["/bin/sh", "-c",
        "stty raw -echo; printf 'GLYPH_READY'; exec /bin/cat"], cwd: shell.cwd, launcher: shell.launcher)
      show(TerminalWindow(launch: launch))
    } else if let index = CommandLine.arguments.firstIndex(of: "--execute"),
      CommandLine.arguments.count > index + 1
    {
      let argv = Array(CommandLine.arguments.dropFirst(index + 1))
      let shell = LaunchSpec.shell
      let launch = LaunchSpec(
        executable: argv[0], arguments: argv, cwd: shell.cwd, launcher: shell.launcher)
      // A measurement run can ask to stay behind whatever the user is doing.
      openTerminalWindow(launch: launch)
    } else {
      return false
    }
    return true
  }
  @MainActor private func startDiagnostics() {
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
    if let path = selectionSmokeReportPath(), let window = windows.first {
      SelectionSmokeTest.start(window: window, path: path)
    }
    if let path = paneLifecycleSmokeReportPath(), let window = windows.first {
      PaneLifecycleSmokeTest.start(window: window, path: path)
    }
  }
  #endif
  @objc func newWindow(_ sender: Any?) {
    show(TerminalWindow(paneID: initialPaneID))
    initialPaneID = nil
  }
  /// Finder and Toolbox use the same open-document Apple event, on both a
  /// cold launch and an already running app. Queue early events until menus
  /// and app setup are ready; they replace the otherwise empty first window.
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    sender.reply(toOpenOrPrint: acceptTerminalFiles(filenames) ? .success : .failure)
  }
  func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    acceptTerminalFiles([filename])
  }
  private func acceptTerminalFiles(_ filenames: [String]) -> Bool {
    guard !terminationRequested, !filenames.isEmpty else { return false }
    let filenames = startupFiles.documents(from: filenames, duringStartup: !finishedLaunching,
      currentEvent: NSAppleEventManager.shared().currentAppleEvent)
    // Acknowledge AppKit's synthetic request without queuing a launch or an
    // error panel. The normal diagnostic/recovery startup still runs below.
    guard !filenames.isEmpty else { return true }
    do {
      let launches = try filenames.map {
        try OpenTerminalFile.launch(path: $0, launcher: LaunchSpec.bundledLauncher)
      }
      if finishedLaunching { launches.forEach { openTerminalWindow(launch: $0) } }
      else { pendingFileLaunches.append(contentsOf: launches) }
      return true
    } catch {
      NSApp.presentError(error)
      return false
    }
  }
  private func openTerminalWindow(launch: LaunchSpec) {
    let window = TerminalWindow(launch: launch)
    windows.append(window)
    if launchesInBackground { window.window?.orderBack(nil) }
    else {
      window.showWindow(nil)
      window.window?.makeKeyAndOrderFront(nil)
    }
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
  @objc func resumeAll(_ sender: Any?) {
    for controller in windows {
      for pane in controller.panes { controller.panePresentation(for: pane)?.resumeStrip.resumeIfOffered() }
    }
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
    SidePulse.shared.configure(enabled: preferences.sidePulseEnabled)
    windows.lazy.flatMap(\.panes).forEach { $0.apply(preferences.view) }
    windows.forEach { $0.applyPanePresentationPreferences(preferences) }
    menu()
    preferencesWindow?.reload()
  }
  func remove(_ window: TerminalWindow) { windows.removeAll { $0 === window }; recoveryChanged() }
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
    // Asked again: the first answer is still to come, or it was given and
    // the quit it allowed did not happen. Waiting for an answer that was
    // already given would never end.
    guard !terminationRequested else { return terminationReply?.isSent == true ? .terminateNow : .terminateLater }
    terminationRequested = true
    SidePulse.shared.configure(enabled: false)
    recoveryLayoutWork?.cancel()
    recoveryCheckpointWork?.cancel()
    recoveryPending.removeAll()
    resumePending = nil
    let cleanups = DispatchGroup()
    if let recovery {
      cleanups.enter()
      recovery.cleanExit { cleanups.leave() }
    }
    windows.forEach { $0.close() }
    // Closing hangs every child up. The app leaves as soon as the last one
    // has been reaped, which for a shell at its prompt is a few milliseconds.
    // That includes children of panes closed earlier: closing the last window
    // is what brings the app here. A child that ignores the hang-up is killed
    // by its session after two seconds; the timer is the limit for anything
    // that outlasts even that.
    let reply = TerminationReply()
    terminationReply = reply
    // AppKit's terminate-later loop runs in modalPanel mode, so a default-mode
    // dispatch callback can remain blocked by the very termination it resolves.
    let modes: [RunLoop.Mode] = [.modalPanel, .default]
    cleanups.enter()
    LiveChildren.whenNoneRemain { cleanups.leave() }
    cleanups.notify(queue: .global(qos: .userInteractive)) {
      RunLoop.main.perform(inModes: modes) { reply.send() }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    let limit = Timer(timeInterval: 3, repeats: false) { _ in reply.send() }
    modes.forEach { RunLoop.main.add(limit, forMode: $0) }
    return .terminateLater
  }
  private func menu() {
    let menus = MainMenu.build(delegate: self, tabNavigation: tabNavigation,
      configuration: TerminalPreferences.current.desktop)
    NSApp.mainMenu = menus.bar
    NSApp.windowsMenu = menus.windows
  }
  /// Adds a window to the app and brings it forward.
  func show(_ window: TerminalWindow) {
    windows.append(window)
    window.showWindow(nil)
    window.window?.makeKeyAndOrderFront(nil)
  }
}

import AppKit
import TerminalInterop
import TerminalHost
import TerminalUI

// The app owns its bundle policy; embedded views use their module resources.
TerminalResources.bundle = .main

#if TERMINAL_DIAGNOSTICS
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
#endif
// Children are told which version of this terminal they run in.
helge_terminal_set_program_version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
let recoveryState = SessionStateStore.open(directory: StateLocation.directory(
  arguments: CommandLine.arguments, bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser))
let restoredFirstPane = recoveryState?.restored?.windows.first.flatMap { window in
  window.panes.first { $0.id == window.root.panes.first }
}
let firstPaneID = restoredFirstPane?.id ?? (recoveryState != nil ? PaneID() : nil)
if let baseLaunch = restoredFirstPane.map({ LaunchSpec.recoveryShell(inheriting: URL(fileURLWithPath: $0.directory).absoluteString) })
  ?? AppDelegate.firstLaunch() {
  let launch = baseLaunch.withResumeFile(firstPaneID.flatMap { recoveryState?.resumeFile($0) })
  let columns = TerminalPreferences.launchInteger("--columns", within: 10...4096)
  let rows = TerminalPreferences.launchInteger("--rows", within: 4...4096)
  EarlyChild.start(launch, grid: columns.flatMap { columns in rows.map { (columns, $0) } })
}
// The libraries take their measurement switches from the app; they do not
// read its command line.
#if TERMINAL_DIAGNOSTICS
do {
  let arguments = Array(CommandLine.arguments.prefix { $0 != "--execute" })
  SessionDiagnostics.collectsStreamStatistics = arguments.contains("--session-statistics-file")
  RenderingDiagnostics.atlasPressure = CommandLine.arguments.contains("--atlas-pressure-smoke")
  RenderingDiagnostics.atlasFallbackBudget = CommandLine.arguments.contains("--atlas-fallback-budget-smoke")
  if let index = arguments.firstIndex(of: "--first-frame-file"), index + 1 < arguments.count {
    RenderingDiagnostics.firstFrameFile = arguments[index + 1]
  }
}
#endif
let application = NSApplication.shared
// Started only now: touching Metal before the application object exists
// leaves the first window unable to become key when the app is launched
// without coming to the front, and its first click is then spent on focus.
let delegate = AppDelegate(rendering: RenderingSetup(), recovery: recoveryState, paneID: firstPaneID)
application.delegate = delegate
application.run()

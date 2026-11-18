#if TERMINAL_DIAGNOSTICS
import AppKit
import Sparkle

/// A copy made by `dev update-rehearsal` carries its instructions in its
/// Info.plist, because Sparkle relaunches an app with no arguments: where to
/// leave a handoff, where the smoke scenario is, and whether to accept the
/// update unasked. Only diagnostic builds read it; a release never does.
struct UpdateRehearsal {
  static let key = "TerminalUpdateRehearsal"
  let handoffDirectory: URL
  let smokeDirectory: URL
  /// Accept and install the update without showing Sparkle's windows.
  let automatic: Bool

  static let current: UpdateRehearsal? = {
    guard let values = Bundle.main.object(forInfoDictionaryKey: key) as? [String: Any],
      let handoff = values["handoff"] as? String, let smoke = values["smoke"] as? String else { return nil }
    return UpdateRehearsal(handoffDirectory: URL(fileURLWithPath: handoff, isDirectory: true),
      smokeDirectory: URL(fileURLWithPath: smoke, isDirectory: true), automatic: values["automatic"] as? Bool ?? true)
  }()
}

/// Says yes where Sparkle's standard windows would ask, and records what
/// Sparkle reports, so a rehearsal needs nobody at the screen.
final class RehearsalUserDriver: NSObject, SPUUserDriver {
  private let log: URL
  init(log: URL) { self.log = log }
  private func note(_ text: String) {
    let line = Data((text + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: log) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    } else { try? line.write(to: log) }
  }
  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { note("checking") }
  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
    note("found \(appcastItem.displayVersionString) (\(appcastItem.versionString))")
    reply(.install)
  }
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    note("not found: \(error.localizedDescription)"); acknowledgement()
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    note("error: \(error.localizedDescription) \((error as NSError).userInfo)"); acknowledgement()
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) { note("downloading") }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
  func showDownloadDidReceiveData(ofLength length: UInt64) {}
  func showDownloadDidStartExtractingUpdate() { note("extracting") }
  func showExtractionReceivedProgress(_ progress: Double) {}
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    note("ready to install"); reply(.install)
  }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    note("installing, application terminated: \(applicationTerminated)")
  }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    note("installed, relaunched: \(relaunched)"); acknowledgement()
  }
  func dismissUpdateInstallation() {}
}
#endif

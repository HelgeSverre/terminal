import AppKit
import Security
import Sparkle

/// Software updates, through Sparkle.
///
/// The app looks for an update once as it launches and when asked from the
/// menu. It never looks on a timer: a running terminal does no background
/// work of its own. An update is offered, never installed unasked.
@MainActor final class Updates: NSObject, SPUUpdaterDelegate {
  static let shared = Updates()

  private var controller: SPUStandardUpdaterController?
  #if TERMINAL_DIAGNOSTICS
  private var rehearsalUpdater: SPUUpdater?
  private var rehearsalDriver: RehearsalUserDriver?
  #endif

  /// Whether this copy of the app updates itself at all.
  var isEnabled: Bool { controller != nil }

  private override init() {
    let enabled = Self.updates(
      arguments: CommandLine.arguments,
      hasFeedKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String,
      signedForRelease: Self.isSignedForRelease)
    super.init()
    #if TERMINAL_DIAGNOSTICS
    // A rehearsal copy is a local build started with no arguments; its feed
    // and key are its own. With `automatic` nothing is shown or asked.
    if let rehearsal = UpdateRehearsal.current {
      if rehearsal.automatic {
        let driver = RehearsalUserDriver(log: rehearsal.smokeDirectory.appendingPathComponent("sparkle.log"))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        rehearsalDriver = driver
        rehearsalUpdater = updater
        do { try updater.start() } catch { NSLog("Update rehearsal could not start Sparkle: %@", String(describing: error)) }
        updater.automaticallyChecksForUpdates = false
      } else {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller?.updater.automaticallyChecksForUpdates = false
      }
      return
    }
    #endif
    controller = enabled
      ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
      : nil
    // Sparkle would otherwise schedule its own checks while the app runs.
    controller?.updater.automaticallyChecksForUpdates = false
  }

  /// Only a released copy, started the ordinary way, updates itself. A
  /// local build has no place to update from and would be replaced by a
  /// release; a run with arguments is a measurement or a test.
  nonisolated static func updates(arguments: [String], hasFeedKey: Bool, signedForRelease: Bool) -> Bool {
    hasFeedKey && signedForRelease && arguments.count <= 1
  }

  /// Before an update replaces the app, running programs are left with a
  /// keeper for the new version to adopt, when this copy hands off at all.
  /// The update goes ahead whether or not that worked.
  nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                           untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    MainActor.assumeIsolated {
      guard let delegate = NSApp.delegate as? AppDelegate, delegate.handoffDirectory != nil else { return false }
      delegate.handOffSessions(relaunch: false, terminates: false) { _ in installHandler() }
      return true
    }
  }

  /// The one check made without being asked. It says nothing unless an
  /// update exists.
  func checkAtLaunch() {
    #if TERMINAL_DIAGNOSTICS
    // A rehearsal asks when its programs are running, not as it starts.
    if UpdateRehearsal.current != nil { return }
    #endif
    controller?.updater.checkForUpdatesInBackground()
  }
  #if TERMINAL_DIAGNOSTICS
  /// Asks for the rehearsal's update now.
  func rehearse() {
    if let rehearsalUpdater { rehearsalUpdater.checkForUpdates() } else { controller?.checkForUpdates(nil) }
  }
  #endif

  /// The menu's "Check for Updates…": always answers, also with "up to date".
  @objc func check(_ sender: Any?) { controller?.checkForUpdates(sender) }

  /// Whether the running code carries a real signature, as a release does,
  /// and not the ad hoc one of a local build.
  private static var isSignedForRelease: Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
      == errSecSuccess, let details = information as? [String: Any],
      let flags = details[kSecCodeInfoFlags as String] as? UInt32
    else { return false }
    return flags & SecCodeSignatureFlags.adhoc.rawValue == 0 && details[kSecCodeInfoTeamIdentifier as String] != nil
  }
}

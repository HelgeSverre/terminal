import AppKit
import Security
import Sparkle

/// Software updates, through Sparkle.
///
/// The app looks for an update once as it launches and when asked from the
/// menu. It never looks on a timer: a running terminal does no background
/// work of its own. An update is offered, never installed unasked.
@MainActor final class Updates: NSObject {
  static let shared = Updates()

  private let controller: SPUStandardUpdaterController?

  /// Whether this copy of the app updates itself at all.
  var isEnabled: Bool { controller != nil }

  private override init() {
    let enabled = Self.updates(
      arguments: CommandLine.arguments,
      hasFeedKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String,
      signedForRelease: Self.isSignedForRelease)
    controller = enabled
      ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
      : nil
    super.init()
    // Sparkle would otherwise schedule its own checks while the app runs.
    controller?.updater.automaticallyChecksForUpdates = false
  }

  /// Only a released copy, started the ordinary way, updates itself. A
  /// local build has no place to update from and would be replaced by a
  /// release; a run with arguments is a measurement or a test.
  nonisolated static func updates(arguments: [String], hasFeedKey: Bool, signedForRelease: Bool) -> Bool {
    hasFeedKey && signedForRelease && arguments.count <= 1
  }

  /// The one check made without being asked. It says nothing unless an
  /// update exists.
  func checkAtLaunch() { controller?.updater.checkForUpdatesInBackground() }

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

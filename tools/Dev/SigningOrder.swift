import Foundation

/// How a release is signed. The release tool and the update rehearsal both
/// sign by this, so a rehearsal signs as a release does. The file has no
/// dependencies: `tools/Distribution.swift` is compiled with it by itself.
enum SigningOrder {
  /// The commands, in order, that sign `app` for distribution with the
  /// hardened runtime: Sparkle's own programs innermost first, as Sparkle
  /// documents for an app signed outside Xcode, then the launcher, then the
  /// app with its entitlements, then a check of the whole.
  static func commands(app: URL, identity: String, entitlements: String) -> [[String]] {
    let signing = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity]
    let updater = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
    let contents = updater.appendingPathComponent("Versions/B")
    return [
      signing + [contents.appendingPathComponent("XPCServices/Installer.xpc").path],
      // The downloader keeps the entitlements it was built with.
      signing + ["--preserve-metadata=entitlements", contents.appendingPathComponent("XPCServices/Downloader.xpc").path],
      signing + [contents.appendingPathComponent("Autoupdate").path],
      signing + [contents.appendingPathComponent("Updater.app").path],
      signing + [updater.path],
      signing + [app.appendingPathComponent("Contents/MacOS/TerminalLauncher").path],
      // The hardened runtime refuses a protected resource to the app, and so
      // to every program run inside it, unless the app is entitled to ask.
      // macOS still asks the user each time; these only make asking possible.
      signing + ["--entitlements", entitlements, app.path],
      ["codesign", "--verify", "--strict", "--deep", app.path],
    ]
  }
}

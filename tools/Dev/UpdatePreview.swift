import Foundation

/// Builds an isolated host for Sparkle's real update UI.
enum UpdatePreview {
  static let command = Command(
    name: "update-preview", usage: "",
    summary: "Open Sparkle with this version's release notes; no update can be installed.", run: run)

  static func run(_ arguments: [String]) throws {
    guard arguments.isEmpty else { throw Failure.usage(command) }
    let plistData = try Data(contentsOf: URL(fileURLWithPath: Repository.path("Resources/Terminal/Info.plist")))
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          let version = plist["CFBundleShortVersionString"] as? String else { throw Failure("missing bundle version") }
    let publisher = ReleasePublisher.Publisher(root: Repository.root, environment: [:]) { _, _ in CommandResult() }
    _ = try publisher.releaseNotes(version: version)
    try AppBundle.run(["development"])
    let scratch = Repository.path("target/update-preview")
    try Console.quietly(["swift", "build", "--package-path", Repository.root, "--scratch-path", scratch,
                         "-c", "debug", "--product", "UpdatePreview"])
    let result = try runCommand(["swift", "build", "--package-path", Repository.root, "--scratch-path", scratch,
                                 "-c", "debug", "--show-bin-path"])
    let products = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    // A unique cached bundle stays valid while the preview is open, even if
    // this checkout is removed or another preview is built.
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("no.helgesverre.terminal.update-preview")
      .appendingPathComponent(UUID().uuidString)
    let app = cache.appendingPathComponent("Update Preview.app").path
    try Console.quietly(["/usr/bin/ditto", Repository.path("dist/Terminal.app"), app])
    let executable = app + "/Contents/MacOS/Terminal"
    try FileManager.default.removeItem(atPath: executable)
    try Console.quietly(["/usr/bin/ditto", products + "/UpdatePreview", executable])
    // Preserve the real app's names, icon, and updater settings. Only isolate
    // its preferences, simulate an older installed copy, and disable installing.
    var info = plist
    info["CFBundleIdentifier"] = "no.helgesverre.terminal.update-preview"
    info["CFBundleVersion"] = "0"
    info["CFBundleShortVersionString"] = "0.0.0"
    info["SUEnableAutomaticChecks"] = false
    info["SUAutomaticallyUpdate"] = false
    info["SUEnableInstallerLauncherService"] = false
    info["NSAppTransportSecurity"] = ["NSAllowsLocalNetworking": true]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
    guard let build = plist["CFBundleVersion"] as? String,
          let minimum = plist["LSMinimumSystemVersion"] as? String else { throw Failure("missing update metadata") }
    let metadata = ReleasePublisher.Metadata(version: version, tag: "v" + version, sourceSHA: "", publish: false)
    let feed = try publisher.appcastXML(metadata: metadata, buildVersion: build, minimumSystemVersion: minimum,
                                       archiveBytes: 0, signature: "", archiveURL: "https://example.invalid/preview-only.zip")
    try Data(feed.utf8).write(to: URL(fileURLWithPath: app + "/Contents/Resources/appcast.xml"))
    try Console.quietly(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", app])
    print("Opening Sparkle preview for \(version). All buttons close the preview; nothing is installed.")
    try Console.quietly(["/usr/bin/open", "-n", app])
  }
}

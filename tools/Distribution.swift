import Foundation
import Darwin
import AppKit
import CryptoKit

// All distribution policy lives here. Recipes express package/release/status;
// callers do not order signing, notarization, stapling or validation.
struct Distribution {
  enum Failure: Error, CustomStringConvertible {
    case message(String)
    case command(String, Int32)
    var description: String {
      switch self {
      case .message(let text): return text
      case .command(let name, let status): return "\(name) failed (\(status))."
      }
    }
  }
  struct Configuration: Decodable {
    var notaryProfile: String?
    var applicationIdentity: String?
  }
  struct Submission: Decodable { let id: String; let status: String }
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let files = FileManager.default
  func run(_ arguments: [String]) throws -> Data {
    // EX_NOHOST can mean a ticket-service propagation delay even after the
    // matching notarization was accepted (observed for the 0.1.1 package).
    // Validation also queries that service. Retry only these ticket operations;
    // invalid/revoked tickets and other commands remain immediately fatal.
    let ticketCommand = arguments.starts(with: ["xcrun", "stapler"])
      && arguments.count > 2 && ["staple", "validate"].contains(arguments[2])
    for attempt in 0..<4 {
      do { return try executeCommand(arguments) }
      catch Failure.command(_, let status) where ticketCommand && status == EX_NOHOST && attempt < 3 {
        let delay = 1 << attempt
        print("Ticket service unavailable; retrying \(arguments[2]) in \(delay)s…")
        Thread.sleep(forTimeInterval: Double(delay))
      }
    }
    preconditionFailure("The final command attempt always returns or throws")
  }
  private func executeCommand(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure.command(arguments.first ?? "Command", process.terminationStatus)
    }
    return data
  }
  func configuration() throws -> Configuration {
    let path = files.homeDirectoryForCurrentUser.appendingPathComponent(".config/terminal/release.json")
    var value = files.fileExists(atPath: path.path)
      ? try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: path))
      : Configuration()
    let env = ProcessInfo.processInfo.environment
    value.notaryProfile = env["APPLE_NOTARY_PROFILE"] ?? value.notaryProfile
    value.applicationIdentity = env["APPLE_APPLICATION_SIGNING_IDENTITY"] ?? value.applicationIdentity
    return value
  }
  func identity(_ configured: String?, kind: String) throws -> String {
    if let configured, !configured.isEmpty { return configured }
    let output = String(decoding: try run(["security", "find-identity", "-v"]), as: UTF8.self)
    let matches = output.components(separatedBy: "\n").compactMap { line -> String? in
      let pieces = line.components(separatedBy: "\"")
      return pieces.count > 1 && pieces[1].hasPrefix("Developer ID \(kind):") ? pieces[1] : nil
    }
    guard matches.count == 1, let match = matches.first else {
      throw Failure.message("Configure one Developer ID \(kind) identity in ~/.config/terminal/release.json.")
    }
    return match
  }
  func notarize(_ archive: URL, profile: String, label: String, output: URL) throws {
    print("Submitting \(label) for notarization…")
    let data = try run(notaryCommand(["submit", archive.path,
      "--wait", "--output-format", "json"], profile: profile))
    try data.write(to: output.appendingPathComponent("notary-\(label).json"), options: .atomic)
    let submission = try JSONDecoder().decode(Submission.self, from: data)
    guard submission.status == "Accepted" else {
      let log = try run(notaryCommand(["log", submission.id], profile: profile))
      try log.write(to: output.appendingPathComponent("notary-\(label)-log.json"), options: .atomic)
      throw Failure.message("Notarization \(submission.status); see dist/release/notary-\(label)-log.json.")
    }
    print("Accepted \(label): \(submission.id)")
  }
  func notaryCommand(_ arguments: [String], profile: String) -> [String] {
    var command = ["xcrun", "notarytool"] + arguments + ["--keychain-profile", profile]
    if let keychain = ProcessInfo.processInfo.environment["APPLE_SIGNING_KEYCHAIN"],
      !keychain.isEmpty
    {
      command += ["--keychain", keychain]
    }
    return command
  }
  func execute(_ operation: String) throws {
    if operation == "install" || operation == "uninstall" {
      try install(removing: operation == "uninstall")
      return
    }
    guard ["package", "release", "status"].contains(operation) else {
      throw Failure.message("Use just package, just release or just release-status.")
    }
    let config = try configuration()
    let application = try identity(config.applicationIdentity, kind: "Application")
    if operation != "package" {
      guard let profile = config.notaryProfile, !profile.isEmpty else {
        throw Failure.message("Set APPLE_NOTARY_PROFILE or notaryProfile in ~/.config/terminal/release.json.")
      }
      _ = try run(notaryCommand(["history", "--output-format", "json"], profile: profile))
    }
    if operation == "status" {
      print("Application: \(application)\nNotarization credentials verified.")
      return
    }
    let source = root.appendingPathComponent("dist/Terminal.app")
    let metadata = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), format: nil)
    guard let info = metadata as? [String: Any],
      let identifier = info["CFBundleIdentifier"] as? String,
      identifier == "no.helgesverre.terminal",
      let version = info["CFBundleShortVersionString"] as? String
    else { throw Failure.message("Build a valid Terminal application first.") }
    let output = root.appendingPathComponent("dist/release")
    try files.createDirectory(at: output, withIntermediateDirectories: true)
    let stage = files.temporaryDirectory.appendingPathComponent("terminal-release-\(UUID().uuidString)")
    try files.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: stage) }
    let app = stage.appendingPathComponent("Helge Terminal.app")
    _ = try run(["ditto", source.path, app.path])
    // The hardened runtime refuses a protected resource to the app, and so
    // to every program run inside it, unless the app is entitled to ask.
    // macOS still asks the user each time; these only make asking possible.
    let entitlements = root.appendingPathComponent("Resources/Terminal/Terminal.entitlements").path
    let signing = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", application]
    // The updater's own programs first, innermost first, as Sparkle documents
    // for an app that is signed outside Xcode. Its downloader keeps the
    // entitlements it was built with.
    let updater = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
    let version = updater.appendingPathComponent("Versions/B")
    _ = try run(signing + [version.appendingPathComponent("XPCServices/Installer.xpc").path])
    _ = try run(signing + ["--preserve-metadata=entitlements", version.appendingPathComponent("XPCServices/Downloader.xpc").path])
    _ = try run(signing + [version.appendingPathComponent("Autoupdate").path])
    _ = try run(signing + [version.appendingPathComponent("Updater.app").path])
    _ = try run(signing + [updater.path])
    _ = try run(signing + [app.appendingPathComponent("Contents/MacOS/TerminalLauncher").path])
    _ = try run(signing + ["--entitlements", entitlements, app.path])
    _ = try run(["codesign", "--verify", "--strict", "--deep", app.path])
    let archive = output.appendingPathComponent("HelgeTerminal-\(version)-arm64.zip")
    if files.fileExists(atPath: archive.path) { try files.removeItem(at: archive) }
    _ = try run(["ditto", "-c", "-k", "--keepParent", "--sequesterRsrc", app.path, archive.path])
    if operation == "release", let profile = config.notaryProfile {
      try notarize(archive, profile: profile, label: "app", output: output)
      _ = try run(["xcrun", "stapler", "staple", app.path])
      _ = try run(["xcrun", "stapler", "validate", app.path])
      _ = try run(["spctl", "--assess", "--type", "execute", app.path])
      try files.removeItem(at: archive)
      _ = try run(["ditto", "-c", "-k", "--keepParent", "--sequesterRsrc", app.path, archive.path])
    }
    let installed = output.appendingPathComponent("Helge Terminal.app")
    if files.fileExists(atPath: installed.path) { try files.removeItem(at: installed) }
    try files.moveItem(at: app, to: installed)
    print("\(operation == "release" ? "Notarized" : "Signed") app: \(output.path)")
  }
  // Signatures differ between development and release. Linker UUIDs identify
  // code; hash every other payload file so stale shaders/icons/metadata cannot
  // accidentally select an older notarized application.
  func payload(_ app: URL) throws -> String {
    var hasher = SHA256()
    for executable in ["Terminal", "TerminalLauncher"] {
      let data = try run(["xcrun", "dwarfdump", "--uuid", app.appendingPathComponent("Contents/MacOS/\(executable)").path])
      let tokens = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
      guard tokens.count >= 2, UUID(uuidString: String(tokens[1])) != nil else {
        throw Failure.message("Missing executable identity.")
      }
      hasher.update(data: Data(tokens[1].utf8))
    }
    guard let entries = files.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey]) else {
      throw Failure.message("Cannot read bundle payload.")
    }
    let paths = entries.compactMap { $0 as? URL }.filter { url in
      let path = String(url.path.dropFirst(app.path.count + 1))
      return !path.hasPrefix("Contents/_CodeSignature/")
        && path != "Contents/CodeResources" // Apple's stapled notarization ticket.
        && path != "Contents/MacOS/Terminal" && path != "Contents/MacOS/TerminalLauncher"
        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.sorted { $0.path < $1.path }
    for path in paths {
      hasher.update(data: Data(path.path.dropFirst(app.path.count).utf8))
      hasher.update(data: try Data(contentsOf: path))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
  func install(removing: Bool) throws {
    let directory = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    let destination = directory.appendingPathComponent("Helge Terminal.app")
    if files.fileExists(atPath: destination.path) {
      let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
      let id = Bundle(url: destination)?.bundleIdentifier
      guard values.isSymbolicLink != true,
        id == "no.helgesverre.terminal" || id == "no.helge.terminal" else {
        throw Failure.message("Refusing to change an unrelated application at \(destination.path).")
      }
      guard !NSWorkspace.shared.runningApplications.contains(where: {
        $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
      }) else { throw Failure.message("Quit the installed Helge Terminal first; its sessions are still running.") }
    }
    if removing {
      if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
      print("Uninstalled Helge Terminal; preferences preserved.")
      return
    }
    var source = root.appendingPathComponent("dist/Terminal.app")
    let release = root.appendingPathComponent("dist/release/Helge Terminal.app")
    // Fingerprinting a bundle that is not there only prints a tool's error.
    if files.fileExists(atPath: release.path),
      let released = try? payload(release), released == (try? payload(source)),
      (try? run(["spctl", "--assess", "--type", "execute", release.path])) != nil {
      source = release
      print("Installing the matching notarized build.")
    }
    _ = try run(["codesign", "--verify", "--strict", "--deep", source.path])
    guard Bundle(url: source)?.bundleIdentifier == "no.helgesverre.terminal" else {
      throw Failure.message("Unexpected installation source.")
    }
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let stage = directory.appendingPathComponent(".terminal-install-\(UUID().uuidString)")
    try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var preserveStage = false
    defer { if !preserveStage { try? files.removeItem(at: stage) } }
    let replacement = stage.appendingPathComponent("new.app")
    let previous = stage.appendingPathComponent("previous.app")
    _ = try run(["ditto", source.path, replacement.path])
    _ = try run(["codesign", "--verify", "--strict", "--deep", replacement.path])
    if files.fileExists(atPath: destination.path) { try files.moveItem(at: destination, to: previous) }
    do { try files.moveItem(at: replacement, to: destination) }
    catch {
      if files.fileExists(atPath: previous.path) {
        do { try files.moveItem(at: previous, to: destination) }
        catch { preserveStage = true; throw Failure.message("Restore the previous app from \(previous.path).") }
      }
      throw error
    }
    print("Installed \(destination.path)")
  }
}

#if !DISTRIBUTION_TESTING
@main struct DistributionCommand {
  static func main() {
    do {
      setbuf(stdout, nil)
      try Distribution().execute(CommandLine.arguments.dropFirst().first ?? "status")
    } catch {
      fputs("Distribution failed: \(error)\n", stderr)
      exit(1)
    }
  }
}
#endif

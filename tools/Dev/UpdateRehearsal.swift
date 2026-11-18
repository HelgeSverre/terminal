import ApplicationServices
import CryptoKit
import Foundation
import Network

/// Rehearses a real update on this Mac, with nothing published: two private
/// copies of the development build under their own bundle identifier, an
/// older "installed" one and the current one as its update, a feed served on
/// loopback and a signing key made for the run. Sparkle in the installed copy
/// downloads, verifies, installs and relaunches as it does for a release,
/// while the copy's panes run real programs that must survive it.
enum UpdateRehearsal {
  static let command = Command(
    name: "update-rehearsal",
    usage: "[--signed] [--windows | --manual] [--published] [--keep-open] [--scenario PATH] [--timeout SECONDS]",
    summary: "Install a local update through Sparkle while programs run; nothing is published.", run: run)

  private static let identifier = "no.helgesverre.terminal.update-rehearsal"
  private static let defaultScenario: [String: Any] = [
    "settle": 6,
    "panes": [
      ["name": "shell", "command": "seq 1 500; echo before-update", "probe": "echo UPDATED_$((6*7))\r", "expect": "UPDATED_42"],
      ["name": "vim", "command": "vim -u NONE", "probe": "ihello_update\u{1b}", "expect": "hello_update"],
      // One process that keeps writing: a shell loop would start a new `sleep` each turn.
      ["name": "output", "command": #"perl -e '$|=1; while(1){print "line ",$i++,"\n"; select(undef,undef,undef,0.05)}'"#,
       "animated": true],
    ],
  ]

  static func run(_ arguments: [String]) throws {
    var manual = false, keepOpen = false, scenarioPath: String?, timeout = 240.0
    var signed = false, windows = false, published = false
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--manual": manual = true
      // Developer ID signatures with the hardened runtime, and a notarized,
      // stapled update, as a release has.
      case "--signed": signed = true
      // Sparkle's own windows, with this tool pressing their buttons.
      case "--windows": windows = true
      // The update is the published release from the published feed, checked
      // with the published key. That release decides what survives it.
      case "--published": published = true; signed = true
      case "--keep-open": keepOpen = true
      case "--scenario" where index + 1 < arguments.count: index += 1; scenarioPath = arguments[index]
      case "--timeout" where index + 1 < arguments.count:
        index += 1
        guard let seconds = Double(arguments[index]), seconds > 0 else { throw Failure.usage(command) }
        timeout = seconds
      default: throw Failure.usage(command)
      }
      index += 1
    }
    guard !(manual && windows) else { throw Failure.usage(command) }
    if windows, !AXIsProcessTrusted() {
      throw Failure("--windows presses Sparkle's buttons and needs Accessibility permission for the app running this command")
    }
    let identity = signed ? try developerIdentity() : nil
    let profile = signed && !published ? try notaryProfile() : nil
    let plistData = try Data(contentsOf: URL(fileURLWithPath: Repository.path("Resources/Terminal/Info.plist")))
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
      let version = plist["CFBundleShortVersionString"] as? String, let build = plist["CFBundleVersion"] as? String,
      let minimum = plist["LSMinimumSystemVersion"] as? String else { throw Failure("missing bundle version") }
    let publisher = ReleasePublisher.Publisher(root: Repository.root, environment: [:]) { _, _ in CommandResult() }
    _ = try publisher.releaseNotes(version: version)
    try AppBundle.run(["development"])

    let runs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(identifier)
    // Each run leaves two bundles and an archive behind for inspection.
    // Runs older than an hour are finished and are removed here.
    let stale = Date().addingTimeInterval(-3600)
    for run in (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
      if let created = try? run.resourceValues(forKeys: [.creationDateKey]).creationDate, created < stale {
        try? FileManager.default.removeItem(at: run)
      }
    }
    let scratch = runs.appendingPathComponent(UUID().uuidString)
    let installed = scratch.appendingPathComponent("Installed/Helge Terminal Rehearsal.app")
    let update = scratch.appendingPathComponent("update/Helge Terminal Rehearsal.app")
    let feed = scratch.appendingPathComponent("feed"), smoke = scratch.appendingPathComponent("smoke")
    for directory in [installed.deletingLastPathComponent(), update.deletingLastPathComponent(), feed, smoke] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let server = try FeedServer(directory: feed)
    let key = Curve25519.Signing.PrivateKey()
    func make(_ app: URL, version: String, build: String) throws {
      try Console.quietly(["/usr/bin/ditto", Repository.path("dist/Terminal.app"), app.path])
      var info = plist
      info["CFBundleIdentifier"] = identifier
      info["CFBundleName"] = "Helge Terminal Rehearsal"
      info["CFBundleVersion"] = build
      info["CFBundleShortVersionString"] = version
      // Against the published feed, the feed and key the release carries stay.
      if !published {
        info["SUFeedURL"] = "http://127.0.0.1:\(server.port)/appcast.xml"
        info["SUPublicEDKey"] = key.publicKey.rawRepresentation.base64EncodedString()
        info["NSAppTransportSecurity"] = ["NSAllowsLocalNetworking": true]
      }
      info["SUEnableAutomaticChecks"] = false
      info["TerminalUpdateRehearsal"] = [
        "handoff": scratch.appendingPathComponent("handoff").path, "smoke": smoke.path, "automatic": !(manual || windows),
      ] as [String: Any]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      if let identity { try sign(app, identity: identity) }
      else { try Console.quietly(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", app.path]) }
    }
    // The installed copy is older than anything real; its update is this build.
    try make(installed, version: "0.0.1", build: "1")
    if published { return try rehearsePublished(installed: installed, smoke: smoke, scratch: scratch, timeout: timeout) }
    try make(update, version: version, build: build)
    let archive = feed.appendingPathComponent("update.zip")
    if let profile {
      print("Notarizing the update (this uploads the rehearsal build to Apple's notary service)…")
      try notarize(update, profile: profile, scratch: scratch)
    }
    try Console.quietly(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", update.path, archive.path])
    let bytes = try Data(contentsOf: archive)
    let metadata = ReleasePublisher.Metadata(version: version, tag: "v" + version, sourceSHA: "", publish: false)
    let appcast = try publisher.appcastXML(
      metadata: metadata, buildVersion: build, minimumSystemVersion: minimum, archiveBytes: bytes.count,
      signature: try UpdateKey.sign(bytes, with: key), archiveURL: "http://127.0.0.1:\(server.port)/update.zip")
    try Data(appcast.utf8).write(to: feed.appendingPathComponent("appcast.xml"))

    var scenario = defaultScenario
    if let scenarioPath {
      guard let data = FileManager.default.contents(atPath: scenarioPath),
        let given = try? JSONSerialization.jsonObject(with: data) as? [String: Any], given["panes"] is [Any] else {
        throw Failure("cannot read a scenario with panes from \(scenarioPath)")
      }
      scenario = given
    }
    scenario["rounds"] = 1
    scenario["update"] = true
    scenario["keepOpen"] = keepOpen
    try JSONSerialization.data(withJSONObject: scenario, options: [.prettyPrinted])
      .write(to: smoke.appendingPathComponent("scenario.json"))

    print("Rehearsal in \(scratch.path)")
    print("Installed 0.0.1 (1); the feed offers \(version) (\(build)). Opening a window that will run programs, then update.")
    if manual { print("Sparkle will ask: choose Install Update, then Install and Relaunch.") }
    try Console.quietly(["/usr/bin/open", "-n", installed.path])

    let result = smoke.appendingPathComponent("round-1.json")
    let deadline = Date().addingTimeInterval(timeout)
    var pressed: [String] = []
    while !FileManager.default.fileExists(atPath: result.path), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      if windows { pressed += pressUpdateButtons(in: installed, except: pressed) }
    }
    if windows {
      print("Pressed in Sparkle's windows: " + (pressed.isEmpty ? "nothing" : pressed.joined(separator: ", ")))
      guard pressed.contains("Install Update") else { throw Failure("Sparkle's update window was never found") }
    }
    let log = (try? String(contentsOf: smoke.appendingPathComponent("sparkle.log"), encoding: .utf8)) ?? ""
    if !log.isEmpty { print("Sparkle: " + log.split(separator: "\n").joined(separator: "; ")) }
    print("Feed requests: " + server.requests.joined(separator: ", "))
    guard let data = FileManager.default.contents(atPath: result.path),
      let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Failure("no result within \(Int(timeout)) s: the update did not finish or the new copy did not adopt the sessions")
    }
    let installedInfo = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
    let installedBuild = installedInfo?["CFBundleVersion"] as? String ?? "?"
    let adoptedBy = report["appBuild"] as? String ?? "?"
    for pane in report["panes"] as? [[String: Any]] ?? [] {
      let checks = ["sameProcess", "descendantsKept", "gridKept", "animated", "probed"].compactMap { name in
        (pane[name] as? Bool).map { "\(name) \($0 ? "yes" : "NO")" }
      }
      print("  \(pane["name"] as? String ?? "?"): " + checks.joined(separator: ", "))
    }
    print("Installed bundle is now build \(installedBuild); sessions adopted by build \(adoptedBy).")
    guard report["passed"] as? Bool == true, installedBuild == build, adoptedBy == build else {
      throw Failure("update rehearsal failed; see \(smoke.path)")
    }
    if signed {
      // What Gatekeeper says of the bundle Sparkle put in place.
      try Console.quietly(["/usr/bin/codesign", "--verify", "--strict", "--deep", installed.path])
      try Console.quietly(["/usr/bin/xcrun", "stapler", "validate", installed.path])
      let assessment = try runCommand(["/usr/sbin/spctl", "--assess", "--type", "execute", "-vv", installed.path])
      print("Gatekeeper: " + assessment.output.split(separator: "\n").joined(separator: "; "))
      guard assessment.succeeded else { throw Failure("Gatekeeper rejects the installed update") }
    }
    print("Update rehearsal passed: Sparkle installed \(version) (\(build)) and every program kept running.")
  }

  /// The published release, installed over a private copy by the published
  /// feed. It proves the feed, the key and the release's signature against a
  /// Developer ID signed host; sessions are handed off but that release
  /// predates adoption, so nothing is expected to take them.
  private static func rehearsePublished(installed: URL, smoke: URL, scratch: URL, timeout: Double) throws {
    let scenario: [String: Any] = ["settle": 3, "rounds": 1, "update": true,
      "panes": [["name": "shell", "command": "echo before-update"]]]
    try JSONSerialization.data(withJSONObject: scenario).write(to: smoke.appendingPathComponent("scenario.json"))
    print("Rehearsal in \(scratch.path)")
    print("Installed 0.0.1 (1), Developer ID signed; Sparkle asks the published feed.")
    try Console.quietly(["/usr/bin/open", "-n", installed.path])
    let info = installed.appendingPathComponent("Contents/Info.plist")
    func installedIdentifier() -> String { NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String ?? "" }
    let deadline = Date().addingTimeInterval(timeout)
    while installedIdentifier() == identifier, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    Thread.sleep(forTimeInterval: 4)
    let log = (try? String(contentsOf: smoke.appendingPathComponent("sparkle.log"), encoding: .utf8)) ?? ""
    print("Sparkle: " + log.split(separator: "\n").joined(separator: "; "))
    // Whatever runs from the rehearsal directory was started by this run.
    let listing = try runCommand(["/bin/ps", "-axo", "pid=,command="]).output
    for line in listing.split(separator: "\n") where line.contains(scratch.path) || line.contains("--session-keeper") && line.contains(identifier) {
      if let pid = Int32(line.split(separator: " ").first ?? ""), pid != getpid() { kill(pid, SIGTERM) }
    }
    guard installedIdentifier() != identifier else { throw Failure("Sparkle did not install the published release; see \(smoke.path)") }
    let now = NSDictionary(contentsOf: info)
    print("Installed bundle is now \(installedIdentifier()) \(now?["CFBundleShortVersionString"] ?? "?") (\(now?["CFBundleVersion"] ?? "?")).")
    try Console.quietly(["/usr/bin/codesign", "--verify", "--strict", "--deep", installed.path])
    try Console.quietly(["/usr/bin/xcrun", "stapler", "validate", installed.path])
    let assessment = try runCommand(["/usr/sbin/spctl", "--assess", "--type", "execute", "-vv", installed.path])
    print("Gatekeeper: " + assessment.output.split(separator: "\n").joined(separator: "; "))
    guard assessment.succeeded else { throw Failure("Gatekeeper rejects the installed release") }
    print("Published update passed: Sparkle took the release from the published feed, verified it and installed it.")
  }

  private static func developerIdentity() throws -> String {
    if let configured = ProcessInfo.processInfo.environment["APPLE_APPLICATION_SIGNING_IDENTITY"], !configured.isEmpty { return configured }
    let output = try runCommand(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).output
    let matches = output.split(separator: "\n").compactMap { line -> String? in
      let pieces = line.components(separatedBy: "\"")
      return pieces.count > 1 && pieces[1].hasPrefix("Developer ID Application:") ? pieces[1] : nil
    }
    guard matches.count == 1 else { throw Failure("--signed needs exactly one Developer ID Application identity in the keychain") }
    return matches[0]
  }
  private static func notaryProfile() throws -> String {
    if let profile = ProcessInfo.processInfo.environment["APPLE_NOTARY_PROFILE"], !profile.isEmpty { return profile }
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/terminal/release.json")
    guard let data = try? Data(contentsOf: path), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profile = values["notaryProfile"] as? String, !profile.isEmpty else {
      throw Failure("--signed needs APPLE_NOTARY_PROFILE or notaryProfile in ~/.config/terminal/release.json")
    }
    return profile
  }
  /// The release's signing order: Sparkle's programs innermost first, then
  /// the launcher, then the app with its entitlements.
  private static func sign(_ app: URL, identity: String) throws {
    let signing = ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity]
    let sparkle = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
    let contents = sparkle.appendingPathComponent("Versions/B")
    try Console.quietly(signing + [contents.appendingPathComponent("XPCServices/Installer.xpc").path])
    try Console.quietly(signing + ["--preserve-metadata=entitlements", contents.appendingPathComponent("XPCServices/Downloader.xpc").path])
    try Console.quietly(signing + [contents.appendingPathComponent("Autoupdate").path])
    try Console.quietly(signing + [contents.appendingPathComponent("Updater.app").path])
    try Console.quietly(signing + [sparkle.path])
    try Console.quietly(signing + [app.appendingPathComponent("Contents/MacOS/TerminalLauncher").path])
    try Console.quietly(signing + ["--entitlements", Repository.path("Resources/Terminal/Terminal.entitlements"), app.path])
    try Console.quietly(["/usr/bin/codesign", "--verify", "--strict", "--deep", app.path])
  }
  private static func notarize(_ app: URL, profile: String, scratch: URL) throws {
    let archive = scratch.appendingPathComponent("notarize.zip")
    try Console.quietly(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path])
    let result = try runCommand(["/usr/bin/xcrun", "notarytool", "submit", archive.path, "--wait",
                                 "--output-format", "json", "--keychain-profile", profile], errors: .separate)
    guard let values = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
      values["status"] as? String == "Accepted" else {
      throw Failure("notarization was not accepted: \(result.output.prefix(600))")
    }
    print("Notarization accepted: \(values["id"] as? String ?? "")")
    try Console.quietly(["/usr/bin/xcrun", "stapler", "staple", app.path])
    try? FileManager.default.removeItem(at: archive)
  }
  /// Presses the buttons a person would in Sparkle's windows, and returns
  /// the titles pressed this time.
  private static func pressUpdateButtons(in app: URL, except done: [String]) -> [String] {
    guard let listing = try? runCommand(["/usr/bin/pgrep", "-f", app.path + "/Contents/MacOS/"]).output else { return [] }
    var pressed: [String] = []
    for pid in listing.split(separator: "\n").compactMap({ pid_t($0) }) {
      var windows: CFTypeRef?
      let application = AXUIElementCreateApplication(pid)
      guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success,
        let list = windows as? [AXUIElement] else { continue }
      var queue = list, visited = 0
      while let element = queue.popLast(), visited < 2000 {
        visited += 1
        var role: CFTypeRef?, title: CFTypeRef?, children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        if role as? String == kAXButtonRole as String, let title = title as? String,
          ["Install Update", "Install and Relaunch"].contains(title), !done.contains(title), !pressed.contains(title),
          AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
          pressed.append(title)
        }
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let more = children as? [AXUIElement] { queue += more }
      }
    }
    return pressed
  }

  /// Serves the files of one directory to this Mac only, and remembers
  /// what was asked for.
  private final class FeedServer {
    private final class Log {
      private let lock = NSLock()
      private var entries: [String] = []
      func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
      var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }
    let port: UInt16
    private let listener: NWListener
    private let log = Log()
    var requests: [String] { log.all }

    init(directory: URL) throws {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      let ready = DispatchSemaphore(value: 0)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready, .failed, .cancelled: ready.signal()
        default: break
        }
      }
      let queue = DispatchQueue(label: "update-rehearsal.feed")
      let log = log
      listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { request, _, _, _ in
          let line = request.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
          let fields = line.split(separator: " ")
          let name = fields.count > 1 ? String(fields[1].dropFirst().prefix { $0 != "?" }) : ""
          let body = name.isEmpty || name.contains("/") || name.contains("..") ? nil
            : FileManager.default.contents(atPath: directory.appendingPathComponent(name).path)
          log.add("\(fields.first ?? "?") /\(name) \(body == nil ? 404 : 200)")
          let status = body == nil ? "404 Not Found" : "200 OK"
          let type = name.hasSuffix(".xml") ? "application/xml" : "application/octet-stream"
          let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
          let payload = fields.first == "HEAD" ? Data() : (body ?? Data())
          connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
      }
      listener.start(queue: queue)
      ready.wait()
      guard let port = listener.port?.rawValue else { throw Failure("cannot serve the rehearsal feed on loopback") }
      self.port = port
    }
  }
}

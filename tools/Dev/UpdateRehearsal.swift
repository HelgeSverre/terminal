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
  private static var defaultScenario: [String: Any] {
    [
      "settle": 6,
      "panes": [
        ["name": "shell", "command": "seq 1 500; echo before-update", "probe": "echo UPDATED_$((6*7))\r", "expect": "UPDATED_42"],
        ["name": "vim", "command": "vim -u NONE", "probe": "ihello_update\u{1b}", "expect": "hello_update"],
        // One process that keeps writing: a shell loop would start a new `sleep` each turn.
        ["name": "output", "command": #"perl -e '$|=1; while(1){print "line ",$i++,"\n"; select(undef,undef,undef,0.05)}'"#,
         "animated": true],
      ],
    ]
  }

  private struct Options {
    var manual = false, keepOpen = false, signed = false, windows = false, published = false
    var scenarioPath: String?
    var timeout = 240.0

    init(_ arguments: [String]) throws {
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
    }
  }

  /// One run's files: two bundles, the feed and what the copies report.
  private struct Files {
    let scratch: URL, installed: URL, update: URL, feed: URL, smoke: URL

    init() throws {
      let runs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(identifier)
      // A run that failed keeps its files for inspection. Those older than
      // an hour have been looked at or never will be.
      let stale = Date().addingTimeInterval(-3600)
      for run in (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
        if let created = try? run.resourceValues(forKeys: [.creationDateKey]).creationDate, created < stale {
          try? FileManager.default.removeItem(at: run)
        }
      }
      scratch = runs.appendingPathComponent(UUID().uuidString)
      installed = scratch.appendingPathComponent("Installed/Helge Terminal Rehearsal.app")
      update = scratch.appendingPathComponent("update/Helge Terminal Rehearsal.app")
      feed = scratch.appendingPathComponent("feed")
      smoke = scratch.appendingPathComponent("smoke")
      for directory in [installed.deletingLastPathComponent(), update.deletingLastPathComponent(), feed, smoke] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    }

    /// Every process running from this run's directory: its copies of the
    /// app and their keepers. Nothing else on the Mac runs from there.
    func processes() -> [pid_t] {
      guard let listing = try? runCommand(["/bin/ps", "-axo", "pid=,command="]).output else { return [] }
      return listing.split(separator: "\n").filter { $0.contains(scratch.path) }
        .compactMap { pid_t($0.split(separator: " ").first ?? "") }.filter { $0 != getpid() }
    }

    /// Ends what the run started and removes what it left on the Mac. The
    /// files of a failed run stay, to be looked at.
    func cleanUp(passed: Bool) {
      let deadline = Date().addingTimeInterval(5)
      while !processes().isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
      for pid in processes() { kill(pid, SIGTERM) }
      // The copies' own settings and Sparkle's stored responses.
      _ = try? runCommand(["/usr/bin/defaults", "delete", identifier])
      let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      for name in ["Preferences/\(identifier).plist", "HTTPStorages/\(identifier)", "HTTPStorages/\(identifier).binarycookies"] {
        try? FileManager.default.removeItem(at: library.appendingPathComponent(name))
      }
      if passed { try? FileManager.default.removeItem(at: scratch) }
      // The runs share their directory with the copies' own cache, which
      // goes when no run is left in it.
      let runs = scratch.deletingLastPathComponent()
      let left = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
      if !left.contains(where: { UUID(uuidString: $0) != nil }) { try? FileManager.default.removeItem(at: runs) }
    }
  }

  static func run(_ arguments: [String]) throws {
    let options = try Options(arguments)
    if options.windows, !AXIsProcessTrusted() {
      throw Failure("--windows presses Sparkle's buttons and needs Accessibility permission for the app running this command")
    }
    let identity = options.signed ? try developerIdentity() : nil
    let profile = options.signed && !options.published ? try notaryProfile() : nil
    let plistData = try Data(contentsOf: URL(fileURLWithPath: Repository.path("Resources/Terminal/Info.plist")))
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
      let version = plist["CFBundleShortVersionString"] as? String, let build = plist["CFBundleVersion"] as? String,
      let minimum = plist["LSMinimumSystemVersion"] as? String else { throw Failure("missing bundle version") }
    let publisher = ReleasePublisher.Publisher(root: Repository.root, environment: [:]) { _, _ in CommandResult() }
    _ = try publisher.releaseNotes(version: version)
    try AppBundle.run(["development"])

    let files = try Files()
    var passed = false
    defer {
      if options.keepOpen { print("Left open; the run's files are in \(files.scratch.path)") }
      else { files.cleanUp(passed: passed) }
    }
    let server = try FeedServer(directory: files.feed)
    let key = Curve25519.Signing.PrivateKey()
    func make(_ app: URL, version: String, build: String) throws {
      try Console.quietly(["/usr/bin/ditto", Repository.path("dist/Terminal.app"), app.path])
      var info = plist
      info["CFBundleIdentifier"] = identifier
      info["CFBundleName"] = "Helge Terminal Rehearsal"
      info["CFBundleVersion"] = build
      info["CFBundleShortVersionString"] = version
      // Against the published feed, the feed and key the release carries stay.
      if !options.published {
        info["SUFeedURL"] = "http://127.0.0.1:\(server.port)/appcast.xml"
        info["SUPublicEDKey"] = key.publicKey.rawRepresentation.base64EncodedString()
        info["NSAppTransportSecurity"] = ["NSAllowsLocalNetworking": true]
      }
      info["SUEnableAutomaticChecks"] = false
      info["TerminalUpdateRehearsal"] = [
        "handoff": files.scratch.appendingPathComponent("handoff").path, "smoke": files.smoke.path,
        "automatic": !(options.manual || options.windows),
      ] as [String: Any]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      if let identity {
        let entitlements = Repository.path("Resources/Terminal/Terminal.entitlements")
        for command in SigningOrder.commands(app: app, identity: identity, entitlements: entitlements) {
          try Console.quietly(command)
        }
      } else { try Console.quietly(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", app.path]) }
    }
    // The installed copy is older than anything real; its update is this build.
    try make(files.installed, version: "0.0.1", build: "1")
    if options.published {
      try rehearsePublished(files, timeout: options.timeout)
      passed = true
      return
    }
    try make(files.update, version: version, build: build)
    let archive = files.feed.appendingPathComponent("update.zip")
    if let profile {
      print("Notarizing the update (this uploads the rehearsal build to Apple's notary service)…")
      try notarize(files.update, profile: profile, scratch: files.scratch)
    }
    try Console.quietly(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", files.update.path, archive.path])
    let bytes = try Data(contentsOf: archive)
    let metadata = ReleasePublisher.Metadata(version: version, tag: "v" + version, sourceSHA: "", publish: false)
    let appcast = try publisher.appcastXML(
      metadata: metadata, buildVersion: build, minimumSystemVersion: minimum, archiveBytes: bytes.count,
      signature: try UpdateKey.sign(bytes, with: key), archiveURL: "http://127.0.0.1:\(server.port)/update.zip")
    try Data(appcast.utf8).write(to: files.feed.appendingPathComponent("appcast.xml"))
    try writeScenario(options, to: files.smoke)

    print("Installed 0.0.1 (1); the feed offers \(version) (\(build)). Opening a window that will run programs, then update.")
    if options.manual { print("Sparkle will ask: choose Install Update, then Install and Relaunch.") }
    try Console.quietly(["/usr/bin/open", "-n", files.installed.path])

    let result = files.smoke.appendingPathComponent("round-1.json")
    let deadline = Date().addingTimeInterval(options.timeout)
    var pressed: [String] = []
    while !FileManager.default.fileExists(atPath: result.path), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      if options.windows { pressed += pressUpdateButtons(in: files.installed, except: pressed) }
    }
    if options.windows {
      print("Pressed in Sparkle's windows: " + (pressed.isEmpty ? "nothing" : pressed.joined(separator: ", ")))
      guard pressed.contains("Install Update") else { throw Failure("Sparkle's update window was never found") }
    }
    printSparkleLog(files)
    print("Feed requests: " + server.requests.joined(separator: ", "))
    guard let data = FileManager.default.contents(atPath: result.path),
      let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Failure("no result within \(Int(options.timeout)) s: the update did not finish or the new copy did not adopt the sessions; see \(files.smoke.path)")
    }
    let installedInfo = NSDictionary(contentsOf: files.installed.appendingPathComponent("Contents/Info.plist"))
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
      throw Failure("update rehearsal failed; see \(files.smoke.path)")
    }
    if options.signed { try assess(files.installed) }
    passed = true
    print("Update rehearsal passed: Sparkle installed \(version) (\(build)) and every program kept running.")
  }

  private static func writeScenario(_ options: Options, to smoke: URL) throws {
    var scenario = defaultScenario
    if let path = options.scenarioPath {
      guard let data = FileManager.default.contents(atPath: path),
        let given = try? JSONSerialization.jsonObject(with: data) as? [String: Any], given["panes"] is [Any] else {
        throw Failure("cannot read a scenario with panes from \(path)")
      }
      scenario = given
    }
    scenario["rounds"] = 1
    scenario["update"] = true
    scenario["keepOpen"] = options.keepOpen
    try JSONSerialization.data(withJSONObject: scenario, options: [.prettyPrinted])
      .write(to: smoke.appendingPathComponent("scenario.json"))
  }
  private static func printSparkleLog(_ files: Files) {
    let log = (try? String(contentsOf: files.smoke.appendingPathComponent("sparkle.log"), encoding: .utf8)) ?? ""
    if !log.isEmpty { print("Sparkle: " + log.split(separator: "\n").joined(separator: "; ")) }
  }
  /// What the system says of the bundle Sparkle put in place: its signature
  /// holds, its notarization ticket is attached and Gatekeeper lets it run.
  private static func assess(_ app: URL) throws {
    try Console.quietly(["/usr/bin/codesign", "--verify", "--strict", "--deep", app.path])
    try Console.quietly(["/usr/bin/xcrun", "stapler", "validate", app.path])
    let assessment = try runCommand(["/usr/sbin/spctl", "--assess", "--type", "execute", "-vv", app.path])
    print("Gatekeeper: " + assessment.output.split(separator: "\n").joined(separator: "; "))
    guard assessment.succeeded else { throw Failure("Gatekeeper rejects the installed bundle") }
  }

  /// The published release, installed over a private copy by the published
  /// feed. It proves the feed, the key and the release's signature against a
  /// Developer ID signed host; sessions are handed off, and whether they are
  /// taken up depends on what that release does.
  private static func rehearsePublished(_ files: Files, timeout: Double) throws {
    let scenario: [String: Any] = ["settle": 3, "rounds": 1, "update": true,
      "panes": [["name": "shell", "command": "echo before-update"]]]
    try JSONSerialization.data(withJSONObject: scenario).write(to: files.smoke.appendingPathComponent("scenario.json"))
    print("Installed 0.0.1 (1), Developer ID signed; Sparkle asks the published feed.")
    try Console.quietly(["/usr/bin/open", "-n", files.installed.path])
    let info = files.installed.appendingPathComponent("Contents/Info.plist")
    func installedIdentifier() -> String { NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String ?? "" }
    let deadline = Date().addingTimeInterval(timeout)
    while installedIdentifier() == identifier, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    // The release that was installed is started, and is not this tool's to
    // drive: it is given a moment to come up and is then ended.
    Thread.sleep(forTimeInterval: 4)
    printSparkleLog(files)
    for pid in files.processes() { kill(pid, SIGTERM) }
    guard installedIdentifier() != identifier else {
      throw Failure("Sparkle did not install the published release; see \(files.smoke.path)")
    }
    let now = NSDictionary(contentsOf: info)
    print("Installed bundle is now \(installedIdentifier()) \(now?["CFBundleShortVersionString"] ?? "?") (\(now?["CFBundleVersion"] ?? "?")).")
    try assess(files.installed)
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
    private final class Log: @unchecked Sendable {
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

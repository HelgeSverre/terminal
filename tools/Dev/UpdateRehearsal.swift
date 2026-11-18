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
    name: "update-rehearsal", usage: "[--manual] [--keep-open] [--scenario PATH] [--timeout SECONDS]",
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
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--manual": manual = true
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
      info["SUFeedURL"] = "http://127.0.0.1:\(server.port)/appcast.xml"
      info["SUPublicEDKey"] = key.publicKey.rawRepresentation.base64EncodedString()
      info["SUEnableAutomaticChecks"] = false
      info["NSAppTransportSecurity"] = ["NSAllowsLocalNetworking": true]
      info["TerminalUpdateRehearsal"] = [
        "handoff": scratch.appendingPathComponent("handoff").path, "smoke": smoke.path, "automatic": !manual,
      ] as [String: Any]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      try Console.quietly(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", app.path])
    }
    // The installed copy is older than anything real; its update is this build.
    try make(installed, version: "0.0.1", build: "1")
    try make(update, version: version, build: build)
    let archive = feed.appendingPathComponent("update.zip")
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
    while !FileManager.default.fileExists(atPath: result.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
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
    print("Update rehearsal passed: Sparkle installed \(version) (\(build)) and every program kept running.")
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

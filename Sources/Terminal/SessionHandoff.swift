import AppKit
import TerminalEngine
import TerminalHost
import TerminalUI

/// What one app leaves for the next: the windows as recovery saves them, and
/// for each pane whose program is still running, where its terminal state is
/// and which of the keeper's descriptors is its PTY.
struct HandoffManifest: Codable {
  struct Pane: Codable {
    var id: PaneID
    /// Position among the keeper's descriptors.
    var index: Int
    var pid: Int32
    var columns: Int
    var rows: Int
    var executable: String
    var arguments: [String]
    var cwd: String
    var environment: [String: String]
  }
  var version = 1
  var created = Date()
  var appBuild: String
  var socket: String
  var descriptorCount: Int
  var layout: SessionLayout
  var panes: [Pane]
}

enum SessionHandoffLocation {
  /// Where handoffs are left: beside the recovery state of an installed
  /// copy, or where `--handoff-directory` says. A copy with neither does not
  /// hand off, so a development build cannot take an installed app's panes.
  static func directory(arguments: [String], bundle: URL, home: URL) -> URL? {
    let args = Array(arguments.dropFirst().prefix { $0 != "--execute" })
    if let index = args.firstIndex(of: "--handoff-directory") {
      guard args.indices.contains(index + 1), !args[index + 1].isEmpty, !args[index + 1].hasPrefix("--") else { return nil }
      return URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL
    }
    return StateLocation.directory(arguments: arguments, bundle: bundle, home: home)?
      .deletingLastPathComponent().appendingPathComponent("Handoff", isDirectory: true)
  }
}

/// Moves running programs from this app to the one that replaces it.
enum SessionHandoffCoordinator {
  struct Adoption {
    let handoff: SessionHandoff
    let launch: LaunchSpec
  }
  struct Claimed {
    let layout: SessionLayout
    var adoptions: [PaneID: Adoption]
  }
  /// How long a keeper waits for the next app before it lets the programs go.
  static let keeperSeconds = 900
  private static let manifestName = "manifest.json"
  private static let maximumBytes = 64 * 1024 * 1024

  /// Takes what a previous app left, if anything. Whatever happens, the
  /// directory is emptied: a handoff is claimed once.
  static func claim(directory: URL?) -> Claimed? {
    guard let directory, let data = read(directory.appendingPathComponent(manifestName)) else { return nil }
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let manifest = try? JSONDecoder().decode(HandoffManifest.self, from: data), manifest.version == 1,
      manifest.layout.isValid, manifest.descriptorCount > 0,
      let descriptors = SessionKeeper.claim(socketPath: manifest.socket, count: manifest.descriptorCount)
    else { return nil }
    var unused = Set(descriptors.indices)
    var adoptions: [PaneID: Adoption] = [:]
    let known = Set(manifest.layout.windows.flatMap { $0.root.panes })
    for pane in manifest.panes where descriptors.indices.contains(pane.index) && unused.contains(pane.index) {
      // A program that ended meanwhile leaves a pane for a new shell.
      guard known.contains(pane.id), adoptions[pane.id] == nil, kill(pane.pid, 0) == 0,
        let content = read(directory.appendingPathComponent(pane.id.string + ".content")),
        let state = read(directory.appendingPathComponent(pane.id.string + ".state")) else { continue }
      unused.remove(pane.index)
      adoptions[pane.id] = Adoption(
        handoff: SessionHandoff(descriptor: descriptors[pane.index], processIdentifier: pane.pid,
          terminal: TerminalHandoff(columns: pane.columns, rows: pane.rows, content: content, state: state)),
        launch: LaunchSpec(executable: pane.executable, arguments: pane.arguments, cwd: pane.cwd,
          launcher: LaunchSpec.bundledLauncher, environment: pane.environment))
    }
    for index in unused { Darwin.close(descriptors[index]) }
    return adoptions.isEmpty ? nil : Claimed(layout: manifest.layout, adoptions: adoptions)
  }

  /// Leaves every running program with a keeper and a manifest in
  /// `directory`. On success the windows show what they had and their
  /// programs belong to the keeper; the app should end. On failure before
  /// the keeper holds the PTYs nothing has changed.
  @MainActor static func handOff(windows: [TerminalWindow], directory: URL, completion: @escaping @MainActor (Bool) -> Void) {
    let saved = windows.compactMap { $0.layout() }
    let key = (NSApp.keyWindow?.windowController as? TerminalWindow).flatMap { UUID(uuidString: $0.automationID) }
    let layout = SessionLayout(appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                               windows: saved, keyWindow: key)
    let panes = windows.flatMap(\.panes)
    guard layout.isValid, !panes.isEmpty, let executable = Bundle.main.executablePath,
      let socket = socketPath() else { return completion(false) }
    do {
      try? FileManager.default.removeItem(at: directory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    } catch { return completion(false) }

    // First a copy of every PTY for the keeper. Until it holds them, every
    // session is untouched and a failure costs nothing.
    var copies: [(pane: TerminalCanvasView, descriptor: Int32)] = []
    var pending = panes.count
    for pane in panes {
      pane.session.duplicatePTY { descriptor in
        if let descriptor { copies.append((pane, descriptor)) }
        pending -= 1
        guard pending == 0 else { return }
        defer { copies.forEach { Darwin.close($0.descriptor) } }
        guard !copies.isEmpty, SessionKeeper.start(executable: executable, socketPath: socket,
          seconds: keeperSeconds, descriptors: copies.map(\.descriptor)) != nil else { return completion(false) }
        detach(copies.map(\.pane), layout: layout, socket: socket, directory: directory, completion: completion)
      }
    }
  }

  @MainActor private static func detach(
    _ panes: [TerminalCanvasView], layout: SessionLayout, socket: String, directory: URL,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    var records: [HandoffManifest.Pane] = []
    var pending = panes.count
    for (index, pane) in panes.enumerated() {
      let launch = pane.session.launch
      pane.session.detachForHandoff { handoff in
        if let handoff {
          // The keeper has its own copy of this PTY.
          Darwin.close(handoff.descriptor)
          if let launch, let id = UUID(uuidString: pane.automationID).map(PaneID.init),
            write(handoff.terminal.content, to: directory.appendingPathComponent(id.string + ".content")),
            write(handoff.terminal.state, to: directory.appendingPathComponent(id.string + ".state")) {
            records.append(HandoffManifest.Pane(
              id: id, index: index, pid: handoff.processIdentifier,
              columns: handoff.terminal.columns, rows: handoff.terminal.rows,
              executable: launch.executable, arguments: launch.arguments, cwd: launch.cwd,
              environment: launch.environment))
          }
        }
        pending -= 1
        guard pending == 0 else { return }
        let manifest = HandoffManifest(
          appBuild: layout.appBuild, socket: socket, descriptorCount: panes.count, layout: layout, panes: records)
        guard !records.isEmpty, let data = try? JSONEncoder().encode(manifest),
          write(data, to: directory.appendingPathComponent(manifestName)) else { return completion(false) }
        completion(true)
      }
    }
  }

  /// A socket path short enough for `sockaddr_un`, in a directory only this
  /// user can enter.
  private static func socketPath() -> String? {
    let name = "helge-terminal-\(UUID().uuidString.prefix(8)).sock"
    let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    if temporary.utf8.count <= SessionKeeper.maximumSocketPath { return temporary }
    let fallback = "/tmp/\(getuid())-\(name)"
    return fallback.utf8.count <= SessionKeeper.maximumSocketPath ? fallback : nil
  }
  private static func read(_ url: URL) -> Data? {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
      size <= maximumBytes else { return nil }
    return try? Data(contentsOf: url)
  }
  private static func write(_ data: Data, to url: URL) -> Bool {
    guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
    return true
  }
}

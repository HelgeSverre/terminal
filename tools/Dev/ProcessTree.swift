import Foundation

/// A launched process together with every descendant it was seen to have.
///
/// Runners start the app from its bundle executable so that they hold a
/// waitable process even when the app crashes or never writes a report.
/// Descendants are recorded while they live, with their start time, so that
/// cleanup can signal exactly this run's survivors and nothing else.
final class ProcessTree {
  /// How a process ended.
  struct Exit: Equatable {
    let code: Int32
    let signalled: Bool
    var succeeded: Bool { !signalled && code == 0 }
  }

  /// Colour settings a developer's shell exports would change what fixtures
  /// print, so launched processes never inherit them.
  static let colourControls = ["NO_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "FORCE_COLOR"]

  private let process = Process()
  /// Start time of every process seen in this tree, by PID.
  private var owned: [pid_t: String] = [:]
  private(set) var exit: Exit?

  /// Launches `command`. `environment` adds to the inherited one; a nil value
  /// removes a variable. With `log`, a new file receives the output.
  init(_ command: [String], environment: [String: String?] = [:], log: String? = nil) throws {
    guard let executable = command.first else { throw Failure("empty command") }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(command.dropFirst())
    var inherited = ProcessInfo.processInfo.environment
    for key in Self.colourControls { inherited[key] = nil }
    for (key, value) in environment { inherited[key] = value }
    process.environment = inherited
    if let log {
      guard FileManager.default.createFile(atPath: log, contents: nil),
            let output = FileHandle(forWritingAtPath: log) else { throw Failure("cannot create log \(log)") }
      process.standardOutput = output
      process.standardError = output
    }
    do { try process.run() } catch { throw Failure("cannot launch \(executable): \(error.localizedDescription)") }
    Self.register(self)
  }

  var pid: pid_t { process.processIdentifier }

  /// Waits up to `seconds` for the launched process to end, recording
  /// descendants meanwhile. Returns nil when it is still running.
  @discardableResult
  func wait(seconds: Double) -> Exit? {
    let deadline = Clock.now + UInt64(seconds * 1_000_000_000)
    while true {
      observe()
      if exit == nil, !process.isRunning {
        exit = Exit(code: process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal)
      }
      if exit != nil || Clock.now >= deadline { return exit }
      usleep(50_000)
    }
  }

  /// Ends whatever is left of the tree: a polite request first, so PTY
  /// hang-up handling can run, then a kill. Returns the PIDs that survived.
  @discardableResult
  func cleanup() -> [pid_t] {
    observe()
    guard !survivors().isEmpty else { return [] }
    signal(survivors(), SIGTERM)
    var deadline = Clock.now + 4_000_000_000
    while !survivors().isEmpty, Clock.now < deadline { wait(seconds: 0.05) }
    signal(survivors(), SIGKILL)
    process.waitUntilExit()
    wait(seconds: 0)
    deadline = Clock.now + 2_000_000_000
    while !survivors().isEmpty, Clock.now < deadline { usleep(50_000) }
    return survivors()
  }

  /// Processes of this tree that are still running.
  var livePIDs: [pid_t] { survivors() }

  /// Whether `pid` was ever seen in this tree. A report can come from a child
  /// of the app, and stays attributable after everything has exited.
  func observedOwned(_ pid: Int?) -> Bool {
    guard let pid, let narrow = pid_t(exactly: pid) else { return false }
    return owned[narrow] != nil
  }

  /// Every running process: its parent and start time, which together with
  /// the PID identify it even after the PID is reused.
  private func table() -> [pid_t: (parent: pid_t, started: String)] {
    let listing = Process()
    let output = Pipe()
    listing.executableURL = URL(fileURLWithPath: "/bin/ps")
    listing.arguments = ["-axo", "pid=,ppid=,lstart="]
    listing.standardOutput = output
    guard (try? listing.run()) != nil else { return [:] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    listing.waitUntilExit()
    var table: [pid_t: (pid_t, String)] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
      table[pid] = (parent, fields[2].trimmingCharacters(in: .whitespaces))
    }
    return table
  }

  private func observe() {
    let table = table()
    var tree = Set(owned.keys.filter { table[$0]?.started == owned[$0] })
    if exit == nil, process.isRunning { tree.insert(pid) }
    while true {
      let children = table.keys.filter { !tree.contains($0) && tree.contains(table[$0]!.parent) }
      if children.isEmpty { break }
      tree.formUnion(children)
    }
    for pid in tree where owned[pid] == nil { owned[pid] = table[pid]?.started }
  }

  private func survivors() -> [pid_t] {
    let table = table()
    return owned.keys.filter { table[$0]?.started == owned[$0] }.sorted()
  }

  private func signal(_ pids: [pid_t], _ number: Int32) {
    // Identity is checked again immediately before each signal.
    for pid in pids where survivors().contains(pid) { kill(pid, number) }
  }

  // An interrupted runner still owns what it launched.
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var registry: [ProcessTree] = []
  private static func register(_ tree: ProcessTree) {
    registryLock.lock(); registry.append(tree); registryLock.unlock()
  }
  /// Ends every tree this run has launched. Called when the tool is interrupted.
  static func cleanupAll() {
    registryLock.lock(); let trees = registry; registryLock.unlock()
    trees.forEach { $0.cleanup() }
  }
}

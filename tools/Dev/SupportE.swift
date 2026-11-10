import CryptoKit
import Foundation

/// The running tool, for commands that launch it again as a fixture.
enum Tool {
  static let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    .standardizedFileURL.path

  /// Writes an executable that runs one of this tool's subcommands. The app
  /// starts `SHELL` as a single path with `-l`, so a subcommand needs a file
  /// of its own. `exec` keeps the PID, so signals reach the subcommand.
  static func writeLauncher(at path: String, subcommand: [String]) throws {
    let words = ([executable] + subcommand).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    try writeExecutable(path, script: "exec " + words.joined(separator: " ") + " \"$@\"")
  }
}

/// Writes a shell script and marks it executable.
func writeExecutable(_ path: String, script: String) throws {
  do {
    try ("#!/bin/sh\n" + script + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  } catch { throw Failure("cannot write \(path): \(error.localizedDescription)") }
}

/// A failed system call, kept apart from `Failure` so that callers can act on the error number.
struct SystemFailure: Error {
  let call: String
  let code: Int32
  init(_ call: String, code: Int32 = errno) {
    self.call = call
    self.code = code
  }
  var message: String { "\(call): \(String(cString: strerror(code)))" }
}

/// Any error as one a command can report.
func asFailure(_ error: Error) -> Failure {
  if let failure = error as? Failure { return failure }
  if let system = error as? SystemFailure { return Failure(system.message) }
  return Failure(error.localizedDescription)
}

/// An absolute path for one given on the command line, with `~` expanded.
func absolutePath(_ path: String) -> String {
  URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
}

/// The path with every symbolic link resolved. Fails when it does not exist.
func realPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else { throw Failure("cannot resolve \(path): \(String(cString: strerror(errno)))") }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// The SHA-256 of some bytes, as lowercase hex.
func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A JSON value on one line, with sorted keys.
func compactJSON(_ object: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// Command-line options: `--name` flags and `--name VALUE` or `--name=VALUE` settings.
struct Options {
  private(set) var flags: Set<String> = []
  private(set) var values: [String: String] = [:]
  private(set) var positionals: [String] = []

  /// Fails with the command's usage on an unknown option or a missing value.
  init(_ arguments: [String], flags known: Set<String>, values settings: Set<String>, command: Command) throws {
    var rest = arguments[...]
    while let argument = rest.popFirst() {
      let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
      if known.contains(argument) {
        flags.insert(argument)
      } else if settings.contains(argument) {
        guard let value = rest.popFirst() else { throw Failure.usage(command) }
        values[argument] = value
      } else if parts.count == 2, settings.contains(parts[0]) {
        values[parts[0]] = parts[1]
      } else if argument.hasPrefix("-") {
        throw Failure.usage(command)
      } else {
        positionals.append(argument)
      }
    }
  }
}

/// Runs a command to completion with this process's input and output, and
/// returns whether it succeeded. `environment` adds to the inherited one; a
/// nil value removes a variable.
func runInherited(_ command: [String], environment: [String: String?] = [:], directory: String? = nil) throws -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: command[0])
  process.arguments = Array(command.dropFirst())
  var inherited = ProcessInfo.processInfo.environment
  for (key, value) in environment { inherited[key] = value }
  process.environment = inherited
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  do { try process.run() } catch { throw Failure("cannot run \(command[0]): \(error.localizedDescription)") }
  process.waitUntilExit()
  return process.terminationReason == .exit && process.terminationStatus == 0
}

/// Takes the next pane number from a counter file shared by every fixture of
/// one run. The file is locked, because panes start at the same time.
func claimPaneNumber(counter path: String, below limit: Int? = nil) throws -> Int {
  let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
  guard descriptor >= 0 else { throw Failure(SystemFailure("open \(path)").message) }
  defer { close(descriptor) }
  guard flock(descriptor, LOCK_EX) == 0 else { throw Failure(SystemFailure("flock \(path)").message) }
  var buffer = [UInt8](repeating: 0, count: 32)
  let count = max(read(descriptor, &buffer, buffer.count), 0)
  let text = String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  let pane = Int(text) ?? 0
  if let limit, !(0..<limit).contains(pane) { throw Failure("too many workload panes") }
  let next = Array(String(pane + 1).utf8)
  guard ftruncate(descriptor, 0) == 0, pwrite(descriptor, next, next.count, 0) == next.count else {
    throw Failure(SystemFailure("write \(path)").message)
  }
  return pane
}

private nonisolated(unsafe) var stopSignalled: sig_atomic_t = 0
private nonisolated(unsafe) var resizeSignalled: sig_atomic_t = 0

/// Signals a fixture acts on in its own loop instead of dying from them.
///
/// The handlers only set a flag. A fixture has a child to reap and a receipt
/// to write before it ends, and neither is safe inside a handler.
enum FixtureSignals {
  static func install(resize: Bool = false) {
    // main.swift ends the tool on SIGINT and SIGTERM, which would skip the receipt.
    interruptions.forEach { $0.cancel() }
    stopSignalled = 0
    resizeSignalled = 0
    for number in [SIGTERM, SIGHUP, SIGINT] { signal(number) { _ in stopSignalled = 1 } }
    if resize { signal(SIGWINCH) { _ in resizeSignalled = 1 } }
  }
  static var stopRequested: Bool { stopSignalled != 0 }

  /// Whether the terminal was resized since the last call.
  static func takeResize() -> Bool {
    guard resizeSignalled != 0 else { return false }
    resizeSignalled = 0
    return true
  }
}

/// How a child process ended, from `waitpid`.
struct ChildStatus: Equatable {
  let raw: Int32
  var signal: Int32? {
    let number = raw & 0x7f
    return number != 0 && number != 0x7f ? number : nil
  }
  var exitCode: Int32? { raw & 0x7f == 0 ? (raw >> 8) & 0xff : nil }
  var succeeded: Bool { exitCode == 0 }
}

/// Reaps `pid` if it has ended. Returns nil while it runs.
func reapIfEnded(_ pid: pid_t) throws -> ChildStatus? {
  var raw: Int32 = 0
  while true {
    let result = waitpid(pid, &raw, WNOHANG)
    if result == pid { return ChildStatus(raw: raw) }
    if result == 0 { return nil }
    if errno != EINTR { throw SystemFailure("waitpid") }
  }
}

/// Waits up to `seconds` for `pid` to end, and reaps it.
func reap(_ pid: pid_t, within seconds: Double) throws -> ChildStatus? {
  let deadline = Clock.now + UInt64(seconds * 1_000_000_000)
  while true {
    if let status = try reapIfEnded(pid) { return status }
    if Clock.now >= deadline { return nil }
    usleep(10_000)
  }
}

/// Starts a child of this process and returns its PID. The caller reaps it.
///
/// With `terminal`, the child's input, output and errors are that terminal
/// device. With `leadsSession` it also starts a session of its own, so the
/// terminal becomes its controlling terminal and a resize reaches it as
/// SIGWINCH. `environment` adds to the inherited one; a nil value removes a variable.
func spawnChild(_ command: [String], environment: [String: String?] = [:], directory: String? = nil,
                terminal: String? = nil, leadsSession: Bool = false, standardError: Int32? = nil) throws -> pid_t {
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  if let terminal {
    posix_spawn_file_actions_addopen(&actions, 0, terminal, O_RDWR | (leadsSession ? 0 : O_NOCTTY), 0)
    posix_spawn_file_actions_adddup2(&actions, 0, 1)
    posix_spawn_file_actions_adddup2(&actions, 0, 2)
  } else {
    for descriptor in [0, 1, 2] as [Int32] { posix_spawn_file_actions_addinherit_np(&actions, descriptor) }
  }
  if let standardError { posix_spawn_file_actions_adddup2(&actions, standardError, 2) }
  if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }

  var attributes: posix_spawnattr_t?
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  // The tool ignores SIGINT and SIGTERM, and an ignored signal stays ignored
  // across exec; the child has to be stoppable.
  var defaults = sigset_t()
  sigemptyset(&defaults)
  for number in [SIGINT, SIGTERM, SIGHUP, SIGWINCH, SIGPIPE] { sigaddset(&defaults, number) }
  posix_spawnattr_setsigdefault(&attributes, &defaults)
  // No other descriptor is passed on: a child holding the terminal's other
  // end would keep it open after the fixture closed it.
  var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
  if leadsSession { flags |= POSIX_SPAWN_SETSID }
  posix_spawnattr_setflags(&attributes, Int16(flags))

  var merged = ProcessInfo.processInfo.environment
  for (key, value) in environment { merged[key] = value }
  var argv = command.map { strdup($0) } + [nil]
  var envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer { (argv + envp).forEach { free($0) } }
  var pid: pid_t = 0
  let result = posix_spawn(&pid, command[0], &actions, &attributes, &argv, &envp)
  guard result == 0 else { throw Failure("cannot launch \(command[0]): \(String(cString: strerror(result)))") }
  return pid
}

// Darwin declares these as macros Swift cannot import.
private let getWindowSize: UInt = 0x4008_7468
private let setWindowSize: UInt = 0x8008_7467

/// The size in rows and columns of the terminal behind a descriptor, or nil when it is not a terminal.
func terminalSize(of descriptor: Int32) -> (rows: Int, columns: Int)? {
  var size = winsize()
  guard ioctl(descriptor, getWindowSize, &size) == 0 else { return nil }
  return (Int(size.ws_row), Int(size.ws_col))
}

/// The controlling end of a new pseudo-terminal. A child opens `slavePath`.
final class PseudoTerminal {
  private(set) var master: Int32
  private var slave: Int32 = -1
  let slavePath: String

  /// The other end is held open as well until `releaseSlave`: macOS refuses
  /// to size a terminal whose other end has never been opened.
  init() throws {
    master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
      throw Failure(SystemFailure("open pseudo-terminal").message)
    }
    slavePath = String(cString: name)
    slave = open(slavePath, O_RDWR | O_NOCTTY)
    guard slave >= 0 else { throw Failure(SystemFailure("open \(slavePath)").message) }
  }
  deinit { close() }

  func setSize(rows: Int, columns: Int) throws {
    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    guard ioctl(master, setWindowSize, &size) == 0 else { throw Failure(SystemFailure("set terminal size").message) }
  }

  /// Leaves the other end to the child that has opened it, so that the
  /// terminal closes when the child does.
  func releaseSlave() {
    guard slave >= 0 else { return }
    Darwin.close(slave)
    slave = -1
  }

  func close() {
    releaseSlave()
    guard master >= 0 else { return }
    Darwin.close(master)
    master = -1
  }
}

/// The descriptors among `descriptors` that have input, an end of file or an
/// error to read, waiting up to `milliseconds` for the first.
func readable(_ descriptors: [Int32], milliseconds: Int32) -> [Int32] {
  var polled = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
  guard poll(&polled, nfds_t(polled.count), milliseconds) > 0 else { return [] }
  return polled.filter { $0.revents != 0 }.map(\.fd)
}

/// What one read from a descriptor produced.
enum ReadResult {
  case bytes(Data)
  case endOfFile
  case nothing
}

/// Reads what is available, up to `limit` bytes. Call after `readable` reported the descriptor.
func readAvailable(_ descriptor: Int32, limit: Int) throws -> ReadResult {
  var buffer = [UInt8](repeating: 0, count: limit)
  let count = read(descriptor, &buffer, limit)
  if count > 0 { return .bytes(Data(buffer[..<count])) }
  if count == 0 { return .endOfFile }
  if errno == EINTR || errno == EAGAIN { return .nothing }
  throw SystemFailure("read")
}

/// Writes all of `data`, however many calls that takes.
func writeAll(_ descriptor: Int32, _ data: Data) throws {
  var offset = 0
  while offset < data.count {
    let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, data.count - offset) }
    if written < 0 {
      if errno == EINTR || errno == EAGAIN { continue }
      throw SystemFailure("write")
    }
    offset += written
  }
}

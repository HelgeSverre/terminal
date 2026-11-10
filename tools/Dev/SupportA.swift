import Foundation

extension Failure {
  /// Any error as a failure, so a runner can record it in its report before
  /// passing it on.
  init(wrapping error: Error) {
    self = (error as? Failure) ?? Failure(error.localizedDescription)
  }
}

extension ProcessTree {
  /// Launches `command` with its output discarded. The shell replaces itself
  /// with the command, so the tree's PID is the command's.
  static func discardingOutput(_ command: [String]) throws -> ProcessTree {
    try ProcessTree(["/bin/sh", "-c", #"exec "$0" "$@" >/dev/null 2>&1"#] + command)
  }
}

/// `path` as an absolute path, read against `base` when it is relative.
func absolutePath(_ path: String, relativeTo base: String) -> String {
  let expanded = (path as NSString).expandingTildeInPath
  return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
    .standardizedFileURL.path
}

/// Whether a JSON value counts as set: anything but a missing value, null or false.
func truthy(_ value: Any?) -> Bool {
  guard let value, !(value is NSNull) else { return false }
  return (value as? NSNumber) !== kCFBooleanFalse
}

/// Whether a process with this PID exists. A PID that cannot be asked about
/// is an error, not an answer.
func processExists(_ pid: Int) throws -> Bool {
  guard let narrow = pid_t(exactly: pid) else { return false }
  if kill(narrow, 0) == 0 { return true }
  guard errno == ESRCH else { throw Failure("cannot inspect process \(pid): \(String(cString: strerror(errno)))") }
  return false
}

/// Runs a command to completion and returns its output and whether it
/// succeeded. `environment` adds to the inherited one, `input` is its standard
/// input, and `directory` its working directory.
func capture(_ command: [String], adding environment: [String: String], input: String? = nil,
             directory: String? = nil) throws -> (output: String, succeeded: Bool) {
  let process = Process()
  let output = Pipe()
  let standardInput = Pipe()
  process.executableURL = URL(fileURLWithPath: command[0])
  process.arguments = Array(command.dropFirst())
  process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
  process.standardInput = standardInput
  process.standardOutput = output
  process.standardError = output
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  // A command that exits without reading its input must not end this tool.
  signal(SIGPIPE, SIG_IGN)
  do { try process.run() } catch { throw Failure("cannot run \(command[0]): \(error.localizedDescription)") }
  try? standardInput.fileHandleForWriting.write(contentsOf: Data((input ?? "").utf8))
  try? standardInput.fileHandleForWriting.close()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (String(decoding: data, as: UTF8.self), process.terminationStatus == 0)
}

/// Writes an executable shell script, creating its directory.
func writeScript(_ body: String, to path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// A bundle whose executable is a shell script, standing in for the app in tests.
func fakeBundle(in directory: String, script: String) throws -> String {
  let bundle = directory + "/Fixture.app"
  try writeScript(script, to: bundle + "/Contents/MacOS/Terminal")
  return bundle
}

/// Runs `body`, which must fail, and returns its failure.
func expectFailure(_ what: String, _ body: () throws -> Void) throws -> Failure {
  do { try body() } catch let failure as Failure { return failure }
  throw Failure("\(what) was accepted")
}

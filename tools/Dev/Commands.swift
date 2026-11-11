import Foundation

/// What a finished command printed and how it ended.
struct CommandResult {
  /// Standard output as the bytes written. Standard error is among them when the two were merged.
  var data = Data()
  /// Standard error, when it was kept apart.
  var error = ""
  /// The exit code, or the signal's number when a signal ended the command.
  var code: Int32 = 0
  var signalled = false

  init(data: Data, error: String, code: Int32, signalled: Bool) {
    self.data = data
    self.error = error
    self.code = code
    self.signalled = signalled
  }

  /// A result as a stand-in for a real command describes one.
  init(output: String = "", error: String = "", status: Int32 = 0) {
    self.init(data: Data(output.utf8), error: error, code: status, signalled: false)
  }

  var output: String { String(decoding: data, as: UTF8.self) }
  /// A command ended by a signal did not succeed, whatever its number.
  var succeeded: Bool { !signalled && code == 0 }
  /// One number for both endings, as a shell gives it: 128 plus the signal's number.
  var status: Int32 { signalled ? 128 + code : code }
  /// The exit status as Ruby printed it: empty for a command a signal ended.
  var exitStatus: String { signalled ? "" : String(code) }
}

/// Where a captured command's standard error goes.
enum ErrorStream {
  /// Into the captured output, in the order written.
  case merged
  /// Into the result's `error`, apart from the output.
  case separate
  /// Into a file, which exists afterwards even when nothing was written.
  case file(String)
}

/// Runs a command to completion and captures what it printed.
///
/// A name without a slash is found on `PATH`. `adding` is merged over this
/// process's environment; a nil value removes a variable. `directory` is
/// where the command runs. Its standard input is `input`, or empty, so it can
/// never wait for a prompt.
func runCommand(_ command: [String], adding environment: [String: String?] = [:], directory: String? = nil,
                input: String? = nil, errors: ErrorStream = .merged) throws -> CommandResult {
  final class Collected { var data = Data() }
  let process = try prepare(command, adding: environment, directory: directory)
  let output = Pipe()
  var errorPipe: Pipe?
  var inputPipe: Pipe?
  process.standardOutput = output
  switch errors {
  case .merged: process.standardError = output
  case .separate:
    errorPipe = Pipe()
    process.standardError = errorPipe
  case .file(let path):
    guard FileManager.default.createFile(atPath: path, contents: nil), let log = FileHandle(forWritingAtPath: path) else {
      throw Failure("cannot create log \(path)")
    }
    process.standardError = log
  }
  if input == nil {
    process.standardInput = FileHandle.nullDevice
  } else {
    let pipe = Pipe()
    // A command that exits without reading its input must not end this tool.
    _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardInput = pipe
    inputPipe = pipe
  }
  try launch(process, command)
  if let inputPipe, let input {
    try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try? inputPipe.fileHandleForWriting.close()
  }

  // Both pipes are drained at once; a full one would stall the command.
  let collected = Collected()
  let drained = DispatchSemaphore(value: 0)
  if let errorPipe {
    DispatchQueue.global().async {
      collected.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      drained.signal()
    }
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  if errorPipe != nil { drained.wait() }
  process.waitUntilExit()
  return CommandResult(data: data, error: String(decoding: collected.data, as: UTF8.self),
                       code: process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal)
}

/// Runs a command to completion with this process's input and output, and
/// returns whether it succeeded. A name without a slash is found on `PATH`.
@discardableResult
func runInherited(_ command: [String], directory: String? = nil) throws -> Bool {
  let process = try prepare(command, adding: [:], directory: directory)
  try launch(process, command)
  process.waitUntilExit()
  return process.terminationReason == .exit && process.terminationStatus == 0
}

/// Puts the terminal on standard input into raw mode, without echo.
///
/// Done here and not by running `stty`: a fixture is its terminal's session
/// leader, and a `stty` started from it as a separate process failed to
/// change the mode in every real run.
func makeStandardInputRaw() throws {
  var mode = termios()
  guard tcgetattr(STDIN_FILENO, &mode) == 0 else { throw Failure("standard input is not a terminal") }
  cfmakeraw(&mode)
  guard tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0 else {
    throw Failure("cannot make the terminal raw: \(String(cString: strerror(errno)))")
  }
}

private func prepare(_ command: [String], adding environment: [String: String?], directory: String?) throws -> Process {
  guard let name = command.first else { throw Failure("empty command") }
  let process = Process()
  if name.contains("/") {
    process.executableURL = URL(fileURLWithPath: name)
    process.arguments = Array(command.dropFirst())
  } else {
    // `env` searches PATH as a shell would, and replaces itself with what it finds.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
  }
  if !environment.isEmpty {
    var merged = ProcessInfo.processInfo.environment
    for (key, value) in environment { merged[key] = value }
    process.environment = merged
  }
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  return process
}

/// The message names the command alone: its arguments can hold passwords.
private func launch(_ process: Process, _ command: [String]) throws {
  do { try process.run() } catch { throw Failure("cannot run \(command[0]): \(error.localizedDescription)") }
}

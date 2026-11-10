import Foundation

/// What a finished command printed and how it ended.
struct CommandResult {
  var output = ""
  var error = ""
  var status: Int32 = 0
  var succeeded: Bool { status == 0 }
}

/// Runs a command found on `PATH` to completion, keeping its two output
/// streams apart. `adding` is merged over this process's environment and the
/// command reads an empty standard input, so it can never wait for a prompt.
func runCommand(_ command: [String], adding environment: [String: String] = [:],
                directory: String? = nil) throws -> CommandResult {
  let process = Process()
  let output = Pipe()
  let error = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = command
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = error
  if !environment.isEmpty {
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
  }
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  // The name alone is reported: arguments can hold passwords.
  do { try process.run() } catch { throw Failure("cannot run \(command.first ?? "command")") }

  // Both pipes are drained at once; a full one would stall the command.
  var errorData = Data()
  let drained = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    errorData = error.fileHandleForReading.readDataToEndOfFile()
    drained.signal()
  }
  let outputData = output.fileHandleForReading.readDataToEndOfFile()
  drained.wait()
  process.waitUntilExit()
  // A command ended by a signal did not succeed, whatever its number.
  let status = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
  return CommandResult(output: String(decoding: outputData, as: UTF8.self),
                       error: String(decoding: errorData, as: UTF8.self), status: status)
}

/// A JSON value whose object keys keep the order they were given in, written
/// the way Ruby's `JSON.generate` and `JSON.pretty_generate` write it. Release
/// files are published and compared byte for byte, so their text is fixed here
/// and not left to `JSONSerialization`.
indirect enum JSONText {
  case string(String)
  case integer(Int)
  case boolean(Bool)
  case array([JSONText])
  case object([(String, JSONText)])

  /// One line, no spaces.
  var compact: String {
    switch self {
    case .string(let value): return JSONText.quote(value)
    case .integer(let value): return String(value)
    case .boolean(let value): return value ? "true" : "false"
    case .array(let items): return "[" + items.map(\.compact).joined(separator: ",") + "]"
    case .object(let members):
      return "{" + members.map { JSONText.quote($0.0) + ":" + $0.1.compact }.joined(separator: ",") + "}"
    }
  }

  /// Two-space indentation, one member per line.
  var pretty: String { pretty(indent: "") }

  private func pretty(indent: String) -> String {
    let inner = indent + "  "
    switch self {
    case .array(let items) where !items.isEmpty:
      return "[\n" + items.map { inner + $0.pretty(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
    case .object(let members) where !members.isEmpty:
      let lines = members.map { inner + JSONText.quote($0.0) + ": " + $0.1.pretty(indent: inner) }
      return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
    default:
      return compact
    }
  }

  /// A JSON string literal. Only the quote, the backslash and control
  /// characters are escaped; a slash and non-ASCII text are written as they are.
  static func quote(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case "\u{08}": result += "\\b"
      case "\u{0C}": result += "\\f"
      default:
        if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) }
        else { result.unicodeScalars.append(scalar) }
      }
    }
    return result + "\""
  }
}

/// A regular expression with Ruby's line rules: `^` and `$` match at every
/// line, a line ends only at a newline, and `.` matches a newline too.
struct LinePattern {
  /// Ruby's `\s`, which is ASCII only; the ICU one also matches Unicode spaces.
  static let space = "[ \\t\\n\\r\\f\\x0B]"
  private let expression: NSRegularExpression

  init(_ pattern: String, ignoringCase: Bool = false) {
    var options: NSRegularExpression.Options = [.anchorsMatchLines, .dotMatchesLineSeparators, .useUnixLineSeparators]
    if ignoringCase { options.insert(.caseInsensitive) }
    // The patterns are constants of this tool; a bad one is a programming error.
    expression = try! NSRegularExpression(pattern: pattern, options: options)
  }

  /// The first match: its range and the text of each capture group.
  func first(in text: String) -> (range: Range<String.Index>, groups: [String])? {
    let whole = NSRange(text.startIndex..., in: text)
    guard let match = expression.firstMatch(in: text, range: whole), let range = Range(match.range, in: text) else {
      return nil
    }
    let groups = (1..<match.numberOfRanges).map { index in
      Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
    return (range, groups)
  }

  func matches(_ text: String) -> Bool { first(in: text) != nil }

  /// `text` with the first match replaced by `replacement`, taken literally,
  /// or nil when nothing matches.
  func replacingFirst(in text: String, with replacement: String) -> String? {
    guard let match = first(in: text) else { return nil }
    return text.replacingCharacters(in: match.range, with: replacement)
  }
}

/// The message of the failure `body` raises. A test fails when it raises none.
func failureMessage(_ what: String, _ body: () throws -> Void) throws -> String {
  do { try body() } catch let failure as Failure { return failure.message }
  throw Failure("\(what) was accepted")
}

enum SupportDTests {
  static let cases = [
    SelfTest.Case(name: "run command: output, error, status, environment and directory are kept apart") {
      try withTemporaryDirectory("dev-run-command-") { directory in
        let script = "printf out; printf err >&2; printf \"$DEV_ADDED\" > added; test -n \"$PATH\" && exit 3"
        let result = try runCommand(["sh", "-c", script], adding: ["DEV_ADDED": "value"], directory: directory)
        try expect(result.output == "out" && result.error == "err", "got: \(result.output) / \(result.error)")
        try expect(result.status == 3 && !result.succeeded, "got status \(result.status)")
        try expect(try String(contentsOfFile: directory + "/added", encoding: .utf8) == "value", "variable is added")
        try expect(try runCommand(["dev-no-such-command"]).status == 127, "a missing command fails")
        try expect(!(try runCommand(["sh", "-c", "kill -9 $$"]).succeeded), "a signalled command fails")
        let large = try runCommand(["sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; head -c 300000 /dev/zero | tr '\\0' y"])
        try expect(large.output.count == 300_000 && large.error.count == 300_000, "large streams do not stall")
      }
    },
    SelfTest.Case(name: "run command: a signing failure names the command and nothing else") {
      let message = try failureMessage("a failing command") {
        try ReleaseSigning.Runner.system.run(["sh", "-c", "echo printed-detail; echo more >&2; exit 1", "argument-detail"])
      }
      try expect(message == "sh -c failed", "got: \(message)")
    },
  ]
}

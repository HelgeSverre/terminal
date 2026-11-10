import Foundation

/// The path with every symbolic link resolved, as the reports record a bundle.
func realPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else { throw Failure("no such file or directory: \(path)") }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// A path made absolute from the current directory, without resolving links.
func absolutePath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

func isDirectory(_ path: String) -> Bool {
  var directory: ObjCBool = false
  return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
}

/// Any error as one the tool reports, so that a failed file operation is
/// recorded in a run's report like every other failure.
func asFailure(_ error: Error) -> Failure { error as? Failure ?? Failure(error.localizedDescription) }

/// Runs a command found on PATH and returns what it wrote to standard output.
/// Error output is kept apart, so it cannot end up in a report, and becomes
/// the failure message when the command fails.
func standardOutput(of command: [String], in directory: String? = nil) throws -> String {
  let errors = NSTemporaryDirectory() + "dev-stderr-" + UUID().uuidString
  guard FileManager.default.createFile(atPath: errors, contents: nil),
        let errorHandle = FileHandle(forWritingAtPath: errors) else { throw Failure("cannot create \(errors)") }
  defer { try? FileManager.default.removeItem(atPath: errors) }
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = command
  process.standardOutput = output
  process.standardError = errorHandle
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  do { try process.run() } catch { throw Failure("cannot run \(command[0]): \(error.localizedDescription)") }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw Failure("\(command[0]) failed: \((try? String(contentsOfFile: errors, encoding: .utf8)) ?? "")")
  }
  return String(decoding: data, as: UTF8.self)
}

/// The PTY benchmark driver that a measured terminal runs as its command.
enum BenchDriver {
  static let source = Repository.path("Benchmarks/TerminalBench/terminal-bench.c")
  static let workloads = ["ascii_short_lines", "ascii_long_lines", "ansi_truecolor", "unicode"]

  /// The compiler invocation, as reports record it.
  static func buildCommand(to driver: String) -> [String] {
    ["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O2", source, "-o", driver]
  }

  /// Compiles the driver, keeps the compiler's messages in `log`, and returns
  /// whether it succeeded.
  static func build(to driver: String, log: String) throws -> Bool {
    let result = try capture(["/usr/bin/env"] + buildCommand(to: driver))
    try result.output.write(toFile: log, atomically: true, encoding: .utf8)
    return result.succeeded
  }

  /// Fails with the driver's own message when it left one beside `report`.
  /// The driver's reason is checked before the app's exit status because it
  /// says more: a wrong grid makes the app exit non-zero as well.
  static func checkFailure(beside report: String) throws {
    let path = report + ".failed"
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return }
    throw Failure((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
  }
}

/// The combined size of the regular files in a bundle. Symbolic links are
/// neither followed nor counted. Without `includingHidden`, names starting
/// with a dot and everything below them are left out.
func bundleBytes(_ bundle: String, includingHidden: Bool) -> Int {
  guard let walker = FileManager.default.enumerator(atPath: bundle) else { return 0 }
  var total = 0
  for case let relative as String in walker {
    if !includingHidden, relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: bundle + "/" + relative),
          attributes[.type] as? FileAttributeType == .typeRegular else { continue }
    total += (attributes[.size] as? NSNumber)?.intValue ?? 0
  }
  return total
}

func fileBytes(_ path: String) throws -> Int {
  guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else {
    throw Failure("cannot read \(path)")
  }
  return size.intValue
}

extension ProcessTree.Exit {
  /// The exit code for a report; null when a signal ended the process.
  var exitStatus: Any { signalled ? NSNull() : Int(code) as Any }
  /// The signal for a report; null when the process exited by itself.
  var terminationSignal: Any { signalled ? Int(code) as Any : NSNull() }
  var summary: String { "\(signalled ? "signal" : "exit") \(code)" }
  var record: [String: Any] { ["exitstatus": exitStatus, "termsig": terminationSignal, "success": succeeded] }
}

/// Judging values read from a JSON report. A parsed number keeps whether it
/// was written as an integer, and a boolean is never taken for a number.
enum JSONValue {
  private static func plainNumber(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number
  }
  static func number(_ value: Any?) -> Double? { plainNumber(value)?.doubleValue }
  /// The value when it was written as an integer; "2.0" is not one.
  static func integer(_ value: Any?) -> Int? {
    guard let number = plainNumber(value), !CFNumberIsFloatType(number) else { return nil }
    return number.intValue
  }
  static func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }
  static func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }
  /// Present and neither null nor false.
  static func isTruthy(_ value: Any?) -> Bool { !isNull(value) && !(isBoolean(value) && value as? Bool == false) }
  static func equals(_ value: Any?, _ expected: Int) -> Bool { number(value) == Double(expected) }
  /// Whether two values are the same number, the same boolean, or both null.
  static func same(_ first: Any?, _ second: Any?) -> Bool {
    if isBoolean(first) || isBoolean(second) {
      return isBoolean(first) && isBoolean(second) && first as? Bool == second as? Bool
    }
    if let first = number(first), let second = number(second) { return first == second }
    return isNull(first) && isNull(second)
  }
}

/// Reading a parsed JSON object. A missing key or a value of the wrong kind
/// fails the run instead of being read as zero or empty.
extension Dictionary where Key == String, Value == Any {
  func fetch(_ key: String) throws -> Any {
    guard let value = self[key] else { throw Failure("key not found: \"\(key)\"") }
    return value
  }
  func number(_ key: String) throws -> Double {
    guard let number = JSONValue.number(try fetch(key)) else { throw Failure("\"\(key)\" is not a number") }
    return number
  }
  func object(_ key: String) throws -> [String: Any] {
    guard let object = try fetch(key) as? [String: Any] else { throw Failure("\"\(key)\" is not an object") }
    return object
  }
  func objects(_ key: String) throws -> [[String: Any]] {
    guard let objects = try fetch(key) as? [[String: Any]] else { throw Failure("\"\(key)\" is not a list of objects") }
    return objects
  }
}

/// Writes reports in the layout the Ruby runners used: two-space indentation
/// and "key": value. A number read or computed as floating point is written
/// as one ("2.0", never "2"), with the shortest digits that read back
/// exactly, so a report copied into another keeps its values and their types.
/// Keys are sorted.
enum ReportJSON {
  static func write(_ value: Any, to path: String) throws {
    try (try text(value) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
  }

  static func text(_ value: Any, indent: String = "") throws -> String {
    let inner = indent + "  "
    switch value {
    case is NSNull: return "null"
    case let string as String: return quoted(string)
    case let number as NSNumber: return try text(number)
    case let list as [Any]:
      if list.isEmpty { return "[]" }
      return "[\n" + (try list.map { inner + (try text($0, indent: inner)) }).joined(separator: ",\n") + "\n\(indent)]"
    case let object as [String: Any]:
      if object.isEmpty { return "{}" }
      let members = try object.keys.sorted().map { key in
        inner + quoted(key) + ": " + (try text(object[key]!, indent: inner))
      }
      return "{\n" + members.joined(separator: ",\n") + "\n\(indent)}"
    default: throw Failure("cannot write a \(type(of: value)) as JSON")
    }
  }

  private static func text(_ number: NSNumber) throws -> String {
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
    guard CFNumberIsFloatType(number) else { return number.stringValue }
    guard number.doubleValue.isFinite else { throw Failure("\(number.doubleValue) cannot be written as JSON") }
    return "\(number.doubleValue)"
  }

  private static func quoted(_ string: String) -> String {
    var text = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": text += "\\\""
      case "\\": text += "\\\\"
      case "\n": text += "\\n"
      case "\r": text += "\\r"
      case "\t": text += "\\t"
      case _ where scalar.value < 0x20: text += String(format: "\\u%04x", scalar.value)
      default: text.unicodeScalars.append(scalar)
      }
    }
    return text + "\""
  }
}

/// Runs `body` with an app bundle whose executable is the given shell script,
/// and the temporary directory that holds it.
func withFixtureApp(_ script: String, _ body: (_ app: String, _ root: String) throws -> Void) throws {
  try withTemporaryDirectory("dev-fixture-app-") { root in
    let app = root + "/Fixture.app"
    try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
    try writeExecutable("#!/bin/sh\n" + script + "\n", to: app + "/Contents/MacOS/Terminal")
    try body(app, root)
  }
}

func writeExecutable(_ text: String, to path: String) throws {
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// The PID a fixture report carries until the fixture replaces it with its own.
let fixturePlaceholderPID = 987_654_321

/// A fixture executable that fails the way the benchmark driver does: it
/// leaves a reason beside the report it was asked for and exits non-zero.
func failingDriverScript(_ reason: String) -> String {
  """
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then shift; printf '\(reason)' > "$1.failed"; exit 7; fi
    shift
  done
  exit 8
  """
}

/// The message of the failure `body` ends with. A test fails when `body`
/// succeeds instead.
func failureMessage(_ expectation: String, _ body: () throws -> Void) throws -> String {
  do { try body() } catch let failure as Failure { return failure.message }
  throw Failure("expected a failure: \(expectation)")
}

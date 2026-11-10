import CryptoKit
import Foundation

/// A JSON value whose objects keep their members in order.
///
/// The comparison reports hash re-serialised snapshots and pass harness
/// records through unchanged, so the text written must depend only on the
/// text read. Integers keep their digits, and the output has the layout of
/// Ruby's `JSON.generate` and `JSON.pretty_generate`, which wrote these
/// reports before.
indirect enum JSONValue {
  case null
  case bool(Bool)
  case integer(String)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([(key: String, value: JSONValue)])

  static func int(_ value: Int) -> JSONValue { .integer(String(value)) }
  static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
  /// A value that may be absent, written as null when it is.
  static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
  static func optional(_ value: Int?) -> JSONValue { value.map(JSONValue.int) ?? .null }

  var members: [(key: String, value: JSONValue)]? { if case .object(let members) = self { return members } else { return nil } }
  var elements: [JSONValue]? { if case .array(let elements) = self { return elements } else { return nil } }
  var text: String? { if case .string(let text) = self { return text } else { return nil } }
  var truth: Bool? { if case .bool(let value) = self { return value } else { return nil } }
  var whole: Int? { if case .integer(let digits) = self { return Int(digits) } else { return nil } }
  /// The numeric value of an integer or a fraction.
  var quantity: Double? {
    switch self {
    case .integer(let digits): return Double(digits)
    case .number(let value): return value
    default: return nil
    }
  }

  /// The member named `key`, or nil when this is not an object or has none.
  subscript(key: String) -> JSONValue? {
    get { members?.first { $0.key == key }?.value }
    set {
      guard var members else { return }
      let index = members.firstIndex { $0.key == key }
      switch (index, newValue) {
      case (let index?, let value?): members[index].value = value
      case (let index?, nil): members.remove(at: index)
      case (nil, let value?): members.append((key, value))
      case (nil, nil): break
      }
      self = .object(members)
    }
  }

  /// Appends to an array member, which must exist.
  mutating func append(_ value: JSONValue, to key: String) {
    self[key] = .array((self[key]?.elements ?? []) + [value])
  }

  /// The member named `key`; a missing one is an error naming `context`.
  func required(_ key: String, in context: String) throws -> JSONValue {
    guard let value = self[key] else { throw Failure("\(context) lacks \(key)") }
    return value
  }

  /// The same value with every object's members ordered by key.
  var sorted: JSONValue {
    switch self {
    case .object(let members):
      return .object(members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map { ($0.key, $0.value.sorted) })
    case .array(let elements): return .array(elements.map(\.sorted))
    default: return self
    }
  }

  /// Whether two values are the same, comparing numbers by value so that 1 equals 1.0.
  func matches(_ other: JSONValue) -> Bool {
    switch (self, other) {
    case (.null, .null): return true
    case (.bool(let left), .bool(let right)): return left == right
    case (.string(let left), .string(let right)): return left == right
    case (.integer(let left), .integer(let right)): return left == right
    case (.integer, .number), (.number, .integer), (.number, .number): return quantity == other.quantity
    case (.array(let left), .array(let right)):
      return left.count == right.count && zip(left, right).allSatisfy { $0.matches($1) }
    case (.object(let left), .object(let right)):
      return left.count == right.count && left.allSatisfy { member in other[member.key].map(member.value.matches) ?? false }
    default: return false
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
  init(stringLiteral value: String) { self = .string(value) }
  init(integerLiteral value: Int) { self = .integer(String(value)) }
  init(floatLiteral value: Double) { self = .number(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements.map { ($0.0, $0.1) }) }
  init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
  /// On one line, with no spaces.
  var compact: String {
    switch self {
    case .array(let elements): return "[" + elements.map(\.compact).joined(separator: ",") + "]"
    case .object(let members):
      return "{" + members.map { Self.quoted($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
    default: return scalar
    }
  }

  /// Indented by two spaces, one member or element per line.
  var pretty: String { pretty(indent: "") }

  private func pretty(indent: String) -> String {
    let inner = indent + "  "
    switch self {
    case .array(let elements) where !elements.isEmpty:
      return "[\n" + elements.map { inner + $0.pretty(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
    case .object(let members) where !members.isEmpty:
      let lines = members.map { inner + Self.quoted($0.key) + ": " + $0.value.pretty(indent: inner) }
      return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
    default: return compact
    }
  }

  /// A scalar as it reads inside a sentence: a string without its quotes.
  var display: String { text ?? compact }

  private var scalar: String {
    switch self {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .integer(let digits): return digits
    case .number(let value): return Self.decimal(value)
    case .string(let text): return Self.quoted(text)
    case .array, .object: return compact
    }
  }

  private static func quoted(_ text: String) -> String {
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
      case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }

  /// The shortest digits that read back as `value`, laid out as Ruby's
  /// `Float#to_s` does: always with a fraction, and with an exponent outside
  /// 0.0001 to 1e15. Recent versions of Ruby's JSON library write numbers
  /// outside that range differently; inside it all agree.
  static func decimal(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    var description = "\(abs(value))"
    var exponent = 0
    if let mark = description.firstIndex(of: "e") {
      exponent = Int(description[description.index(after: mark)...]) ?? 0
      description = String(description[..<mark])
    }
    let parts = description.split(separator: ".", omittingEmptySubsequences: false)
    var digits = Array(parts[0] + (parts.count > 1 ? parts[1] : ""))
    // The value is 0.DIGITS times ten to the power `point`.
    var point = parts[0].count + exponent
    while digits.count > 1, digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.count > 1, digits.last == "0" { digits.removeLast() }
    let sign = value.sign == .minus ? "-" : ""
    if digits == ["0"] { return sign + "0.0" }
    if point > 0, point <= 15 {
      let padded = digits + Array(repeating: "0", count: max(0, point - digits.count))
      let fraction = padded.count > point ? String(padded[point...]) : "0"
      return sign + String(padded[..<point]) + "." + fraction
    }
    if point > -4, point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + String(digits) }
    let fraction = digits.count > 1 ? String(digits[1...]) : "0"
    return sign + String(digits[0]) + "." + fraction + String(format: "e%+03d", point - 1)
  }

  /// Writes the pretty form and a final newline.
  func write(to path: String) throws {
    do { try (pretty + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    catch { throw Failure("cannot write \(path): \(error.localizedDescription)") }
  }
}

extension JSONValue {
  /// Parses one JSON document. Trailing text, and anything RFC 8259 does not allow, is an error.
  init(parsing data: Data) throws {
    var parser = JSONParser(bytes: Array(data))
    self = try parser.document()
  }
  init(parsing text: String) throws { try self.init(parsing: Data(text.utf8)) }
  init(parsingFile path: String) throws {
    guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
    do { try self.init(parsing: data) } catch let failure as Failure { throw Failure("\(path): \(failure.message)") }
  }
}

private struct JSONParser {
  let bytes: [UInt8]
  var position = 0

  mutating func document() throws -> JSONValue {
    let value = try value(depth: 0)
    skipSpace()
    guard position == bytes.count else { throw failure("unexpected text after the value") }
    return value
  }

  private func failure(_ message: String) -> Failure { Failure("invalid JSON at byte \(position): \(message)") }
  private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

  private mutating func skipSpace() {
    while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { position += 1 }
  }

  private mutating func take(_ word: String) -> Bool {
    let expected = Array(word.utf8)
    guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected else {
      return false
    }
    position += expected.count
    return true
  }

  private mutating func value(depth: Int) throws -> JSONValue {
    guard depth <= 100 else { throw failure("nested too deeply") }
    skipSpace()
    guard let byte = current else { throw failure("unexpected end") }
    switch byte {
    case UInt8(ascii: "{"): return try object(depth: depth)
    case UInt8(ascii: "["): return try array(depth: depth)
    case UInt8(ascii: "\""): return .string(try string())
    case UInt8(ascii: "t") where take("true"): return .bool(true)
    case UInt8(ascii: "f") where take("false"): return .bool(false)
    case UInt8(ascii: "n") where take("null"): return .null
    default: return try number()
    }
  }

  private mutating func object(depth: Int) throws -> JSONValue {
    position += 1
    var result = JSONValue.object([])
    skipSpace()
    if current == UInt8(ascii: "}") { position += 1; return result }
    while true {
      skipSpace()
      guard current == UInt8(ascii: "\"") else { throw failure("expected a member name") }
      let key = try string()
      skipSpace()
      guard current == UInt8(ascii: ":") else { throw failure("expected a colon") }
      position += 1
      // A repeated name keeps its first position and takes the last value.
      result[key] = try value(depth: depth + 1)
      skipSpace()
      if current == UInt8(ascii: ",") { position += 1; continue }
      guard current == UInt8(ascii: "}") else { throw failure("expected a comma or the end of the object") }
      position += 1
      return result
    }
  }

  private mutating func array(depth: Int) throws -> JSONValue {
    position += 1
    var elements: [JSONValue] = []
    skipSpace()
    if current == UInt8(ascii: "]") { position += 1; return .array(elements) }
    while true {
      elements.append(try value(depth: depth + 1))
      skipSpace()
      if current == UInt8(ascii: ",") { position += 1; continue }
      guard current == UInt8(ascii: "]") else { throw failure("expected a comma or the end of the array") }
      position += 1
      return .array(elements)
    }
  }

  private mutating func string() throws -> String {
    position += 1
    var units: [UInt8] = []
    while let byte = current {
      position += 1
      switch byte {
      case UInt8(ascii: "\""):
        guard let text = String(validatingUTF8: units.map { CChar(bitPattern: $0) } + [0]) else {
          throw failure("a string is not UTF-8")
        }
        return text
      case UInt8(ascii: "\\"): units += try escape()
      case 0..<0x20: throw failure("a control character inside a string")
      default: units.append(byte)
      }
    }
    throw failure("unterminated string")
  }

  private mutating func escape() throws -> [UInt8] {
    guard let byte = current else { throw failure("unterminated escape") }
    position += 1
    switch byte {
    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): return [byte]
    case UInt8(ascii: "b"): return [0x08]
    case UInt8(ascii: "f"): return [0x0C]
    case UInt8(ascii: "n"): return [0x0A]
    case UInt8(ascii: "r"): return [0x0D]
    case UInt8(ascii: "t"): return [0x09]
    case UInt8(ascii: "u"):
      var unit = try hexUnit()
      // A high surrogate and the low one after it name a single scalar.
      if (0xD800..<0xDC00).contains(unit), take("\\u") {
        let low = try hexUnit()
        unit = (0xDC00..<0xE000).contains(low) ? 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00) : 0xFFFD
      }
      return Array(String(Unicode.Scalar(unit) ?? "\u{FFFD}").utf8)
    default: throw failure("unknown escape")
    }
  }

  private mutating func hexUnit() throws -> UInt32 {
    guard position + 4 <= bytes.count,
          let unit = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16) else {
      throw failure("expected four hex digits")
    }
    position += 4
    return unit
  }

  private mutating func number() throws -> JSONValue {
    let start = position
    func digit(_ byte: UInt8?) -> Bool { byte.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
    if current == UInt8(ascii: "-") { position += 1 }
    guard digit(current) else { throw failure("unexpected character") }
    if current == UInt8(ascii: "0") { position += 1 } else { while digit(current) { position += 1 } }
    var whole = true
    if current == UInt8(ascii: ".") {
      whole = false
      position += 1
      guard digit(current) else { throw failure("expected a digit after the point") }
      while digit(current) { position += 1 }
    }
    if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
      whole = false
      position += 1
      if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { position += 1 }
      guard digit(current) else { throw failure("expected a digit in the exponent") }
      while digit(current) { position += 1 }
    }
    let literal = String(decoding: bytes[start..<position], as: UTF8.self)
    if whole { return .integer(literal == "-0" ? "0" : literal) }
    guard let value = Double(literal) else { throw failure("unreadable number") }
    return .number(value)
  }
}

/// The SHA-256 of some bytes, as lowercase hex.
func sha256(of data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The path with every symbolic link resolved. The file must exist.
func realPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else { throw Failure("cannot resolve \(path): \(String(cString: strerror(errno)))") }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// Where a program named without a directory is found on PATH. Reports record
/// commands as they are written, such as `xcrun swiftc`, and launch the file this finds.
func executablePath(_ name: String) throws -> String {
  if name.contains("/") { return name }
  let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
  for directory in directories where FileManager.default.isExecutableFile(atPath: "\(directory)/\(name)") {
    return "\(directory)/\(name)"
  }
  throw Failure("\(name) is not on PATH")
}

/// How a helper command ended, and what it wrote to standard output.
struct Finished {
  let output: Data
  let code: Int32
  let signalled: Bool
  var succeeded: Bool { !signalled && code == 0 }
  var text: String { String(decoding: output, as: UTF8.self) }
  /// The exit status as Ruby printed it: empty for a process a signal ended.
  var exitStatus: String { signalled ? "" : String(code) }
}

/// Where a helper command's standard error goes.
enum ErrorStream {
  /// Into the captured output, in the order written.
  case merged
  /// Into a new file, which exists afterwards even when nothing was written.
  case file(String)
}

/// Runs a command to completion and captures its output as bytes. `adding`
/// extends the inherited environment; `directory` is where it runs.
func runCaptured(_ command: [String], adding environment: [String: String] = [:], directory: String? = nil,
                 errors: ErrorStream = .merged) throws -> Finished {
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: try executablePath(command[0]))
  process.arguments = Array(command.dropFirst())
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = pipe
  switch errors {
  case .merged: process.standardError = pipe
  case .file(let path):
    guard FileManager.default.createFile(atPath: path, contents: nil), let log = FileHandle(forWritingAtPath: path) else {
      throw Failure("cannot create log \(path)")
    }
    process.standardError = log
  }
  if !environment.isEmpty {
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
  }
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  do { try process.run() } catch { throw Failure("cannot run \(command[0]): \(error.localizedDescription)") }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return Finished(output: data, code: process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal)
}

/// Writes a shell script and makes it executable. Tests use these in place of real programs.
func writeExecutable(_ path: String, _ script: String, mode: Int = 0o755) throws {
  try script.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

/// Lets a runner end in order when it is interrupted.
///
/// The tool's default is to end launched processes and exit at once, which
/// leaves no report. A runner that promises a report for an interrupted run
/// calls `observe()` and then `check()` wherever it waits; the interruption
/// surfaces there as an ordinary failure and takes the runner's failure path.
enum Interruption {
  nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
  private static let lock = NSLock()
  nonisolated(unsafe) private static var count = 0

  /// Whether an interruption has arrived since `observe()`.
  static var requested: Bool {
    lock.lock(); defer { lock.unlock() }
    return count > 0
  }

  /// Replaces exit-on-signal with a request that `check()` reports. A second
  /// signal ends everything at once, so a runner that has stopped checking can still be stopped.
  static func observe() {
    guard sources.isEmpty else { return }
    interruptions.forEach { $0.cancel() }
    sources = [SIGINT, SIGTERM].map { number in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        lock.lock(); count += 1; let repeated = count > 1; lock.unlock()
        if repeated {
          ProcessTree.cleanupAll()
          exit(130)
        }
      }
      source.resume()
      return source
    }
  }

  static func check() throws {
    if requested { throw Failure("interrupted") }
  }
}

extension ProcessTree {
  /// Waits like `wait(seconds:)`, and fails early when the run is interrupted.
  func waitInterruptibly(seconds: Double) throws -> Exit? {
    let deadline = Clock.now + UInt64(seconds * 1_000_000_000)
    while true {
      let now = Clock.now
      if let exit = wait(seconds: now < deadline ? min(0.2, Double(deadline - now) / 1_000_000_000) : 0) { return exit }
      try Interruption.check()
      if Clock.now >= deadline { return nil }
    }
  }
}

enum JSONValueTests {
  static let cases = [
    SelfTest.Case(name: "ordered json: text is kept through parsing and writing") {
      let source = #"{"b":1,"a":[true,null,-0,12345678901234567890,1.50,"é\n\u0001😀/"],"b":{"z":{},"y":[]}}"#
      let value = try JSONValue(parsing: source)
      try expect(value.compact == "{\"b\":{\"z\":{},\"y\":[]},\"a\":[true,null,0,12345678901234567890,1.5,\"é\\n\\u0001😀/\"]}",
                 "got \(value.compact)")
      try expect(value.sorted.compact.hasPrefix(#"{"a":[true"#) && value.sorted.compact.hasSuffix(#""b":{"y":[],"z":{}}}"#), "sorted")
      try expect(value.pretty == "{\n  \"b\": {\n    \"z\": {},\n    \"y\": []\n  },\n  \"a\": [\n    true,\n    null,\n    0,\n"
                   + "    12345678901234567890,\n    1.5,\n    \"é\\n\\u0001😀/\"\n  ]\n}", "got \(value.pretty)")
      for broken in ["", "{", "[1,]", "{\"a\":1,}", "01", "1.", "nul", "\"a", "[1] 2", "{'a':1}", "NaN"] {
        try expect((try? JSONValue(parsing: broken)) == nil, "accepted \(broken)")
      }
    },
    SelfTest.Case(name: "ordered json: fractions are written as Ruby writes them") {
      let expected: [(Double, String)] = [
        (0, "0.0"), (-0.0, "-0.0"), (1, "1.0"), (120, "120.0"), (0.1, "0.1"), (12.34, "12.34"), (-2.5, "-2.5"),
        (0.0001, "0.0001"), (0.00001, "1.0e-05"), (1.5e-7, "1.5e-07"), (999999999999999.9, "999999999999999.9"), (1e15, "1.0e+15"),
        (9007199254740992, "9.007199254740992e+15"), (1e16, "1.0e+16"), (1.2345e22, "1.2345e+22"), (5e-324, "5.0e-324"),
        (123456.789, "123456.789"), (1e100, "1.0e+100"),
      ]
      for (value, text) in expected { try expect(JSONValue.decimal(value) == text, "\(value) gave \(JSONValue.decimal(value))") }
    },
  ]
}

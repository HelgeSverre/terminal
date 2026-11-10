import Foundation

/// A JSON value whose objects keep their members in order.
///
/// The comparison reports hash re-serialised snapshots and pass harness
/// records through unchanged, and release files are published and compared
/// byte for byte, so the text written must depend only on the value and not
/// be left to `JSONSerialization`. Integers keep their digits, and the output
/// has the layout of Ruby's `JSON.generate` and `JSON.pretty_generate`, which
/// wrote these files before.
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

  /// A JSON string literal. Only the quote, the backslash and control
  /// characters are escaped; a slash and non-ASCII text are written as they are.
  static func quoted(_ text: String) -> String {
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
  /// A value read by `JSONSerialization`, or built from dictionaries and
  /// arrays, with every object's members ordered by key. A number keeps
  /// whether it is floating point, so a report copied into another keeps its
  /// values and their types: 2.0 is written "2.0", never "2".
  init(sortingKeysOf value: Any) throws {
    switch value {
    case is NSNull: self = .null
    case let string as String: self = .string(string)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else if CFNumberIsFloatType(number) {
        guard number.doubleValue.isFinite else { throw Failure("\(number.doubleValue) cannot be written as JSON") }
        self = .number(number.doubleValue)
      } else {
        self = .integer(number.stringValue)
      }
    case let list as [Any]: self = .array(try list.map(JSONValue.init(sortingKeysOf:)))
    case let object as [String: Any]:
      self = .object(try object.keys.sorted().map { ($0, try JSONValue(sortingKeysOf: object[$0]!)) })
    default: throw Failure("cannot write a \(type(of: value)) as JSON")
    }
  }
}

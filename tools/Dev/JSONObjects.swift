import Foundation

/// Reads a JSON object from a file.
func readJSONObject(_ path: String) throws -> [String: Any] {
  guard let data = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw Failure("\(path) is not a JSON object")
  }
  return object
}

/// Writes a JSON value in Foundation's layout, pretty-printed with sorted
/// keys and a final newline. Reports that must read as the Ruby runners
/// wrote them are written through `JSONValue` instead.
func writeJSON(_ object: Any, to path: String) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// A JSON value on one line, with sorted keys, in Foundation's layout.
func compactJSON(_ object: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// Judging values of a report read by `readJSONObject`. A parsed number
/// keeps whether it was written as an integer, and a boolean is never taken
/// for a number.
enum ReportValue {
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
    guard let number = ReportValue.number(try fetch(key)) else { throw Failure("\"\(key)\" is not a number") }
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

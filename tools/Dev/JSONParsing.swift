import Foundation

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

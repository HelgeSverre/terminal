import Foundation

/// A streaming NFA, with no recursion, backtracking, Foundation Regex, or
/// retained document. Each state keeps only its oldest viable start. Regex
/// searches take the first nonempty acceptance (shortest, non-overlapping).
struct BoundedSearchRegex {
  private struct Atom {
    var ranges: [ClosedRange<UInt32>]
    var inverted = false
    var any = false
    func accepts(_ scalar: Unicode.Scalar) -> Bool {
      if any { return scalar.value != 10 }
      return ranges.contains { $0.contains(scalar.value) } != inverted
    }
  }
  private struct State {
    let atom: Atom
    let optional: Bool
    let repeats: Bool
  }
  static let maxMatchScalars = 4096
  private let states: [State]
  let startAnchored: Bool
  let endAnchored: Bool
  private var active: [Int?]
  private(set) var exceeded = false

  init(_ query: String, caseSensitive: Bool) throws {
    let input = Array(query.unicodeScalars)
    var index = 0
    startAnchored = input.first == "^"
    if startAnchored { index += 1 }
    var parsed: [State] = []
    var end = false
    func folded(_ scalar: Unicode.Scalar) throws -> UInt32 {
      let values = caseSensitive ? [scalar] : UnicodeLowercase.lowercase(scalar)
      // Class endpoints and atoms must stay one scalar; literal mode supports
      // expanding lowercase mappings, regex deliberately rejects them.
      guard values.count == 1 else { throw TerminalSearchAdmissionError.query }
      return values[0].value
    }
    func escaped() throws -> Unicode.Scalar {
      guard index < input.count else { throw TerminalSearchAdmissionError.query }
      let value = input[index]; index += 1
      switch value {
      case "n": return "\n"
      case "t": return "\t"
      case "r": return "\r"
      case "\\", ".", "[", "]", "^", "$", "?", "*", "+", "(", ")", "{", "}", "|", "-": return value
      default: throw TerminalSearchAdmissionError.query
      }
    }
    while index < input.count {
      let character = input[index]; index += 1
      if character == "$", index == input.count { end = true; break }
      let atom: Atom
      switch character {
      case ".": atom = Atom(ranges: [], any: true)
      case "\\":
        let value = try folded(escaped())
        atom = Atom(ranges: [value...value])
      case "[":
        var inverted = false
        if index < input.count, input[index] == "^" { inverted = true; index += 1 }
        var ranges: [ClosedRange<UInt32>] = []
        while index < input.count, input[index] != "]" {
          var lower = input[index]; index += 1
          if lower == "\\" { lower = try escaped() }
          var upper = lower
          if index + 1 < input.count, input[index] == "-", input[index + 1] != "]" {
            index += 1; upper = input[index]; index += 1
            if upper == "\\" { upper = try escaped() }
          }
          let first = try folded(lower), last = try folded(upper)
          guard first <= last else { throw TerminalSearchAdmissionError.query }
          ranges.append(first...last)
          guard ranges.count <= 128 else { throw TerminalSearchAdmissionError.query }
        }
        guard index < input.count, !ranges.isEmpty else { throw TerminalSearchAdmissionError.query }
        index += 1
        atom = Atom(ranges: ranges, inverted: inverted)
      case "^", "$", "?", "*", "+", "(", ")", "{", "}", "|", "]":
        throw TerminalSearchAdmissionError.query
      default:
        let value = try folded(character)
        atom = Atom(ranges: [value...value])
      }
      var quantifier: Unicode.Scalar?
      if index < input.count, (input[index] == "?" || input[index] == "*" || input[index] == "+") {
        quantifier = input[index]; index += 1
      }
      if quantifier == "+" {
        parsed.append(State(atom: atom, optional: false, repeats: false))
        parsed.append(State(atom: atom, optional: true, repeats: true))
      } else {
        parsed.append(State(atom: atom, optional: quantifier == "?" || quantifier == "*", repeats: quantifier == "*"))
      }
      guard parsed.count <= 256 else { throw TerminalSearchAdmissionError.query }
    }
    guard !parsed.isEmpty else { throw TerminalSearchAdmissionError.query }
    states = parsed
    endAnchored = end
    active = Array(repeating: nil, count: parsed.count + 1)
  }

  mutating func reset() { active = Array(repeating: nil, count: active.count) }

  /// `position` is the input offset; returned offsets describe a nonempty hit.
  mutating func push(_ scalar: Unicode.Scalar, position: Int, canStart: Bool, lineStart: Bool) -> Range<Int>? {
    if canStart && (!startAnchored || lineStart) {
      active[0] = min(active[0] ?? position, position)
    }
    // The epsilon graph only advances, so one forward pass closes it.
    Self.close(&active, states: states)
    var following = Array<Int?>(repeating: nil, count: active.count)
    for index in states.indices {
      guard let start = active[index], states[index].atom.accepts(scalar) else { continue }
      guard position - start < Self.maxMatchScalars else { exceeded = true; continue }
      let destination = states[index].repeats ? index : index + 1
      following[destination] = min(following[destination] ?? start, start)
    }
    Self.close(&following, states: states)
    active = following
    if let start = active[states.count] { return start..<(position + 1) }
    return nil
  }

  private static func close(_ values: inout [Int?], states: [State]) {
    for index in states.indices where states[index].optional {
      if let start = values[index] { values[index + 1] = min(values[index + 1] ?? start, start) }
    }
  }
}

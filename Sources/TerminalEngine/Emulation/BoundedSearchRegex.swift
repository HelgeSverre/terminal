import Foundation

/// A Thompson NFA with leftmost-longest, nonempty matching. Parsing depth,
/// instruction count, class size and active match length are all bounded.
/// No recursive execution or backtracking; every scalar visits each reachable
/// instruction at most once, keeping the oldest start at an instruction.
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
  private indirect enum Node {
    case atom(Atom), sequence([Node]), choice([Node]), repeated(Node, Unicode.Scalar)
    case lineStart, lineEnd
  }
  private enum Instruction {
    case consume(Atom, Int), split(Int, Int), lineStart(Int), lineEnd(Int), match
  }
  private struct Thread { let state: Int; let start: Int }
  private struct Parser {
    let input: [Unicode.Scalar]
    let caseSensitive: Bool
    var index = 0
    var nodes = 0
    mutating func expression(depth: Int = 0) throws -> Node {
      guard depth <= 32 else { throw TerminalSearchAdmissionError.query }
      var alternatives = [try sequence(depth: depth)]
      while index < input.count, input[index] == "|" {
        index += 1
        alternatives.append(try sequence(depth: depth))
      }
      return alternatives.count == 1 ? alternatives[0] : .choice(alternatives)
    }
    mutating func sequence(depth: Int) throws -> Node {
      var sequence: [Node] = []
      while index < input.count, input[index] != "|", input[index] != ")" {
        nodes += 1
        guard nodes <= 256 else { throw TerminalSearchAdmissionError.query }
        var node = try atom(depth: depth)
        if index < input.count, input[index] == "?" || input[index] == "*" || input[index] == "+" {
          let quantifier = input[index]; index += 1
          switch node {
          case .lineStart, .lineEnd: throw TerminalSearchAdmissionError.query
          default: node = .repeated(node, quantifier)
          }
        }
        sequence.append(node)
      }
      guard !sequence.isEmpty else { throw TerminalSearchAdmissionError.query }
      return sequence.count == 1 ? sequence[0] : .sequence(sequence)
    }
    mutating func atom(depth: Int) throws -> Node {
      let character = input[index]; index += 1
      switch character {
      case "(":
        let inner = try expression(depth: depth + 1)
        guard index < input.count, input[index] == ")" else { throw TerminalSearchAdmissionError.query }
        index += 1
        return inner
      case "^": return .lineStart
      case "$": return .lineEnd
      case ".": return .atom(Atom(ranges: [], any: true))
      case "\\":
        let escapedValue = try escaped()
        let value = try folded(escapedValue)
        return .atom(Atom(ranges: [value...value]))
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
        return .atom(Atom(ranges: ranges, inverted: inverted))
      case "?", "*", "+", ")", "{", "}", "|", "]": throw TerminalSearchAdmissionError.query
      default:
        let value = try folded(character)
        return .atom(Atom(ranges: [value...value]))
      }
    }
    func folded(_ scalar: Unicode.Scalar) throws -> UInt32 {
      let values = caseSensitive ? [scalar] : UnicodeLowercase.lowercase(scalar)
      guard values.count == 1 else { throw TerminalSearchAdmissionError.query }
      return values[0].value
    }
    mutating func escaped() throws -> Unicode.Scalar {
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
  }
  private struct Compiler {
    var code: [Instruction] = [.match]
    mutating func append(_ instruction: Instruction) throws -> Int {
      guard code.count < 256 else { throw TerminalSearchAdmissionError.query }
      code.append(instruction)
      return code.count - 1
    }
    mutating func compile(_ node: Node, next: Int) throws -> Int {
      switch node {
      case .atom(let atom): return try append(.consume(atom, next))
      case .lineStart: return try append(.lineStart(next))
      case .lineEnd: return try append(.lineEnd(next))
      case .sequence(let nodes):
        var following = next
        for node in nodes.reversed() { following = try compile(node, next: following) }
        return following
      case .choice(let nodes):
        var alternatives = try compile(nodes[nodes.count - 1], next: next)
        for node in nodes.dropLast().reversed() {
          let branch = try compile(node, next: next)
          alternatives = try append(.split(branch, alternatives))
        }
        return alternatives
      case .repeated(let node, let quantifier):
        if quantifier == "?" {
          let body = try compile(node, next: next)
          return try append(.split(body, next))
        }
        let loop = try append(.match)
        let body = try compile(node, next: loop)
        code[loop] = .split(body, next)
        return quantifier == "*" ? loop : body
      }
    }
  }

  static let maxMatchScalars = 4096
  private let code: [Instruction]
  private let entry: Int
  /// Boundary proofs are conservatively retained for all regexes, so anchors
  /// inside a group or alternation have the same stale-result protection.
  private var active: [Thread] = []
  private var candidate: Range<Int>?
  private(set) var exceeded = false
  private var remainingWork = 64 * 1024 * 1024

  init(_ query: String, caseSensitive: Bool) throws {
    var parser = Parser(input: Array(query.unicodeScalars), caseSensitive: caseSensitive)
    let expression = try parser.expression()
    guard parser.index == parser.input.count else { throw TerminalSearchAdmissionError.query }
    var compiler = Compiler()
    entry = try compiler.compile(expression, next: 0)
    code = compiler.code
  }
  mutating func reset() { active.removeAll(keepingCapacity: true); candidate = nil }

  mutating func push(_ scalar: Unicode.Scalar, position: Int, previousWord: Bool,
                     lineStart: Bool, wholeWord: Bool) -> Range<Int>? {
    if !wholeWord || !previousWord { active.append(Thread(state: entry, start: position)) }
    let closure = close(position: position, lineStart: lineStart, lineEnd: scalar == "\n",
                        acceptsBoundary: !wholeWord || !Self.word(scalar))
    remainingWork -= closure.work
    if remainingWork <= 0 { exceeded = true; return nil }
    for start in closure.matches { consider(start..<position) }
    var following: [Thread] = []
    for thread in closure.consumers {
      if let candidate, thread.start > candidate.lowerBound { continue }
      guard case .consume(let atom, let destination) = code[thread.state] else { continue }
      remainingWork -= max(1, atom.ranges.count)
      if remainingWork <= 0 { exceeded = true; return nil }
      guard atom.accepts(scalar) else { continue }
      guard position - thread.start < Self.maxMatchScalars else { exceeded = true; continue }
      following.append(Thread(state: destination, start: thread.start))
    }
    active = following
    if let candidate, !active.contains(where: { $0.start <= candidate.lowerBound }) { return candidate }
    return nil
  }

  mutating func finish(position: Int, lineStart: Bool, wholeWord: Bool) -> Range<Int>? {
    let closure = close(position: position, lineStart: lineStart, lineEnd: true, acceptsBoundary: true)
    remainingWork -= closure.work
    if remainingWork <= 0 { exceeded = true; return nil }
    for start in closure.matches { consider(start..<position) }
    return candidate
  }

  private mutating func consider(_ range: Range<Int>) {
    guard !range.isEmpty else { return }
    if let current = candidate,
       range.lowerBound > current.lowerBound || (range.lowerBound == current.lowerBound && range.upperBound <= current.upperBound) { return }
    candidate = range
  }

  private func close(position: Int, lineStart: Bool, lineEnd: Bool,
                     acceptsBoundary: Bool) -> (consumers: [Thread], matches: [Int], work: Int) {
    // Oldest seeds are traversed first; a state is visited only once. Epsilon
    // cycles from nested repetition cannot cause recursion or repeated work.
    var stack = active.sorted { $0.start > $1.start }
    var visited = Array(repeating: false, count: code.count)
    var work = active.count * 8
    var consumers: [Thread] = []
    var matches: [Int] = []
    while let thread = stack.popLast() {
      guard !visited[thread.state] else { continue }
      visited[thread.state] = true
      work += 1
      switch code[thread.state] {
      case .consume: consumers.append(thread)
      case .split(let first, let second):
        stack.append(Thread(state: second, start: thread.start))
        stack.append(Thread(state: first, start: thread.start))
      case .lineStart(let next): if lineStart { stack.append(Thread(state: next, start: thread.start)) }
      case .lineEnd(let next): if lineEnd { stack.append(Thread(state: next, start: thread.start)) }
      case .match: if acceptsBoundary { matches.append(thread.start) }
      }
    }
    return (consumers, matches, work)
  }

  private static func word(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
      || scalar.properties.generalCategory == .nonspacingMark
      || scalar.properties.generalCategory == .spacingMark
      || scalar.properties.generalCategory == .enclosingMark
  }
}

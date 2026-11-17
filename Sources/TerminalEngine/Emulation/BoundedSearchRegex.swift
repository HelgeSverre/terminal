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
    /// `\w`: the same word test whole-word matching uses.
    var word = false
    func accepts(_ scalar: Unicode.Scalar) -> Bool {
      if any { return scalar.value != 10 }
      if word { return scalar.isSearchWord != inverted }
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
        if index < input.count, input[index] == "?" || input[index] == "*" || input[index] == "+" || input[index] == "{" {
          let quantifier = input[index]; index += 1
          switch node {
          case .lineStart, .lineEnd: throw TerminalSearchAdmissionError.query
          default: node = quantifier == "{" ? try counted(node) : .repeated(node, quantifier)
          }
        }
        sequence.append(node)
      }
      guard !sequence.isEmpty else { throw TerminalSearchAdmissionError.query }
      return sequence.count == 1 ? sequence[0] : .sequence(sequence)
    }
    /// `{n}`, `{n,}` and `{n,m}` after the opening brace, written out as
    /// copies. The instruction limit bounds what a count can expand to.
    mutating func counted(_ node: Node) throws -> Node {
      func number() -> Int? {
        var value: Int?
        while index < input.count, let digit = input[index].properties.numericType == .decimal && input[index].isASCII
          ? Int(input[index].value) - 48 : nil {
          value = (value ?? 0) * 10 + digit; index += 1
          if value! > 256 { return nil }
        }
        return value
      }
      guard let minimum = number(), index < input.count else { throw TerminalSearchAdmissionError.query }
      var maximum: Int? = minimum
      if input[index] == "," {
        index += 1
        maximum = index < input.count && input[index] == "}" ? nil : number()
        guard maximum != nil || (index < input.count && input[index] == "}") else { throw TerminalSearchAdmissionError.query }
      }
      guard index < input.count, input[index] == "}", maximum.map({ $0 >= minimum && $0 > 0 }) ?? true else {
        throw TerminalSearchAdmissionError.query
      }
      index += 1
      var parts = Array(repeating: node, count: minimum)
      if let maximum {
        // a{2,4} is aa(a(a)?)?: each optional copy admits the next.
        var optional: Node?
        for _ in minimum..<maximum {
          optional = .repeated(optional.map { .sequence([node, $0]) } ?? node, "?")
        }
        if let optional { parts.append(optional) }
      } else { parts.append(.repeated(node, "*")) }
      return parts.count == 1 ? parts[0] : .sequence(parts)
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
        if index < input.count, let shorthand = Self.shorthand(input[index]) { index += 1; return .atom(shorthand) }
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
          guard lower.value <= upper.value else { throw TerminalSearchAdmissionError.query }
          ranges.append(lower.value...upper.value)
          if !caseSensitive { ranges.append(contentsOf: Self.lowercaseImage(lower.value...upper.value)) }
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
    /// Text is lowercased before a case-insensitive match, so a class also
    /// accepts the lowercase of each member. Folding only the endpoints would
    /// make `[@-Z]` cover the punctuation between `Z` and `a`.
    static func lowercaseImage(_ range: ClosedRange<UInt32>) -> [ClosedRange<UInt32>] {
      var image: [ClosedRange<UInt32>] = []
      // A wider range than this keeps only its own members.
      guard range.count <= 65_536 else { return image }
      for value in range {
        guard let scalar = Unicode.Scalar(value) else { continue }
        let lowered = UnicodeLowercase.lowercase(scalar)
        guard lowered.count == 1, lowered[0].value != value else { continue }
        if let last = image.last, last.upperBound + 1 == lowered[0].value {
          image[image.count - 1] = last.lowerBound...lowered[0].value
        } else if image.last?.contains(lowered[0].value) != true {
          image.append(lowered[0].value...lowered[0].value)
        }
      }
      return image
    }
    static func shorthand(_ scalar: Unicode.Scalar) -> Atom? {
      let space: [ClosedRange<UInt32>] = [9...13, 32...32]
      switch scalar {
      case "d": return Atom(ranges: [48...57])
      case "D": return Atom(ranges: [48...57], inverted: true)
      case "s": return Atom(ranges: space)
      case "S": return Atom(ranges: space, inverted: true)
      case "w": return Atom(ranges: [], word: true)
      case "W": return Atom(ranges: [], inverted: true, word: true)
      default: return nil
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
  private var active: [Thread] = []
  private var candidate: Range<Int>?
  private(set) var exceeded = false
  /// A path that reached `maxMatchScalars` was dropped; results may be incomplete.
  private(set) var truncated = false
  /// A base allowance, plus a grant for each scalar seen for the first time.
  /// An ordinary pattern costs less per scalar than the grant, so history
  /// length never exhausts it; repeated lookahead replay still does.
  private var remainingWork = 64 * 1024 * 1024
  private static let workPerScalar = 128
  private var granted = 0
  // Scratch reused for every scalar.
  private var stack: [Thread] = []
  private var consumers: [Thread] = []
  private var matchStarts: [Int] = []
  private var visited: [UInt32]
  private var visit: UInt32 = 0

  init(_ query: String, caseSensitive: Bool) throws {
    var parser = Parser(input: Array(query.unicodeScalars), caseSensitive: caseSensitive)
    let expression = try parser.expression()
    guard parser.index == parser.input.count else { throw TerminalSearchAdmissionError.query }
    var compiler = Compiler()
    entry = try compiler.compile(expression, next: 0)
    code = compiler.code
    visited = Array(repeating: 0, count: code.count)
  }
  mutating func reset() { active.removeAll(keepingCapacity: true); candidate = nil }

  mutating func push(_ scalar: Unicode.Scalar, position: Int, previousWord: Bool,
                     lineStart: Bool, wholeWord: Bool) -> Range<Int>? {
    if position >= granted { granted = position + 1; remainingWork += Self.workPerScalar }
    // Seeds arrive in position order and every later step keeps that order,
    // so `active` is always sorted by start, oldest first.
    if !wholeWord || !previousWord { active.append(Thread(state: entry, start: position)) }
    remainingWork -= close(position: position, lineStart: lineStart, lineEnd: scalar == "\n",
                           acceptsBoundary: !wholeWord || !scalar.isSearchWord)
    if remainingWork <= 0 { exceeded = true; return nil }
    for start in matchStarts { consider(start..<position) }
    active.removeAll(keepingCapacity: true)
    for thread in consumers {
      if let candidate, thread.start > candidate.lowerBound { continue }
      guard case .consume(let atom, let destination) = code[thread.state] else { continue }
      remainingWork -= max(1, atom.ranges.count)
      if remainingWork <= 0 { exceeded = true; return nil }
      guard atom.accepts(scalar) else { continue }
      active.append(Thread(state: destination, start: thread.start))
    }
    if let candidate, !active.contains(where: { $0.start <= candidate.lowerBound }) { return candidate }
    return nil
  }

  mutating func finish(position: Int, lineStart: Bool) -> Range<Int>? {
    remainingWork -= close(position: position, lineStart: lineStart, lineEnd: true, acceptsBoundary: true)
    if remainingWork <= 0 { exceeded = true; return nil }
    for start in matchStarts { consider(start..<position) }
    return candidate
  }

  private mutating func consider(_ range: Range<Int>) {
    guard !range.isEmpty else { return }
    if let current = candidate,
       range.lowerBound > current.lowerBound || (range.lowerBound == current.lowerBound && range.upperBound <= current.upperBound) { return }
    candidate = range
  }

  /// Fills `consumers` and `matchStarts` from `active` and returns the work
  /// done. Oldest seeds are traversed first and a state is visited once, so
  /// epsilon cycles from nested repetition cause neither recursion nor
  /// repeated work.
  ///
  /// A path already `maxMatchScalars` long is dropped before it can claim a
  /// state, so a younger path waiting at the same state takes over.
  private mutating func close(position: Int, lineStart: Bool, lineEnd: Bool, acceptsBoundary: Bool) -> Int {
    stack.removeAll(keepingCapacity: true)
    stack.append(contentsOf: active.reversed())
    consumers.removeAll(keepingCapacity: true)
    matchStarts.removeAll(keepingCapacity: true)
    if visit == .max { visit = 0; for index in visited.indices { visited[index] = 0 } }
    visit += 1
    var work = active.count * 8
    while let thread = stack.popLast() {
      guard position - thread.start < Self.maxMatchScalars else { truncated = true; continue }
      guard visited[thread.state] != visit else { continue }
      visited[thread.state] = visit
      work += 1
      switch code[thread.state] {
      case .consume: consumers.append(thread)
      case .split(let first, let second):
        stack.append(Thread(state: second, start: thread.start))
        stack.append(Thread(state: first, start: thread.start))
      case .lineStart(let next): if lineStart { stack.append(Thread(state: next, start: thread.start)) }
      case .lineEnd(let next): if lineEnd { stack.append(Thread(state: next, start: thread.start)) }
      case .match: if acceptsBoundary { matchStarts.append(thread.start) }
      }
    }
    return work
  }
}

extension Unicode.Scalar {
  /// What whole-word search and `\w` call part of a word: letters, numbers,
  /// combining marks and underscore.
  var isSearchWord: Bool {
    self == "_" || properties.isAlphabetic || properties.numericType != nil
      || properties.generalCategory == .nonspacingMark
      || properties.generalCategory == .spacingMark
      || properties.generalCategory == .enclosingMark
  }
}

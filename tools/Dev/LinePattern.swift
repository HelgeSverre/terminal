import Foundation

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

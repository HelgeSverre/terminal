import Foundation

/// Search of terminal scalars, without locale-dependent normalization.
public struct TerminalSearchOptions: Equatable, Sendable {
  public var caseSensitive: Bool
  /// A word consists of Unicode letters, numbers, marks and underscore.
  public var wholeWord: Bool
  /// Enables the bounded regular-expression syntax described in
  /// `docs/search.md`. Unsupported syntax is rejected, never treated literally.
  public var regularExpression: Bool

  public init(caseSensitive: Bool = false, wholeWord: Bool = false, regularExpression: Bool = false) {
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
    self.regularExpression = regularExpression
  }

  package var flags: UInt32 {
    (caseSensitive ? 1 : 0) | (wholeWord ? 2 : 0) | (regularExpression ? 4 : 0)
  }
  init(flags: UInt32) {
    self.init(caseSensitive: flags & 1 != 0, wholeWord: flags & 2 != 0, regularExpression: flags & 4 != 0)
  }
}

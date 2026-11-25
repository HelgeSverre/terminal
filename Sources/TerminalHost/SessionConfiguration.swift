import Foundation
import TerminalEngine

/// What a host may change about a running session.
public struct TerminalSessionConfiguration: Sendable {
  public let historyRows: Int
  public let followTailOnInput: Bool
  /// The colors the terminal starts with. The view draws its cursor and
  /// selection from here too.
  public var colors = TerminalColorScheme.standard
  /// The name/version returned by XTVERSION; the host supplies its release version.
  public var identity = TerminalIdentity.helgeTerminal
  /// How wide text is laid out until the program says otherwise with mode
  /// 2027. True: a grapheme cluster, such as an emoji with a skin tone or a
  /// flag, takes the cells of one character. False: every code point with a
  /// width takes its own cells, as a shell that counts code points expects;
  /// such emoji are then drawn in pieces.
  public var graphemeClustering = true
  package let selectionWordProfile: TerminalSelectionWordProfile
  public init(historyRows: Int = 50_000, followTailOnInput: Bool = true,
              colors: TerminalColorScheme = .standard, identity: TerminalIdentity = .helgeTerminal) {
    self.init(historyRows: historyRows, followTailOnInput: followTailOnInput, selectionWordProfile: .standard)
    self.colors = colors
    self.identity = identity
  }
  package init(historyRows: Int = 50_000, followTailOnInput: Bool = true,
               selectionWordProfile: TerminalSelectionWordProfile) {
    self.historyRows = min(50_000, max(0, historyRows))
    self.followTailOnInput = followTailOnInput
    self.selectionWordProfile = selectionWordProfile
  }
}

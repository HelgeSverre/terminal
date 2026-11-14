import Foundation
import TerminalEngine

/// What a host may change about a running session.
public struct TerminalSessionConfiguration {
  public let historyRows: Int
  public let followTailOnInput: Bool
  /// The colors the terminal starts with. The view draws its cursor and
  /// selection from here too.
  public var colors = TerminalColorScheme.standard
  package let selectionWordProfile: TerminalSelectionWordProfile
  public init(historyRows: Int = 50_000, followTailOnInput: Bool = true,
              colors: TerminalColorScheme = .standard) {
    self.init(historyRows: historyRows, followTailOnInput: followTailOnInput, selectionWordProfile: .standard)
    self.colors = colors
  }
  package init(historyRows: Int = 50_000, followTailOnInput: Bool = true,
               selectionWordProfile: TerminalSelectionWordProfile) {
    self.historyRows = min(50_000, max(0, historyRows))
    self.followTailOnInput = followTailOnInput
    self.selectionWordProfile = selectionWordProfile
  }
}

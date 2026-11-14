import Foundation
import TerminalCore

/// What a host may change about a running session.
public struct TerminalSessionConfiguration {
  public let historyRows: Int
  public let followTailOnInput: Bool
  package let selectionWordProfile: TerminalSelectionWordProfile
  public init(historyRows: Int = 50_000, followTailOnInput: Bool = true) {
    self.init(historyRows: historyRows, followTailOnInput: followTailOnInput, selectionWordProfile: .standard)
  }
  package init(historyRows: Int = 50_000, followTailOnInput: Bool = true,
               selectionWordProfile: TerminalSelectionWordProfile) {
    self.historyRows = min(50_000, max(0, historyRows))
    self.followTailOnInput = followTailOnInput
    self.selectionWordProfile = selectionWordProfile
  }
}

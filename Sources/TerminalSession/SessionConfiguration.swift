import Foundation
import TerminalCore

/// What a host may change about a running session.
package struct TerminalSessionConfiguration {
  package let historyRows: Int
  package let followTailOnInput: Bool
  package let selectionWordProfile: TerminalSelectionWordProfile
  package init(historyRows: Int = 50_000, followTailOnInput: Bool = true,
       selectionWordProfile: TerminalSelectionWordProfile = .standard) {
    self.historyRows = min(50_000, max(0, historyRows))
    self.followTailOnInput = followTailOnInput
    self.selectionWordProfile = selectionWordProfile
  }
}

import Foundation

/// History reading has its own bounded, immutable surface. It does not move
/// the viewport, alter terminal selection, or expose owner-confined rows.
package struct TerminalHistoryCursor: Equatable, Sendable {
  package let document: UUID
  package let alternate: Bool
  package let row: UInt64
}
package enum TerminalHistoryPageRequest: Sendable {
  case latest
  case older(TerminalHistoryCursor)
  case newer(TerminalHistoryCursor)
}
package struct TerminalHistoryPage: Sendable {
  package struct Row: Sendable {
    package let cursor: TerminalHistoryCursor
    package let text: String
    package let truncated: Bool
  }
  package let rows: [Row]
  package let hasOlder: Bool
  package let hasNewer: Bool
  package var text: String { rows.map(\.text).joined(separator: "\n") }
}

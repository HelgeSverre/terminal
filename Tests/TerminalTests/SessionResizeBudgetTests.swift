import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession

/// Serialized: the test holds the process-wide reflow budget.
@Suite(.serialized) @MainActor struct SessionResizeBudgetTests {
  /// Reflow memory comes from one budget for the whole process. A resize
  /// that finds it taken by other panes must wait and then commit, not be
  /// dropped: the pane's view already has the new size.
  @Test func resizeWaitsForReflowBudget() async {
    var held: [ReflowReservationLedger.Lease] = []
    while let lease = ReflowReservationLedger.shared.reserve(32 * 1024 * 1024) { held.append(lease) }
    let session = Session(launch: TestEnvironment.shell("stty raw -echo; printf BUDGET_RESIZE_READY; exec /bin/cat"))
    defer { session.close() }
    var requested: Date?
    var grid = (columns: 0, rows: 0)
    var statuses: [String] = []
    session.onStatus = { statuses.append($0) }
    session.onSnapshot = { snapshot in
      grid = (snapshot.cols, snapshot.rows.count)
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if requested == nil && text.contains("BUDGET_RESIZE_READY") {
        requested = Date()
        session.resize(cols: 40, rows: 10)
      }
    }
    #expect(await TestEnvironment.wait { requested.map { Date().timeIntervalSince($0) >= 0.4 } ?? false })
    #expect(grid == (80, 24), "the resize must wait while the budget is held")
    held.removeAll()
    #expect(await TestEnvironment.wait { grid == (40, 10) }, "the resize must commit once the budget frees")
    #expect(!statuses.contains { $0.contains("rejected") })
  }
}

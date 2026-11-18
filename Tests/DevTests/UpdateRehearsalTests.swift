import Foundation
import Testing
@testable import dev

@Suite struct UpdateRehearsalTests {
  /// A mistyped option must not start a build and open windows.
  @Test func unknownOrIncompleteArgumentsAreUsageErrors() {
    for arguments in [["--bogus"], ["--scenario"], ["--timeout"], ["--timeout", "0"], ["--timeout", "soon"], ["extra"]] {
      do {
        try UpdateRehearsal.run(arguments)
        Issue.record("accepted \(arguments)")
      } catch let failure as Failure {
        #expect(failure.isUsage, "\(arguments): \(failure.message)")
      } catch { Issue.record("\(arguments): \(error)") }
    }
  }
}

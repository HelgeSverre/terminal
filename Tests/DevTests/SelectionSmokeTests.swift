import Foundation
import Testing
@testable import dev

@Suite struct SelectionSmokeTests {
  /// Runs `body` with a stand-in app whose report passes every check but `failing`.
  private func withFakeApp(failing: String?, _ body: (String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-selection-smoke-") { directory in
      let report: [String: Any] = [
        "passed": true, "expected_known_text": SelectionSmoke.expectedText,
        "checks": Dictionary(uniqueKeysWithValues: SelectionSmoke.checks.map { ($0, $0 != failing) }),
        "counts": ["required_checks": SelectionSmoke.checks.count, "passed_checks": SelectionSmoke.checks.count],
      ]
      try writeJSON(report, to: directory + "/report.json")
      let bundle = try fakeBundle(in: directory, script: "cp '\(directory)/report.json' \"$2\"")
      try body(bundle, directory + "/reports")
    }
  }

  @Test("selection smoke: a complete passing report passes and gains the runner's record") func aCompletePassingReportPasses() throws {
    try withFakeApp(failing: nil) { bundle, reports in
      try SelectionSmoke.run(bundle: bundle, reportDirectory: reports)
      let report = try readJSONObject(reports + "/selection-smoke.json")
      let runner = report["runner"] as? [String: Any]
      #expect(report["passed"] as? Bool == true, "report passed")
      #expect(runner?["app_exited"] as? Bool == true, "app exit recorded")
      #expect(runner?["cleanup_survivors"] as? [Int] == [], "no survivors recorded")
    }
  }

  @Test("selection smoke: a failed check is named and the report marked failed") func aFailedCheckIsNamed() throws {
    try withFakeApp(failing: "wide_drag") { bundle, reports in
      let failure = try #require(throws: Failure.self) { try SelectionSmoke.run(bundle: bundle, reportDirectory: reports) }
      #expect(failure.message == "selection checks failed: wide_drag", "got: \(failure.message)")
      let report = try readJSONObject(reports + "/selection-smoke.json")
      #expect(report["passed"] as? Bool == false, "report failed")
      #expect(report["runner_error"] as? String == failure.message, "the failure is recorded")
      #expect(report["checks"] != nil, "the app's checks are kept")
    }
  }
}

import Foundation
import Testing
@testable import dev

@Suite struct StartupGridSmokeTests {
  /// Runs `body` with a stand-in app that reports `columns`, a shell
  /// expression, as the width it saw. It lives long enough to be seen as the
  /// owner of its report.
  private func withFakeApp(columns: String, pixelWidth: Int = 640,
                           _ body: (String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-startup-grid-") { directory in
      let script = """
        printf '{"terminal_pid": %d, "columns": %d, "rows": %d, "pixel_width": \(pixelWidth), "pixel_height": 384}' \
          $$ "\(columns)" "$4" > "${11}"
        sleep 0.3
        """
      try body(try fakeBundle(in: directory, script: script), directory + "/reports/startup-grid.json")
    }
  }

  @Test("startup grid smoke: a pixel size of zero fails and names the case") func aPixelSizeOfZeroFails() throws {
    try withFakeApp(columns: "$2", pixelWidth: 0) { bundle, report in
      let failure = try #require(throws: Failure.self) { try StartupGridSmoke.run(app: bundle, reportPath: report) { _ in } }
      #expect(failure.message == "80x24 at 8pt: the driver saw a pixel size of 0x384", "got: \(failure.message)")
      let written = try readJSONObject(report)
      #expect(written["passed"] as? Bool == false && written["failure"] as? String == failure.message,
              "the failure is recorded")
      #expect((written["cases"] as? [[String: Any]])?.count == 1, "the failed case is recorded")
    }
  }

  @Test("startup grid smoke: three matching grids from a clean exit pass") func threeMatchingGridsPass() throws {
    try withFakeApp(columns: "$2") { bundle, report in
      try StartupGridSmoke.run(app: bundle, reportPath: report) { _ in }
      let written = try readJSONObject(report)
      let cases = written["cases"] as? [[String: Any]] ?? []
      #expect(written["passed"] as? Bool == true, "report passed")
      #expect(written["frozen_executable_sha256"] as? String == written["executable_sha256"] as? String,
              "the frozen hash is recorded")
      #expect(cases.count == 3, "three cases")
      #expect(cases.first?["observed"] as? [Int] == [80, 24, 640, 384], "got: \(cases)")
      #expect(cases.allSatisfy { ($0["cleanup_survivors"] as? [Int]) == [] }, "no survivors")
    }
  }

  @Test("startup grid smoke: another grid than requested fails and is reported") func anotherGridThanRequestedFails() throws {
    try withFakeApp(columns: "1") { bundle, report in
      let failure = try #require(throws: Failure.self) { try StartupGridSmoke.run(app: bundle, reportPath: report) { _ in } }
      #expect(failure.message == "wrong owner/grid", "got: \(failure.message)")
      let written = try readJSONObject(report)
      #expect(written["passed"] as? Bool == false, "report failed")
      #expect(written["failure"] as? String == "wrong owner/grid", "the failure is recorded")
      #expect((written["cases"] as? [[String: Any]])?.count == 1, "the failed case is recorded")
    }
  }
}

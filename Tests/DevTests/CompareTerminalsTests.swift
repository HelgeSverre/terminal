import Foundation
import Testing
@testable import dev

@Suite struct CompareTerminalsTests {
  @Test("compare terminals: a valid owned report is accepted and the app reaped") func aValidOwnedReportIsAccepted() throws {
    let (record, failure) = try trial(report: report())
    #expect(failure == nil, "got: \(failure ?? "")")
    #expect(record["natural_exit"] as? Bool == true, "exit is natural")
    #expect((record["report"] as? [String: Any])?["terminal"] as? String == "ghostty", "report is kept")
    #expect(ReportValue.same(record["report_pid"], record["pid"]), "report names the launched process")
    #expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
  }

  @Test("compare terminals: the driver's failure is kept when the app exits non-zero") func theDriversFailureIsKeptWhen() throws {
    let (record, failure) = try trial(failed: "geometry is 100x27; expected 100x30", status: 7)
    #expect(failure == "geometry is 100x27; expected 100x30", "got: \(failure ?? "no failure")")
    #expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
  }

  @Test("compare terminals: a wrong label and a missing mode are rejected") func aWrongLabelAndAMissing() throws {
    for change in [["terminal": "another-app"], ["output_post_processing": NSNull()]] as [[String: Any]] {
      let (record, failure) = try trial(report: report().merging(change) { _, new in new })
      #expect(failure != nil, "\(change.keys) is rejected")
      #expect(record["report"] == nil, "report is not kept")
      #expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
    }
  }

  @Test("compare terminals: kitty gets an isolated grid and quits with its window") func kittyGetsAnIsolatedGridAnd() throws {
    let command = try CompareTerminals.launchCommand("kitty", executable: "/fixture/kitty", configuration: "/fixture/config",
                                    driver: ["/fixture/driver"])
    #expect(Array(command.prefix(5)) == ["/fixture/kitty", "--config", "NONE", "--session", "none"], "isolated")
    for option in ["initial_window_width=100c", "initial_window_height=30c", "shell_integration=disabled",
                   "macos_quit_when_last_window_closed=yes"] {
      #expect(command.contains(option), "passes \(option)")
    }
    let (record, failure) = try trial(name: "kitty", report: report().merging(["terminal": "kitty"]) { _, new in new })
    #expect(failure == nil, "got: \(failure ?? "")")
    #expect(record["natural_exit"] as? Bool == true, "kitty's report is accepted")
  }

  @Test("compare terminals: an app that outlives the limit is ended and recorded") func anAppThatOutlivesTheLimit() throws {
    let (record, failure) = try trial(linger: true)
    #expect(failure == "ghostty timed out", "got: \(failure ?? "no failure")")
    #expect(record["natural_exit"] as? Bool == false, "exit is not natural")
    #expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
    #expect(kill(pid_t(record["pid"] as? Int ?? 0), 0) != 0, "the app is gone")
  }

}

private func report() -> [String: Any] {
  ["schema": 2, "terminal": "ghostty", "terminal_pid": fixturePlaceholderPID, "columns": 100, "rows": 30,
   "pixel_width": 800, "pixel_height": 540, "output_post_processing": true,
   "workloads": BenchDriver.workloads.map { name -> [String: Any] in
     ["name": name, "source_bytes_per_run": 1, "run_samples": [["run": 1, "mib_per_second": 1.0] as [String: Any]],
      "mib_per_second": ["p50": 1.0]]
   }]
}

/// Measures a fixture terminal once and returns its record with the
/// failure the measurement ended in, if any. The fixture writes `report` or
/// the `failed` reason where the driver would, then exits with `status`, or
/// stays when `linger`.
private func trial(name: String = "ghostty", report: [String: Any]? = nil, failed: String? = nil,
                          status: Int = 0, linger: Bool = false) throws -> (record: [String: Any], failure: String?) {
  try withTemporaryDirectory("dev-compare-terminals-") { directory in
    let executable = directory + "/fixture"
    if let report { try JSONValue(sortingKeysOf: report).write(to: executable + ".report") }
    if let failed { try failed.write(toFile: executable + ".failed", atomically: true, encoding: .utf8) }
    // The fixture must live long enough to be seen, or its PID is not known as owned.
    try writeScript("""
      sleep \(linger ? "30" : "0.3")
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --output ]; then
          if [ -f "$0.report" ]; then sed "s/\(fixturePlaceholderPID)/$$/" "$0.report" > "$2"; fi
          if [ -f "$0.failed" ]; then cp "$0.failed" "$2.failed"; fi
        fi
        shift
      done
      exit \(status)
      """, to: executable)
    var comparison = CompareTerminals.Comparison(output: directory, bytes: 1, runs: 1)
    if linger { comparison.limit = 0.3 }
    var trial = CompareTerminals.Trial(order: [name])
    var failure: String?
    do {
      try comparison.measure(name, executable: executable, driver: "/fixture/driver",
                             configuration: "/fixture/config", index: 1, trial: &trial)
    } catch { failure = Failure(wrapping: error).message }
    return (trial.apps[name] ?? [:], failure)
  }
}

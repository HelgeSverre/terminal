import Foundation
import Testing
@testable import dev

@Suite struct CompareTerminalAppsTests {
  @Test("compare terminal apps: observations in execution order are accepted") func observationsInExecutionOrderAreAccepted() throws {
    try validate(observations())
  }

  @Test("compare terminal apps: the driver's failure precedes a non-zero exit and the app is reaped") func theDriversFailurePrecedesANonzero() throws {
    try withFakeBundle(failingDriverScript("fixture driver failed")) { app, root in
      var comparison = CompareTerminalApps.Comparison(output: root, bytes: 2 * 1_048_576, runs: 3)
      comparison.driver = "/unused-driver"
      let message = try #require(throws: Failure.self) { try comparison.measure("candidate", app) }.message
      #expect(message == "fixture driver failed", "got: \(message)")
      let record = comparison.records["candidate"] ?? [:]
      #expect(record["natural_exit"] as? Bool == false, "exit is not natural")
      #expect((record["cleanup_survivors"] as? [Int]) == [], "nothing survives")
    }
  }

  @Test("compare terminal apps: a sample count without all observations is rejected") func aSampleCountWithoutAllObservations() throws {
    rejects("a missing observation") { try validate(Array(observations().dropLast())) }
  }

  @Test("compare terminal apps: duplicate and reordered run numbers are rejected") func duplicateAndReorderedRunNumbersAre() throws {
    var samples = observations()
    samples[2]["run"] = 2
    rejects("a duplicate run") { try validate(samples) }
    rejects("reversed runs") { try validate(observations().reversed()) }
  }

  @Test("compare terminal apps: a forged gate median is rejected") func aForgedGateMedianIsRejected() throws {
    var rate = summary(4.0, 8.0)
    rate["p50"] = 100.0
    rejects("a forged median") { try validate(observations(), rate: rate) }
  }

  @Test("compare terminal apps: independently sorted paired values are rejected") func independentlySortedPairedValuesAreRejected() throws {
    var samples = observations()
    for (index, time) in [0.25, 0.5, 1.0].enumerated() { samples[index]["elapsed_seconds"] = time }
    rejects("unpaired values") { try validate(samples) }
  }

  @Test("compare terminal apps: unavailable CPU time is accepted only when all observations agree") func unavailableCpuTimeIsAcceptedOnly() throws {
    var samples = observations()
    for index in samples.indices { samples[index]["terminal_cpu_seconds"] = NSNull() }
    try validate(samples, cpu: NSNull())
    samples[0]["terminal_cpu_seconds"] = 0.1
    rejects("a partly available CPU time") { try validate(samples, cpu: NSNull()) }
  }

  @Test("compare terminal apps: non-finite observations are rejected") func nonfiniteObservationsAreRejected() throws {
    var samples = observations()
    samples[0]["mib_per_second"] = Double.infinity
    rejects("an infinite rate") { try validate(samples) }
  }

  @Test("compare terminal apps: two accepted apps give a report with the order and the gate") func twoAcceptedAppsGiveAReport() throws {
    try withFakeBundle(reportingScript) { app, root in
      try writeDriverReport(for: app, rate: 2.0)
      var comparison = try CompareTerminalApps.Comparison(output: root + "/report", baselineApp: app, candidateApp: app, environment: [
        "BENCH_FIRST": "candidate", "BENCH_BYTES": "1048576", "BENCH_RUNS": "1"])
      try comparison.run()
      let report = try readJSONObject(root + "/report/comparison.json")
      #expect(report["passed"] as? Bool == true, "comparison passed")
      #expect(report["order"] as? [String] == ["candidate", "baseline"], "order follows BENCH_FIRST")
      let gate = try report.object("performance_gate")
      #expect(gate["passed"] as? Bool == true, "gate passed")
      #expect(try gate.object("observed_ratios").number("unicode") == 1, "ratio is one")
      let baseline = try report.object("apps").object("baseline")
      #expect(baseline["report"] as? String == "baseline.json" && baseline["natural_exit"] as? Bool == true,
                 "the baseline is recorded")
      let text = try String(contentsOfFile: root + "/report/comparison.json", encoding: .utf8)
      #expect(text.contains("\"unicode\": 1.0"), "a ratio is written as floating point")
      #expect(comparison.summary == "Completed both app benchmarks; all owned processes exited cleanly; "
                   + "performance gate passed (every workload at or above 70% of baseline)", "got: \(comparison.summary)")
    }
  }

  @Test("compare terminal apps: a missed gate leaves the measurement passed and is stated in the summary") func aMissedGateLeavesTheMeasurement() throws {
    try withFakeBundle(reportingScript) { app, root in
      let slow = root + "/Slow.app"
      try writeScript(reportingScript, to: slow + "/Contents/MacOS/Terminal")
      try writeDriverReport(for: app, rate: 2.0)
      try writeDriverReport(for: slow, rate: 1.0)
      var comparison = try CompareTerminalApps.Comparison(output: root + "/report", baselineApp: app, candidateApp: slow, environment: [
        "BENCH_BYTES": "1048576", "BENCH_RUNS": "1"])
      try comparison.run()
      let report = try readJSONObject(root + "/report/comparison.json")
      #expect(report["passed"] as? Bool == true, "both apps were measured")
      #expect(report["order"] as? [String] == ["baseline", "candidate"], "the baseline is measured first by default")
      let refused = try #require(throws: Failure.self) {
        _ = try CompareTerminalApps.Comparison(output: root + "/other", baselineApp: app, candidateApp: slow,
                           environment: ["BENCH_FIRST": "first"])
      }
      #expect(refused.message == "BENCH_FIRST must be baseline or candidate", "got: \(refused.message)")
      #expect(try report.object("performance_gate")["passed"] as? Bool == false, "the gate is missed")
      let workloads = BenchDriver.workloads.sorted().map { "\($0) 50.0%" }.joined(separator: ", ")
      #expect(comparison.summary == "Completed both app benchmarks; all owned processes exited cleanly; "
                   + "performance gate failed (below 70% of baseline: \(workloads))", "got: \(comparison.summary)")
    }
  }

}

/// A fixture app that writes the report beside its executable where the
/// driver would, under the label and with the PID it was launched with.
private let reportingScript = """
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then output=$2; fi
    if [ "$1" = --terminal ]; then label=$2; fi
    shift
  done
  sed -e "s/\(fixturePlaceholderPID)/$$/" -e "s/LABEL/$label/" "$0.report" > "$output"
  """

/// Writes the report a fixture app answers with: one 1 MiB run of every
/// workload at `rate` MiB per second.
private func writeDriverReport(for app: String, rate: Double) throws {
  func summary(_ value: Double) -> [String: Any] { ["samples": 1, "p50": value, "p95": value, "p99": value, "max": value] }
  try JSONValue(sortingKeysOf: [
    "schema": 2, "terminal": "LABEL", "terminal_pid": fixturePlaceholderPID, "columns": 100, "rows": 30,
    "pixel_width": 800, "pixel_height": 540, "output_post_processing": true,
    "workloads": BenchDriver.workloads.map { name -> [String: Any] in
      ["name": name, "source_bytes_per_run": 1_048_576, "mib_per_second": summary(rate),
       "elapsed_seconds": summary(1 / rate), "terminal_cpu_seconds": NSNull(),
       "run_samples": [["run": 1, "mib_per_second": rate, "elapsed_seconds": 1 / rate,
                        "terminal_cpu_seconds": NSNull()] as [String: Any]]]
    },
  ] as [String: Any]).write(to: app + "/Contents/MacOS/Terminal.report")
}

private func observations() -> [[String: Any]] {
  [["run": 1, "mib_per_second": 2.0, "elapsed_seconds": 1.0, "terminal_cpu_seconds": 0.1],
   ["run": 2, "mib_per_second": 8.0, "elapsed_seconds": 0.25, "terminal_cpu_seconds": 0.3],
   ["run": 3, "mib_per_second": 4.0, "elapsed_seconds": 0.5, "terminal_cpu_seconds": 0.2]]
}

private func summary(_ median: Double, _ maximum: Double) -> [String: Any] {
  ["samples": 3, "p50": median, "p95": median, "p99": median, "max": maximum]
}

/// Validates a 2 MiB, three-run workload made of `samples` and summaries.
private func validate(_ samples: [[String: Any]], rate: [String: Any] = summary(4.0, 8.0),
                             cpu: Any = summary(0.2, 0.3)) throws {
  let workload: [String: Any] = [
    "source_bytes_per_run": 2 * 1_048_576, "run_samples": samples,
    "mib_per_second": rate, "elapsed_seconds": summary(0.5, 1.0), "terminal_cpu_seconds": cpu,
  ]
  try CompareTerminalApps.Comparison(output: "", bytes: 2 * 1_048_576, runs: 3).validateWorkload(workload, "fixture")
}

private func rejects(_ what: String, _ body: () throws -> Void) {
  #expect(throws: Failure.self, Comment(rawValue: what)) { try body() }
}

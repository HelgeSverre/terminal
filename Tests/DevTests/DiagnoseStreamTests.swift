import Foundation
import Testing
@testable import dev

@Suite struct DiagnoseStreamTests {
  @Test("diagnose stream: the driver's failure precedes a non-zero exit and cleanup is recorded") func theDriversFailurePrecedesANonzero() throws {
    try withFakeBundle(failingDriverScript("fixture stream driver failed")) { app, root in
      let message = try #require(throws: Failure.self) {
        try DiagnoseStream.diagnose(app: app, output: root + "/diagnostic", bytes: 1, background: false)
      }.message
      #expect(message.contains("fixture stream driver failed"), "got: \(message)")
      let report = try readJSONObject(root + "/diagnostic/diagnostic.json")
      #expect(report["passed"] as? Bool == false, "diagnosis did not pass")
      #expect((report["failure"] as? String)?.contains("fixture stream driver failed") == true, "failure is recorded")
      #expect((report["cleanup_survivors"] as? [Any])?.isEmpty == true, "nothing survives")
    }
  }

  @Test("diagnose stream: counters are reported per MiB of source, without the high-water marks") func countersAreReportedPerMibOf() throws {
    try withFakeBundle(reportingScript) { app, root in
      let source = 1_048_576
      try JSONValue(sortingKeysOf: [
        "schema": 2, "terminal": "session-diagnostic", "terminal_pid": fixturePlaceholderPID, "columns": 100, "rows": 30,
        "workloads": [[
          "name": "ascii_short_lines", "source_bytes_per_run": source, "mib_per_second": ["samples": DiagnoseStream.runs, "p50": 2.0],
          "run_samples": (1...DiagnoseStream.runs).map { ["run": $0, "mib_per_second": 2.0, "elapsed_seconds": 0.5] as [String: Any] },
        ] as [String: Any]],
      ] as [String: Any]).write(to: app + "/Contents/MacOS/Terminal.driver")
      try JSONValue(sortingKeysOf: [
        "child_reaped": true, "read_ended": true, "parser_ended": true,
        "bytes_read": source * DiagnoseStream.runs, "bytes_parsed": source * DiagnoseStream.runs, "queued_output_bytes": 0,
        "stream_diagnostic": ["feed_bytes": source * DiagnoseStream.runs, "output_events": 20, "event_queue_high_water": 3,
                              "queued_output_bytes_high_water": 4],
      ] as [String: Any]).write(to: app + "/Contents/MacOS/Terminal.session")
      try DiagnoseStream.diagnose(app: app, output: root + "/diagnostic", bytes: source, background: false)
      let report = try readJSONObject(root + "/diagnostic/diagnostic.json")
      #expect(report["passed"] as? Bool == true && report["natural_exit"] as? Bool == true, "diagnosis passed")
      let perMiB = try report.object("per_source_mib")
      #expect(perMiB.keys.sorted() == ["feed_bytes", "output_events"], "got: \(perMiB.keys.sorted())")
      #expect(try perMiB.number("output_events") == 2, "two events per MiB")
      #expect(try report.number("mean_output_event_bytes") == 524_288, "mean event size")
      let text = try String(contentsOfFile: root + "/diagnostic/diagnostic.json", encoding: .utf8)
      #expect(text.contains("\"output_events\": 2.0"), "a rate is written as floating point")
    }
  }

}

/// A fixture app that writes the driver report and the session statistics
/// kept beside its executable to where it was asked to.
private let reportingScript = """
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --session-statistics-file ]; then cp "$0.session" "$2"; fi
    if [ "$1" = --output ]; then sed "s/\(fixturePlaceholderPID)/$$/" "$0.driver" > "$2"; fi
    shift
  done
  """

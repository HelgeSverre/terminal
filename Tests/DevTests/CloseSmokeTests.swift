import Foundation
import Testing
@testable import dev

@Suite struct CloseSmokeTests {
  /// Runs `body` with a stand-in bundle and an empty report directory.
  private func withFakeApp(_ script: String, _ body: (String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-close-smoke-") { directory in
      let reports = directory + "/reports"
      try FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
      try body(try fakeBundle(in: directory, script: script), reports)
    }
  }

  @Test("close smoke: a successful app exit does not hide a surviving child") func aSuccessfulAppExitDoesNotHide() throws {
    let sentinel = try ProcessTree(["/bin/sleep", "30"])
    defer { sentinel.cleanup() }
    // The app outlives the first look at its tree, so the child is known to be its own.
    let script = """
      sleep 30 &
      printf '{"passed": true, "trigger": "last-window-close", "child_pid": %d}' $! > "$2"
      sleep 0.4
      """
    try withFakeApp(script) { bundle, reports in
      let failure = try #require(throws: Failure.self) {
        try CloseSmoke.run(CloseSmoke.modes[0], bundle: bundle, reportDirectory: reports)
      }
      #expect(failure.message.contains("PTY child survived"), "got: \(failure.message)")
      let report = try readJSONObject(reports + "/close-window-smoke.json")
      #expect(report["passed"] as? Bool == false, "report failed")
      #expect(try !processExists(report["child_pid"] as? Int ?? 0), "cleanup ended the child")
      #expect(kill(sentinel.pid, 0) == 0, "a bystander still runs")
    }
  }

  @Test("close smoke: a report for the wrong trigger cannot pass") func aReportForTheWrongTrigger() throws {
    try withFakeApp(#"printf '{"passed": true, "trigger": "cmd+q", "child_pid": 1}' > "$2""#) { bundle, reports in
      let failure = try #require(throws: Failure.self) {
        try CloseSmoke.run(CloseSmoke.modes[0], bundle: bundle, reportDirectory: reports)
      }
      #expect(failure.message.contains("incorrect shutdown trigger"), "got: \(failure.message)")
      let report = try readJSONObject(reports + "/close-window-smoke.json")
      #expect(report["passed"] as? Bool == false, "report failed")
    }
  }

  @Test("close smoke: the app's report is kept when the app does not exit cleanly") func theAppsReportIsKept() throws {
    let script = #"printf '{"passed": true, "trigger": "last-window-close", "child_pid": 1}' > "$2"; exit 3"#
    try withFakeApp(script) { bundle, reports in
      let failure = try #require(throws: Failure.self) {
        try CloseSmoke.run(CloseSmoke.modes[0], bundle: bundle, reportDirectory: reports)
      }
      #expect(failure.message == "window: app did not exit successfully", "got: \(failure.message)")
      let report = try readJSONObject(reports + "/close-window-smoke.json")
      #expect(report["passed"] as? Bool == false && report["runner_error"] as? String == failure.message,
              "the runner's verdict is recorded: \(report)")
      #expect(report["trigger"] as? String == "last-window-close" && report["child_pid"] as? Int == 1,
              "the app's report is kept: \(report)")
    }
  }

  @Test("close smoke: native reports gain a pass only after both shutdown checks") func nativeReportsGainAPass() throws {
    let script = """
      /usr/bin/true & child=$!
      wait $child
      trigger=last-window-close
      case " $* " in *" --quit-shortcut "*) trigger=cmd+q ;; esac
      printf '{"trigger": "%s", "child_pid": %d}' $trigger $child > "$2"
      """
    try withFakeApp(script) { bundle, reports in
      for mode in CloseSmoke.modes {
        try CloseSmoke.run(mode, bundle: bundle, reportDirectory: reports)
        let report = try readJSONObject("\(reports)/close-\(mode.name)-smoke.json")
        for key in ["passed", "app_exited", "child_exited"] {
          #expect(report[key] as? Bool == true, "\(mode.name): \(key)")
        }
        #expect(report["bundle_path"] as? String == bundle, "\(mode.name): bundle path")
      }
    }
  }
}

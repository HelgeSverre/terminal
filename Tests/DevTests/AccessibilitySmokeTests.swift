import Foundation
import Testing
@testable import dev

@Suite struct AccessibilitySmokeTests {
  /// Runs `body` with a signable stand-in bundle whose executable runs the
  /// fixture command, as the app's pane would.
  private func withFakeApp(script: String = #"for last; do :; done; exec /bin/sh -c "$last""#,
                           _ body: (String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-accessibility-smoke-") { directory in
      let bundle = try fakeBundle(in: directory, script: script)
      let information = ["CFBundleIdentifier": "test.fixture", "CFBundleExecutable": "Terminal", "CFBundlePackageType": "APPL"]
      try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
        .write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
      try body(bundle, directory)
    }
  }

  @Test("accessibility smoke: a passing probe passes and the fixture's tree is ended and recorded") func aPassingProbePasses() throws {
    try withFakeApp { bundle, directory in
      // The probe answers after the fixture has had time to record its PID.
      try AccessibilitySmoke.run(bundle: bundle, reportDirectory: directory + "/reports") { probe in
        try writeScript(#"sleep 0.4; printf '{"passed": true}' > "$6""#, to: probe)
      }
      let provenance = try readJSONObject(directory + "/reports/provenance.json")
      let status = provenance["app_exit_status"] as? [String: Any]
      #expect(provenance["runner"] as? String == "AccessibilitySmoke.swift", "runner named")
      #expect((provenance["fixture_bundle_id"] as? String)?.count == "no.helgesverre.terminal.accessibility-fixture.".count + 12,
              "got: \(provenance["fixture_bundle_id"] ?? "nothing")")
      #expect(provenance["controlled_child_pid"] as? Int != nil, "child PID recorded")
      #expect(provenance["controlled_child_exited"] as? Bool == true, "child ended")
      #expect(provenance["cleanup_survivors"] as? [Int] == [], "no survivors")
      #expect((provenance["owned_pids_before_cleanup"] as? [Int])?.isEmpty == false, "owned processes recorded")
      #expect(status?["signaled"] as? Bool == true && status?["signal"] as? Int == 15, "got: \(status ?? [:])")
      #expect(provenance["runner_error"] == nil, "no runner error")
    }
  }

  @Test("accessibility smoke: a probe that saw the pane and failed is not retried") func aProbeThatSawThePaneAndFailed() throws {
    try withFakeApp { bundle, directory in
      let failure = try #require(throws: Failure.self) {
        try AccessibilitySmoke.run(bundle: bundle, reportDirectory: directory + "/reports") { probe in
          try writeScript(#"echo run >> "$6.runs"; printf '{"passed": false, "pane": {}, "error": "no link"}' > "$6""#,
                          to: probe)
        }
      }
      #expect(failure.message == "accessibility probe failed: no link", "got: \(failure.message)")
      let runs = try String(contentsOfFile: directory + "/reports/external-ax.json.runs", encoding: .utf8)
      #expect(runs == "run\n", "the probe ran once")
    }
  }

  @Test("accessibility smoke: provenance is written when the child cannot be inspected") func provenanceIsWrittenWhenTheChildCannotBeInspected() throws {
    // The fixture records PID 1, which this user may not ask about.
    let script = #"for last; do :; done; exec /bin/sh -c "$(printf '%s' "$last" | sed 's/"\$\$"/1/')""#
    try withFakeApp(script: script) { bundle, directory in
      let failure = try #require(throws: Failure.self) {
        try AccessibilitySmoke.run(bundle: bundle, reportDirectory: directory + "/reports") { probe in
          try writeScript(#"sleep 0.4; printf '{"passed": true}' > "$6""#, to: probe)
        }
      }
      #expect(failure.message.hasPrefix("cannot inspect process 1:"), "got: \(failure.message)")
      let provenance = try readJSONObject(directory + "/reports/provenance.json")
      #expect(provenance["controlled_child_pid"] as? Int == 1, "the child PID is recorded")
      #expect(provenance["cleanup_error"] as? String == failure.message, "the cleanup failure is recorded")
      #expect(provenance["cleanup_survivors"] as? [Int] == [], "the fixture's tree is ended")
    }
  }

  @Test("accessibility smoke: the child PID file is one shell word") func theChildPIDFileIsOneShellWord() throws {
    #expect(AccessibilitySmoke.shellEscaped("/var/T/a-b_c.pid") == "/var/T/a-b_c.pid", "safe characters are kept")
    #expect(AccessibilitySmoke.shellEscaped("/tmp/it's here") == #"/tmp/it\'s\ here"#, "others are escaped")
    #expect(AccessibilitySmoke.shellEscaped("") == "''", "an empty word is quoted")
  }
}

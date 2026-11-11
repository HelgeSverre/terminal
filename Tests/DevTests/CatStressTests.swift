import Foundation
import Testing
@testable import dev

@Suite struct CatStressTests {
  /// A fixture app that writes a passing report for a source of `bytes`,
  /// where `$3` is the size it was launched with.
  private func reportingScript(bytes: String) -> String {
    """
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --cat-smoke ]; then
        printf '{"passed": true, "final": true, "source_file_bytes": %s, "renderer": {"command_errors": 0}, "session": {"child_reaped": true, "read_ended": true, "parser_ended": true}}' "\(bytes)" > "$2"
      fi
      shift
    done
    """
  }

  @Test("cat stress: a passing app report from a clean exit passes and is recorded") func aPassingAppReportPasses() throws {
    try withFakeBundle(reportingScript(bytes: "$3")) { app, root in
      try "source text\n".write(toFile: root + "/source.txt", atomically: true, encoding: .utf8)
      try CatStress.stress(app: app, source: root + "/source.txt", output: root + "/cat", motion: false)
      let provenance = try readJSONObject(root + "/cat/provenance.json")
      #expect(provenance["passed"] as? Bool == true, "run passed")
      #expect(ReportValue.equals(provenance["source_bytes"], 12), "source size is recorded")
      #expect(provenance["source_name"] as? String == "source.txt", "source name is recorded")
      #expect((provenance["cleanup_survivors"] as? [Any])?.isEmpty == true, "nothing survives")
    }
  }

  @Test("cat stress: a report for another extent fails the run and is recorded") func aReportForAnotherExtentFails() throws {
    try withFakeBundle(reportingScript(bytes: "1")) { app, root in
      try "source text\n".write(toFile: root + "/source.txt", atomically: true, encoding: .utf8)
      let message = try #require(throws: Failure.self) {
        try CatStress.stress(app: app, source: root + "/source.txt", output: root + "/cat", motion: false)
      }.message
      #expect(message == "Wrong source extent", "got: \(message)")
      let provenance = try readJSONObject(root + "/cat/provenance.json")
      #expect(provenance["passed"] as? Bool == false, "run did not pass")
      #expect(provenance["failure"] as? String == "Wrong source extent", "failure is recorded")
    }
  }
}

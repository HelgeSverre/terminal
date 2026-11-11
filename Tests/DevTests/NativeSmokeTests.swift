import Foundation
import Testing
@testable import dev

@Suite struct NativeSmokeTests {
  /// Runs `body` with an executable shell script standing in for the app.
  private func withFakeApp(_ script: String, _ body: (String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-native-smoke-") { directory in
      let executable = directory + "/app"
      try writeScript(script, to: executable)
      try body(executable, directory)
    }
  }

  @Test("native smoke: a passing report from a clean exit passes") func aPassingReportFromACleanExit() throws {
    try withFakeApp("printf '{\"passed\": true}' > \"$2\"") { executable, directory in
      try NativeSmoke.run(NativeSmoke.modes[0], executable: executable, reportDirectory: directory)
    }
  }

  @Test("native smoke: a failing report names the failed checks") func aFailingReportNamesTheFailedChecks() throws {
    try withFakeApp("printf '{\"passed\": false, \"checks\": {\"a\": true, \"b\": false}}' > \"$2\"") { executable, directory in
      let failure = try #require(throws: Failure.self) {
        try NativeSmoke.run(NativeSmoke.modes[0], executable: executable, reportDirectory: directory)
      }
      #expect(failure.message.contains("1 of 2 checks failed: b"), "got: \(failure.message)")
    }
  }

  @Test("native smoke: a lingering child fails the run and is ended") func aLingeringChildFailsTheRun() throws {
    // The app must live long enough for its child to be seen under it.
    try withFakeApp("sleep 30 & printf '{\"passed\": true}' > \"$2\"; sleep 0.4") { executable, directory in
      let failure = try #require(throws: Failure.self) {
        try NativeSmoke.run(NativeSmoke.modes[0], executable: executable, reportDirectory: directory)
      }
      #expect(failure.message.contains("leaving children"), "got: \(failure.message)")
    }
  }
}

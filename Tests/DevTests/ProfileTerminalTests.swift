import Foundation
import Testing
@testable import dev

@Suite struct ProfileTerminalTests {
  @Test("profile terminal: an early driver failure precedes a non-zero exit and cleanup is recorded") func anEarlyDriverFailurePrecedesA() throws {
    try withFakeBundle(failingDriverScript("fixture profile driver failed")) { app, root in
      var profile = try ProfileTerminal.Profile(app: app, output: root + "/profile", workload: "all")
      let message = try #require(throws: Failure.self) { try profile.run() }.message
      #expect(message == "fixture profile driver failed", "got: \(message)")
      let report = try readJSONObject(root + "/profile/profile.json")
      #expect(report["passed"] as? Bool == false, "profile did not pass")
      #expect((report["failure"] as? String)?.contains("fixture profile driver failed") == true, "failure is recorded")
      let survivors = try report.object("lifecycle").object("app").fetch("cleanup_survivors") as? [Any]
      #expect(survivors?.isEmpty == true, "nothing survives")
    }
  }

  @Test("profile terminal: a cleanup survivor fails a completed profile, and the app is still cleaned up") func aCleanupSurvivorFailsACompleted() throws {
    try withTemporaryDirectory("dev-profile-cleanup-") { root in
      var sampleCleanups = 0
      var appCleanups = 0
      var profile = ProfileTerminal.Profile(output: root + "/profile")
      try FileManager.default.createDirectory(atPath: profile.output, withIntermediateDirectories: false)
      profile.sampleProcess = ProfileTerminal.Owned(pid: 101, exit: { nil }, livePIDs: { [4242] }) {
        sampleCleanups += 1
        return [4242]
      }
      profile.appProcess = ProfileTerminal.Owned(pid: 101, exit: { nil }, livePIDs: { [] }) {
        appCleanups += 1
        return []
      }
      profile.lifecycle = ["sample": ["pid": 101, "natural_exit": false], "app": ["pid": 101, "natural_exit": false]]
      profile.result["passed"] = true
      let message = try #require(throws: Failure.self) { try profile.finish(after: nil) }.message
      #expect(message.contains("sample survivors: 4242"), "got: \(message)")
      #expect(sampleCleanups == 1 && appCleanups == 1, "each process is cleaned up once")
      let report = try readJSONObject(root + "/profile/profile.json")
      #expect(report["passed"] as? Bool == false, "profile did not pass")
      #expect((report["failure"] as? String)?.contains("sample survivors: 4242") == true, "failure is recorded")
      let sample = try report.object("lifecycle").object("sample")
      #expect((sample["cleanup_survivors"] as? [Int]) == [4242], "survivors are recorded")
      #expect(sample["forced_cleanup"] as? Bool == true, "cleanup is recorded as forced")
    }
  }

}

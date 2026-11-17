import Foundation
import Testing
@testable import dev

@Suite struct CITimingTests {
  func fixture(aggregate: String = "success", finished: String = "2026-11-17T00:06:03Z") throws -> Data {
    let names = ["macOS · Headless tests", "Terminal protocol conformance", "Emulator address-sanitizer fuzzing", "macOS · Swift native tests"]
    let jobs = names.enumerated().map { index, name -> [String: Any] in
      ["name": name, "run_id": 44, "head_sha": "fixture-commit", "conclusion": index == 3 ? aggregate : "success",
       "started_at": index == 3 ? "2026-11-17T00:05:40Z" : "2026-11-17T00:00:00Z",
       "completed_at": index == 3 ? finished : "2026-11-17T00:05:40Z",
       "steps": index == 0 ? [["name": "Run Swift native tests", "started_at": "2026-11-17T00:00:30Z",
                                "completed_at": "2026-11-17T00:05:15Z"]] : []]
    }
    return try JSONSerialization.data(withJSONObject: ["jobs": jobs])
  }

  @Test func setupAndAggregationRemainInsideTheFeedbackBoundary() throws {
    let result = try CITiming.summarize(fixture())
    #expect(result.run == 44 && result.commit == "fixture-commit")
    #expect(result.nativeTestSeconds == 285)
    #expect(result.headlessJobSeconds == 340)
    #expect(result.completeFeedbackSeconds == 363)
    #expect(result.passed && !result.underFiveMinutes)
  }

  @Test func aFastFailedGateCannotMeetTheTarget() throws {
    func faster(_ data: Data) -> Data {
      Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "00:05:40", with: "00:04:40")
        .replacingOccurrences(of: "00:06:03", with: "00:04:59")
        .replacingOccurrences(of: "00:05:15", with: "00:04:15").utf8)
    }
    let result = try CITiming.summarize(faster(fixture(aggregate: "failure")))
    #expect(!result.passed && !result.underFiveMinutes)
    #expect(try CITiming.summarize(faster(fixture())).underFiveMinutes)
    #expect(throws: Failure.self) { try CITiming.summarize(Data(#"{"jobs":[]}"#.utf8)) }
    #expect(throws: Failure.self) { try CITiming.summarize(fixture(finished: "2026-11-17T00:04:59Z")) }
  }
}

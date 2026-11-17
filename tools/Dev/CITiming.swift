import Foundation

/// Report both latency boundaries from GitHub's jobs API, including setup,
/// cache transfer and the required aggregate check in complete feedback.
enum CITiming {
  static let command = Command(name: "ci-timing", usage: "JOBS_JSON OUTPUT_JSON",
    summary: "Summarize a completed CI run's test-step and complete-feedback latency.", run: run)

  struct Jobs: Decodable {
    struct Job: Decodable {
      struct Step: Decodable {
        let name: String
        let started_at: String?
        let completed_at: String?
      }
      let name: String
      let run_id: Int
      let head_sha: String
      let conclusion: String?
      let started_at: String?
      let completed_at: String?
      let steps: [Step]
    }
    let jobs: [Job]
  }

  struct Receipt: Codable {
    let run: Int
    let commit: String
    let passed: Bool
    let nativeTestSeconds: Double
    let headlessJobSeconds: Double
    let completeFeedbackSeconds: Double
    let underFiveMinutes: Bool
  }

  static func summarize(_ data: Data) throws -> Receipt {
    let jobs = try JSONDecoder().decode(Jobs.self, from: data).jobs
    let required = Set(["macOS · Headless tests", "Terminal protocol conformance",
                        "Emulator address-sanitizer fuzzing", "macOS · Swift native tests"])
    guard required.isSubset(of: Set(jobs.map(\.name))),
          let headless = jobs.first(where: { $0.name == "macOS · Headless tests" }),
          let aggregate = jobs.first(where: { $0.name == "macOS · Swift native tests" }),
          let native = headless.steps.first(where: { $0.name == "Run Swift native tests" }),
          Set(jobs.map(\.run_id)).count == 1, Set(jobs.map(\.head_sha)).count == 1 else {
      throw Failure("expected one complete CI jobs response with headless and aggregate checks")
    }
    // Job times have whole seconds; step times carry milliseconds.
    let formatter = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions.insert(.withFractionalSeconds)
    func date(_ value: String?) throws -> Date {
      guard let value, let result = formatter.date(from: value) ?? fractional.date(from: value) else { throw Failure("CI timing requires completed job and step timestamps") }
      return result
    }
    func duration(_ start: String?, _ end: String?) throws -> Double {
      let seconds = try date(end).timeIntervalSince(date(start))
      guard seconds >= 0 else { throw Failure("CI timing timestamps are reversed") }
      return seconds
    }
    let starts = try jobs.map { try date($0.started_at) }
    let ends = try jobs.map { try date($0.completed_at) }
    guard let first = starts.min() else { throw Failure("CI timing has no jobs") }
    let completed = try date(aggregate.completed_at)
    guard ends.allSatisfy({ $0 <= completed }) else { throw Failure("aggregate check finished before another gate") }
    let feedback = completed.timeIntervalSince(first)
    guard feedback >= 0 else { throw Failure("CI feedback timestamps are reversed") }
    let nativeSeconds = try duration(native.started_at, native.completed_at)
    let passed = jobs.allSatisfy { $0.conclusion == "success" }
    return Receipt(run: headless.run_id, commit: headless.head_sha, passed: passed,
                   nativeTestSeconds: nativeSeconds,
                   headlessJobSeconds: try duration(headless.started_at, headless.completed_at),
                   completeFeedbackSeconds: feedback,
                   underFiveMinutes: passed && nativeSeconds < 300 && feedback < 300)
  }

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 2 else { throw Failure.usage(command) }
    let receipt = try summarize(Data(contentsOf: URL(fileURLWithPath: arguments[0])))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
    print(String(format: "Native tests %.2fs; headless job %.2fs; complete feedback %.2fs; passed=%@; under5m=%@",
      receipt.nativeTestSeconds, receipt.headlessJobSeconds, receipt.completeFeedbackSeconds,
      String(receipt.passed), String(receipt.underFiveMinutes)))
    guard receipt.passed else { throw Failure("CI run did not pass every gate; timing receipt is retained") }
  }
}

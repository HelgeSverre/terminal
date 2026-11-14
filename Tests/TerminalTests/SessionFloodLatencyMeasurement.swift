import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

/// Not a check: prints how long typed input takes to reach a program, idle
/// and while that program floods the terminal with output. The time runs
/// from handing the key to the session to the program's read, so it covers
/// the output queued ahead of the key, the key's encoding and the PTY write.
///
/// Run with `TERMINAL_MEASURE=1 just unit-test --filter SessionFloodLatencyMeasurement`.
@Suite(.serialized) @MainActor struct SessionFloodLatencyMeasurement {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMINAL_MEASURE"] != nil), arguments: ["idle", "flood"])
  func keyToProgram(mode: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flood-latency-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // The child the developer tool's latency comparison uses: it stamps every
    // byte it reads with the clock read below.
    let echo = directory.appendingPathComponent("keyecho").path
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["clang", "-O2", TestEnvironment.repository.appendingPathComponent("tools/Dev/KeyEcho.c").path, "-o", echo]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0, "KeyEcho.c did not compile")

    let log = directory.appendingPathComponent("log").path
    let session = Session(launch: LaunchSpec(
      executable: echo, arguments: [echo, log, mode], cwd: "/tmp", launcher: TestEnvironment.launcher))
    defer { session.close() }
    func marks(_ label: String) -> [UInt64] {
      guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
      return text.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ")
        return fields.count == 2 && fields[0] == label ? UInt64(fields[1]) : nil
      }
    }
    try #require(await TestEnvironment.wait { !marks("ready").isEmpty }, "the key program did not start")
    // Let the flood get going.
    _ = await TestEnvironment.wait(seconds: 0.8) { false }

    var milliseconds: [Double] = []
    for _ in 0..<300 {
      let before = marks("key").count
      let sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      try #require(session.input("a"), "input rejected")
      try #require(await TestEnvironment.wait(seconds: 2) { marks("key").count > before }, "a key never arrived")
      milliseconds.append(Double(marks("key")[before] &- sent) / 1e6)
      _ = await TestEnvironment.wait(seconds: 0.004) { false }
    }
    session.input("q")
    milliseconds.sort()
    func percentile(_ p: Double) -> Double { milliseconds[min(milliseconds.count - 1, Int(Double(milliseconds.count) * p))] }
    print(String(
      format: "FLOOD_LATENCY %@ keys %d  median %.3f ms  p95 %.3f ms  p99 %.3f ms  max %.3f ms",
      mode, milliseconds.count, percentile(0.5), percentile(0.95), percentile(0.99), milliseconds.last ?? 0))
  }
}

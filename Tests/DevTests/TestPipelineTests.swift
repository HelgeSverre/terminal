import Foundation
import Testing
@testable import dev

@Suite struct TestPipelineTests {
  @Test func lanesOverlapButEachLaneRemainsSerial() throws {
    final class State: @unchecked Sendable {
      let lock = NSLock(), aStarted = DispatchSemaphore(value: 0), bStarted = DispatchSemaphore(value: 0)
      var order: [String] = []
      var metOtherLane = 0
      func record(_ value: String) { lock.lock(); order.append(value); lock.unlock() }
    }
    let state = State()
    let lanes = [["a1", "a2"], ["b1", "b2"]].map { $0.map { TestPipeline.Phase(name: $0, arguments: []) } }
    try TestPipeline.run(lanes: lanes) { phase in
      state.record(phase.name + "-start")
      if phase.name.hasSuffix("1") {
        // A serial implementation times out, rather than hanging the suite.
        let own = phase.name == "a1" ? state.aStarted : state.bStarted
        let other = phase.name == "a1" ? state.bStarted : state.aStarted
        own.signal()
        let met = other.wait(timeout: .now() + 2) == .success
        state.lock.lock(); state.metOtherLane += met ? 1 : 0; state.lock.unlock()
      }
      state.record(phase.name + "-end")
    }
    #expect(state.metOtherLane == 2)
    for prefix in ["a", "b"] {
      #expect(state.order.firstIndex(of: prefix + "1-end")! < state.order.firstIndex(of: prefix + "2-start")!)
    }
  }

  @Test func aFailedLaneStopsAndTheOtherLaneIsJoined() throws {
    final class State: @unchecked Sendable {
      let lock = NSLock()
      var events: [String] = []
      func record(_ value: String) { lock.lock(); events.append(value); lock.unlock() }
    }
    let state = State()
    let lanes = [["failed", "must-not-run"], ["other", "joined"]]
      .map { $0.map { TestPipeline.Phase(name: $0, arguments: []) } }
    let error = try #require(throws: Failure.self) {
      try TestPipeline.run(lanes: lanes) { phase in
        if phase.name == "failed" { throw Failure("fixture failed") }
        state.record(phase.name)
      }
    }
    #expect(error.message.contains("fixture failed"))
    #expect(state.events == ["other", "joined"])
    #expect(throws: Failure.self) { try TestPipeline.run(lanes: []) { _ in } }
    #expect(throws: Failure.self) { try TestPipeline.run(lanes: [[], [], []]) { _ in } }
  }

  @Test func prebuiltRunnerKeepsFiltersRuntimeOverridesAndFailures() throws {
    try withTemporaryDirectory("prebuilt-tests-") { root in
      let helper = root + "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
      let bundle = root + "/products/TerminalPackageTests.xctest/Contents/MacOS/TerminalPackageTests"
      for file in [helper, bundle] {
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path,
                                                withIntermediateDirectories: true)
      }
      try Data().write(to: URL(fileURLWithPath: bundle))
      try writeScript("printf '%s\\n' \"$@\"; printf '%s\\n' \"$DYLD_FRAMEWORK_PATH\" \"$NO_COLOR\"; exit 7", to: helper)
      let runner = try PrebuiltTests.runner(products: root + "/products", swift: root + "/toolchain/usr/bin/swift",
                                            platform: root + "/platform", environment: ["DYLD_FRAMEWORK_PATH": "/override"])
      let result = try runCommand(runner.arguments(["--filter", "DevTests", "--xunit-output", root + "/developer.xml"]),
                                 adding: runner.environment)
      #expect(result.status == 7)
      let arguments = result.output.split(separator: "\n").map(String.init)
      #expect(arguments.contains(bundle))
      #expect(arguments.contains("--no-parallel") && arguments.contains("swift-testing"))
      #expect(arguments.contains("DevTests") && arguments.contains(root + "/developer.xml"))
      #expect(arguments.contains("/override:" + root + "/platform/Developer/Library/Frameworks"))
      #expect(arguments.last == "1")
      try FileManager.default.removeItem(atPath: bundle)
      #expect(throws: Failure.self) {
        try PrebuiltTests.runner(products: root + "/products", swift: root + "/toolchain/usr/bin/swift",
                                 platform: root + "/platform", environment: [:])
      }
    }
  }
}

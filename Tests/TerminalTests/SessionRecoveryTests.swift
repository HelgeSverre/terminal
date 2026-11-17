import Foundation
import Testing
import TerminalInterop
@testable import TerminalApp
@testable import TerminalHost
@testable import TerminalEngine

@Suite(.serialized) @MainActor struct SessionRecoveryTests {
  private func fixture() -> SessionLayout {
    let id = PaneID(), window = UUID()
    return SessionLayout(appBuild: "test", windows: [WindowLayout(id: window,
      frame: CGRect(x: 50, y: 50, width: 800, height: 600), root: .pane(id), activePane: id,
      panes: [PaneState(id: id, directory: "/", title: "test", color: nil)],
      tabGroup: window, tabIndex: 0, selectedTab: true, zoomed: false, fullScreen: false)], keyWindow: window)
  }
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func writeRunning(_ directory: URL, restoring: Bool = false) throws {
    try JSONEncoder().encode(SessionStateStore.Running(pid: 1, started: Date(), restoring: restoring))
      .write(to: directory.appendingPathComponent("running"))
  }

  @Test func locationDoesNotUseBundleIdentifier() {
    let home = URL(fileURLWithPath: "/Users/test")
    let installed = URL(fileURLWithPath: "/Users/test/Applications/Helge Terminal.app")
    let development = URL(fileURLWithPath: "/Users/test/code/terminal/dist/Terminal.app")
    #expect(StateLocation.directory(arguments: ["app"], bundle: development, home: home) == nil)
    #expect(StateLocation.directory(arguments: ["app", "--background"], bundle: installed, home: home) == nil)
    #expect(StateLocation.directory(arguments: ["app"], bundle: installed, home: home)?.lastPathComponent == "Sessions")
    #expect(StateLocation.directory(arguments: ["app", "--state-directory", "/private/test"], bundle: development, home: home)?.path == "/private/test")
    #expect(StateLocation.directory(arguments: ["app", "--state-directory"], bundle: installed, home: home) == nil)
    #expect(StateLocation.directory(arguments: ["app"], bundle: URL(fileURLWithPath: "/Applications-other/App.app"), home: home) == nil)
  }

  @Test func layoutRoundTripAndValidation() throws {
    var value = fixture()
    let other = PaneID()
    value.windows[0].root = .split(vertical: true, ratio: 0.37,
      first: value.windows[0].root, second: .pane(other))
    value.windows[0].panes.append(PaneState(id: other, directory: "/", title: "second", color: "#123456"))
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(SessionLayout.self, from: encoded) == value)
    #expect(value.isValid)
    value.windows[0].panes.removeLast()
    #expect(!value.isValid)
    #expect(PaneLayout.boundedRatio(.nan) == 0.5)
    #expect(PaneLayout.boundedRatio(-1) == 0)
    #expect(PaneLayout.boundedRatio(2) == 1)
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    #expect(WindowLayout.clampedFrame(CGRect(x: -5000, y: 9000, width: 1200, height: 900), to: [screen]) == screen)
  }

  @Test func lockGenerationsAndCleanQuit() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var store = try #require(SessionStateStore.open(directory: dir)) as SessionStateStore?
    #expect(store?.restored == nil)
    #expect(SessionStateStore.open(directory: dir) == nil)
    var complete = false
    let first = fixture()
    store?.save(first) { complete = true }
    #expect(await TestEnvironment.wait { complete })
    var second = first
    second.windows[0].panes[0].title = "second"
    complete = false
    store?.save(second) { complete = true }
    #expect(await TestEnvironment.wait { complete })
    let previous = try Data(contentsOf: dir.appendingPathComponent("layout.previous.json"))
    #expect(try JSONDecoder().decode(SessionLayout.self, from: previous) == first)
    store = nil // Simulates a dead process releasing only the lock.
    store = try #require(SessionStateStore.open(directory: dir))
    #expect(store?.restored == second)
    store?.cleanExit()
    store = nil
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    store = SessionStateStore.open(directory: dir)
    #expect(store?.restored == nil)
    store?.cleanExit()
  }

  @Test func everyTruncationFallsBackToPrevious() throws {
    let good = fixture(), bytes = try JSONEncoder().encode(good)
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for count in 0..<bytes.count {
      try writeRunning(dir)
      try bytes.write(to: dir.appendingPathComponent("layout.previous.json"))
      try bytes.prefix(count).write(to: dir.appendingPathComponent("layout.json"))
      let store = try #require(SessionStateStore.open(directory: dir))
      #expect(store.restored == good, "truncated at byte \(count)")
      store.cleanExit()
    }
  }

  @Test func missingCurrentStaleTemporaryFutureAndRestoreLoop() throws {
    let dir = try directory(), good = fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bytes = try JSONEncoder().encode(good)
    try writeRunning(dir)
    try bytes.write(to: dir.appendingPathComponent("layout.previous.json"))
    try Data("stale".utf8).write(to: dir.appendingPathComponent("layout.json.tmp"))
    var store = try #require(SessionStateStore.open(directory: dir)) as SessionStateStore?
    #expect(store?.restored == good)
    store = nil // Dies before the restore is marked complete.
    store = try #require(SessionStateStore.open(directory: dir))
    #expect(store?.restored == nil)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("quarantine/layout.previous.json").path))
    store?.cleanExit(); store = nil
    try writeRunning(dir)
    var future = good; future.version = 999
    try JSONEncoder().encode(future).write(to: dir.appendingPathComponent("layout.json"))
    try bytes.write(to: dir.appendingPathComponent("layout.previous.json"))
    store = try #require(SessionStateStore.open(directory: dir))
    #expect(store?.restored == nil)
    let preserved = try Data(contentsOf: dir.appendingPathComponent("quarantine/layout.json"))
    #expect(try JSONDecoder().decode(SessionLayout.self, from: preserved).version == 999)
    store?.cleanExit()
  }

  @Test func quietAndMaximumAgeDoNotPollCleanPanes() {
    var timing = RecoveryCheckpointTiming()
    #expect(timing.delay(at: 0) == nil)
    #expect(timing.output(at: 0))
    #expect(!timing.output(at: 1_000_000_000))
    #expect(timing.delay(at: 2_000_000_000) == 1)
    #expect(timing.delay(at: 3_000_000_000) == 0)
    for second in 2...60 { _ = timing.output(at: UInt64(second) * 1_000_000_000) }
    #expect(timing.delay(at: 60_000_000_000) == 0)
    timing.captured()
    #expect(timing.delay(at: 70_000_000_000, force: true) == nil)
  }

  @Test func checkpointUsesPrimaryAndRestoresLiteralFaintText() throws {
    let source = try #require(helge_terminal_create(8, 3))
    let target = try #require(helge_terminal_create(8, 3))
    defer { helge_terminal_destroy(source); helge_terminal_destroy(target) }
    TerminalSelectionTests.feed(source, "one-two-three\r\nprimary\u{1b}[?1049hALTERNATE")
    let capture = TerminalRecoveryBridge.capture(core: source)
    var text: String?
    for _ in 0..<10_000 { if let result = capture.advance() { text = result; break } }
    #expect(text?.contains("one-two-three") == true, "soft wraps join")
    #expect(text?.contains("ALTERNATE") == false)
    // Even a tampered checkpoint cannot dispatch an OSC or change a mode.
    TerminalRecoveryBridge.seed(core: target, text: "\u{1b}]52;c;AAAA\u{7}\nRestored\n")
    let snapshot = try #require(swiftTerminalSnapshot(target, scroll: nil, now: 0).snapshot)
    #expect(snapshot.rows.flatMap(\.cells).contains { $0.text == "R" && $0.style.faint })
    #expect(helge_terminal_take_bells(target) == 0)
    #expect(helge_terminal_validate(target))
  }
}

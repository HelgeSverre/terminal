import Foundation
import Testing
import TerminalInterop
import Darwin
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
  /// The declared result makes `#require` unwrap; assigned to an optional it checked nothing.
  private func open(_ directory: URL) throws -> SessionStateStore {
    try #require(SessionStateStore.open(directory: directory))
  }
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("terminal-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func writeRunning(_ directory: URL, restoring: Bool = false) throws {
    try JSONEncoder().encode(SessionStateStore.Running(pid: 1, started: Date(), restoring: restoring))
      .write(to: directory.appendingPathComponent("running"))
  }
  private func clean(_ store: SessionStateStore?) async {
    await withCheckedContinuation { continuation in
      guard let store else { continuation.resume(); return }
      store.cleanExit { continuation.resume() }
    }
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
    #expect(StateLocation.directory(arguments: ["app", "--execute", "child", "--state-directory", "/private/child-state"], bundle: installed, home: home) == nil)
    #expect(StateLocation.directory(arguments: ["app", "--state-directory", "/private/app-state", "--execute", "child", "--state-directory", "/private/child-state"], bundle: development, home: home)?.path == "/private/app-state")
    #expect(StateLocation.directory(arguments: ["app"], bundle: URL(fileURLWithPath: "/Applications-other/App.app"), home: home) == nil)
  }

  @Test func savePrunesOnlyFilesOfPanesThatAreGone() async throws {
    let dir = try directory(), layout = fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try open(dir)
    let panes = dir.appendingPathComponent("panes")
    let kept = layout.windows[0].panes[0].id.string, gone = PaneID().string
    let names = ["\(kept).txt", "\(kept).resume", "\(kept).resume.tmp", "\(gone).txt", "\(gone).resume.tmp"]
    for name in names { try Data("x".utf8).write(to: panes.appendingPathComponent(name)) }
    await withCheckedContinuation { continuation in store.save(layout) { continuation.resume() } }
    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: panes.path))
    #expect(remaining == Set(names.prefix(3)))
    await clean(store)
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
    var store = try open(dir) as SessionStateStore?
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
    store = try open(dir)
    #expect(store?.restored == second)
    await clean(store)
    store = nil
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    store = SessionStateStore.open(directory: dir)
    #expect(store?.restored == nil)
    await clean(store)
  }

  @Test func everyTruncationFallsBackToPrevious() async throws {
    let good = fixture(), bytes = try JSONEncoder().encode(good)
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for count in 0..<bytes.count {
      try writeRunning(dir)
      try bytes.write(to: dir.appendingPathComponent("layout.previous.json"))
      try bytes.prefix(count).write(to: dir.appendingPathComponent("layout.json"))
      let store = try open(dir)
      #expect(store.restored == good, "truncated at byte \(count)")
      await clean(store)
    }
  }

  @Test func missingCurrentStaleTemporaryFutureAndRestoreLoop() async throws {
    let dir = try directory(), good = fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bytes = try JSONEncoder().encode(good)
    try writeRunning(dir)
    try bytes.write(to: dir.appendingPathComponent("layout.previous.json"))
    try Data("stale".utf8).write(to: dir.appendingPathComponent("layout.json.tmp"))
    var store = try open(dir) as SessionStateStore?
    #expect(store?.restored == good)
    store = nil // Dies before the restore is marked complete.
    store = try open(dir)
    #expect(store?.restored == nil)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("quarantine/layout.previous.json").path))
    await clean(store); store = nil
    try writeRunning(dir)
    var future = good; future.version = 999
    try JSONEncoder().encode(future).write(to: dir.appendingPathComponent("layout.json"))
    try bytes.write(to: dir.appendingPathComponent("layout.previous.json"))
    store = try open(dir)
    #expect(store?.restored == nil)
    let preserved = try Data(contentsOf: dir.appendingPathComponent("quarantine/layout.json"))
    #expect(try JSONDecoder().decode(SessionLayout.self, from: preserved).version == 999)
    await clean(store)
  }

  @Test func quietAndMaximumAgeDoNotPollCleanPanes() {
    var timing = RecoveryCheckpointTiming()
    #expect(timing.delay(at: 0) == nil)
    let first = timing.output(at: 0)
    let repeated = timing.output(at: 1_000_000_000)
    #expect(first)
    #expect(!repeated)
    #expect(timing.delay(at: 2_000_000_000) == 1)
    #expect(timing.delay(at: 3_000_000_000) == 0)
    for second in 2...60 { _ = timing.output(at: UInt64(second) * 1_000_000_000) }
    #expect(timing.delay(at: 60_000_000_000) == 0)
    timing.captured()
    #expect(timing.delay(at: 70_000_000_000, force: true) == nil)
  }
  @Test func specialFilesDoNotBlockRecoveryReads() async throws {
    let dir = try directory(), good = fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeRunning(dir)
    try JSONEncoder().encode(good).write(to: dir.appendingPathComponent("layout.previous.json"))
    #expect(mkfifo(dir.appendingPathComponent("layout.json").path, 0o600) == 0)
    let store = try open(dir)
    #expect(store.restored == good)
    let pane = good.windows[0].panes[0].id
    #expect(mkfifo(dir.appendingPathComponent("panes/\(pane.string).scrollback").path, 0o600) == 0)
    #expect(store.scrollback(pane).unavailable)
    await clean(store)
  }
  @Test func tornMetadataKeepsAuthoritativeRunStatus() async throws {
    let dir = try directory(), good = fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try JSONEncoder().encode(good).write(to: dir.appendingPathComponent("layout.json"))
    try Data("N{partial-metadata".utf8).write(to: dir.appendingPathComponent("running"))
    var store = try open(dir) as SessionStateStore?
    #expect(store?.restored == good)
    store = nil
    // The store set R before any restored view or shell could be created.
    let marker = try Data(contentsOf: dir.appendingPathComponent("running"))
    #expect(marker.first == 82)
    store = try open(dir)
    #expect(store?.restored == nil)
    await clean(store)
  }
  @Test func checkpointChecksumAndPrivatePermissions() async throws {
    let dir = try directory(), layout = fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try open(dir), pane = layout.windows[0].panes[0].id
    store.saveScrollback("saved output\n", rows: 1, pane: pane)
    var complete = false
    store.save(layout) { complete = true }
    #expect(await TestEnvironment.wait { complete })
    #expect(store.scrollback(pane).text == "saved output\n")
    let file = dir.appendingPathComponent("panes/\(pane.string).scrollback")
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)
    var bytes = try Data(contentsOf: file)
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: file)
    #expect(store.scrollback(pane).unavailable)
    await clean(store)
  }

  @Test func checkpointKeepsTheScreenWhenScrollbackIsDisabled() throws {
    let source = try #require(helge_terminal_create(8, 3))
    defer { helge_terminal_destroy(source) }
    helge_terminal_set_history_limit(source, 0)
    TerminalSelectionTests.feed(source, "old\r\nkept\r\nrows\r\nhere")
    let capture = TerminalRecoveryBridge.capture(core: source)
    var text: String?
    for _ in 0..<10_000 { if let result = capture.advance() { text = result; break } }
    #expect(text?.contains("kept") == true && text?.contains("here") == true)
    #expect(text?.contains("old") == false, "the row that left the screen had no history to go to")
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

  @Test func restorationSeedsAtFirstGridAndConfiguredHistoryBound() async throws {
    let lines = (0..<300).map { String(format: "%04d", $0) + String(repeating: "x", count: 150) }
    let session = TerminalSession(recovering: TestEnvironment.shell("stty raw -echo; printf READY; exec /bin/cat"),
      text: lines.joined(separator: "\n") + "\n", startsAtFirstGrid: true)
    defer { session.close() }
    session.configure(TerminalSessionConfiguration(historyRows: 400))
    session.resize(cols: 160, rows: 3)
    #expect(await TestEnvironment.wait { session.processIdentifier != nil })
    let text: String? = await withCheckedContinuation { continuation in
      session.recoveryHistory(maximumBytes: 1_048_576) { continuation.resume(returning: $0) }
    }
    #expect(text?.contains(lines[0]) == true)
    #expect(text?.contains(lines[299]) == true)
  }

  @Test func busyHistoryReadKeepsDirtyCheckpointRetryAndCloseCompletion() async throws {
    let text = String(repeating: String(repeating: "x", count: 154) + "\n", count: 1000)
    let session = TerminalSession(recovering: TestEnvironment.shell("stty raw -echo; printf READY; exec /bin/cat"),
      text: text, startsAtFirstGrid: true)
    defer { session.close() }
    var dirty = false
    session.onRecoveryActivity = { dirty = true }
    session.configure(TerminalSessionConfiguration(historyRows: 2000))
    session.resize(cols: 160, rows: 3)
    #expect(await TestEnvironment.wait { dirty })
    var readDelivered = false
    var checkpointDelivered = false
    var retry: Double?
    session.recoveryHistory(maximumBytes: 131_072) { _ in readDelivered = true }
    session.recoveryCheckpoint(force: true) { _, _, delay in
      retry = delay; checkpointDelivered = true
    }
    #expect(await TestEnvironment.wait { checkpointDelivered })
    #expect(retry != nil, "a concurrent read must retain the dirty pane's future checkpoint")
    session.close()
    #expect(await TestEnvironment.wait { readDelivered }, "close completes an outstanding capture")
  }
}

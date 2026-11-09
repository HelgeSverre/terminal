import Foundation
import Testing
@testable import TerminalApp

/// SidePulse protocol events, multi-pane policy and the file writer. No hardware.
@Suite struct SidePulseTests {
  /// The real parser, across arbitrary PTY chunk boundaries and with OSC BEL terminators.
  @Test func parserReportsCommandActivity() {
    let core = terminal_create(80, 24)!
    defer { terminal_destroy(core) }
    func feed(_ text: String, bytewise: Bool = false) {
      let bytes = Array(text.utf8)
      bytes.withUnsafeBufferPointer { buffer in
        var used = 0
        while used < buffer.count {
          used += terminal_feed(
            core, buffer.baseAddress! + used, bytewise ? 1 : buffer.count - used, 1)
        }
      }
    }
    feed("\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}", bytewise: true)
    #expect(
      swiftTerminalTakeActivity(core) == nil, "Initial prompt must not flash success or bell")
    feed("\u{1b}]133;C\u{1b}\\", bytewise: true)
    #expect(swiftTerminalTakeActivity(core) == .working)
    #expect(swiftTerminalCommandRunning(core))
    feed("\u{7}")
    #expect(swiftTerminalTakeActivity(core) == .attention && swiftTerminalCommandRunning(core))
    feed("\u{1b}]133;D;2\u{7}\u{1b}]133;A;redraw=1\u{7}\u{1b}]133;B\u{7}")
    #expect(swiftTerminalTakeActivity(core) == .failed)
    #expect(!swiftTerminalCommandRunning(core))
    feed("\u{1b}]133;C\u{7}\u{1b}]133;D;0\u{7}")
    #expect(swiftTerminalTakeActivity(core) == .succeeded)
    feed("\u{1b}]133;C\u{7}\u{1b}]133;D;nonsense\u{7}")
    #expect(swiftTerminalTakeActivity(core) == .idle, "Unknown exit is not success")
    feed("\u{1b}]133;C\u{7}\u{1b}c")
    #expect(swiftTerminalTakeActivity(core) == .idle)
  }

  /// One engine across panes: priorities, alert expiry, heartbeat, reconnection,
  /// write failure and disabling.
  @Test func engineAggregatesPanesAndFollowsTheDevice() {
    var candidates: [URL] = []
    var writes: [(URL, String)] = []
    var fail = false
    var discoveries = 0
    let engine = SidePulseEngine(
      discover: {
        discoveries += 1
        return candidates
      },
      write: { url, program in
        if fail { throw CocoaError(.fileWriteNoPermission) }
        writes.append((url, program))
      })
    let a = UUID()
    let b = UUID()
    engine.tick(now: 0)
    #expect(discoveries == 0 && writes.isEmpty, "Disabled integration performs no device I/O")
    engine.configure(enabled: true, now: 0)
    #expect(engine.status.contains("not connected"))
    let target = URL(fileURLWithPath: "/Volumes/SidePulsePro/LEDS.LED")
    candidates = [target]
    engine.record(.working, session: a, now: 1)
    engine.tick(now: 1)
    #expect(writes.last?.1 == SidePulseEngine.programs[.working])
    let count = writes.count
    engine.tick(now: 2)
    #expect(writes.count == count, "Stable states must not restart animations")
    engine.record(.succeeded, session: b, now: 2)
    engine.tick(now: 3)
    #expect(writes.count == count, "One completion cannot mask another running pane")
    engine.record(.failed, session: b, now: 3)
    engine.tick(now: 3)
    #expect(writes.last?.1 == SidePulseEngine.programs[.failed])
    engine.tick(now: 10)
    #expect(writes.last?.1 == SidePulseEngine.programs[.working])
    engine.record(.attention, session: a, now: 11, running: true)
    engine.tick(now: 11)
    #expect(writes.last?.1 == SidePulseEngine.programs[.attention])
    engine.tick(now: 18)
    #expect(writes.last?.1 == SidePulseEngine.programs[.working])
    engine.remove(session: a)
    engine.tick(now: 19)
    #expect(writes.last?.1 == "off\n")
    engine.test(now: 20)
    #expect(writes.last!.1.contains("800ms pulse"))
    engine.tick(now: 24)
    #expect(writes.last?.1 == "off\n")
    engine.tick(now: 85)
    let heartbeatCount = writes.count
    #expect(heartbeatCount > count)
    candidates.append(URL(fileURLWithPath: "/Volumes/SidePulsePro 1/LEDS.LED"))
    engine.tick(now: 86)
    #expect(writes.count == heartbeatCount && engine.status.contains("Multiple"))
    candidates = []
    engine.tick(now: 87)
    candidates = [target]
    engine.tick(now: 88)
    #expect(
      writes.count == heartbeatCount + 1, "Reconnection must resend even unchanged state")
    fail = true
    engine.record(.working, session: a, now: 89)
    engine.tick(now: 89)
    #expect(engine.status.contains("write failed"))
    fail = false
    engine.tick(now: 90)
    #expect(engine.status.contains("Connected"))
    engine.configure(enabled: false, now: 91)
    #expect(writes.last?.1 == "off\n" && engine.status == "Disabled")
    let disabledCount = discoveries
    engine.tick(now: 100)
    #expect(discoveries == disabledCount)
  }

  @Test func onlyProVolumeNamesMatch() {
    for name in ["SidePulsePro", "SidePulse", "SidePulsePro 1", "SidePulse Pro"] {
      #expect(SidePulseDevice.isProName(name))
    }
    for name in ["SidePulseDot", "PulseDot", "MySidePulseProBackup", "SidePulsePro-backup"] {
      #expect(!SidePulseDevice.isProName(name))
    }
  }

  /// The actual filesystem writer: truncate, no creation, no symlink following,
  /// no temporary files or rename; limits are checked before the target changes.
  @Test func writerOnlyTruncatesAnExistingRegularFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sidepulse-test-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("LEDS.LED")
    try Data(repeating: 120, count: 400).write(to: file)
    for program in SidePulseEngine.programs.values {
      #expect(program.utf8.count <= 512 && program.split(separator: "\n").count <= 20)
      try SidePulseDevice.write(file, program: program)
      let written = try String(contentsOf: file, encoding: .utf8)
      #expect(written == program)
    }
    let before = try Data(contentsOf: file)
    #expect(throws: (any Error).self) { try SidePulseDevice.write(file, program: String(repeating: "x", count: 513)) }
    var unchanged = try Data(contentsOf: file)
    #expect(unchanged == before)
    let missing = folder.appendingPathComponent("missing")
    #expect(throws: (any Error).self) { try SidePulseDevice.write(missing, program: "off") }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    let link = folder.appendingPathComponent("symlink")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: (any Error).self) { try SidePulseDevice.write(link, program: "off") }
    unchanged = try Data(contentsOf: file)
    #expect(unchanged == before)
  }
}

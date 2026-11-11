import AppKit
import Foundation

/// Compares how long a key takes to reach the program in a terminal.
///
/// Every terminal is started with a login zsh whose start-up file hands over
/// to a small program that timestamps each byte it reads. A key event is then
/// posted to the terminal, and the time from posting to the program's read is
/// the latency: event delivery, the terminal's key handling and its write to
/// the PTY. Keyboard hardware and the display are not part of it. It is
/// measured with the program idle, and again while it floods the terminal
/// with output. Needs Accessibility permission for the app hosting the tool.
enum CompareInputLatency {
  static let command = Command(
    name: "compare-input-latency", usage: "APP NEW_OUTPUT_DIRECTORY [KEYS]",
    summary: "Time a posted key to its arrival at a program in the terminal, idle and under an output flood.",
    run: run)

  static let modes = ["idle", "flood"]

  static func run(_ arguments: [String]) throws {
    guard (2...3).contains(arguments.count) else { throw Failure.usage(command) }
    let app = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
    let keys = arguments.count == 3 ? Int(arguments[2]) ?? 0 : 100
    guard keys >= 1 else { throw Failure("KEYS must be at least 1") }
    guard AXIsProcessTrusted() else {
      throw Failure("posting keys needs Accessibility permission for the app this tool runs in")
    }
    let output = try OutputDirectory(creating: arguments[1])
    let echo = output.file("keyecho")
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("KeyEcho.c").path
    guard try runInherited(["/usr/bin/xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror", source, "-o", echo]) else {
      throw Failure("cannot build \(source)")
    }
    let (measured, skipped) = try Terminal.available(app: app, output: output)

    let loadBefore = Host.loadAverage
    var samples: [String: [String: [Double]]] = [:]
    var unreached: [String: String] = skipped
    for mode in modes {
      for terminal in measured {
        do {
          samples[terminal.name, default: [:]][mode] =
            try measure(terminal, mode: mode, keys: keys, echo: echo, output: output)
        } catch let failure as Failure {
          unreached[terminal.name] = failure.message
        }
        usleep(700_000)
      }
    }

    try output.write(json: [
      "app": app, "keys": keys, "system": Host.system,
      "method": "a key event posted to the terminal's process, timed to its read by a raw-mode program on the PTY; idle, and while that program floods output",
      "unit": "milliseconds from posting the key to the program reading it",
      "load_before": loadBefore, "load_after": Host.loadAverage, "skipped": unreached, "samples": samples,
    ], to: "input-latency.json")
    print("Milliseconds from posting a key to the program reading it, \(keys) keys per case: median, then 95th percentile.")
    func cell(_ values: [Double]?) -> [Double] { values ?? [] }
    let reached = measured.map(\.name).filter { samples[$0] != nil }
    Table.print(rows: reached, skipped: unreached, columns: [
      ("idle p50 (ms)", { [percentile(cell(samples[$0]?["idle"]), 0.5)].compactMap { $0 } }),
      ("idle p95 (ms)", { [percentile(cell(samples[$0]?["idle"]), 0.95)].compactMap { $0 } }),
      ("flood p50 (ms)", { [percentile(cell(samples[$0]?["flood"]), 0.5)].compactMap { $0 } }),
      ("flood p95 (ms)", { [percentile(cell(samples[$0]?["flood"]), 0.95)].compactMap { $0 } }),
    ], decimals: 2)
  }

  static func percentile(_ values: [Double], _ share: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((share * Double(sorted.count - 1)).rounded()))]
  }

  /// Runs one terminal in one mode and returns the latency of each key, in milliseconds.
  static func measure(_ terminal: Terminal, mode: String, keys: Int, echo: String, output: OutputDirectory) throws -> [Double] {
    let log = output.file("\(terminal.name)-\(mode).log")
    let shellDirectory = output.file("zdotdir-\(terminal.name)-\(mode)")
    try FileManager.default.createDirectory(atPath: shellDirectory, withIntermediateDirectories: true)
    try "exec '\(echo)' '\(log)' \(mode)\n".write(toFile: shellDirectory + "/.zshrc", atomically: true, encoding: .utf8)
    let process = try OwnedProcess(executable: terminal.executable, arguments: terminal.bare,
                                   environment: ["ZDOTDIR": shellDirectory, "SHELL": "/bin/zsh"])
    defer { process.stop() }

    func marks(_ label: String) -> [UInt64] {
      guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
      return text.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ")
        return fields.count == 2 && fields[0] == label ? UInt64(fields[1]) : nil
      }
    }
    let deadline = Clock.now + 10_000_000_000
    while marks("ready").isEmpty, Clock.now < deadline, process.isRunning { usleep(20_000) }
    guard !marks("ready").isEmpty else {
      throw Failure("the shell in \(terminal.name) did not start the key program (its environment is not passed on)")
    }
    // Let the window settle and, in flood mode, the flood get going.
    usleep(800_000)

    // A posted key is sometimes dropped by a terminal that is not in front.
    // Such a key is posted again and not counted; too many end the run.
    var latencies: [Double] = [], dropped = 0
    while latencies.count < keys {
      let before = marks("key").count
      let posted = Clock.now
      post(character: "a", to: process.pid)
      let limit = posted + 500_000_000
      var arrived: UInt64?
      while arrived == nil, Clock.now < limit {
        usleep(500)
        let seen = marks("key")
        if seen.count > before { arrived = seen[before] }
      }
      if let arrived {
        latencies.append(Clock.milliseconds(from: posted, to: arrived))
      } else {
        dropped += 1
        guard dropped <= keys else {
          throw Failure("\(terminal.name) dropped \(dropped) posted keys and took \(latencies.count)")
        }
      }
      usleep(30_000)
    }
    post(character: "q", to: process.pid)
    usleep(200_000)
    return latencies
  }

  /// Posts a key press and release that types `character` to one process.
  static func post(character: Character, to pid: pid_t) {
    let text = Array(String(character).utf16)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
      event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
      event.postToPid(pid)
    }
  }

  static let tests = [
    SelfTest.Case(name: "input latency: percentiles pick the nearest sample") {
      let values = [5.0, 1.0, 4.0, 2.0, 3.0]
      try expect(percentile(values, 0.5) == 3.0, "median of five")
      try expect(percentile(values, 0.95) == 5.0, "95th percentile of five")
      try expect(percentile([], 0.5) == nil, "no samples, no percentile")
    },
    SelfTest.Case(name: "screen watch: only the marker's magenta counts as the marker") {
      try expect(ScreenWatch.isMarker(0x00ff_00ff), "pure magenta")
      try expect(ScreenWatch.isMarker(0x00f0_30e8), "magenta after colour conversion")
      try expect(!ScreenWatch.isMarker(0x00ff_ffff), "white")
      try expect(!ScreenWatch.isMarker(0x00ff_0000), "red")
      try expect(!ScreenWatch.isMarker(0x0010_1012), "a dark background")
    },
  ]
}

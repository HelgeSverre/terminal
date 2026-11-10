import Foundation

/// Compares warm startup time across terminals.
///
/// Every sample launches a fresh instance from the terminal's executable and
/// stops it afterwards. Terminals that run a given command are timed to four
/// points; the others are started with their default shell and only their
/// window is timed.
enum CompareStartup {
  static let command = Command(
    name: "compare-startup", usage: "APP NEW_OUTPUT_DIRECTORY [ROUNDS]",
    summary: "Time launch to window, first frame and running command for APP and the reference terminals.",
    run: run)

  struct Terminal {
    let name: String
    let executable: String
    /// Launch arguments that run the stamp child writing to the given path,
    /// or nil when the terminal is started bare.
    var arguments: ((_ stamp: String, _ output: String) -> [String])? = nil
    /// A second instance would join or disturb one the user has open, so the
    /// terminal is skipped while it is running.
    var sharesInstance = false
  }

  /// One launch. Times are milliseconds after the launch; nil is not observed.
  struct Sample {
    var window: Double?
    var frame: Double?
    var command: Double?
    var reply: Double?
    var json: [String: Any] {
      var object: [String: Any] = [:]
      object["window_ms"] = window
      object["frame_ms"] = frame
      object["command_ms"] = command
      object["reply_ms"] = reply
      return object
    }
  }

  static func terminals(app: String, ghosttyConfiguration: String) -> [Terminal] {
    [
      Terminal(name: "terminal", executable: app + "/Contents/MacOS/Terminal") { stamp, output in
        ["--first-frame-file", output + ".frame", "--exit-after-command", "--execute", stamp, output]
      },
      Terminal(name: "ghostty", executable: "/Applications/Ghostty.app/Contents/MacOS/ghostty") { stamp, output in
        ["--config-default-files=false", "--config-file=" + ghosttyConfiguration, "-e", stamp, output]
      },
      Terminal(name: "kitty", executable: "/Applications/kitty.app/Contents/MacOS/kitty") { stamp, output in
        ["--config", "NONE", "--session", "none", "-o", "confirm_os_window_close=0",
         "-o", "macos_quit_when_last_window_closed=yes", stamp, output]
      },
      Terminal(name: "iterm2", executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2", sharesInstance: true),
      Terminal(name: "apple_terminal",
               executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
               sharesInstance: true),
    ]
  }

  static func run(_ arguments: [String]) throws {
    guard (2...3).contains(arguments.count) else { throw Failure.usage(command) }
    let app = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
    let rounds = arguments.count == 3 ? Int(arguments[2]) ?? 0 : 10
    guard rounds >= 2 else { throw Failure("ROUNDS must be at least 2: the first launch is not counted") }
    let output = try OutputDirectory(creating: arguments[1])

    let stamp = output.file("stamp")
    let stampSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Stamp.c").path
    guard try runHelper("/usr/bin/xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror", stampSource, "-o", stamp) else {
      throw Failure("cannot build \(stampSource)")
    }
    // A disposable configuration: no restored windows, no confirmation, and
    // the instance ends with its window.
    let ghosttyConfiguration = output.file("ghostty.conf")
    try """
      window-save-state = never
      quit-after-last-window-closed = true
      confirm-close-surface = false
      shell-integration = none

      """.write(toFile: ghosttyConfiguration, atomically: true, encoding: .utf8)

    var skipped: [String: String] = [:]
    let measured = terminals(app: app, ghosttyConfiguration: ghosttyConfiguration).filter { terminal in
      if !FileManager.default.isExecutableFile(atPath: terminal.executable) {
        skipped[terminal.name] = "not installed"
      } else if terminal.sharesInstance, isRunning(executable: terminal.executable) {
        skipped[terminal.name] = "already running; left alone"
      }
      return skipped[terminal.name] == nil
    }

    let loadBefore = Host.loadAverage
    var samples: [String: [Sample]] = [:]
    for round in 0..<rounds {
      // Rotating the order keeps one terminal from always following the same neighbor.
      for offset in measured.indices {
        let terminal = measured[(round + offset) % measured.count]
        samples[terminal.name, default: []].append(
          try sample(terminal, stamp: stamp, output: output.file("\(terminal.name)-\(round).stamp")))
        usleep(500_000)
      }
    }

    try output.write(json: [
      "app": app, "rounds": rounds, "system": Host.system,
      "method": "fresh instance per sample, launched from its executable; warm; the first launch of each terminal is excluded from medians",
      "unit": "milliseconds after launch",
      "load_before": loadBefore, "load_after": Host.loadAverage, "skipped": skipped,
      "samples": samples.mapValues { $0.map(\.json) },
    ], to: "startup.json")
    printTable(measured.map(\.name), samples: samples, skipped: skipped, rounds: rounds)
  }

  /// Launches `terminal` once, waits for its window and its stamp, and stops it.
  static func sample(_ terminal: Terminal, stamp: String, output: String) throws -> Sample {
    let process = try OwnedProcess(executable: terminal.executable,
                                   arguments: terminal.arguments?(stamp, output) ?? [])
    defer { process.stop() }
    var sample = Sample()
    let deadline = process.launchedAt + 10_000_000_000
    while Clock.now < deadline, process.isRunning {
      // The window appeared between the previous look and this one.
      let now = Clock.now
      if ScreenWindow.all().contains(where: { $0.pid == process.pid && $0.width >= 100 && $0.height >= 100 }) {
        sample.window = Clock.milliseconds(from: process.launchedAt, to: now)
        break
      }
      usleep(500)
    }
    guard terminal.arguments != nil else { return sample }

    // The stamp child writes "done" last; the app adds its first frame beside it.
    var marks: [String: UInt64] = [:]
    let stampDeadline = Clock.now + 3_000_000_000
    while marks["done"] == nil, Clock.now < stampDeadline {
      usleep(20_000)
      marks = Self.marks(in: output)
    }
    marks.merge(Self.marks(in: output + ".frame")) { first, _ in first }
    func elapsed(_ label: String) -> Double? {
      marks[label].map { Clock.milliseconds(from: process.launchedAt, to: $0) }
    }
    sample.command = elapsed("exec")
    sample.reply = elapsed("reply")
    sample.frame = elapsed("frame")
    return sample
  }

  /// Reads "label nanoseconds" lines.
  static func marks(in path: String) -> [String: UInt64] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var marks: [String: UInt64] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: " ")
      if fields.count == 2, let value = UInt64(fields[1]) { marks[String(fields[0])] = value }
    }
    return marks
  }

  static func printTable(_ names: [String], samples: [String: [Sample]], skipped: [String: String], rounds: Int) {
    let columns: [(title: String, value: (Sample) -> Double?)] = [
      ("window (ms)", { $0.window }), ("first frame (ms)", { $0.frame }),
      ("command (ms)", { $0.command }), ("reply (ms)", { $0.reply }),
    ]
    print("Median milliseconds after launch, with the range, over \(rounds - 1) warm launches. - is not measured.")
    print("terminal".padding(toLength: 16, withPad: " ", startingAt: 0)
            + columns.map { $0.title.padding(toLength: 20, withPad: " ", startingAt: 0) }.joined())
    for name in names {
      let warm = Array((samples[name] ?? []).dropFirst())
      let cells = columns.map { column -> String in
        let values = warm.compactMap(column.value)
        guard let median = values.median, let low = values.min(), let high = values.max() else { return "-" }
        return String(format: "%.0f (%.0f-%.0f)", median, low, high)
      }
      print(name.padding(toLength: 16, withPad: " ", startingAt: 0)
              + cells.map { $0.padding(toLength: 20, withPad: " ", startingAt: 0) }.joined())
    }
    for (name, reason) in skipped.sorted(by: { $0.key < $1.key }) { print("\(name): skipped (\(reason))") }
  }
}

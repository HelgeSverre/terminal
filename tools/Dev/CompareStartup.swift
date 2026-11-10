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
    let (measured, skipped) = try Terminal.available(app: app, output: output)

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
                                   arguments: terminal.command?(stamp, output) ?? terminal.bare)
    defer { process.stop() }
    var sample = Sample()
    if let shown = process.waitForWindow(until: process.launchedAt + 10_000_000_000) {
      sample.window = Clock.milliseconds(from: process.launchedAt, to: shown)
    }
    guard terminal.command != nil else { return sample }

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
    print("Median milliseconds after launch, with the range, over \(rounds - 1) warm launches. - is not measured.")
    Table.print(rows: names, skipped: skipped, columns: [
      ("window (ms)", { name in samples[name, default: []].dropFirst().compactMap(\.window) }),
      ("first frame (ms)", { name in samples[name, default: []].dropFirst().compactMap(\.frame) }),
      ("command (ms)", { name in samples[name, default: []].dropFirst().compactMap(\.command) }),
      ("reply (ms)", { name in samples[name, default: []].dropFirst().compactMap(\.reply) }),
    ])
  }
}

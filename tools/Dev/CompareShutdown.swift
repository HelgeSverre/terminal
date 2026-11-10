import AppKit
import Foundation

/// Compares how long terminals take to quit.
///
/// Every sample launches a fresh instance with its default shell, lets it
/// settle, and asks it to quit the way the Dock's Quit and Command-Q do. It
/// times two points: the last window leaving the screen, and the process
/// ending, which is when its Dock icon goes.
enum CompareShutdown {
  static let command = Command(
    name: "compare-shutdown", usage: "APP NEW_OUTPUT_DIRECTORY [ROUNDS]",
    summary: "Time a quit request to window gone and process gone for APP and the reference terminals.",
    run: run)

  /// One quit. Times are milliseconds after the request; nil is not reached
  /// before the limit, as when the terminal asks for confirmation.
  struct Sample {
    var windowGone: Double?
    var processGone: Double?
    var json: [String: Any] {
      var object: [String: Any] = [:]
      object["window_gone_ms"] = windowGone
      object["process_gone_ms"] = processGone
      return object
    }
  }

  /// How long an instance idles at its prompt before it is asked to quit.
  static let settleSeconds = 1.5
  /// A terminal that has not quit by now is recorded as not quitting.
  static let limitNanoseconds: UInt64 = 8_000_000_000

  static func run(_ arguments: [String]) throws {
    guard (2...3).contains(arguments.count) else { throw Failure.usage(command) }
    let app = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
    let rounds = arguments.count == 3 ? Int(arguments[2]) ?? 0 : 5
    guard rounds >= 1 else { throw Failure("ROUNDS must be at least 1") }
    let output = try OutputDirectory(creating: arguments[1])
    let (measured, skipped) = try Terminal.available(app: app, output: output)

    let loadBefore = Host.loadAverage
    var samples: [String: [Sample]] = [:]
    for round in 0..<rounds {
      for offset in measured.indices {
        let terminal = measured[(round + offset) % measured.count]
        samples[terminal.name, default: []].append(try sample(terminal))
        usleep(500_000)
      }
    }

    try output.write(json: [
      "app": app, "rounds": rounds, "system": Host.system,
      "method": "fresh instance with its default shell, idle \(settleSeconds) s, then a quit request (NSRunningApplication.terminate)",
      "unit": "milliseconds after the quit request",
      "load_before": loadBefore, "load_after": Host.loadAverage, "skipped": skipped,
      "samples": samples.mapValues { $0.map(\.json) },
    ], to: "shutdown.json")
    print("Median milliseconds after the quit request, with the range, over \(rounds) quits. - is did not quit within \(limitNanoseconds / 1_000_000_000) s.")
    Table.print(rows: measured.map(\.name), skipped: skipped, columns: [
      ("window gone (ms)", { name in samples[name, default: []].compactMap(\.windowGone) }),
      ("process gone (ms)", { name in samples[name, default: []].compactMap(\.processGone) }),
    ])
  }

  /// Launches `terminal`, asks it to quit once it has settled, and watches it go.
  static func sample(_ terminal: Terminal) throws -> Sample {
    let process = try OwnedProcess(executable: terminal.executable, arguments: terminal.bare)
    defer { process.stop() }
    guard process.waitForWindow(until: process.launchedAt + 10_000_000_000) != nil else {
      throw Failure("\(terminal.name) showed no window")
    }
    usleep(useconds_t(settleSeconds * 1_000_000))
    guard let application = NSRunningApplication(processIdentifier: process.pid) else {
      throw Failure("\(terminal.name) is not a running application")
    }

    var sample = Sample()
    let requested = Clock.now
    application.terminate()
    while Clock.now < requested + limitNanoseconds {
      let now = Clock.now
      if sample.windowGone == nil, !process.hasWindow {
        sample.windowGone = Clock.milliseconds(from: requested, to: now)
      }
      if !process.isRunning {
        sample.processGone = Clock.milliseconds(from: requested, to: Clock.now)
        // A process that is gone has no window, whichever was noticed first.
        sample.windowGone = sample.windowGone ?? sample.processGone
        break
      }
      usleep(1_000)
    }
    return sample
  }
}

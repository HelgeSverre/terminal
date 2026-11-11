import Foundation
import ScreenCaptureKit

/// Compares what a person sees when a terminal starts.
///
/// Every sample launches a fresh instance with a login shell and watches the
/// screen: when the window becomes visible, and when the shell's first output
/// is painted in it. The shell is zsh with a start-up file that only prints a
/// block of marker colour, so the second time is the terminal's own doing:
/// creating the window, starting the shell, reading its output and drawing it.
/// The user's shell configuration is not read.
enum CompareVisibleStartup {
  static let command = Command(
    name: "compare-visible-startup", usage: "APP NEW_OUTPUT_DIRECTORY [ROUNDS]",
    summary: "Time launch to a visible window and to the shell's first output on screen.",
    run: run)

  /// One launch. Times are milliseconds after the launch; nil is not seen.
  struct Sample {
    var listed: Double?
    var visible: Double?
    var output: Double?
    var json: [String: Any] {
      var object: [String: Any] = [:]
      object["window_listed_ms"] = listed
      object["window_visible_ms"] = visible
      object["shell_output_visible_ms"] = output
      return object
    }
  }

  /// How long a sample waits for the shell's output after the launch.
  static let limitNanoseconds: UInt64 = 5_000_000_000

  static func run(_ arguments: [String]) throws {
    guard (2...3).contains(arguments.count) else { throw Failure.usage(command) }
    let app = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
    let rounds = arguments.count == 3 ? Int(arguments[2]) ?? 0 : 10
    guard rounds >= 2 else { throw Failure("ROUNDS must be at least 2: the first launch is not counted") }
    let output = try OutputDirectory(creating: arguments[1])
    let (measured, skipped) = try Terminal.available(app: app, output: output)
    // A zsh configuration directory whose only start-up file paints the marker.
    let shellDirectory = output.file("zdotdir")
    try FileManager.default.createDirectory(atPath: shellDirectory, withIntermediateDirectories: true)
    let escaped = ScreenWatch.markerText.replacingOccurrences(of: "\u{1b}", with: "\\e")
      .replacingOccurrences(of: "\r\n", with: "\\n")
    try "printf '\(escaped)'\n".write(toFile: shellDirectory + "/.zshrc", atomically: true, encoding: .utf8)
    let displays = try ScreenWatch.displays()
    guard !displays.isEmpty else { throw Failure("no display to watch") }

    let loadBefore = Host.loadAverage
    var samples: [String: [Sample]] = [:]
    for round in 0..<rounds {
      for offset in measured.indices {
        let terminal = measured[(round + offset) % measured.count]
        samples[terminal.name, default: []].append(
          try sample(terminal, displays: displays, environment: ["ZDOTDIR": shellDirectory, "SHELL": "/bin/zsh"]))
        usleep(900_000)
      }
    }

    try output.write(json: [
      "app": app, "rounds": rounds, "system": Host.system,
      "method": "fresh instance with a login zsh whose only start-up file prints a block of marker colour, launched from its executable; the screen is captured at the display's refresh rate; the first launch of each terminal is excluded from medians",
      "unit": "milliseconds after launch",
      "display_refresh_note": "a frame's time is when it was shown, so each figure is rounded up to the next refresh",
      "load_before": loadBefore, "load_after": Host.loadAverage, "skipped": skipped,
      "samples": samples.mapValues { $0.map(\.json) },
    ], to: "visible-startup.json")
    print("Median milliseconds after launch, with the range, over \(rounds - 1) warm launches. - is not seen within \(limitNanoseconds / 1_000_000_000) s.")
    print("A frame's time is when it was shown, so each screen figure is rounded up to the next refresh.")
    Table.print(rows: measured.map(\.name), skipped: skipped, columns: [
      ("window listed (ms)", { name in samples[name, default: []].dropFirst().compactMap(\.listed) }),
      ("window visible (ms)", { name in samples[name, default: []].dropFirst().compactMap(\.visible) }),
      ("shell output visible (ms)", { name in samples[name, default: []].dropFirst().compactMap(\.output) }),
    ])
  }

  /// Launches `terminal` once. Every display is watched, because a new
  /// window opens on whichever one is active at that moment.
  static func sample(_ terminal: Terminal, displays: [SCDisplay], environment: [String: String]) throws -> Sample {
    let watches = displays.map(ScreenWatch.init(display:))
    for watch in watches { try watch.start() }
    defer { watches.forEach { $0.stop() } }
    let process = try OwnedProcess(executable: terminal.executable, arguments: terminal.bare, environment: environment)
    defer { process.stop() }
    var sample = Sample()
    let deadline = process.launchedAt + limitNanoseconds
    guard let listed = process.waitForWindow(until: deadline), var window = process.window else { return sample }
    sample.listed = Clock.milliseconds(from: process.launchedAt, to: listed)
    // Apple Terminal lists its window where it last was and then moves it to
    // the active display. Wait until the frame holds still; the watches keep
    // the frames shown meanwhile.
    for _ in 0..<12 {
      usleep(40_000)
      guard let later = process.window else { break }
      if later.frame == window.frame { break }
      window = later
    }
    let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
    guard let index = displays.firstIndex(where: { $0.frame.contains(centre) }) else { return sample }
    let watch = watches[index]
    watch.watch(window: window.frame, listedAt: listed)
    while Clock.now < deadline, process.isRunning, watch.markerVisibleAt == nil { usleep(2_000) }
    sample.visible = watch.windowVisibleAt.map { Clock.milliseconds(from: process.launchedAt, to: $0) }
    sample.output = watch.markerVisibleAt.map { Clock.milliseconds(from: process.launchedAt, to: $0) }
    return sample
  }
}

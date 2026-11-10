import CoreGraphics
import Foundation

/// An error a command reports to the person running it.
struct Failure: Error {
  let message: String
  private(set) var isUsage = false
  init(_ message: String) { self.message = message }

  /// Any error as one a command can report, so that a runner can record it
  /// in its report before passing it on.
  init(wrapping error: Error) {
    if let failure = error as? Failure {
      self = failure
    } else if let system = error as? SystemFailure {
      self.init(system.message)
    } else {
      self.init(error.localizedDescription)
    }
  }

  /// A wrong invocation. The tool ends with status 2 instead of 1.
  static func usage(_ message: String) -> Failure {
    var failure = Failure(message)
    failure.isUsage = true
    return failure
  }
  static func usage(_ command: Command) -> Failure { usage("usage: dev \(command.name) \(command.usage)") }
}

/// A failed system call, kept apart from `Failure` so that callers can act on the error number.
struct SystemFailure: Error {
  let call: String
  let code: Int32
  init(_ call: String, code: Int32 = errno) {
    self.call = call
    self.code = code
  }
  var message: String { "\(call): \(String(cString: strerror(code)))" }
}

/// Command-line options: `--name` flags and `--name VALUE` or `--name=VALUE` settings.
struct Options {
  private(set) var flags: Set<String> = []
  private(set) var values: [String: String] = [:]
  private(set) var positionals: [String] = []

  /// Fails with the command's usage on an unknown option or a missing value.
  init(_ arguments: [String], flags known: Set<String>, values settings: Set<String>, command: Command) throws {
    var rest = arguments[...]
    while let argument = rest.popFirst() {
      let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
      if known.contains(argument) {
        flags.insert(argument)
      } else if settings.contains(argument) {
        guard let value = rest.popFirst() else { throw Failure.usage(command) }
        values[argument] = value
      } else if parts.count == 2, settings.contains(parts[0]) {
        values[parts[0]] = parts[1]
      } else if argument.hasPrefix("-") {
        throw Failure.usage(command)
      } else {
        positionals.append(argument)
      }
    }
  }
}

/// The clock every measurement uses. `tools/Dev/Stamp.c` and the app's
/// `--first-frame-file` report on the same one.
enum Clock {
  static var now: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
  static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
    (Double(end) - Double(start)) / 1_000_000
  }
}

/// A process this tool started, and may therefore stop. Nothing else is ever
/// signalled, so an instance the user has open is safe.
final class OwnedProcess {
  private let process = Process()
  let launchedAt: UInt64

  init(executable: String, arguments: [String]) throws {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    launchedAt = Clock.now
    do { try process.run() } catch { throw Failure("cannot launch \(executable): \(error.localizedDescription)") }
  }
  var pid: pid_t { process.processIdentifier }
  var isRunning: Bool { process.isRunning }
  var hasWindow: Bool {
    ScreenWindow.all().contains { $0.pid == pid && $0.width >= 100 && $0.height >= 100 }
  }

  /// When the process first has a window on screen, or nil if `deadline`
  /// passes or it exits first. The window appeared between two looks about a
  /// millisecond apart; the earlier one is reported.
  func waitForWindow(until deadline: UInt64) -> UInt64? {
    while Clock.now < deadline, process.isRunning {
      let now = Clock.now
      if hasWindow { return now }
      usleep(500)
    }
    return nil
  }

  /// Asks the process to quit, and kills it if it has not within two seconds.
  func stop() {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Clock.now + 2_000_000_000
    while process.isRunning, Clock.now < deadline { usleep(20_000) }
    if process.isRunning { kill(pid, SIGKILL) }
    process.waitUntilExit()
  }
}

/// Whether any running process was started from `executable`.
func isRunning(executable: String) -> Bool {
  let listing = Process()
  let output = Pipe()
  listing.executableURL = URL(fileURLWithPath: "/bin/ps")
  listing.arguments = ["-Ao", "command="]
  listing.standardOutput = output
  guard (try? listing.run()) != nil else { return false }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  listing.waitUntilExit()
  return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { $0.hasPrefix(executable) }
}

/// An ordinary window that is on screen now.
struct ScreenWindow {
  let pid: pid_t
  let width: Double
  let height: Double

  static func all() -> [ScreenWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { entry in
      // Layer 0 holds application windows; menu bar items and overlays sit above it.
      guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
      return ScreenWindow(pid: pid, width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                          height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
    }
  }
}

/// A directory for one run's output. Runs never write into an existing one,
/// so a report cannot be mixed with an earlier run's files.
struct OutputDirectory {
  let path: String

  init(creating path: String) throws {
    let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
    guard !FileManager.default.fileExists(atPath: absolute) else {
      throw Failure("\(absolute) exists; choose a new output directory")
    }
    do { try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true) }
    catch { throw Failure("cannot create \(absolute): \(error.localizedDescription)") }
    self.path = absolute
  }
  func file(_ name: String) -> String { path + "/" + name }

  func write(json object: Any, to name: String) throws { try writeJSON(object, to: file(name)) }
}

/// The machine state a report records beside its numbers.
enum Host {
  static var loadAverage: [Double] {
    var values = [Double](repeating: 0, count: 3)
    getloadavg(&values, 3)
    return values.map { ($0 * 100).rounded() / 100 }
  }
  static var system: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

extension Array where Element == Double {
  var median: Double? { isEmpty ? nil : sorted()[count / 2] }
}

/// Prints one row per terminal: the median of each column's values with their range.
enum Table {
  static func print(rows: [String], skipped: [String: String],
                    columns: [(title: String, values: (String) -> [Double])]) {
    func cell(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
    Swift.print(cell("terminal", 16) + columns.map { cell($0.title, 22) }.joined())
    for name in rows {
      let cells = columns.map { column -> String in
        let values = column.values(name)
        guard let median = values.median, let low = values.min(), let high = values.max() else { return "-" }
        return String(format: "%.0f (%.0f-%.0f)", median, low, high)
      }
      Swift.print(cell(name, 16) + cells.map { cell($0, 22) }.joined())
    }
    for (name, reason) in skipped.sorted(by: { $0.key < $1.key }) { Swift.print("\(name): skipped (\(reason))") }
  }
}

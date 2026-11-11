import Foundation

/// What a build step prints: one line per step, with how long it took.
///
/// Colors are the app's own, the yellow accent and the muted gray, and are
/// used only when the output is a terminal that has not asked for none.
enum Console {
  static let colored: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return isatty(STDOUT_FILENO) != 0 && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
  }()

  private static let accent = "\u{1B}[38;2;250;204;21m"
  private static let muted = "\u{1B}[38;2;142;143;150m"
  private static let danger = "\u{1B}[38;2;248;113;113m"
  private static let bold = "\u{1B}[1m"
  private static let reset = "\u{1B}[0m"

  private static func paint(_ text: String, _ color: String) -> String { colored ? color + text + reset : text }

  /// Runs `body` as a named step. The name is printed first, so a slow step
  /// shows what is being waited for, and the time when it ends.
  @discardableResult
  static func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
    let label = "  " + paint("▸", accent) + " " + name
    write(label)
    let started = Clock.now
    do {
      let value = try body()
      let seconds = Double(Clock.now - started) / 1_000_000_000
      let padding = String(repeating: " ", count: max(1, 44 - name.count))
      write(padding + paint(String(format: "%5.1f s", seconds), muted) + "\n")
      return value
    } catch {
      write("  " + paint("failed", danger) + "\n")
      throw error
    }
  }

  /// The closing line of a run that succeeded.
  static func done(_ text: String) {
    write("  " + paint("✓", accent) + " " + paint(text, colored ? bold : "") + "\n")
  }

  /// Runs a command for a step. Its output is shown only when it fails,
  /// which is when it is wanted.
  @discardableResult
  static func quietly(_ command: [String], adding environment: [String: String?] = [:]) throws -> String {
    let result = try runCommand(command, adding: environment)
    guard result.succeeded else {
      throw Failure("\(command.first ?? "command") failed\n" + result.output.trimmingCharacters(in: .newlines))
    }
    return result.output
  }

  private static func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
}

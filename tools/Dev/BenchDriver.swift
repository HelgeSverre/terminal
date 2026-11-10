import Foundation

/// The PTY benchmark driver that a measured terminal runs as its command.
enum BenchDriver {
  static let source = Repository.path("Benchmarks/TerminalBench/terminal-bench.c")
  static let workloads = ["ascii_short_lines", "ascii_long_lines", "ansi_truecolor", "unicode"]

  /// The compiler invocation, as reports record it.
  static func buildCommand(to driver: String) -> [String] {
    ["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O2", source, "-o", driver]
  }

  /// Compiles the driver, keeps the compiler's messages in `log`, and returns
  /// whether it succeeded.
  static func build(to driver: String, log: String) throws -> Bool {
    let result = try runCommand(buildCommand(to: driver))
    try result.output.write(toFile: log, atomically: true, encoding: .utf8)
    return result.succeeded
  }

  /// Fails with the driver's own message when it left one beside `report`.
  /// The driver's reason is checked before the app's exit status because it
  /// says more: a wrong grid makes the app exit non-zero as well.
  static func checkFailure(beside report: String) throws {
    let path = report + ".failed"
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return }
    throw Failure((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
  }
}

/// The PID a fixture report carries until the fixture replaces it with its own.
let fixturePlaceholderPID = 987_654_321

/// A fixture executable that fails the way the benchmark driver does: it
/// leaves a reason beside the report it was asked for and exits non-zero.
func failingDriverScript(_ reason: String) -> String {
  """
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then shift; printf '\(reason)' > "$1.failed"; exit 7; fi
    shift
  done
  exit 8
  """
}

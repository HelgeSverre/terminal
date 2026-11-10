import Foundation

/// Sends a whole local file through `/bin/cat` in the app and judges the
/// app's own report of the run.
///
/// The app keeps primary-screen history and resizes itself on a schedule
/// while the file streams. With `motion` it also moves and resizes its window
/// throughout. Nothing of the file's contents is recorded.
enum CatStress {
  static let command = Command(
    name: "cat-stress", usage: "APP SOURCE_FILE NEW_OUTPUT_DIRECTORY [motion]",
    summary: "Stream SOURCE_FILE through /bin/cat in APP with live resizes, optionally moving the window.",
    run: run)

  static func run(_ arguments: [String]) throws {
    let motion = arguments.count == 4 && arguments[3] == "motion"
    guard arguments.count == (motion ? 4 : 3) else { throw Failure.usage(command) }
    try stress(app: arguments[0], source: arguments[1], output: arguments[2], motion: motion)
    print("PASS full-file cat stress; app and children exited cleanly")
  }

  /// What identifies a file's contents without reading them: device, inode,
  /// size, and modification time in seconds and nanoseconds.
  struct Source {
    let identity: [Int]
    let bytes: Int
    let isRegular: Bool

    init(_ path: String) throws {
      var status = stat()
      guard stat(path, &status) == 0 else { throw Failure("cannot inspect \(path)") }
      bytes = Int(status.st_size)
      isRegular = status.st_mode & S_IFMT == S_IFREG
      identity = [Int(status.st_dev), Int(truncatingIfNeeded: status.st_ino), bytes,
                  status.st_mtimespec.tv_sec, status.st_mtimespec.tv_nsec]
    }
  }

  /// Runs the stress and writes provenance.json, which records the failure
  /// and the cleanup when the run fails.
  static func stress(app: String, source: String, output: String, motion: Bool) throws {
    let app = try realPath(app)
    let source = try realPath(source)
    let output = absolutePath(output)
    guard !FileManager.default.fileExists(atPath: output) else { throw Failure("Choose a new output directory") }
    let executable = app + "/Contents/MacOS/Terminal"
    guard FileManager.default.isExecutableFile(atPath: executable) else { throw Failure("Missing app executable") }
    let initial = try Source(source)
    guard initial.isRegular, initial.bytes > 0 else { throw Failure("Source must be a nonempty regular file") }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    var result: [String: Any] = [
      "passed": false, "app": app, "source_name": (source as NSString).lastPathComponent,
      "window_motion_requested": motion,
      "source_bytes": initial.bytes, "source_identity": initial.identity,
      "executable_sha256": try sha256(ofFile: executable),
      "runner_sha256": try sha256(ofFile: #filePath),
      "scope": "Full local file through /bin/cat, primary history and scheduled live resize probes; no file contents recorded.",
    ]
    var process: ProcessTree?
    var failure: Failure?
    do {
      try run(executable: executable, source: source, initial: initial, output: output, motion: motion,
              process: &process, result: &result)
    } catch {
      failure = asFailure(error)
      result["failure"] = failure?.message
    }
    let survivors = (process?.cleanup() ?? []).map { Int($0) }
    result["cleanup_survivors"] = survivors
    if !survivors.isEmpty { result["passed"] = false }
    try ReportJSON.write(result, to: output + "/provenance.json")
    if let failure { throw failure }
    guard result["passed"] as? Bool == true else { throw Failure("Cat stress cleanup failed") }
  }

  private static func run(executable: String, source: String, initial: Source, output: String, motion: Bool,
                          process: inout ProcessTree?, result: inout [String: Any]) throws {
    let report = output + "/cat.json"
    var command = [executable, "--columns", "100", "--rows", "30", "--font-size", "14", "--history-limit", "10000",
                   "--cat-smoke", report, String(initial.bytes)]
    if motion { command.append("--cat-motion-stress") }
    command += ["--execute", "/bin/cat", "--", source]
    let app = try ProcessTree(command, output: .log(output + "/app-launch.log"))
    process = app
    result["pid"] = Int(app.pid)
    guard let exit = app.wait(seconds: 630) else { throw Failure("Cat stress timed out") }
    result["exit_status"] = exit.exitStatus
    guard exit.succeeded else { throw Failure("App exited unsuccessfully") }
    guard app.livePIDs.isEmpty else { throw Failure("App left owned children") }
    let data = try readJSONObject(report)
    guard JSONValue.isTruthy(try data.fetch("passed")), JSONValue.isTruthy(try data.fetch("final")) else {
      throw Failure("Cat stress checks failed")
    }
    guard JSONValue.equals(try data.fetch("source_file_bytes"), initial.bytes) else { throw Failure("Wrong source extent") }
    guard try data.object("renderer").number("command_errors") == 0 else { throw Failure("Metal command errors") }
    if motion { try checkMotion(try data.object("window_motion")) }
    let session = try data.object("session")
    guard ["child_reaped", "read_ended", "parser_ended"].allSatisfy({ JSONValue.isTruthy(session[$0]) }) else {
      throw Failure("Session did not drain and reap")
    }
    guard try Source(source).identity == initial.identity else { throw Failure("Source changed during the run") }
    result["natural_exit"] = true
    result["passed"] = true
  }

  /// The window must have kept moving until the file ended, for at least one
  /// whole cycle, and its position and size must each have changed.
  private static func checkMotion(_ movement: [String: Any]) throws {
    guard try movement.fetch("stopped_reason") as? String == "cat_finished" else {
      throw Failure("Window motion did not finish")
    }
    guard try movement.number("duration_seconds") >= 7, try movement.number("tick_count") > 1 else {
      throw Failure("Window motion did not cover a complete cycle")
    }
    let bounds = try movement.object("applied_frame_bounds")
    for axis in ["x", "y", "width", "height"] {
      guard try bounds.number("max_\(axis)") > (try bounds.number("min_\(axis)")) + 1 else {
        throw Failure("Window \(axis) did not vary")
      }
    }
  }

  static let tests = [
    SelfTest.Case(name: "cat stress: a passing app report from a clean exit passes and is recorded") {
      try withFixtureApp(reportingScript(bytes: "$3")) { app, root in
        try "source text\n".write(toFile: root + "/source.txt", atomically: true, encoding: .utf8)
        try stress(app: app, source: root + "/source.txt", output: root + "/cat", motion: false)
        let provenance = try readJSONObject(root + "/cat/provenance.json")
        try expect(provenance["passed"] as? Bool == true, "run passed")
        try expect(JSONValue.equals(provenance["source_bytes"], 12), "source size is recorded")
        try expect(provenance["source_name"] as? String == "source.txt", "source name is recorded")
        try expect((provenance["cleanup_survivors"] as? [Any])?.isEmpty == true, "nothing survives")
      }
    },
    SelfTest.Case(name: "cat stress: a report for another extent fails the run and is recorded") {
      try withFixtureApp(reportingScript(bytes: "1")) { app, root in
        try "source text\n".write(toFile: root + "/source.txt", atomically: true, encoding: .utf8)
        let message = try failureMessage("wrong extent") {
          try stress(app: app, source: root + "/source.txt", output: root + "/cat", motion: false)
        }
        try expect(message == "Wrong source extent", "got: \(message)")
        let provenance = try readJSONObject(root + "/cat/provenance.json")
        try expect(provenance["passed"] as? Bool == false, "run did not pass")
        try expect(provenance["failure"] as? String == "Wrong source extent", "failure is recorded")
      }
    },
  ]

  /// A fixture app that writes a passing report for a source of `bytes`,
  /// where `$3` is the size it was launched with.
  private static func reportingScript(bytes: String) -> String {
    """
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --cat-smoke ]; then
        printf '{"passed": true, "final": true, "source_file_bytes": %s, "renderer": {"command_errors": 0}, "session": {"child_reaped": true, "read_ended": true, "parser_ended": true}}' "\(bytes)" > "$2"
      fi
      shift
    done
    """
  }
}

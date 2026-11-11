import Foundation

/// Checks that a grid requested at launch is the grid the first command sees.
///
/// A frozen copy of the bundle runs the benchmark driver once at each of three
/// font sizes. The driver reports the terminal size it found; the app must
/// then exit by itself and leave no children.
enum StartupGridSmoke {
  static let command = Command(
    name: "startup-grid-smoke", usage: "APP REPORT.json",
    summary: "Launch APP at three requested grids and require each to reach its first command.",
    run: run)

  struct Grid {
    let columns: Int
    let rows: Int
    let fontSize: Int
  }

  static let grids = [
    Grid(columns: 80, rows: 24, fontSize: 8),
    Grid(columns: 100, rows: 30, fontSize: 14),
    Grid(columns: 60, rows: 14, fontSize: 20),
  ]

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 2 else { throw Failure.usage(command) }
    let here = FileManager.default.currentDirectoryPath
    try run(app: absolutePath(arguments[0], relativeTo: here),
            reportPath: absolutePath(arguments[1], relativeTo: here), buildDriver: buildDriver)
    print("PASS startup grid: explicit cells at 8/14/20pt, natural exit, owned children reaped")
  }

  /// Runs every grid and writes the report, whether or not the run passed.
  /// `buildDriver` puts the driver executable at the path it is given.
  static func run(app: String, reportPath: String, buildDriver: (String) throws -> Void) throws {
    let hash = try sha256(ofFile: app + "/Contents/MacOS/Terminal")
    var report: [String: Any] = ["passed": false, "executable_sha256": hash]
    var cases: [[String: Any]] = []
    var failure: Failure?
    do {
      try withTemporaryDirectory("terminal-startup-grid-") { directory in
        let executable = try freeze(app, into: directory, expecting: hash)
        report["frozen_executable_sha256"] = hash
        let driver = directory + "/grid-driver"
        try buildDriver(driver)
        for (index, grid) in grids.enumerated() {
          let result = launch(grid, executable: executable, driver: driver, files: "\(directory)/\(index)")
          cases.append(result.entry)
          if let failure = result.failure { throw failure }
        }
      }
      report["passed"] = true
    } catch {
      failure = Failure(wrapping: error)
      report["failure"] = failure?.message
    }
    report["cases"] = cases
    try FileManager.default.createDirectory(
      atPath: (reportPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try writeJSON(report, to: reportPath)
    if let failure { throw failure }
  }

  /// Copies the bundle so that a build in progress cannot replace the
  /// executable under test, and returns the copy's executable.
  private static func freeze(_ app: String, into directory: String, expecting hash: String) throws -> String {
    let frozen = directory + "/Terminal.app"
    guard try runInherited(["/usr/bin/ditto", app, frozen]) else { throw Failure("bundle copy failed") }
    let executable = frozen + "/Contents/MacOS/Terminal"
    guard try sha256(ofFile: executable) == hash else { throw Failure("app executable changed while freezing") }
    return executable
  }

  static func buildDriver(_ path: String) throws {
    guard try runInherited(["/usr/bin/xcrun", "clang", "-O2", BenchDriver.source, "-o", path]) else {
      throw Failure("driver build failed")
    }
  }

  /// Runs one grid. The report entry is returned with the failure, so a failed
  /// case is still recorded. `files` is the path the case's `.json` and `.log`
  /// are named after.
  private static func launch(_ grid: Grid, executable: String, driver: String,
                             files: String) -> (entry: [String: Any], failure: Failure?) {
    var entry: [String: Any] = ["requested": [grid.columns, grid.rows], "font_size": grid.fontSize]
    let output = files + ".json"
    let size = ["--columns", String(grid.columns), "--rows", String(grid.rows)]
    var app: ProcessTree?
    var failure: Failure?
    do {
      // The size is given twice: before `--execute` to the app, after it to the driver.
      let launched = try ProcessTree(
        [executable] + size + ["--font-size", String(grid.fontSize), "--exit-after-command",
          "--execute", driver, "--output", output, "--terminal", "grid-smoke", "--bytes", "1", "--runs", "1",
          "--idle-seconds", "1", "--workload", "ascii_short_lines"] + size,
        output: .log(files + ".log"))
      app = launched
      entry["observed"] = try observe(launched, grid, output: output)
      entry["natural_exit"] = true
    } catch {
      failure = Failure(wrapping: error)
    }
    let survivors = app?.cleanup() ?? []
    entry["cleanup_survivors"] = survivors.map { Int($0) }
    if !survivors.isEmpty { failure = Failure("processes survived cleanup") }
    return (entry, failure)
  }

  /// Waits for the app to exit by itself and returns the size the driver saw:
  /// columns, rows, pixel width and pixel height.
  private static func observe(_ app: ProcessTree, _ grid: Grid, output: String) throws -> [Any] {
    let exit = app.wait(seconds: 15)
    if let reason = try? String(contentsOfFile: output + ".failed", encoding: .utf8) { throw Failure(reason) }
    guard exit?.succeeded == true else { throw Failure("app timeout/failure") }
    let data = try readJSONObject(output)
    // The driver runs as a child of the app, so its report must come from this tree.
    guard app.observedOwned(data["terminal_pid"] as? Int),
          data["columns"] as? Int == grid.columns, data["rows"] as? Int == grid.rows else {
      throw Failure("wrong owner/grid")
    }
    guard app.livePIDs.isEmpty else { throw Failure("children survived natural exit") }
    // A size of zero means the command started before the terminal knew its pixel size.
    let pixels = ["pixel_width", "pixel_height"].map { data[$0] as? Int ?? 0 }
    guard pixels.allSatisfy({ $0 > 0 }) else {
      throw Failure("\(grid.columns)x\(grid.rows) at \(grid.fontSize)pt: the driver saw a pixel size of \(pixels[0])x\(pixels[1])")
    }
    return ["columns", "rows", "pixel_width", "pixel_height"].map { data[$0] ?? NSNull() }
  }
}

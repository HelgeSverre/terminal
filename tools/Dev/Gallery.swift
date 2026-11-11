import Foundation

/// Captures a README screenshot from a copy of the app: `dev gallery overview|panes`.
///
/// The copy runs a fixture in place of the shell, showing only public Files,
/// Git and diff output of a disposable workspace. The PNG is staged beside
/// the approved image and replaces it only after every process of the run
/// has been reaped, so an existing image survives a failed capture.
enum Gallery {
  static let command = Command(
    name: "gallery", usage: "[--app PATH] [--files PATH] [--source-sha SHA] [overview|panes]",
    summary: "Capture a README screenshot from a copy of the app.",
    run: run)

  static let scenarios = ["overview", "panes"]
  private static let driverSource = Repository.path("tools/gallery/Driver.swift")
  private static let captureSource = Repository.path("tools/gallery/Capture.swift")

  static func run(_ arguments: [String]) throws {
    // The app copy starts this in each pane.
    if arguments.first == "fixture" { return try fixture(ProcessInfo.processInfo.environment) }

    let options = try Options(arguments, flags: [], values: ["--app", "--files", "--source-sha"], command: command)
    let scenario = options.positionals.first ?? "overview"
    guard scenarios.contains(scenario) else { throw Failure.usage(command) }
    let app = options.values["--app"].map { absolutePath($0) } ?? Repository.path("dist/Terminal.app")
    let screenshots = Repository.path("assets/screenshots")
    try createDirectory(screenshots)
    guard isDirectory(app) else { throw Failure("gallery app is missing") }
    let source = app + "/Contents/MacOS/Terminal"
    guard FileManager.default.isExecutableFile(atPath: source) else { throw Failure("gallery executable is missing") }
    let files = try resolveExecutable(
      "files", explicit: options.values["--files"], fallback: absolutePath("~/.local/bin/files"),
      searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "")

    let capture = Capture(
      scenario: scenario, app: app, files: files, destination: screenshots + "/\(scenario).png",
      report: ["scenario": scenario, "source_app": app, "source_revision": options.values["--source-sha"] ?? NSNull(),
               "executable_sha256": try sha256(ofFile: source), "fixture": "public disposable Files/git/diff content"])
    try withTemporaryDirectory("terminal-gallery-\(scenario)-") { try capture.run(in: $0) }
    print("PASS gallery \(scenario): \(capture.destination)")
  }

  private static func createDirectory(_ path: String) throws {
    do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    catch { throw Failure("cannot create \(path): \(error.localizedDescription)") }
  }

  /// The program to run as `name`: the explicit path, else the first match on
  /// the search path, else the fallback.
  static func resolveExecutable(_ name: String, explicit: String?, fallback: String, searchPath: String) throws -> String {
    func isProgram(_ path: String) -> Bool {
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        && FileManager.default.isExecutableFile(atPath: path)
    }
    if let explicit {
      let path = absolutePath(explicit)
      guard isProgram(path) else { throw Failure("not an executable: \(path)") }
      return path
    }
    let candidates = searchPath.split(separator: ":").map { absolutePath("\($0)/\(name)") } + [absolutePath(fallback)]
    guard let found = candidates.first(where: isProgram) else {
      throw Failure("could not find executable for \(name); pass --\(name) PATH")
    }
    return found
  }

  /// A disposable Git workspace with one staged file changed again, so that
  /// `git diff` has something public to show.
  static func writeWorkspace(_ directory: String) throws {
    try createDirectory(directory + "/src")
    try createDirectory(directory + "/assets")
    let source = directory + "/src/main.swift"
    do {
      try "# Terminal\n\nA native terminal for focused work.\n"
        .write(toFile: directory + "/README.md", atomically: false, encoding: .utf8)
      try "import Foundation\nprint(\"Hello, Terminal\")\n".write(toFile: source, atomically: false, encoding: .utf8)
      try "<svg xmlns=\"http://www.w3.org/2000/svg\"/>\n"
        .write(toFile: directory + "/assets/logo.svg", atomically: false, encoding: .utf8)
      guard try runInherited(["/usr/bin/git", "-C", directory, "init", "-q"]),
            try runInherited(["/usr/bin/git", "-C", directory, "add", "src/main.swift"]) else {
        throw Failure("public fixture Git initialization failed")
      }
      try "import Foundation\n\nprint(\"Hello, Terminal\")\nprint(\"Ready for focused work\")\n"
        .write(toFile: source, atomically: false, encoding: .utf8)
    } catch { throw Failure(wrapping: error) }
  }

  /// One capture run and the receipt it writes beside the image.
  final class Capture {
    let scenario: String
    let app: String
    let files: String
    let destination: String
    private var report: [String: Any]
    private var processes: [ProcessTree] = []

    init(scenario: String, app: String, files: String, destination: String, report: [String: Any]) {
      self.scenario = scenario
      self.app = app
      self.files = files
      self.destination = destination
      self.report = report
    }

    private var folder: String { URL(fileURLWithPath: destination).deletingLastPathComponent().path }
    private var staged: String { folder + "/.\(scenario)-\(getpid()).pending.png" }

    /// Captures into `directory`, then reaps everything and writes the
    /// receipt whatever happened. Only a run that passed and cleaned up replaces the image.
    func run(in directory: String) throws {
      var failure: Failure?
      do {
        try capture(in: directory)
        report["passed"] = true
      } catch {
        failure = Failure(wrapping: error)
        report["passed"] = false
        report["error"] = "Failure: \(failure?.message ?? "")"
      }
      let cleanup = processes.reversed().map { (pid: Int($0.pid), survivors: $0.cleanup().map { Int($0) }) }
      report["cleanup"] = cleanup.map { ["pid": $0.pid, "survivors": $0.survivors] as [String: Any] }
      let cleaned = cleanup.allSatisfy(\.survivors.isEmpty)
      let passed = report["passed"] as? Bool == true && cleaned
      report["passed"] = passed
      defer { try? FileManager.default.removeItem(atPath: staged) }
      try writeJSON(report, to: folder + "/.\(scenario).capture.json")
      if passed, FileManager.default.fileExists(atPath: staged), rename(staged, destination) != 0 {
        throw Failure(SystemFailure("replace \(destination)").message)
      }
      guard cleaned else { throw Failure("gallery process cleanup failed") }
      if let failure { throw failure }
    }

    private func launch(_ command: [String], environment: [String: String?] = [:], log: String) throws -> ProcessTree {
      let process = try ProcessTree(command, environment: environment, output: .log(log))
      processes.append(process)
      return process
    }

    private func capture(in directory: String) throws {
      let workspace = directory + "/workspace"
      try writeWorkspace(workspace)
      let copy = directory + "/Gallery Terminal.app"
      do { try FileManager.default.copyItem(atPath: app, toPath: copy) }
      catch { throw Failure("cannot copy \(app): \(error.localizedDescription)") }
      let executable = copy + "/Contents/MacOS/Terminal"
      let driver = directory + "/GalleryDriver", camera = directory + "/GalleryCapture"
      try compile(driverSource, to: driver)
      try compile(captureSource, to: camera)
      // Panes the driver splits off start `SHELL`, which has to be one path.
      let shell = directory + "/fixture-shell"
      try Tool.writeLauncher(at: shell, subcommand: ["gallery", "fixture"])
      let environment: [String: String?] = [
        "PATH": ([URL(fileURLWithPath: files).deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
          .joined(separator: ":"),
        "SHELL": shell, "TERM": "xterm-256color", "COLORTERM": "truecolor", "NO_COLOR": nil,
        "TERMINAL_GALLERY_DIRECTORY": directory, "TERMINAL_GALLERY_CWD": workspace,
        "TERMINAL_GALLERY_FILES": files, "TERMINAL_GALLERY_EXECUTABLE": executable,
        "TERMINAL_GALLERY_SCENARIO": scenario,
      ]

      let app = try launch([executable, "--font-size", "18", "--columns", "112", "--rows", "38",
                            "--execute", Tool.executable, "gallery", "fixture"],
                           environment: environment, log: directory + "/app.log")
      let deadline = Clock.now + 15_000_000_000
      while !FileManager.default.fileExists(atPath: directory + "/pane-0-ready") {
        guard app.wait(seconds: 0.05) == nil else { throw Failure("gallery app exited before fixture became ready") }
        guard Clock.now < deadline else { throw Failure("gallery fixture startup timed out") }
      }
      let pid = String(app.pid)
      let setup = try launch([driver, scenario, pid, directory], environment: environment, log: directory + "/driver.log")
      guard setup.wait(seconds: 15)?.succeeded == true else { throw Failure("gallery window setup failed") }
      let identity = try readJSONObject(directory + "/identity.json")
      guard let window = identity["window"] as? Int else { throw Failure("gallery identity names no window") }
      let image = directory + "/capture.png"
      let shot = try launch([camera, String(window), pid, image], log: directory + "/capture.log")
      guard shot.wait(seconds: 12)?.succeeded == true else { throw Failure("gallery PNG capture failed") }
      let size = (try? FileManager.default.attributesOfItem(atPath: image))?[.size] as? NSNumber
      guard let size, size.intValue > 0 else {
        throw Failure("gallery capture is missing")
      }
      do { try FileManager.default.copyItem(atPath: image, toPath: staged) }
      catch { throw Failure("cannot stage \(staged): \(error.localizedDescription)") }
      report["identity"] = identity
      report["output"] = destination
      report["png_sha256"] = try sha256(ofFile: staged)
    }

    private func compile(_ source: String, to output: String) throws {
      guard try runInherited(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-O", source, "-o", output]) else {
        throw Failure("compile failed: \(source)")
      }
    }
  }

  /// The shell replacement of a gallery pane. Each pane shows a different
  /// real Files, Git or diff view and then stays quiet for the capture.
  static func fixture(_ environment: [String: String]) throws {
    func required(_ key: String) throws -> String {
      guard let value = environment[key] else { throw Failure("missing environment variable \(key)") }
      return try realPath(value)
    }
    let root = try required("TERMINAL_GALLERY_DIRECTORY")
    let pane = try claimPaneNumber(counter: root + "/pane-counter")
    let cwd = try required("TERMINAL_GALLERY_CWD")
    let files = try required("TERMINAL_GALLERY_FILES")
    let scenario = environment["TERMINAL_GALLERY_SCENARIO"] ?? "overview"
    let listing = [files, "--color=always", "--no-git", "-L", "2", cwd]
    // Without `--no-pager` git hands a terminal's output to a pager, which waits for a key.
    let diff = ["/usr/bin/git", "--no-pager", "diff", "--color=always", "--", "src/main.swift"]
    func write(_ text: String) { try? writeAll(STDOUT_FILENO, Data(text.utf8)) }
    func section(_ title: String) { write("\u{1B}[38;2;92;166;255m\(title)\u{1B}[0m\r\n") }
    /// Tells the runner this pane has drawn, and keeps the pane open.
    func stayReady() throws -> Never {
      try "ready\n".write(toFile: root + "/pane-\(pane)-ready", atomically: false, encoding: .utf8)
      while true { sleep(60) }
    }

    write("\u{1B}]0;Terminal\u{07}\u{1B}[2J\u{1B}[H")
    switch pane {
    case 0:
      section("workspace  ·  files --color=always")
      _ = try runInherited(listing)
      // The panes scenario splits this pane, so it shows the listing alone.
      if scenario == "panes" { try stayReady() }
      write("\r\n")
      section("$ git diff --color=always -- src/main.swift")
      _ = try runInherited(diff, directory: cwd)
    case 1:
      section("$ cat src/main.swift")
      if let source = FileManager.default.contents(atPath: cwd + "/src/main.swift") { try? writeAll(STDOUT_FILENO, source) }
    case 2:
      section("$ git diff --color=always -- src/main.swift")
      _ = try runInherited(diff, directory: cwd)
    default:
      section("terminal")
      _ = try runInherited(listing)
    }
    try stayReady()
  }

  static let tests = [
    SelfTest.Case(name: "gallery: an executable resolves from the explicit path, the search path, then the fallback") {
      try withTemporaryDirectory("dev-gallery-resolve-") { directory in
        for name in ["first", "second", "fallback"] {
          try FileManager.default.createDirectory(atPath: directory + "/" + name, withIntermediateDirectories: true)
        }
        let second = directory + "/second/files", fallback = directory + "/fallback/files"
        try writeScript("true", to: second)
        try writeScript("true", to: fallback)
        // A directory and a file without the execute bit are passed over.
        try FileManager.default.createDirectory(atPath: directory + "/first/files", withIntermediateDirectories: true)
        let search = "\(directory)/first:\(directory)/second"
        func resolve(_ explicit: String?, _ fallback: String, _ search: String) throws -> String {
          try resolveExecutable("files", explicit: explicit, fallback: fallback, searchPath: search)
        }
        try expect(try resolve(nil, fallback, search) == second, "the search path comes before the fallback")
        try expect(try resolve(nil, fallback, "\(directory)/first") == fallback, "the fallback is used last")
        try expect(try resolve(fallback, second, search) == fallback, "an explicit path wins")
        let refusals: [(String?, String, String)] = [(directory + "/first/files", fallback, "not an executable"),
                                                     (nil, directory + "/none", "pass --files PATH")]
        for (explicit, missing, message) in refusals {
          do {
            _ = try resolve(explicit, missing, "\(directory)/first")
            throw Failure("a missing executable was accepted")
          } catch let failure as Failure {
            try expect(failure.message.contains(message), "got: \(failure.message)")
          }
        }
      }
    },
    SelfTest.Case(name: "gallery: panes take consecutive numbers from the shared counter") {
      try withTemporaryDirectory("dev-gallery-counter-") { directory in
        let counter = directory + "/pane-counter"
        try expect(try (0..<3).map { _ in try claimPaneNumber(counter: counter) } == [0, 1, 2], "three panes count from zero")
        try expect(try String(contentsOfFile: counter, encoding: .utf8) == "3", "the counter holds the next number")
        try "8".write(toFile: counter, atomically: true, encoding: .utf8)
        do {
          _ = try claimPaneNumber(counter: counter, below: 8)
          throw Failure("a ninth pane was accepted")
        } catch let failure as Failure {
          try expect(failure.message == "too many workload panes", "got: \(failure.message)")
        }
      }
    },
    SelfTest.Case(name: "gallery: the workspace has one staged file with an unstaged change") {
      try withTemporaryDirectory("dev-gallery-workspace-") { directory in
        try writeWorkspace(directory + "/workspace")
        let diff = try runCommand(["/usr/bin/git", "-C", directory + "/workspace", "diff", "--", "src/main.swift"])
        try expect(diff.succeeded && diff.output.contains("+print(\"Ready for focused work\")"), "the diff shows the added line")
        let status = try runCommand(["/usr/bin/git", "-C", directory + "/workspace", "status", "--porcelain"])
        try expect(status.output.contains("AM src/main.swift"), "the source is staged and changed: \(status.output)")
      }
    },
  ]
}

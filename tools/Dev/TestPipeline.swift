import Foundation

/// The headless gate consumes one SwiftPM build. Test binaries and the app
/// bundle use the same optimized, test-enabled products; release builds remain
/// separate and never consume these artifacts.
enum TestPipeline {
  static let command = Command(name: "test", usage: "",
    summary: "Run the headless gate using the test products built by just test.", run: run)

  static func prebuiltProduct(_ name: String) -> String? {
    guard let directory = ProcessInfo.processInfo.environment["TERMINAL_TEST_PRODUCTS"] else { return nil }
    let path = directory + "/" + name
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }

  static func prebuiltHelper(source: String) -> String? {
    let products = [
      "tools/tui_stress/Driver.swift": "TUIStressDriver",
      "tools/rendering_proof/Capture.swift": "RenderingCapture",
      "tools/rendering_proof/Driver.swift": "RenderingDriver",
    ]
    guard let entry = products.first(where: { Repository.path($0.key) == source }) else { return nil }
    return prebuiltProduct(entry.value)
  }

  struct Phase {
    let name: String
    let arguments: [String]
    var environment: [String: String?] = [:]
  }

  // The GPU recipe probes the exact hosted shared-heap driver fault before
  // running these suites. Keep CPU geometry in the ordinary application gate.
  static let applicationTestOptions = ["DevTests", "GlyphRasterWorkerTests", "GlyphResidency",
    "PresentationMetalTests", "GraphicsRenderedGapTests"].flatMap { ["--skip", $0] }

  /// A lane is serial, including tests that mutate their process globals.
  /// Every started lane is joined before an error escapes; failed lanes do not
  /// run their remaining phases. No build command belongs inside these lanes.
  static func run(lanes: [[Phase]], phase: @escaping (Phase) throws -> Void) throws {
    guard (1...2).contains(lanes.count) else { throw Failure("test gate supports one or two lanes") }
    final class Failures: @unchecked Sendable {
      let lock = NSLock()
      var messages: [Int: String] = [:]
      func record(_ index: Int, _ error: Error) {
        lock.lock(); defer { lock.unlock() }
        messages[index] = String(describing: error)
      }
    }
    let failures = Failures(), queue = OperationQueue()
    queue.maxConcurrentOperationCount = lanes.count
    for (index, lane) in lanes.enumerated() {
      queue.addOperation {
        do { for entry in lane { try phase(entry) } }
        catch { failures.record(index, error) }
      }
    }
    queue.waitUntilAllOperationsAreFinished()
    if !failures.messages.isEmpty {
      throw Failure(failures.messages.keys.sorted().compactMap { failures.messages[$0] }.joined(separator: "\n"))
    }
  }

  static func run(_ arguments: [String]) throws {
    guard arguments.isEmpty else { throw Failure.usage(command) }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let products = executable.deletingLastPathComponent().path
    for name in ["TerminalApp", "TerminalLauncher", "TerminfoProbe", "PTYTests", "TUIStressDriver",
                 "RenderingCapture", "RenderingDriver"] {
      guard FileManager.default.isExecutableFile(atPath: products + "/" + name) else {
        throw Failure("missing test product \(name); run just test to build the complete gate")
      }
    }
    setenv("TERMINAL_TEST_PRODUCTS", products, 1)
    setenv("TERMINAL_TEST_HOOKS", "1", 1)
    try FileManager.default.createDirectory(atPath: Repository.path("reports/test-timing"), withIntermediateDirectories: true)
    var timings: [[String: Any]] = []
    let reportLock = NSLock(), gateStarted = Clock.now
    func phase(_ entry: Phase) throws {
      let started = Clock.now
      let result = try runCommand(entry.arguments, adding: entry.environment, directory: Repository.root)
      let seconds = Double(Clock.now - started) / 1_000_000_000
      reportLock.lock(); defer { reportLock.unlock() }
      FileHandle.standardOutput.write(result.data)
      timings.append(["phase": entry.name, "seconds": seconds, "status": result.status,
                      "started_seconds": Double(started - gateStarted) / 1_000_000_000])
      try writeJSON(["phases": timings, "wall_seconds": Double(Clock.now - gateStarted) / 1_000_000_000],
                    to: Repository.path("reports/test-timing/phases.json"))
      guard result.succeeded else { throw Failure("test phase \(entry.name) failed (\(result.status))") }
      Console.done(String(format: "%@  %.2f s", entry.name, seconds))
    }
    let dev = products + "/dev"
    let shards = ProcessInfo.processInfo.environment["TERMINAL_TEST_SHARDS"] ?? "1"
    guard ["1", "2"].contains(shards) else { throw Failure("TERMINAL_TEST_SHARDS must be 1 or 2") }
    let runner = shards == "2" ? try PrebuiltTests.runner(products: products) : nil
    func tests(_ name: String, _ options: [String], _ report: String) -> Phase {
      let options = options + ["--xunit-output", Repository.path("reports/test-timing/" + report + ".xml")]
      return Phase(name: name, arguments: runner?.arguments(options) ?? (["just", "unit-test", "--skip-build"] + options),
                   environment: runner?.environment ?? [:])
    }
    try phase(Phase(name: "syntax", arguments: [dev, "sources", "check"]))
    try phase(Phase(name: "bundle", arguments: [dev, "bundle", "testing", products]))
    let developer = tests("developer-tests", ["--filter", "DevTests"], "developer")
    let tooling = Phase(name: "tooling", arguments: ["just", "_workflow-tools"])
    let terminfo = Phase(name: "terminfo", arguments: [dev, "terminfo-smoke"])
    let font = Phase(name: "font-catalog", arguments: [Repository.path("dist/Terminal.app/Contents/MacOS/Terminal"),
      "--font-catalog", Repository.path("reports/font-glyphs.txt")])
    let application = tests("app-tests", applicationTestOptions, "app")
    if shards == "2" {
      // Font output and the bundle exist before either test process starts.
      // Sources and SwiftPM products stay frozen until both lanes have joined.
      try phase(font)
      try run(lanes: [[developer, tooling, terminfo], [application]], phase: phase)
    } else {
      for entry in [developer, tooling, terminfo, font, application] { try phase(entry) }
    }
    try phase(Phase(name: "glyph-tests", arguments: ["just", "_glyph-rendering-tests"]))
    try phase(Phase(name: "pty", arguments: [products + "/PTYTests", Repository.path("dist/Terminal.app/Contents/MacOS/TerminalLauncher")]))
  }
}

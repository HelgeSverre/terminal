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
    func phase(_ name: String, _ arguments: [String]) throws {
      let started = Clock.now
      let result = try runCommand(arguments, directory: Repository.root)
      FileHandle.standardOutput.write(result.data)
      let seconds = Double(Clock.now - started) / 1_000_000_000
      timings.append(["phase": name, "seconds": seconds, "status": result.status])
      try writeJSON(["phases": timings], to: Repository.path("reports/test-timing/phases.json"))
      guard result.succeeded else { throw Failure("test phase \(name) failed (\(result.status))") }
      Console.done(String(format: "%@  %.2f s", name, seconds))
    }
    let dev = products + "/dev"
    let tests = ["just", "unit-test", "--skip-build"]
    try phase("syntax", [dev, "sources", "check"])
    try phase("bundle", [dev, "bundle", "testing", products])
    try phase("developer-tests", tests + ["--filter", "DevTests", "--xunit-output", "reports/test-timing/developer.xml"])
    try phase("tooling", ["just", "_workflow-tools"])
    try phase("terminfo", [dev, "terminfo-smoke"])
    try phase("font-catalog", [Repository.path("dist/Terminal.app/Contents/MacOS/Terminal"), "--font-catalog",
                               Repository.path("reports/font-glyphs.txt")])
    try phase("app-tests", tests + ["--skip", "DevTests", "--skip", "GlyphRasterWorkerTests", "--skip", "GlyphResidency",
                                     "--xunit-output", "reports/test-timing/app.xml"])
    try phase("glyph-tests", ["just", "_glyph-rendering-tests"])
    try phase("pty", [products + "/PTYTests", Repository.path("dist/Terminal.app/Contents/MacOS/TerminalLauncher")])
  }
}

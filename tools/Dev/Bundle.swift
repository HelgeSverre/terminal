import Foundation

/// Builds the app bundle: `dev bundle development|release`.
///
/// The package compiles the app and its launcher. What a package cannot do
/// is done here: the icon, the Metal library, the terminfo database, the
/// bundle's layout and its signature.
enum AppBundle {
  static let command = Command(
    name: "bundle", usage: "development|release",
    summary: "Compile the app and assemble dist/Terminal.app.",
    run: run)

  enum Configuration: String {
    case development, release

    /// Development is optimized too, since the smokes and measurements run
    /// it, but compiles file by file so a small edit is a short build.
    /// Release optimizes the whole module and skips dynamic exclusivity
    /// checks: on the parser's hot path they cost a quarter of throughput.
    var buildArguments: [String] {
      switch self {
      case .development: ["-c", "debug", "-Xswiftc", "-O"]
      case .release: ["-c", "release", "-Xswiftc", "-enforce-exclusivity=unchecked"]
      }
    }
  }

  static func run(_ arguments: [String]) throws {
    guard arguments.count == 1, let configuration = Configuration(rawValue: arguments[0]) else {
      throw Failure.usage(command)
    }
    let started = Clock.now
    let app = Repository.path("dist/Terminal.app")
    let resources = app + "/Contents/Resources"
    let programs = app + "/Contents/MacOS"
    let scratch = Repository.path("target/native")
    for directory in [resources, programs, scratch] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    let products = try Console.step("Compile Terminal (\(configuration.rawValue))") { try compile(configuration) }
    try Console.step("Icon, shader and terminfo") {
      try icon(into: scratch + "/Terminal.icns")
      let intermediate = scratch + "/Terminal.air"
      try Console.quietly(["xcrun", "-sdk", "macosx", "metal", "-c", Repository.path("Resources/Terminal/Terminal.metal"),
                           "-o", intermediate])
      try Console.quietly(["xcrun", "-sdk", "macosx", "metallib", intermediate, "-o", resources + "/Terminal.metallib"])
      try Console.quietly(["/usr/bin/tic", "-x", "-o", resources + "/terminfo",
                           Repository.path("Resources/Terminal/Terminal.terminfo")])
    }
    try Console.step("Assemble and sign the bundle") {
      try replace(programs + "/Terminal", with: products + "/TerminalApp")
      try replace(programs + "/TerminalLauncher", with: products + "/TerminalLauncher")
      try replace(app + "/Contents/Info.plist", with: Repository.path("Resources/Terminal/Info.plist"))
      try replace(resources + "/Terminal.sdef", with: Repository.path("Resources/Terminal/Terminal.sdef"))
      try replace(resources + "/Terminal.icns", with: scratch + "/Terminal.icns")
      try Console.quietly(["/usr/bin/ditto", Repository.path("Resources/Terminal/ShellIntegration"),
                           resources + "/ShellIntegration"])
      try Console.quietly(["/usr/bin/ditto", Repository.path("assets/fonts"), resources + "/Fonts"])
      // Ad hoc: a local build is signed for this machine only.
      try Console.quietly(["/usr/bin/codesign", "--force", "--sign", "-", programs + "/TerminalLauncher"])
      try Console.quietly(["/usr/bin/codesign", "--force", "--sign", "-", app])
    }
    let seconds = Double(Clock.now - started) / 1_000_000_000
    Console.done(String(format: "dist/Terminal.app  %.1f s", seconds))
  }

  /// Compiles the app and its launcher and returns the directory holding them.
  /// Each configuration has its own build directory, apart from the one the
  /// test suites use: they compile the app with its test hooks.
  private static func compile(_ configuration: Configuration) throws -> String {
    let build = ["swift", "build", "--package-path", Repository.root,
                 "--scratch-path", Repository.path("target/swiftpm/\(configuration.rawValue)")]
      + configuration.buildArguments
    let withoutHooks: [String: String?] = ["TERMINAL_TEST_HOOKS": nil]
    for product in ["TerminalApp", "TerminalLauncher"] {
      try Console.quietly(build + ["--product", product], adding: withoutHooks)
    }
    return try Console.quietly(build + ["--show-bin-path"], adding: withoutHooks)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Makes the `.icns` from the one source image, when that image is newer.
  private static func icon(into icns: String) throws {
    let source = Repository.path("assets/AppIcon.png")
    func modified(_ path: String) -> Date? {
      (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
    if let made = modified(icns), let drawn = modified(source), made > drawn { return }
    let iconset = (icns as NSString).deletingPathExtension + ".iconset"
    try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
      for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let pixels = String(size * scale)
        try Console.quietly(["/usr/bin/sips", "-z", pixels, pixels, source,
                             "--out", "\(iconset)/icon_\(size)x\(size)\(suffix).png"])
      }
    }
    try Console.quietly(["/usr/bin/iconutil", "-c", "icns", iconset, "-o", icns])
  }

  private static func replace(_ destination: String, with source: String) throws {
    try? FileManager.default.removeItem(atPath: destination)
    do { try FileManager.default.copyItem(atPath: source, toPath: destination) }
    catch { throw Failure("cannot copy \(source): \(error.localizedDescription)") }
  }
}

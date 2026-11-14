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

    let products = try Console.step("Compile Terminal (\(configuration.rawValue))") {
      try configuration == .development ? compileIncrementally() : compileWholeModule(into: scratch + "/release")
    }
    let frameworks = app + "/Contents/Frameworks"
    try Console.step("Icon, shader and terminfo") {
      try icon(into: scratch + "/Terminal.icns")
      let intermediate = scratch + "/Terminal.air"
      try Console.quietly(["xcrun", "-sdk", "macosx", "metal", "-c", Repository.path("Sources/TerminalUI/Resources/Terminal.metal"),
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
      try Console.quietly(["/usr/bin/ditto", Repository.path("Sources/TerminalUI/Resources/Fonts"), resources + "/Fonts"])
      try embedUpdater(into: frameworks)
      // Ad hoc: a local build is signed for this machine only.
      try Console.quietly(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", frameworks + "/Sparkle.framework"])
      try Console.quietly(["/usr/bin/codesign", "--force", "--sign", "-", programs + "/TerminalLauncher"])
      try Console.quietly(["/usr/bin/codesign", "--force", "--sign", "-", app])
    }
    let seconds = Double(Clock.now - started) / 1_000_000_000
    Console.done(String(format: "dist/Terminal.app  %.1f s", seconds))
  }

  /// The development build: the package compiles the app and its launcher
  /// file by file, so a small edit is a short build. It is optimized too,
  /// since the smokes and measurements run it. It has its own build
  /// directory, apart from the one the test suites use: they compile the app
  /// with its test hooks. Returns the directory holding the two programs.
  private static func compileIncrementally() throws -> String {
    let build = ["swift", "build", "--package-path", Repository.root,
                 "--scratch-path", packageDirectory, "-c", "debug", "-Xswiftc", "-O"]
    let withoutHooks: [String: String?] = ["TERMINAL_TEST_HOOKS": nil]
    for product in ["TerminalApp", "TerminalLauncher"] {
      try Console.quietly(build + ["--product", product], adding: withoutHooks)
    }
    return try Console.quietly(build + ["--show-bin-path"], adding: withoutHooks)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The release build: one compiler run over each module's sources.
  ///
  /// The package is not used here. Its release builds optimize a whole
  /// module but generate code on many threads, one unit per file, and that
  /// measured 9% slower on truecolor output than a single unit. Dynamic
  /// exclusivity checks are off as well: on the parser's hot path they cost
  /// a quarter of throughput. Returns the directory holding the two programs.
  private static func compileWholeModule(into directory: String) throws -> String {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    // The package fetches the updater; this build only links against it.
    try Console.quietly(["swift", "package", "--package-path", Repository.root, "--scratch-path", packageDirectory, "resolve"])
    let warnings = ["-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0"]
    let interop = Repository.path("Sources/TerminalInterop")
    let spawn = directory + "/Spawn.o"
    try Console.quietly(["xcrun", "clang"] + warnings + ["-I", interop + "/include", "-c", interop + "/Spawn.c", "-o", spawn])
    try Console.quietly(["xcrun", "clang"] + warnings
      + [Repository.path("Sources/TerminalLauncher/Launcher.c"), "-o", directory + "/TerminalLauncher"])
    let compile = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-whole-module-optimization",
                   "-enforce-exclusivity=unchecked", "-target", "arm64-apple-macosx15.0",
                   "-package-name", "terminal", "-I", interop + "/include", "-I", directory]
    var objects = [spawn]
    for module in libraryModules {
      let object = directory + "/" + module + ".o"
      try Console.quietly(compile + ["-parse-as-library", "-module-name", module, "-emit-module",
                                     "-emit-module-path", directory + "/" + module + ".swiftmodule",
                                     "-emit-object", "-o", object] + swiftSources(in: "Sources/" + module))
      objects.append(object)
    }
    try Console.quietly(compile + ["-module-name", "Terminal",
                         "-F", (updaterFramework as NSString).deletingLastPathComponent, "-framework", "Sparkle",
                         "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                         "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal",
                         "-framework", "CoreText", "-framework", "ImageIO"]
      + swiftSources(in: "Sources/Terminal") + objects + ["-o", directory + "/TerminalApp"])
    return directory
  }

  /// The package's library targets, each before the ones that import it.
  static let libraryModules = ["TerminalEngine", "TerminalHost", "TerminalUI"]

  private static func swiftSources(in directory: String) throws -> [String] {
    let root = Repository.path(directory)
    guard let found = FileManager.default.enumerator(atPath: root) else { throw Failure("cannot list \(root)") }
    return found.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted().map { root + "/" + $0 }
  }

  private static let packageDirectory = Repository.path("target/swiftpm/development")
  /// Sparkle as the package downloads it: for both Mac architectures, with headers.
  private static let updaterFramework = packageDirectory
    + "/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

  /// Copies the updater into the bundle, reduced to what this app ships:
  /// Apple Silicon code and no headers. That halves it, to about 1.5 MB.
  private static func embedUpdater(into frameworks: String) throws {
    let destination = frameworks + "/Sparkle.framework"
    try? FileManager.default.removeItem(atPath: destination)
    try FileManager.default.createDirectory(atPath: frameworks, withIntermediateDirectories: true)
    try Console.quietly(["/usr/bin/ditto", updaterFramework, destination])
    for name in ["Headers", "PrivateHeaders", "Modules"] {
      try? FileManager.default.removeItem(atPath: destination + "/" + name)
      try? FileManager.default.removeItem(atPath: destination + "/Versions/B/" + name)
    }
    guard let found = FileManager.default.enumerator(atPath: destination) else { return }
    for case let relative as String in found {
      let path = destination + "/" + relative
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil,
        FileManager.default.isExecutableFile(atPath: path),
        let architectures = try? runCommand(["/usr/bin/lipo", "-archs", path]), architectures.succeeded,
        architectures.output.contains("x86_64")
      else { continue }
      try Console.quietly(["/usr/bin/lipo", "-thin", "arm64", path, "-output", path])
    }
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

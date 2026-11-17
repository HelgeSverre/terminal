// swift-tools-version: 6.0
import PackageDescription

// The package is two things. For another app it is three libraries and a
// launcher; see docs/embedding.md. In this repository it also compiles the
// app, the developer tool and the test suites, and `just build` assembles the
// app bundle around the compiled program.
//
// Consumer mode is the default for both URL and local-path dependencies.
// Repository tooling opts into the app/updater/tests explicitly; directory
// names never determine the package graph.
let development = Context.environment["TERMINAL_DEVELOPMENT"] == "1"

// Code that only the tests reach is compiled in when the suites are built
// (`just unit-test` sets the variable) and left out of the app. Consumer mode
// ignores test settings; hooks require the explicit development opt-in too.
let testHooks: [SwiftSetting] = !development || Context.environment["TERMINAL_TEST_HOOKS"] == nil ? [] : [
  .define("SESSION_IO_TESTING"), .define("GLYPH_RESIDENCY_TESTING"), .define("SNAPSHOT_ABI_DIAGNOSTICS"),
]

let libraries: [Target] = [
  // The C declarations of the emulator's interface, and the PTY spawn.
  .target(name: "TerminalInterop", path: "Sources/TerminalInterop"),
  // The emulator: parser, document, reflow, selection, search and text
  // width. No window system, no process handling.
  .target(
    name: "TerminalEngine", dependencies: ["TerminalInterop"], path: "Sources/TerminalEngine",
    swiftSettings: [.swiftLanguageMode(.v5)] + testHooks),
  // A terminal with a child process on a PTY: reading, writing, resizing
  // and the order of everything that touches the emulator.
  .target(
    name: "TerminalHost", dependencies: ["TerminalEngine", "TerminalInterop"], path: "Sources/TerminalHost",
    resources: [.copy("Resources/ShellIntegration")],
    swiftSettings: [.swiftLanguageMode(.v5)] + testHooks),
  // The AppKit view of a session: Metal drawing, keyboard and mouse input,
  // selection, find and accessibility.
  .target(
    name: "TerminalUI", dependencies: ["TerminalHost", "TerminalEngine"], path: "Sources/TerminalUI",
    // The fonts and the shader source. The app bundle carries its own
    // copies, with the shader compiled.
    resources: [.copy("Resources/Fonts"), .copy("Resources/Terminal.metal")],
    swiftSettings: [.swiftLanguageMode(.v5)] + testHooks),
  // The helper every PTY child is started through.
  .executableTarget(name: "TerminalLauncher", path: "Sources/TerminalLauncher"),
]

let application: [Target] = [
  .executableTarget(
    name: "TerminalApp",
    dependencies: ["TerminalUI", "TerminalHost", "TerminalEngine", "TerminalInterop", .product(name: "Sparkle", package: "Sparkle")],
    path: "Sources/Terminal",
    swiftSettings: [.swiftLanguageMode(.v5), .define("TERMINAL_DIAGNOSTICS", .when(configuration: .debug))]
      + testHooks + (testHooks.isEmpty ? [] : [.define("TERMINAL_DIAGNOSTICS")]),
    // Where the bundle keeps the frameworks it carries.
    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
  // The developer tool, built here for its tests; `just` builds the one it runs.
  .executableTarget(
    name: "dev", path: "tools/Dev", exclude: ["KeyEcho.c", "Stamp.c"],
    swiftSettings: [.swiftLanguageMode(.v5)]),
  .executableTarget(
    name: "UpdatePreview", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
    path: "tools/UpdatePreview", swiftSettings: [.swiftLanguageMode(.v5)],
    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
  .testTarget(
    name: "DevTests", dependencies: ["dev"], path: "Tests/DevTests",
    swiftSettings: [.swiftLanguageMode(.v5)]),
  .testTarget(
    name: "TerminalTests",
    dependencies: ["TerminalApp", "TerminalUI", "TerminalHost", "TerminalEngine", "TerminalInterop", "TerminalLauncher"],
    path: "Tests/TerminalTests", exclude: ["differential-fixtures.json"],
    swiftSettings: [.swiftLanguageMode(.v5)]),
]

// Existing integration probes share the package's emulator instead of compiling
// its sources again in each just recipe. They remain separate processes.
let testPrograms = ["MetalUploadProbe.swift", "TerminfoProbe.swift", "pty.c", "Fuzz.swift", "EscTest.swift"]
let testTools: [Target] = [
  .executableTarget(name: "TerminfoProbe", dependencies: ["TerminalEngine", "TerminalInterop"],
    path: "Tests/Programs", exclude: testPrograms.filter { $0 != "TerminfoProbe.swift" },
    sources: ["TerminfoProbe.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
  .executableTarget(name: "PTYTests", dependencies: ["TerminalEngine", "TerminalInterop"],
    path: "Tests/Programs", exclude: testPrograms.filter { $0 != "pty.c" }, sources: ["pty.c"]),
  .executableTarget(name: "TUIStressDriver", path: "tools/tui_stress", exclude: ["README.md"],
    sources: ["Driver.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
  .executableTarget(name: "RenderingCapture", path: "tools/rendering_proof", exclude: ["Driver.swift", "README.md"],
    sources: ["Capture.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
  .executableTarget(name: "RenderingDriver", path: "tools/rendering_proof", exclude: ["Capture.swift", "README.md"],
    sources: ["Driver.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
]

let package = Package(
  name: "Terminal",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    // What another app embeds.
    .library(name: "TerminalUI", targets: ["TerminalUI"]),
    .library(name: "TerminalHost", targets: ["TerminalHost"]),
    // The emulator alone: bytes in, screen text and replies out.
    .library(name: "TerminalEngine", targets: ["TerminalEngine"]),
    // The helper every session starts its child through; an embedding app
    // carries it in its bundle.
    .executable(name: "TerminalLauncher", targets: ["TerminalLauncher"]),
  ],
  dependencies: development ? [
    // The updater. Pinned exactly: it installs software on the user's machine.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
  ] : [],
  targets: libraries + (development ? application + testTools : []))

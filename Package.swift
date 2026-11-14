// swift-tools-version: 6.0
import PackageDescription

// The package is two things. For another app it is three libraries and a
// launcher; see docs/embedding.md. In this repository it also compiles the
// app, the developer tool and the test suites, and `just build` assembles the
// app bundle around the compiled program.
//
// A package manager keeps the packages an app depends on in a `checkouts`
// directory. There the app, its updater and the tests are left out, so an
// embedding app resolves and builds only the libraries.
let embedded = Context.packageDirectory.contains("/checkouts/")

// Code that only the tests reach is compiled in when the suites are built
// (`just unit-test` sets the variable) and left out of the app. An embedding
// app's build never gets it, whatever its environment holds.
let testHooks: [SwiftSetting] = embedded || Context.environment["TERMINAL_TEST_HOOKS"] == nil ? [] : [
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
    swiftSettings: [.swiftLanguageMode(.v5)] + testHooks,
    // Where the bundle keeps the frameworks it carries.
    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
  // The developer tool, built here for its tests; `just` builds the one it runs.
  .executableTarget(
    name: "dev", path: "tools/Dev", exclude: ["KeyEcho.c", "Stamp.c"],
    swiftSettings: [.swiftLanguageMode(.v5)]),
  .testTarget(
    name: "DevTests", dependencies: ["dev"], path: "Tests/DevTests",
    swiftSettings: [.swiftLanguageMode(.v5)]),
  .testTarget(
    name: "TerminalTests",
    dependencies: ["TerminalApp", "TerminalUI", "TerminalHost", "TerminalEngine", "TerminalInterop", "TerminalLauncher"],
    path: "Tests/TerminalTests",
    swiftSettings: [.swiftLanguageMode(.v5)]),
]

let package = Package(
  name: "Terminal",
  platforms: [.macOS(.v15)],
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
  dependencies: embedded ? [] : [
    // The updater. Pinned exactly: it installs software on the user's machine.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
  ],
  targets: libraries + (embedded ? [] : application))

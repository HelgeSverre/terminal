// swift-tools-version: 6.0
import PackageDescription

// Compiles the app, its launcher and the developer tool, and builds the test
// suites. `just build` assembles the app bundle around the compiled program.
// Code that only the tests reach is compiled in when the suites are built
// (`just unit-test` sets the variable) and left out of the app.
let testHooks: [SwiftSetting] = Context.environment["TERMINAL_TEST_HOOKS"] == nil ? [] : [
  .define("SESSION_IO_TESTING"), .define("GLYPH_RESIDENCY_TESTING"), .define("SNAPSHOT_ABI_DIAGNOSTICS"),
]

let package = Package(
  name: "Terminal",
  platforms: [.macOS(.v15)],
  dependencies: [
    // The updater. Pinned exactly: it installs software on the user's machine.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
  ],
  targets: [
    // The C declarations of the emulator's interface, and the PTY spawn.
    .target(name: "TerminalInterop", path: "Sources/TerminalInterop"),
    // The emulator: parser, document, reflow, selection, search and text
    // width. No window system, no process handling.
    .target(
      name: "TerminalCore", dependencies: ["TerminalInterop"], path: "Sources/TerminalCore",
      swiftSettings: [.swiftLanguageMode(.v5)] + testHooks),
    // A terminal with a child process on a PTY: reading, writing, resizing
    // and the order of everything that touches the emulator.
    .target(
      name: "TerminalSession", dependencies: ["TerminalCore", "TerminalInterop"], path: "Sources/TerminalSession",
      swiftSettings: [.swiftLanguageMode(.v5)] + testHooks),
    // The AppKit view of a session: Metal drawing, keyboard and mouse input,
    // selection, find and accessibility.
    .target(
      name: "TerminalView", dependencies: ["TerminalSession", "TerminalCore"], path: "Sources/TerminalView",
      swiftSettings: [.swiftLanguageMode(.v5)] + testHooks),
    .executableTarget(
      name: "TerminalApp",
      dependencies: ["TerminalView", "TerminalSession", "TerminalCore", "TerminalInterop", .product(name: "Sparkle", package: "Sparkle")],
      path: "Sources/Terminal",
      swiftSettings: [.swiftLanguageMode(.v5)] + testHooks,
      // Where the bundle keeps the frameworks it carries.
      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    // The helper every PTY child is started through.
    .executableTarget(
      name: "TerminalLauncher", path: "Sources/TerminalLauncher",
      cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]),
    // The developer tool, built here for its tests; `just` builds the one it runs.
    .executableTarget(
      name: "dev", path: "tools/Dev", exclude: ["KeyEcho.c", "Stamp.c"],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "DevTests", dependencies: ["dev"], path: "Tests/DevTests",
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "TerminalTests",
      dependencies: ["TerminalApp", "TerminalView", "TerminalSession", "TerminalCore", "TerminalInterop", "TerminalLauncher"],
      path: "Tests/TerminalTests",
      swiftSettings: [.swiftLanguageMode(.v5)]),
  ])

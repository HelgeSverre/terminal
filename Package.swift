// swift-tools-version: 6.0
import PackageDescription

// Compiles the app, its launcher and the developer tool, and builds the test
// suites. `just build` assembles the app bundle around the compiled program.
let bridgingHeader = Context.packageDirectory + "/Sources/Terminal/Interop/Bridge.h"

// Code that only the tests reach is compiled in when the suites are built
// (`just unit-test` sets the variable) and left out of the app.
let testHooks: [SwiftSetting] = Context.environment["TERMINAL_TEST_HOOKS"] == nil ? [] : [
  .define("SESSION_IO_TESTING"), .define("GLYPH_RESIDENCY_TESTING"), .define("SNAPSHOT_ABI_DIAGNOSTICS"),
]

let package = Package(
  name: "Terminal",
  platforms: [.macOS(.v15)],
  targets: [
    .target(
      name: "TerminalInterop", path: "Sources/Terminal/Interop", publicHeadersPath: ".",
      cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]),
    .executableTarget(
      name: "TerminalApp",
      dependencies: ["TerminalInterop"],
      path: "Sources/Terminal",
      exclude: ["Interop"],
      swiftSettings: [
        .swiftLanguageMode(.v5),
        .unsafeFlags(["-import-objc-header", bridgingHeader, "-disable-bridging-pch"]),
      ] + testHooks),
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
      dependencies: ["TerminalApp", "TerminalLauncher"],
      path: "Tests/TerminalTests",
      swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-import-objc-header", bridgingHeader, "-disable-bridging-pch"])]),
  ])

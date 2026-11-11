// swift-tools-version: 6.0
import PackageDescription

// Builds the app's sources for the test suite: `swift test`. The app bundle
// itself is still built by `just build`.
let bridgingHeader = Context.packageDirectory + "/Sources/Terminal/Interop/Bridge.h"

let package = Package(
  name: "Terminal",
  platforms: [.macOS(.v15)],
  targets: [
    .target(name: "TerminalInterop", path: "Sources/Terminal/Interop", publicHeadersPath: "."),
    .executableTarget(
      name: "TerminalApp",
      dependencies: ["TerminalInterop"],
      path: "Sources/Terminal",
      exclude: ["Interop"],
      swiftSettings: [
        .swiftLanguageMode(.v5),
        .unsafeFlags(["-import-objc-header", bridgingHeader, "-disable-bridging-pch"]),
        .define("SESSION_IO_TESTING"), .define("GLYPH_RESIDENCY_TESTING"), .define("SNAPSHOT_ABI_DIAGNOSTICS"),
      ]),
    // The helper every PTY child is started through.
    .executableTarget(name: "TerminalLauncher", path: "Sources/TerminalLauncher"),
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

// swift-tools-version: 6.0
import PackageDescription

// Two hosts built only from the package's public interface: a window with
// a login shell, and a window that replays a recording through a transport. See docs/embedding.md.
let package = Package(
  name: "EmbeddingExample",
  platforms: [.macOS(.v14)],
  dependencies: [.package(name: "Terminal", path: "../..")],
  targets: [
    .executableTarget(
      name: "EmbeddingExample",
      dependencies: [
        .product(name: "TerminalUI", package: "Terminal"),
        .product(name: "TerminalHost", package: "Terminal"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    // A terminal with no process: a transport replays a recording into it.
    .executableTarget(
      name: "ReplayExample",
      dependencies: [
        .product(name: "TerminalUI", package: "Terminal"),
        .product(name: "TerminalHost", package: "Terminal"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]),
  ])

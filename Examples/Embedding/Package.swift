// swift-tools-version: 6.0
import PackageDescription

// A window with one terminal in it, built only from the package's public
// interface. See docs/embedding.md.
let package = Package(
  name: "EmbeddingExample",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "Terminal", path: "../..")],
  targets: [
    .executableTarget(
      name: "EmbeddingExample",
      dependencies: [
        .product(name: "TerminalView", package: "Terminal"),
        .product(name: "TerminalSession", package: "Terminal"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)])
  ])

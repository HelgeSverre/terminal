// swift-tools-version: 6.2
import PackageDescription

// Two minimal hosts that run one command in one terminal view and exit when
// it ends: one embeds this package, one embeds SwiftTerm. They exist so the
// PTY driver in Benchmarks/TerminalBench can measure both libraries the way
// an embedding app gets them. See reports/swiftterm-throughput-2026-11-14.
let package = Package(
  name: "EmbeddedHosts",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(name: "Terminal", path: "../.."),
    // The newest release. It needs a one-line edit to compile with Swift
    // 6.2.4; the report's README says which.
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"),
  ],
  targets: [
    .executableTarget(
      name: "OursHost",
      dependencies: [
        .product(name: "TerminalView", package: "Terminal"),
        .product(name: "TerminalSession", package: "Terminal"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(
      name: "SwiftTermHost",
      dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
      swiftSettings: [.swiftLanguageMode(.v5)]),
  ])

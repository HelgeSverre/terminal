// swift-tools-version: 6.0
import PackageDescription

// Two hosts built only from the package's public interface: a window with
// a login shell, and a window that replays a recording through a transport. See docs/embedding.md.
// The qualification runner clears TERMINAL_DEVELOPMENT, including for the
// dependency manifest. Optional URL/revision exercise the same public hosts.
let terminal: Package.Dependency = {
  if let url = Context.environment["TERMINAL_EMBEDDING_URL"],
     let revision = Context.environment["TERMINAL_EMBEDDING_REVISION"] {
    return .package(name: "Terminal", url: url, revision: revision)
  }
  return .package(name: "Terminal", path: "../..")
}()
let package = Package(
  name: "EmbeddingExample",
  platforms: [.macOS(.v14)],
  dependencies: [terminal],
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

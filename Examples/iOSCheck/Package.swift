// swift-tools-version: 6.0
import PackageDescription

// Runs the terminal view on the iOS simulator:
//   xcodebuild test -scheme iOSCheck-Package -destination 'platform=iOS Simulator,id=<udid>'
// See docs/embedding.md.
let package = Package(
  name: "iOSCheck",
  platforms: [.iOS(.v17), .macOS(.v14)],
  dependencies: [.package(name: "Terminal", path: "../..")],
  targets: [
    .target(name: "iOSCheck", dependencies: [
      .product(name: "TerminalUI", package: "Terminal"), .product(name: "TerminalHost", package: "Terminal"),
    ]),
    .testTarget(name: "iOSCheckTests", dependencies: ["iOSCheck"]),
  ])

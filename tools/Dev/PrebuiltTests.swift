import Foundation

/// Invoke the toolchain's Swift Testing helper against immutable build products.
/// Two `swift test --skip-build` commands still contend for SwiftPM's workspace
/// lock. The helper runs only tests; it cannot resolve packages or rebuild.
enum PrebuiltTests {
  struct Runner {
    let helper: String
    let bundle: String
    let environment: [String: String?]

    func arguments(_ options: [String]) -> [String] {
      [helper, "--test-bundle-path", bundle, "--testing-library", "swift-testing", "--no-parallel"] + options
    }
  }

  static func runner(products: String) throws -> Runner {
    let swift = try runCommand(["/usr/bin/xcrun", "--find", "swift"])
    let platform = try runCommand(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-platform-path"])
    guard swift.succeeded, platform.succeeded else { throw Failure("cannot locate the test toolchain") }
    return try runner(products: products, swift: swift.output.trimmingCharacters(in: .whitespacesAndNewlines),
                      platform: platform.output.trimmingCharacters(in: .whitespacesAndNewlines),
                      environment: ProcessInfo.processInfo.environment)
  }

  static func runner(products: String, swift: String, platform: String,
                     environment: [String: String]) throws -> Runner {
    let toolchain = URL(fileURLWithPath: swift).deletingLastPathComponent().deletingLastPathComponent().path
    let helper = toolchain + "/libexec/swift/pm/swiftpm-testing-helper"
    let bundle = products + "/TerminalPackageTests.xctest/Contents/MacOS/TerminalPackageTests"
    guard FileManager.default.isExecutableFile(atPath: helper), FileManager.default.fileExists(atPath: bundle) else {
      throw Failure("missing prebuilt Swift Testing helper or bundle; run just test with the selected toolchain")
    }
    func appended(_ key: String, _ paths: [String]) -> String {
      ([environment[key]].compactMap { $0 }.filter { !$0.isEmpty } + paths).joined(separator: ":")
    }
    // Match SwiftPM's macOS test runtime search paths, preserving overrides.
    return Runner(helper: helper, bundle: bundle, environment: [
      "NO_COLOR": "1",
      "DYLD_FRAMEWORK_PATH": appended("DYLD_FRAMEWORK_PATH", [platform + "/Developer/Library/Frameworks"]),
      "DYLD_LIBRARY_PATH": appended("DYLD_LIBRARY_PATH", [platform + "/Developer/usr/lib",
        toolchain + "/lib/swift/macosx"]),
    ])
  }
}

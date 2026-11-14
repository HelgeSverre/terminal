import Foundation
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

/// Where the tests find what the package built beside them.
enum TestEnvironment {
  /// The directory holding the built products, found from the test bundle.
  static let products = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()
  /// Lives in the test bundle, so its bundle is the test bundle.
  private final class Anchor {}

  /// The repository checkout, for fixtures that live beside the sources.
  static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// The launcher a session starts its child through.
  static let launcher = products.appendingPathComponent("TerminalLauncher").path

  /// A `/bin/sh -c` child in `/tmp`.
  static func shell(_ script: String) -> LaunchSpec {
    LaunchSpec(executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], cwd: "/tmp", launcher: launcher)
  }

  /// Waits until `condition` holds or `seconds` pass, and returns whether it
  /// held. The wait suspends, so work queued on the main thread runs
  /// meanwhile: under `swift test` the main run loop cannot be spun from
  /// inside a test.
  @MainActor static func wait(seconds: TimeInterval = 8, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
  }
}

/// Defaults that live in memory. A real suite, even one removed again, leaves
/// a file in `~/Library/Preferences`: the preferences daemon writes an empty
/// one back some seconds after the test deletes it.
final class MemoryDefaults: UserDefaults {
  private var values: [String: Any] = [:]

  init() { super.init(suiteName: nil)! }

  override func object(forKey key: String) -> Any? { values[key] }
  override func set(_ value: Any?, forKey key: String) { values[key] = value }
  override func removeObject(forKey key: String) { values[key] = nil }
}

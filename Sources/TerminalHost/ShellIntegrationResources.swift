import Foundation

private final class ShellIntegrationResourceAnchor {}

/// The package's shell hooks, for a host packaging or configuring a launcher.
/// Libraries use their own resource bundle; the host's main bundle is never inspected.
public enum TerminalShellIntegration {
  /// Root containing `zsh`, `bash` and `fish`. Nil if a manually linked host
  /// omitted resources; SwiftPM copies this directory automatically.
  public static var directory: URL? {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle(for: ShellIntegrationResourceAnchor.self)
    #endif
    guard let url = bundle.url(forResource: "ShellIntegration", withExtension: nil),
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }
}

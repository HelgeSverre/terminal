import Foundation
import TerminalHost

extension LaunchSpec {
  func withResumeFile(_ url: URL?) -> Self {
    guard let url else { return self }
    var environment = environment
    environment["HELGE_TERMINAL_RESUME_FILE"] = url.path
    return LaunchSpec(executable: executable, arguments: arguments, cwd: cwd, launcher: launcher, environment: environment)
  }
}

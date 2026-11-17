import Foundation

extension LaunchSpec {
  /// Only implicit interactive shells are augmented. Explicit command and
  /// startup flags retain exactly the semantics the caller requested.
  package func preparedShellIntegration() -> (arguments: [String], environment: [String: String]) {
    var environment = environment
    guard arguments.count == 1 || arguments == [arguments.first ?? "", "-l"] else {
      return (arguments, environment)
    }
    let launcherDirectory = launcher.map {
      URL(fileURLWithPath: $0).deletingLastPathComponent()
        .appendingPathComponent("../Resources/ShellIntegration").standardizedFileURL.path
    }
    let directory = shellIntegrationDirectory ?? launcherDirectory.flatMap {
      FileManager.default.fileExists(atPath: $0) ? $0 : nil
    } ?? TerminalShellIntegration.directory?.path
    guard let directory, directory.hasPrefix("/") else { return (arguments, environment) }
    let shell = URL(fileURLWithPath: executable).lastPathComponent
    func readable(_ suffix: String) -> Bool {
      FileManager.default.isReadableFile(atPath: directory + "/" + suffix)
    }
    switch shell {
    case "zsh" where readable("zsh/.zshenv"):
      environment["HELGE_TERMINAL_INTEGRATION_DIRECTORY"] = directory
    case "bash" where arguments.count == 1 && readable("bash/rc.bash"):
      environment["HELGE_TERMINAL_INTEGRATION_DIRECTORY"] = directory
      return ([arguments[0], "--rcfile", directory + "/bash/rc.bash", "-i"], environment)
    case "fish" where readable("fish/hooks.fish"):
      environment["HELGE_TERMINAL_INTEGRATION_DIRECTORY"] = directory
      // The path is expanded as a quoted variable by fish, never as code.
      return (arguments + ["--init-command", "source \"$HELGE_TERMINAL_INTEGRATION_DIRECTORY/fish/hooks.fish\""], environment)
    default: break
    }
    return (arguments, environment)
  }
}

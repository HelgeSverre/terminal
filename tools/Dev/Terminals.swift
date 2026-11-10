import Foundation

/// A terminal the comparisons launch, and how to launch a disposable instance
/// of it that restores nothing and asks no questions.
struct Terminal {
  let name: String
  let executable: String
  /// Arguments for an instance running its default shell.
  var bare: [String] = []
  /// Arguments that run the stamp child writing to the given path, or nil
  /// when the terminal cannot be given a command this way.
  var command: ((_ stamp: String, _ output: String) -> [String])? = nil
  /// A second instance would join or disturb one the user has open, so the
  /// terminal is skipped while it is running.
  var sharesInstance = false

  /// The terminals that can be measured now, and why the others cannot.
  /// Writes the configuration files the launches refer to into `output`.
  static func available(app: String, output: OutputDirectory) throws -> (measured: [Terminal], skipped: [String: String]) {
    let ghosttyConfiguration = output.file("ghostty.conf")
    try """
      window-save-state = never
      quit-after-last-window-closed = true
      confirm-close-surface = false
      shell-integration = none

      """.write(toFile: ghosttyConfiguration, atomically: true, encoding: .utf8)
    let ghostty = ["--config-default-files=false", "--config-file=" + ghosttyConfiguration]
    let kitty = ["--config", "NONE", "--session", "none", "-o", "confirm_os_window_close=0",
                 "-o", "macos_quit_when_last_window_closed=yes"]
    let all = [
      Terminal(name: "terminal", executable: app + "/Contents/MacOS/Terminal") { stamp, output in
        ["--first-frame-file", output + ".frame", "--exit-after-command", "--execute", stamp, output]
      },
      Terminal(name: "ghostty", executable: "/Applications/Ghostty.app/Contents/MacOS/ghostty", bare: ghostty) {
        ghostty + ["-e", $0, $1]
      },
      Terminal(name: "kitty", executable: "/Applications/kitty.app/Contents/MacOS/kitty", bare: kitty) {
        kitty + [$0, $1]
      },
      Terminal(name: "iterm2", executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2", sharesInstance: true),
      Terminal(name: "apple_terminal",
               executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
               sharesInstance: true),
    ]
    var skipped: [String: String] = [:]
    let measured = all.filter { terminal in
      if !FileManager.default.isExecutableFile(atPath: terminal.executable) {
        skipped[terminal.name] = "not installed"
      } else if terminal.sharesInstance, isRunning(executable: terminal.executable) {
        skipped[terminal.name] = "already running; left alone"
      }
      return skipped[terminal.name] == nil
    }
    return (measured, skipped)
  }
}

import Foundation
import TerminalHost

/// AppKit may treat unpaired command-line values as startup documents. Keep
/// values already owned by our CLI out of that synthetic handoff. Genuine
/// open-document Apple events and every event after launch retain normal
/// Finder/Toolbox behavior, even when their paths match a launch argument.
struct StartupTerminalFileFilter {
  private let claimedPaths: Set<String>
  private let directory: URL

  init(arguments: [String], currentDirectory: String) {
    let directory = URL(fileURLWithPath: currentDirectory, isDirectory: true)
    self.directory = directory
    var claimed = Set<String>()
    var explicitDocuments = Set<String>()
    let options = Self.optionValueCounts
    func path(_ text: String) -> String {
      URL(fileURLWithPath: text, relativeTo: directory).standardizedFileURL.path
    }
    var index = 1
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--execute" {
        for value in arguments[index...] { claimed.insert(path(value)) }
        break
      }
      if ["-NSOpen", "-NSOpenTemp"].contains(argument), index + 1 < arguments.count {
        explicitDocuments.insert(path(arguments[index + 1]))
        index += 2
        continue
      }
      guard let count = options[argument] else { index += 1; continue }
      claimed.insert(path(argument))
      index += 1
      for _ in 0..<count {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else { break }
        claimed.insert(path(arguments[index]))
        index += 1
      }
    }
    claimedPaths = claimed.subtracting(explicitDocuments)
  }

  func documents(from filenames: [String], duringStartup: Bool, currentEvent: NSAppleEventDescriptor?) -> [String] {
    // 'aevt'/'odoc' is an actual open-document Apple event, not finishLaunching's
    // synthetic opening of command-line/NSOpen values. Never filter it by path.
    guard duringStartup,
      !(currentEvent?.eventClass == 0x61657674 && currentEvent?.eventID == 0x6f646f63) else { return filenames }
    return filenames.filter {
      !claimedPaths.contains(URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL.path)
    }
  }

  private static var optionValueCounts: [String: Int] {
    var options = ["--background": 0, "--working-directory": 1, "--state-directory": 1,
      "--handoff-directory": 1,
      "--font-size": 1, "--history-limit": 1, "--columns": 1, "--rows": 1]
    #if TERMINAL_DIAGNOSTICS
    for option in ["--self-test", "--editing-smoke", "--glyph-smoke", "--close-smoke", "--demo-smoke",
      "--resize-smoke", "--intense-resize-smoke", "--selection-smoke", "--pane-lifecycle-smoke",
      "--font-catalog", "--first-frame-file", "--session-statistics-file", "--handoff-smoke"] { options[option] = 1 }
    options["--cat-smoke"] = 2
    for option in ["--atlas-pressure-smoke", "--atlas-fallback-budget-smoke", "--cat-motion-stress",
      "--idle-test", "--keep-open", "--mute", "--quit-shortcut", "--smoke-stream", "--exit-after-command"] {
      options[option] = 0
    }
    #endif
    return options
  }
}

/// Launch Services sends a file, not shell source. Pass its path as an argv
/// element so spaces, quotes and shell metacharacters remain literal. The
/// executable's shebang selects its interpreter, just as a direct launch does.
enum OpenTerminalFile {
  static func launch(path: String, launcher: String?) throws -> LaunchSpec {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path,
        NSLocalizedDescriptionKey: "Only executable files can be opened in Terminal."])
    }
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path,
        NSLocalizedDescriptionKey: "The file “\(url.lastPathComponent)” is not executable.",
        NSLocalizedRecoverySuggestionErrorKey: "Give the file execute permission before opening it in Terminal."])
    }
    return LaunchSpec(executable: url.path, arguments: [url.path],
      cwd: url.deletingLastPathComponent().path, launcher: launcher)
  }
}

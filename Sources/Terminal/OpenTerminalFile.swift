import Foundation
import TerminalHost

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

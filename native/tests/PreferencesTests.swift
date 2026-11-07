import Foundation

@main struct PreferencesTests {
  static func main() throws {
    func edited(_ path: String, size: String = "14", history: String = "50000") throws -> TerminalPreferences {
      try TerminalPreferences.edited(fontSize: size, historyRows: history,
        optionSendsEscape: false, followTailOnInput: true, startingDirectory: path)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let blank = try edited("")
    let tilde = try edited("~")
    let slash = try edited("~/")
    precondition(blank.startingDirectory == home)
    precondition(tilde.startingDirectoryText == "~")
    precondition(slash.launchDirectory == home)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal settings \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let value = try edited(folder.path, size: "14.5", history: "0")
    precondition(value.fontSize == 14.5 && value.session.historyRows == 0)
    precondition(value.startingDirectory == folder.standardizedFileURL.path)
    precondition(value.launchDirectory == folder.standardizedFileURL.path)
    for (path, size, history) in [("relative", "14", "10"), (folder.path + "/missing", "14", "10"),
      (home, "nan", "10"), (home, "41", "10"), (home, "14", "-1"), (home, "14", "50001")] {
      do { _ = try edited(path, size: size, history: history); preconditionFailure("invalid preferences accepted") }
      catch is TerminalPreferences.ValidationError {}
    }
    let file = folder.appendingPathComponent("not-a-folder")
    try Data().write(to: file)
    do { _ = try edited(file.path); preconditionFailure("file accepted as directory") }
    catch TerminalPreferences.ValidationError.directory {}
    try FileManager.default.removeItem(at: folder)
    precondition(value.launchDirectory == home) // A saved folder may disappear later.
    print("PASS preferences: home, tilde, absolute folders/spaces, fractional size, bounds, invalid paths and file rejection")
  }
}

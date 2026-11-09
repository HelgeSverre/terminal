import Foundation

@main struct PreferencesTests {
  static func main() throws {
    func edited(_ path: String, size: String = "14", history: String = "50000",
                words: String = TerminalSelectionWordProfile.standard.punctuation) throws -> TerminalPreferences {
      try TerminalPreferences.edited(fontSize: size, historyRows: history,
        optionSendsEscape: false, followTailOnInput: true, startingDirectory: path,
        selectionWordCharacters: words)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let blank = try edited("")
    let tilde = try edited("~")
    let slash = try edited("~/")
    precondition(blank.startingDirectory == home)
    precondition(tilde.startingDirectoryText == "~")
    precondition(slash.launchDirectory == home)
    let customWords = try edited("", words: "//_猫/")
    precondition(customWords.selectionWordProfile.punctuation == "/_猫")
    precondition(customWords.session.selectionWordProfile == customWords.selectionWordProfile)
    let unicodeWords = try edited("", words: "")
    precondition(unicodeWords.selectionWordProfile.punctuation.isEmpty)
    let encodedProfile = try JSONEncoder().encode(customWords.selectionWordProfile)
    let decodedProfile = try JSONDecoder().decode(TerminalSelectionWordProfile.self, from: encodedProfile)
    precondition(decodedProfile == customWords.selectionWordProfile)
    for invalid in [" ", "x\ny", "\u{1b}", String(repeating: "x", count: 65)] {
      do { _ = try edited("", words: invalid); preconditionFailure("invalid word characters accepted") }
      catch TerminalPreferences.ValidationError.wordCharacters {}
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal settings \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let value = try edited(folder.path, size: "14.5", history: "0")
    precondition(value.fontSize == 14.5 && value.session.historyRows == 0)
    precondition(value.startingDirectory == folder.standardizedFileURL.path)
    precondition(value.launchDirectory == folder.standardizedFileURL.path)
    let location = URL(fileURLWithPath: folder.path).absoluteString
    precondition(blank.launchDirectory(inheriting: location) == folder.standardizedFileURL.path)
    precondition(blank.launchDirectory(inheriting: location.replacingOccurrences(of: "file:///", with: "file://localhost/")) == folder.standardizedFileURL.path)
    for invalid in [nil, "", "relative", "https://localhost/tmp", "file://remote.invalid/tmp",
      "file://user@localhost/tmp", "file:///tmp?query", "file:///tmp#fragment", "file:///tmp/%00",
      "file:///not-a-real-terminal-directory-\(UUID().uuidString)"] as [String?] {
      precondition(blank.launchDirectory(inheriting: invalid) == blank.launchDirectory)
    }
    for (path, size, history) in [("relative", "14", "10"), (folder.path + "/missing", "14", "10"),
      (home, "nan", "10"), (home, "41", "10"), (home, "14", "-1"), (home, "14", "50001")] {
      do { _ = try edited(path, size: size, history: history); preconditionFailure("invalid preferences accepted") }
      catch is TerminalPreferences.ValidationError {}
    }
    let file = folder.appendingPathComponent("not-a-folder")
    let special = folder.appendingPathComponent("project 猫 #%")
    try FileManager.default.createDirectory(at: special, withIntermediateDirectories: false)
    let hooks = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("native/ShellIntegration/zsh/hooks.zsh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-f", "-c", "source \"$1\"; _helge_terminal_report_directory", "fixture", hooks.path]
    process.currentDirectoryURL = special
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let report = String(decoding: output, as: UTF8.self)
    precondition(process.terminationStatus == 0 && report.hasPrefix("\u{001b}]7;file://localhost/") &&
      report.hasSuffix("/project%20%E7%8C%AB%20%23%25\u{0007}"), "Incorrect OSC7 encoding: \(report.debugDescription)")
    let reportedLocation = String(report.dropFirst(4).dropLast())
    let actualDirectory = blank.launchDirectory(inheriting: reportedLocation)
    let actualIdentity = try FileManager.default.attributesOfItem(atPath: actualDirectory)
    let expectedIdentity = try FileManager.default.attributesOfItem(atPath: special.path)
    precondition(actualIdentity[.systemFileNumber] as? NSNumber == expectedIdentity[.systemFileNumber] as? NSNumber)
    try Data().write(to: file)
    do { _ = try edited(file.path); preconditionFailure("file accepted as directory") }
    catch TerminalPreferences.ValidationError.directory {}
    try FileManager.default.removeItem(at: folder)
    precondition(value.launchDirectory == home) // A saved folder may disappear later.
    print("PASS preferences: home, tilde, absolute folders/spaces, fractional size, bounds, invalid paths and file rejection")
  }
}

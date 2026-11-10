import AppKit
import Foundation

@main struct PreferencesTests {
  static func main() throws {
    func edited(_ path: String, size: String = "14", history: String = "50000",
                words: String = TerminalSelectionWordProfile.standard.punctuation,
                showPaneTitles: Bool = true, inactivePaneDim: PaneInactiveDim = .five) throws -> TerminalPreferences {
      try TerminalPreferences.edited(fontSize: size, historyRows: history,
        optionSendsEscape: false, followTailOnInput: true, startingDirectory: path,
        selectionWordCharacters: words, showPaneTitles: showPaneTitles, inactivePaneDim: inactivePaneDim)
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
    let hooks = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Terminal/ShellIntegration/zsh/hooks.zsh")
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
    let suite = "no.helgesverre.terminal.preferences-tests.\(UUID().uuidString)"
    let isolatedDefaults = UserDefaults(suiteName: suite)!
    defer { isolatedDefaults.removePersistentDomain(forName: suite) }
    precondition(TerminalPreferences.load(from: isolatedDefaults).showPaneTitles)
    precondition(TerminalPreferences.load(from: isolatedDefaults).inactivePaneDim == .five)
    let presentationPreferences = try TerminalPreferences.edited(
      fontSize: "14", historyRows: "120", optionSendsEscape: true, followTailOnInput: false,
      startingDirectory: folder.path, selectionWordCharacters: "-_",
      showPaneTitles: false, inactivePaneDim: .ten)
    presentationPreferences.save(to: isolatedDefaults)
    let restoredPresentationPreferences = TerminalPreferences.load(from: isolatedDefaults)
    precondition(!restoredPresentationPreferences.showPaneTitles)
    precondition(restoredPresentationPreferences.inactivePaneDim == .ten)
    precondition(restoredPresentationPreferences.optionSendsEscape)
    let changedFontKeepingPresentation = try TerminalPreferences.edited(
      fontSize: "16", historyRows: String(restoredPresentationPreferences.historyRows),
      optionSendsEscape: restoredPresentationPreferences.optionSendsEscape,
      followTailOnInput: restoredPresentationPreferences.followTailOnInput,
      startingDirectory: restoredPresentationPreferences.startingDirectory,
      selectionWordCharacters: restoredPresentationPreferences.selectionWordProfile.punctuation,
      showPaneTitles: restoredPresentationPreferences.showPaneTitles,
      inactivePaneDim: restoredPresentationPreferences.inactivePaneDim)
    precondition(!changedFontKeepingPresentation.showPaneTitles && changedFontKeepingPresentation.inactivePaneDim == .ten)

    precondition(PaneColorChoice.palette.count == 16)
    precondition(Set(PaneColorChoice.palette.map(\.name)).count == 16)
    precondition(PaneChromeColor(hex: "#f08")?.hex == "#FF0088")
    precondition(PaneChromeColor(hex: " #2c6a65 ")?.hex == "#2C6A65")
    for invalidHex in ["2C6A65", "#12", "#1234", "#00112233", "#GG0011"] {
      precondition(PaneChromeColor(hex: invalidHex) == nil, "accepted invalid pane color \(invalidHex)")
    }
    precondition(PaneChromeColor(hex: "#101010")?.readableForeground == .white)
    precondition(PaneChromeColor(hex: "#F0F0F0")?.readableForeground == .black)
    let viewport = NSView(frame: .zero)
    let panePresentation = TerminalPanePresentationView(canvas: viewport)
    panePresentation.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
    panePresentation.configure(showHeader: true, active: false, inactiveDim: .five)
    panePresentation.layoutSubtreeIfNeeded()
    precondition(panePresentation.minimumSize == NSSize(width: 200, height: 140))
    precondition(viewport.frame == NSRect(x: 0, y: 20, width: 320, height: 200))
    precondition(abs(viewport.alphaValue - 0.95) < 0.001)
    func headerSubview(_ identifier: String) -> NSView? {
      panePresentation.subviews.flatMap(\.subviews).first { $0.accessibilityIdentifier() == identifier }
    }
    guard let title = headerSubview("no.helgesverre.terminal.pane-title") as? NSTextField,
      let close = headerSubview("no.helgesverre.terminal.pane.close") as? NSButton
    else { preconditionFailure("pane header lacks its title or close button") }
    precondition(headerSubview("no.helgesverre.terminal.pane.choose-color") == nil)
    // A label draws from the top of its frame, so the frame must hug the text.
    precondition(title.frame.height == ceil(title.cell!.cellSize.height)
      && abs(title.frame.midY - TerminalPanePresentationView.headerHeight / 2) <= 0.5,
      "pane title is not vertically centered: \(title.frame)")
    precondition(abs(close.frame.midY - TerminalPanePresentationView.headerHeight / 2) <= 0.5)
    precondition(close.frame.maxX <= 320 && close.frame.maxX >= 312 && title.frame.maxX < close.frame.minX)
    var closed = 0
    panePresentation.onClose = { closed += 1 }
    close.performClick(nil)
    precondition(closed == 1)
    for dim in [PaneInactiveDim.twenty, .fifty] {
      precondition(PaneInactiveDim(storedValue: dim.rawValue) == dim)
      panePresentation.configure(showHeader: true, active: false, inactiveDim: dim)
      precondition(abs(viewport.alphaValue - (1 - CGFloat(dim.rawValue) / 100)) < 0.001)
    }
    precondition(PaneInactiveDim.allCases.map(\.label) == ["Off", "5%", "10%", "20%", "50%"])
    panePresentation.configure(showHeader: false, active: true, inactiveDim: .ten)
    panePresentation.layoutSubtreeIfNeeded()
    precondition(panePresentation.minimumSize == NSSize(width: 200, height: 120))
    precondition(viewport.frame == NSRect(x: 0, y: 0, width: 320, height: 220))
    precondition(abs(viewport.alphaValue - 1) < 0.001)
    try FileManager.default.removeItem(at: folder)
    precondition(value.launchDirectory == home) // A saved folder may disappear later.
    print("PASS preferences: home, tilde, paths, pane settings, private defaults, color validation and viewport geometry")
  }
}

import AppKit
import Foundation
import Testing
@testable import TerminalApp

/// Serialized as a precaution: preferences persist through UserDefaults. The
/// tests use a private suite and never touch the user's standard defaults.
@Suite(.serialized) @MainActor enum PreferencesTests {
  static func edited(_ path: String, size: String = "14", history: String = "50000",
              words: String = TerminalSelectionWordProfile.standard.punctuation,
              showPaneTitles: Bool = true, inactivePaneDim: PaneInactiveDim = .five) throws -> TerminalPreferences {
    try TerminalPreferences.edited(fontSize: size, historyRows: history,
      optionSendsEscape: false, followTailOnInput: true, startingDirectory: path,
      selectionWordCharacters: words, showPaneTitles: showPaneTitles, inactivePaneDim: inactivePaneDim,
      defaultPaneColor: .standard)
  }

  /// SidePulse is off until enabled, and the choice persists both ways.
  @Test static func sidePulseDefaultsOffAndPersists() {
    let suite = "sidepulse-preferences-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!TerminalPreferences.load(from: defaults).sidePulseEnabled)
    var prefs = TerminalPreferences.load(from: defaults)
    prefs.sidePulseEnabled = true
    prefs.save(to: defaults)
    #expect(TerminalPreferences.load(from: defaults).sidePulseEnabled)
    prefs.sidePulseEnabled = false
    prefs.save(to: defaults)
    #expect(!TerminalPreferences.load(from: defaults).sidePulseEnabled)
  }

  /// Home, tilde, launch directories, word characters, OSC 7 reporting and
  /// rejection of invalid editor input.
  @Test static func directoriesAndValidation() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let blank = try edited("")
    let tilde = try edited("~")
    let slash = try edited("~/")
    #expect(blank.startingDirectory == home)
    #expect(tilde.startingDirectoryText == "~")
    #expect(slash.launchDirectory == home)
    let customWords = try edited("", words: "//_猫/")
    #expect(customWords.selectionWordProfile.punctuation == "/_猫")
    #expect(customWords.session.selectionWordProfile == customWords.selectionWordProfile)
    let unicodeWords = try edited("", words: "")
    #expect(unicodeWords.selectionWordProfile.punctuation.isEmpty)
    let encodedProfile = try JSONEncoder().encode(customWords.selectionWordProfile)
    let decodedProfile = try JSONDecoder().decode(TerminalSelectionWordProfile.self, from: encodedProfile)
    #expect(decodedProfile == customWords.selectionWordProfile)
    for invalid in [" ", "x\ny", "\u{1b}", String(repeating: "x", count: 65)] {
      do { _ = try edited("", words: invalid); Issue.record("invalid word characters accepted") }
      catch TerminalPreferences.ValidationError.wordCharacters {}
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal settings \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let value = try edited(folder.path, size: "14.5", history: "0")
    #expect(value.fontSize == 14.5 && value.session.historyRows == 0)
    #expect(value.startingDirectory == folder.standardizedFileURL.path)
    #expect(value.launchDirectory == folder.standardizedFileURL.path)
    let location = URL(fileURLWithPath: folder.path).absoluteString
    #expect(blank.launchDirectory(inheriting: location) == folder.standardizedFileURL.path)
    #expect(blank.launchDirectory(inheriting: location.replacingOccurrences(of: "file:///", with: "file://localhost/")) == folder.standardizedFileURL.path)
    for invalid in [nil, "", "relative", "https://localhost/tmp", "file://remote.invalid/tmp",
      "file://user@localhost/tmp", "file:///tmp?query", "file:///tmp#fragment", "file:///tmp/%00",
      "file:///not-a-real-terminal-directory-\(UUID().uuidString)"] as [String?] {
      #expect(blank.launchDirectory(inheriting: invalid) == blank.launchDirectory)
    }
    for (path, size, history) in [("relative", "14", "10"), (folder.path + "/missing", "14", "10"),
      (home, "nan", "10"), (home, "41", "10"), (home, "14", "-1"), (home, "14", "50001")] {
      do { _ = try edited(path, size: size, history: history); Issue.record("invalid preferences accepted") }
      catch is TerminalPreferences.ValidationError {}
    }
    let file = folder.appendingPathComponent("not-a-folder")
    let special = folder.appendingPathComponent("project 猫 #%")
    try FileManager.default.createDirectory(at: special, withIntermediateDirectories: false)
    let hooks = TestEnvironment.repository.appendingPathComponent("Resources/Terminal/ShellIntegration/zsh/hooks.zsh")
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
    #expect(process.terminationStatus == 0 && report.hasPrefix("\u{001b}]7;file://localhost/") &&
      report.hasSuffix("/project%20%E7%8C%AB%20%23%25\u{0007}"), "Incorrect OSC7 encoding: \(report.debugDescription)")
    for (command, expected) in [("true", "0"), ("false", "1")] {
      let statusProcess = Process()
      statusProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
      statusProcess.arguments = ["-f", "-c", "source \"$1\"; \(command); _helge_terminal_precmd", "fixture", hooks.path]
      let statusPipe = Pipe()
      statusProcess.standardOutput = statusPipe
      try statusProcess.run()
      let statusOutput = statusPipe.fileHandleForReading.readDataToEndOfFile()
      statusProcess.waitUntilExit()
      precondition(String(decoding: statusOutput, as: UTF8.self).contains("\u{001b}]133;D;\(expected)\u{0007}"))
    }
    let reportedLocation = String(report.dropFirst(4).dropLast())
    let actualDirectory = blank.launchDirectory(inheriting: reportedLocation)
    let actualIdentity = try FileManager.default.attributesOfItem(atPath: actualDirectory)
    let expectedIdentity = try FileManager.default.attributesOfItem(atPath: special.path)
    #expect(actualIdentity[.systemFileNumber] as? NSNumber == expectedIdentity[.systemFileNumber] as? NSNumber)
    try Data().write(to: file)
    do { _ = try edited(file.path); Issue.record("file accepted as directory") }
    catch TerminalPreferences.ValidationError.directory {}
    try FileManager.default.removeItem(at: folder)
    #expect(value.launchDirectory == home) // A saved folder may disappear later.
  }

  /// Private defaults: pane presentation settings round-trip and bad values fall back.
  @Test static func privateDefaultsAndPresentation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal settings \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let suite = "no.helgesverre.terminal.preferences-tests.\(UUID().uuidString)"
    let isolatedDefaults = UserDefaults(suiteName: suite)!
    defer { isolatedDefaults.removePersistentDomain(forName: suite) }
    #expect(TerminalPreferences.load(from: isolatedDefaults).showPaneTitles)
    #expect(TerminalPreferences.load(from: isolatedDefaults).inactivePaneDim == .five)
    // Panes start in the darkest palette color until the preference says otherwise.
    func brightness(_ color: PaneChromeColor) -> Int { Int(color.red) + Int(color.green) + Int(color.blue) }
    let darkest = PaneColorChoice.palette.map(\.color).min { brightness($0) < brightness($1) }
    #expect(PaneChromeColor.standard == darkest && PaneChromeColor.standard.hex == "#18191C")
    #expect(TerminalPreferences.load(from: isolatedDefaults).defaultPaneColor == .standard)
    let presentationPreferences = try TerminalPreferences.edited(
      fontSize: "14", historyRows: "120", optionSendsEscape: true, followTailOnInput: false,
      startingDirectory: folder.path, selectionWordCharacters: "-_",
      showPaneTitles: false, inactivePaneDim: .ten, defaultPaneColor: PaneChromeColor(hex: "#2B6A65")!)
    presentationPreferences.save(to: isolatedDefaults)
    let restoredPresentationPreferences = TerminalPreferences.load(from: isolatedDefaults)
    #expect(restoredPresentationPreferences.defaultPaneColor.hex == "#2B6A65")
    #expect(!restoredPresentationPreferences.showPaneTitles)
    #expect(restoredPresentationPreferences.inactivePaneDim == .ten)
    #expect(restoredPresentationPreferences.optionSendsEscape)
    let changedFontKeepingPresentation = try TerminalPreferences.edited(
      fontSize: "16", historyRows: String(restoredPresentationPreferences.historyRows),
      optionSendsEscape: restoredPresentationPreferences.optionSendsEscape,
      followTailOnInput: restoredPresentationPreferences.followTailOnInput,
      startingDirectory: restoredPresentationPreferences.startingDirectory,
      selectionWordCharacters: restoredPresentationPreferences.selectionWordProfile.punctuation,
      showPaneTitles: restoredPresentationPreferences.showPaneTitles,
      inactivePaneDim: restoredPresentationPreferences.inactivePaneDim,
      defaultPaneColor: restoredPresentationPreferences.defaultPaneColor)
    #expect(!changedFontKeepingPresentation.showPaneTitles && changedFontKeepingPresentation.inactivePaneDim == .ten)
    // A stored value that is not a color falls back instead of failing the load.
    isolatedDefaults.set("teal", forKey: "defaultPaneColor")
    #expect(TerminalPreferences.load(from: isolatedDefaults).defaultPaneColor == .standard)
  }

  /// The pane color palette: swatch layout, hex field, selection and color validation.
  @Test static func paneColorPalette() {
    #expect(PaneColorChoice.palette.count == 18)
    #expect(Set(PaneColorChoice.palette.map(\.name)).count == 18)
    // Square swatches fill complete rows, and the popover content is exactly
    // the grid plus its padding: no slack beside or below the swatches.
    let colorPalette = PaneColorPaletteView()
    colorPalette.layoutSubtreeIfNeeded()
    let swatches = colorPalette.subviews.flatMap(\.subviews).flatMap(\.subviews).compactMap { $0 as? NSButton }
    #expect(swatches.count == 18 && swatches.count % PaneColorPaletteView.columns == 0)
    #expect(swatches.allSatisfy { $0.frame.size == NSSize(width: 24, height: 24) })
    let paletteWidth: CGFloat = 198 // 6 swatches of 24, 5 gaps of 6, 12 padding each side
    #expect(colorPalette.frame.width == paletteWidth, "palette width \(colorPalette.frame.width)")
    let swatchEdges = swatches.map { colorPalette.convert($0.bounds, from: $0) }
    let swatchLeft: CGFloat = swatchEdges.map(\.minX).min() ?? 0
    let swatchRight: CGFloat = swatchEdges.map(\.maxX).max() ?? 0
    #expect(swatchLeft == 12 && swatchRight == paletteWidth - 12)
    guard let colorHex = colorPalette.subviews.flatMap(\.subviews).flatMap(\.subviews)
      .first(where: { $0.accessibilityIdentifier() == "no.helgesverre.terminal.pane.color.hex" })
    else { Issue.record("palette lacks its hex field"); return }
    let hexEdges = colorPalette.convert(colorHex.bounds, from: colorHex)
    #expect(hexEdges.maxX == paletteWidth - 12, "hex field does not share the grid edge")
    let hexMargin: CGFloat = min(hexEdges.minY, colorPalette.frame.height - hexEdges.maxY)
    #expect(hexMargin == 12, "hex row margin \(hexMargin)")
    var pickedColors: [String] = []
    colorPalette.onPick = { pickedColors.append($0.hex) }
    swatches[1].performClick(nil)
    #expect(pickedColors == ["#26272B"], "second swatch is the new darker gray")
    // The palette tracks its choice: a picked swatch or a valid typed hex.
    #expect(colorPalette.selected?.hex == "#26272B"
      && (colorHex as? NSTextField)?.stringValue == "#26272B")
    #expect(swatches[1].accessibilityValue() as? String == "selected"
      && swatches[0].accessibilityValue() as? String == "")
    colorPalette.selected = .standard
    #expect((colorHex as? NSTextField)?.stringValue == "#18191C"
      && swatches[0].accessibilityValue() as? String == "selected")
    #expect(PaneChromeColor(hex: "#f08")?.hex == "#FF0088")
    #expect(PaneChromeColor(hex: " #2c6a65 ")?.hex == "#2C6A65")
    for invalidHex in ["2C6A65", "#12", "#1234", "#00112233", "#GG0011"] {
      #expect(PaneChromeColor(hex: invalidHex) == nil, "accepted invalid pane color \(invalidHex)")
    }
    #expect(PaneChromeColor(hex: "#101010")?.readableForeground == .white)
    #expect(PaneChromeColor(hex: "#F0F0F0")?.readableForeground == .black)
  }

  /// Pane header, dimming, find bar and middle-click close.
  @Test static func panePresentationAndFindBar() throws {
    let viewport = NSView(frame: .zero)
    let panePresentation = TerminalPanePresentationView(canvas: viewport)
    panePresentation.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
    panePresentation.configure(showHeader: true, active: false, inactiveDim: .five, defaultColor: .standard)
    // A pane follows the default color until it is given its own.
    #expect(panePresentation.color == .standard)
    let teal = PaneChromeColor(hex: "#2B6A65")!
    panePresentation.configure(showHeader: true, active: false, inactiveDim: .five, defaultColor: teal)
    #expect(panePresentation.color == teal)
    panePresentation.choose(.charcoal)
    panePresentation.configure(showHeader: true, active: false, inactiveDim: .five, defaultColor: .standard)
    #expect(panePresentation.color == .charcoal, "a pane's own color must survive a default change")
    panePresentation.layoutSubtreeIfNeeded()
    #expect(panePresentation.minimumSize == NSSize(width: 200, height: 140))
    #expect(viewport.frame == NSRect(x: 0, y: 20, width: 320, height: 200))
    #expect(abs(viewport.alphaValue - 0.95) < 0.001)
    func headerSubview(_ identifier: String) -> NSView? {
      panePresentation.subviews.flatMap(\.subviews).first { $0.accessibilityIdentifier() == identifier }
    }
    guard let title = headerSubview("no.helgesverre.terminal.pane-title") as? NSTextField,
      let close = headerSubview("no.helgesverre.terminal.pane.close") as? NSButton
    else { Issue.record("pane header lacks its title or close button"); return }
    #expect(headerSubview("no.helgesverre.terminal.pane.choose-color") == nil)
    // A label draws from the top of its frame, so the frame must hug the text.
    #expect(title.frame.height == ceil(title.cell!.cellSize.height)
      && abs(title.frame.midY - TerminalPanePresentationView.headerHeight / 2) <= 0.5,
      "pane title is not vertically centered: \(title.frame)")
    #expect(abs(close.frame.midY - TerminalPanePresentationView.headerHeight / 2) <= 0.5)
    #expect(close.frame.maxX <= 320 && close.frame.maxX >= 312 && title.frame.maxX < close.frame.minX)
    var closed = 0
    panePresentation.onClose = { closed += 1 }
    close.performClick(nil)
    #expect(closed == 1)
    // The find bar docks over the first rows of the canvas. It never takes
    // height from the grid, so opening it cannot reflow the terminal.
    let findBar = panePresentation.findBar
    #expect(findBar.isHidden)
    #expect(findBar.frame == NSRect(x: 0, y: 20, width: 320, height: FindBarView.height))
    var findSteps: [Bool] = []
    var findClosed = 0
    findBar.onStep = { findSteps.append($0) }
    findBar.onClose = { findClosed += 1 }
    findBar.open()
    #expect(!findBar.isHidden && viewport.frame == NSRect(x: 0, y: 20, width: 320, height: 200))
    func findSubview<View: NSView>(_ name: String) throws -> View {
      try #require(findBar.subviews.first(where: {
        $0.accessibilityIdentifier() == "no.helgesverre.terminal.find." + name
      }) as? View, "find bar lacks \(name)")
    }
    let findQuery: NSTextField = try findSubview("query")
    let findCount: NSTextField = try findSubview("count")
    let findNext: NSButton = try findSubview("next")
    let findPrevious: NSButton = try findSubview("previous")
    // The placeholder is the bar's only label.
    #expect(findQuery.placeholderAttributedString?.string == "Find in scrollback")
    #expect(findCount.isHidden && !findNext.isEnabled && !findPrevious.isEnabled)
    findBar.show(.matches(index: 3, total: 14, capped: false))
    findBar.layoutSubtreeIfNeeded()
    #expect(findCount.stringValue == "3/14" && !findCount.isHidden && findNext.isEnabled)
    #expect(findQuery.frame.maxX <= findCount.frame.minX && findCount.frame.maxX <= findPrevious.frame.minX)
    findBar.show(.matches(index: 1, total: 10_000, capped: true))
    #expect(findCount.stringValue == "1/10000+")
    findNext.performClick(nil)
    findPrevious.performClick(nil)
    // Return walks toward older output, like the down arrow; Esc closes.
    let findEditor = NSTextView()
    #expect(findBar.control(findQuery, textView: findEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(findSteps == [true, false, true])
    #expect(findBar.control(findQuery, textView: findEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(findClosed == 1)
    #expect(!findBar.control(findQuery, textView: findEditor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    findBar.show(.noMatches)
    #expect(findCount.stringValue == "No matches" && !findNext.isEnabled && !findPrevious.isEnabled)
    findBar.dismiss()
    #expect(findBar.isHidden && findBar.result == .idle)
    // Middle click on the header closes; other buttons and releases outside do not.
    guard let header = close.superview else { Issue.record("close button has no header"); return }
    let headerWindow = NSWindow(contentRect: panePresentation.frame, styleMask: [.borderless],
      backing: .buffered, defer: true)
    headerWindow.contentView = panePresentation
    // Pane commands resolve their pane from keyboard focus, which may sit in
    // the find bar's query field instead of the canvas.
    #expect(TerminalPanePresentationView.enclosing(viewport) === panePresentation)
    #expect(TerminalPanePresentationView.enclosing(nil) == nil)
    #expect(TerminalPanePresentationView.enclosing(NSView()) == nil)
    findBar.open()
    #expect(headerWindow.firstResponder is NSTextView, "find query did not take focus")
    #expect(TerminalPanePresentationView.enclosing(headerWindow.firstResponder) === panePresentation,
      "focus in the find query does not resolve to its pane")
    findBar.dismiss()
    func otherUp(button: Int, at point: NSPoint) -> NSEvent {
      let event = NSEvent.mouseEvent(with: .otherMouseUp, location: header.convert(point, to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: headerWindow.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 0)!
      return NSEvent(cgEvent: { let e = event.cgEvent!; e.setIntegerValueField(.mouseEventButtonNumber,
        value: Int64(button)); return e }())!
    }
    header.otherMouseUp(with: otherUp(button: 2, at: NSPoint(x: 40, y: 10)))
    #expect(closed == 2, "middle click on the pane header did not close the pane")
    header.otherMouseUp(with: otherUp(button: 3, at: NSPoint(x: 40, y: 10)))
    header.otherMouseUp(with: otherUp(button: 2, at: NSPoint(x: 40, y: 80)))
    #expect(closed == 2)
    for dim in [PaneInactiveDim.twenty, .fifty] {
      #expect(PaneInactiveDim(storedValue: dim.rawValue) == dim)
      panePresentation.configure(showHeader: true, active: false, inactiveDim: dim, defaultColor: .standard)
      #expect(abs(viewport.alphaValue - (1 - CGFloat(dim.rawValue) / 100)) < 0.001)
    }
    #expect(PaneInactiveDim.allCases.map(\.label) == ["Off", "5%", "10%", "20%", "50%"])
    panePresentation.configure(showHeader: false, active: true, inactiveDim: .ten, defaultColor: .standard)
    panePresentation.layoutSubtreeIfNeeded()
    #expect(panePresentation.minimumSize == NSSize(width: 200, height: 120))
    #expect(viewport.frame == NSRect(x: 0, y: 0, width: 320, height: 220))
    #expect(abs(viewport.alphaValue - 1) < 0.001)
  }
}

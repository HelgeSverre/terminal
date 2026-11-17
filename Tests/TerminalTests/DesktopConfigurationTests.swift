import AppKit
import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalHost
import TerminalUI

@Suite(.serialized) @MainActor enum DesktopConfigurationTests {
  @Test static func recoveryDoesNotRunDefaultProfile() throws {
    var preferences = TerminalPreferences.load(from: UserDefaults(suiteName: "recovery-profile-\(UUID().uuidString)")!)
    preferences.desktop.profiles = [.init(id: "command", name: "Command", executable: "/bin/echo",
      arguments: ["must-not-run-during-restore"], directory: "", environment: ["PROFILE_ONLY": "yes"])]
    preferences.desktop.defaultProfile = "command"
    let launch = LaunchSpec.recoveryShell(inheriting: "file:///", preferences: preferences)
    #expect(launch.executable == LaunchSpec.loginShellPath)
    #expect(launch.arguments == [LaunchSpec.loginShellPath, "-l"])
    #expect(launch.cwd == "/" && launch.environment["PROFILE_ONLY"] == nil)
  }

  @Test static func configurationRoundTripAndInvalidStorageFallback() throws {
    let name = "desktop-configuration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var preferences = TerminalPreferences.load(from: defaults)
    preferences.desktop.leftOptionSendsEscape = true
    preferences.desktop.rightOptionSendsEscape = false
    preferences.desktop.cursorStyle = 6
    preferences.desktop.theme = TerminalUserTheme()
    preferences.desktop.visualBell = false
    preferences.desktop.profiles = [.init(id: "shell", name: "Shell", executable: "/bin/sh", arguments: ["-l"], directory: "", environment: ["HELGE_PROFILE": "yes"])]
    preferences.desktop.defaultProfile = "shell"
    preferences.desktop.shortcuts = [.init(action: .zoomPane, key: "z", modifiers: ["command", "control"])]
    preferences.save(to: defaults)
    let loaded = TerminalPreferences.load(from: defaults)
    #expect(loaded.desktop == preferences.desktop)
    #expect(loaded.view.cursorStyle == 6)
    #expect(loaded.view.leftOptionSendsEscape == true && loaded.view.rightOptionSendsEscape == false)
    #expect(loaded.session.colors == preferences.desktop.theme?.colors)
    #expect(try DesktopConfiguration.decode(preferences.desktop.encoded()) == preferences.desktop)
  }

  @Test static func partialConfigurationsDecodeWithDefaults() throws {
    #expect(try DesktopConfiguration.decode(Data("{}".utf8)) == .standard)
    let bell = try DesktopConfiguration.decode(Data(#"{"visualBell":false}"#.utf8))
    #expect(!bell.visualBell && bell.profiles.isEmpty && bell.shortcuts.isEmpty)
    let profile = try DesktopConfiguration.decode(Data(
      #"{"profiles":[{"id":"sh","name":"Shell","executable":"/bin/sh"}],"defaultProfile":"sh"}"#.utf8))
    #expect(profile.profiles == [.init(id: "sh", name: "Shell", executable: "/bin/sh", arguments: [], directory: "", environment: [:])])
    #expect(profile.visualBell)
    #expect(throws: (any Error).self) { try DesktopConfiguration.decode(Data(#"{"profiles":[{"id":"sh"}]}"#.utf8)) }
  }

  @Test static func unreadableStoredConfigurationSurvivesUnrelatedSaves() throws {
    let name = "desktop-unreadable-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let unreadable = Data(#"{"cursorStyle":9}"#.utf8)
    defaults.set(unreadable, forKey: "desktopConfiguration")
    var preferences = TerminalPreferences.load(from: defaults)
    #expect(preferences.desktop == .standard)
    preferences.save(to: defaults)
    #expect(defaults.data(forKey: "desktopConfiguration") == unreadable)
    preferences.desktop.visualBell = false
    preferences.save(to: defaults)
    #expect(TerminalPreferences.load(from: defaults).desktop.visualBell == false)
  }

  @Test static func splitKeepsProfileDirectoryUntilThePaneReportsOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let launch = LaunchSpec(executable: "/bin/sh", arguments: ["/bin/sh"], cwd: "/usr", environment: ["A": "b"])
    #expect(launch.inheritingDirectory(nil) == launch)
    #expect(launch.inheritingDirectory("file://remote.invalid/tmp") == launch)
    #expect(launch.inheritingDirectory(root.appendingPathComponent("missing").absoluteString) == launch)
    let inherited = launch.inheritingDirectory(root.absoluteString)
    #expect(inherited.cwd == root.path && inherited.environment == ["A": "b"] && inherited.executable == "/bin/sh")
  }

  @Test static func profileLaunchIsLiteralAndChecksFilesystem() throws {
    let profile = TerminalLaunchProfile(id: "test", name: "Literal", executable: "/bin/sh",
      arguments: ["-c", "printf '%s' \"$1\"", "fixture", "$(touch /should-not-exist)"],
      directory: "", environment: ["TEST_PROFILE": "literal"])
    let launch = try profile.launch(fallbackDirectory: "/", launcher: nil)
    #expect(launch.arguments == ["/bin/sh"] + profile.arguments)
    #expect(launch.environment["TEST_PROFILE"] == "literal")
    var invalid = profile
    invalid.executable = "/missing-terminal-profile"
    #expect(throws: (any Error).self) { try invalid.launch(fallbackDirectory: "/", launcher: nil) }
    invalid = profile
    invalid.environment = ["INVALID=KEY": "value"]
    #expect(throws: (any Error).self) { try invalid.validate() }
    invalid = profile
    invalid.arguments = ["bad\0argument"]
    #expect(throws: (any Error).self) { try invalid.validate() }
  }

  @Test static func shortcutsThemesAndResourceLimits() throws {
    var value = DesktopConfiguration.standard
    value.shortcuts = [.init(action: .focusLeft, key: "h", modifiers: ["command", "control"])]
    try value.validate()
    value.shortcuts.append(.init(action: .focusRight, key: "h", modifiers: ["control", "command"]))
    #expect(throws: (any Error).self) { try value.validate() }
    value.shortcuts = [.init(action: .newWindow, key: "q", modifiers: ["command"])]
    #expect(throws: (any Error).self) { try value.validate() }
    value.shortcuts = []
    value.cursorStyle = 7
    #expect(throws: (any Error).self) { try value.validate() }
    value.cursorStyle = nil
    value.defaultProfile = "missing"
    #expect(throws: (any Error).self) { try value.validate() }
    value.defaultProfile = nil
    var theme = TerminalUserTheme()
    theme.ansi.removeLast()
    value.theme = theme
    #expect(throws: (any Error).self) { try value.validate() }
    #expect(throws: (any Error).self) {
      try DesktopConfiguration.decode(Data(repeating: 32, count: DesktopConfiguration.maximumBytes + 1))
    }
  }

  @Test static func bellBurstsAreQuietlyCoalesced() {
    var gate = VisualBellGate()
    let first = gate.admit(now: 100)
    let early = gate.admit(now: 100.1)
    let beforeDeadline = gate.admit(now: 100.74)
    let atDeadline = gate.admit(now: 100.75)
    let invalid = gate.admit(now: .nan)
    #expect(first)
    #expect(!early)
    #expect(!beforeDeadline)
    #expect(atDeadline)
    #expect(!invalid)
  }
  @Test static func configurableActionsCannotClaimFixedMenuShortcuts() throws {
    _ = NSApplication.shared
    let tabs = NSMenu(title: "Tabs")
    TerminalTabNavigation { nil }.addMenuItems(to: tabs)
    let fixedItems = tabs.items + TerminalEditMenu.make().items
    func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
      [("command", NSEvent.ModifierFlags.command), ("shift", .shift), ("control", .control), ("option", .option)]
        .filter { flags.contains($0.1) }.map(\.0)
    }
    for item in fixedItems where item.keyEquivalent.utf8.count == 1 && item.keyEquivalentModifierMask.contains(.command) {
      var value = DesktopConfiguration.standard
      value.shortcuts = [.init(action: .newWindow, key: item.keyEquivalent,
        modifiers: modifierNames(item.keyEquivalentModifierMask))]
      #expect(throws: (any Error).self) { try value.validate() }
    }
    for number in 1...9 {
      var value = DesktopConfiguration.standard
      value.shortcuts = [.init(action: .zoomPane, key: String(number), modifiers: ["command"])]
      #expect(throws: (any Error).self) { try value.validate() }
    }
    // Additional modifiers distinguish a user binding from numbered-tab keys.
    var accepted = DesktopConfiguration.standard
    accepted.shortcuts = [.init(action: .zoomPane, key: "2", modifiers: ["control", "command"])]
    try accepted.validate()
    for item in fixedItems {
      #expect(item.keyEquivalent != accepted.shortcuts[0].key
        || item.keyEquivalentModifierMask != accepted.shortcuts[0].flags)
    }
    // The View menu's plus command also uses the shifted equals spelling.
    for key in ["=", "+"] {
      #expect(throws: (any Error).self) {
        try TerminalShortcut(action: .newTab, key: key, modifiers: ["shift", "command"]).validate()
      }
    }
  }
  @Test static func directionalFocusUsesNestedPaneGeometry() {
    let source = CGRect(x: 0, y: 0, width: 100, height: 200)
    let neighbors = [CGRect(x: 100, y: 100, width: 100, height: 100),
      CGRect(x: 100, y: 0, width: 100, height: 100),
      CGRect(x: 200, y: 0, width: 100, height: 200)]
    #expect(PaneNavigation.neighbor(from: source, candidates: neighbors, direction: .right) == 0)
    #expect(PaneNavigation.neighbor(from: source, candidates: neighbors, direction: .left) == nil)
    #expect(PaneNavigation.neighbor(from: neighbors[1], candidates: [source, neighbors[0]], direction: .up) == 1)
    #expect(PaneNavigation.neighbor(from: neighbors[0], candidates: [source, neighbors[1]], direction: .down) == 1)
  }
}

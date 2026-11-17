import AppKit
import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalHost

@Suite(.serialized) @MainActor enum DesktopConfigurationTests {
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
    #expect(loaded.session.colors == preferences.desktop.theme?.colors)
    defaults.set(Data("{}".utf8), forKey: "desktopConfiguration")
    #expect(TerminalPreferences.load(from: defaults).desktop == .standard)
    #expect(try DesktopConfiguration.decode(preferences.desktop.encoded()) == preferences.desktop)
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
    #expect(gate.admit(now: 100))
    #expect(!gate.admit(now: 100.1))
    #expect(!gate.admit(now: 100.74))
    #expect(gate.admit(now: 100.75))
    #expect(!gate.admit(now: .nan))
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

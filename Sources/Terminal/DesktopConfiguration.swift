import AppKit
import TerminalEngine
import TerminalHost

/// Saved desktop policy. Import is bounded and validated before replacing the
/// current draft; commands are argv, never implicitly evaluated by a shell.
struct DesktopConfiguration: Codable, Equatable {
  var profiles: [TerminalLaunchProfile] = []
  var defaultProfile: String? = nil
  var shortcuts: [TerminalShortcut] = []
  var theme: TerminalUserTheme? = nil
  var cursorStyle: UInt8? = nil
  var visualBell = true
  var leftOptionSendsEscape: Bool? = nil
  var rightOptionSendsEscape: Bool? = nil

  static let maximumBytes = 131_072
  static let standard = DesktopConfiguration()
  enum Invalid: LocalizedError {
    case value(String)
    var errorDescription: String? { if case .value(let text) = self { return text }; return nil }
  }
  static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw Invalid.value("Configuration must be smaller than 128 KiB.") }
    let value = try JSONDecoder().decode(Self.self, from: data)
    try value.validate()
    return value
  }
  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
  func validate() throws {
    guard profiles.count <= 32, Set(profiles.map(\.id)).count == profiles.count else {
      throw Invalid.value("Use at most 32 profiles with unique identifiers.")
    }
    for profile in profiles { try profile.validate() }
    guard defaultProfile == nil || profiles.contains(where: { $0.id == defaultProfile }) else {
      throw Invalid.value("The default profile must name a saved profile identifier.")
    }
    guard cursorStyle == nil || (1...6).contains(cursorStyle!) else {
      throw Invalid.value("Cursor style is null (application controlled), or 1–6 (blinking/steady block, underline, bar).")
    }
    guard shortcuts.count <= TerminalShortcut.Action.allCases.count,
      Set(shortcuts.map(\.action)).count == shortcuts.count,
      Set(shortcuts.map(\.chord)).count == shortcuts.count else {
      throw Invalid.value("Use one shortcut per action and do not reuse a key combination.")
    }
    for shortcut in shortcuts { try shortcut.validate() }
    let effective = TerminalShortcut.defaults.map { fallback in shortcuts.first { $0.action == fallback.action } ?? fallback }
    guard Set(effective.map(\.chord)).count == effective.count else {
      throw Invalid.value("A shortcut conflicts with another action's default. Remap both actions to distinct keys.")
    }
    try theme?.validate()
    guard try encoded().count <= Self.maximumBytes else {
      throw Invalid.value("Configuration must be smaller than 128 KiB.")
    }
  }
}

struct TerminalLaunchProfile: Codable, Equatable {
  var id: String
  var name: String
  var executable: String
  /// Arguments after argv[0]. Use [] for no arguments, ["-l"] for a login shell.
  var arguments: [String]
  var directory: String
  var environment: [String: String]

  func validate() throws {
    func plain(_ value: String, limit: Int) -> Bool {
      value.utf8.count <= limit && !value.unicodeScalars.contains { $0.value == 0 || $0.value < 32 || $0.value == 127 }
    }
    guard !id.isEmpty, plain(id, limit: 64), !name.isEmpty, plain(name, limit: 80),
      executable.hasPrefix("/"), plain(executable, limit: 8192),
      arguments.count <= 128, arguments.reduce(0, { $0 + $1.utf8.count }) <= 32768,
      arguments.allSatisfy({ !$0.utf8.contains(0) }),
      directory.isEmpty || directory.hasPrefix("/") || directory.hasPrefix("~/"),
      plain(directory, limit: 8192), environment.count <= 64,
      environment.allSatisfy({ key, value in
        !key.isEmpty && key.utf8.count <= 128 && key.utf8.allSatisfy {
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        } && value.utf8.count <= 8192 && !value.utf8.contains(0)
      }) else { throw DesktopConfiguration.Invalid.value("Profile \(name): use an absolute executable, valid directory and bounded arguments/environment.") }
  }
  func launch(fallbackDirectory: String, launcher: String?) throws -> LaunchSpec {
    try validate()
    let path = directory.isEmpty ? fallbackDirectory : (directory as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.isExecutableFile(atPath: executable),
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw DesktopConfiguration.Invalid.value("Profile \(name): the executable or starting directory no longer exists.")
    }
    return LaunchSpec(executable: executable, arguments: [executable] + arguments,
      cwd: path, launcher: launcher, environment: environment)
  }
}

struct TerminalShortcut: Codable, Equatable {
  static let defaults: [TerminalShortcut] = [
    .init(action: .newWindow, key: "n", modifiers: ["command"]),
    .init(action: .newTab, key: "t", modifiers: ["command"]),
    .init(action: .splitRight, key: "d", modifiers: ["command"]),
    .init(action: .splitBelow, key: "d", modifiers: ["command", "shift"]),
    .init(action: .focusLeft, key: "h", modifiers: ["command", "control"]),
    .init(action: .focusDown, key: "j", modifiers: ["command", "control"]),
    .init(action: .focusUp, key: "k", modifiers: ["command", "control"]),
    .init(action: .focusRight, key: "l", modifiers: ["command", "control"]),
    .init(action: .zoomPane, key: "z", modifiers: ["command", "control"]),
    .init(action: .movePaneToWindow, key: "n", modifiers: ["command", "control"]),
  ]
  enum Action: String, Codable, CaseIterable {
    case newWindow, newTab, splitRight, splitBelow, focusLeft, focusRight, focusUp, focusDown, zoomPane, movePaneToWindow
    var selectorName: String {
      switch self {
      case .splitRight: return "splitVertical:"
      case .splitBelow: return "splitHorizontal:"
      case .zoomPane: return "togglePaneZoom:"
      default: return rawValue + ":"
      }
    }
  }
  var action: Action
  var key: String
  var modifiers: [String]
  var chord: String { modifiers.sorted().joined(separator: "+") + ":" + key.lowercased() }
  func validate() throws {
    guard key.count == 1, key.utf8.count == 1, key.utf8.allSatisfy({ (33...126).contains($0) }),
      key == key.lowercased(), Set(modifiers).count == modifiers.count,
      modifiers.contains("command"), Set(modifiers).isSubset(of: ["command", "option", "control", "shift"]),
      !(modifiers == ["command"] && ["q", "w", ",", "c", "v", "x", "a", "f", "h", "m", "k", "+", "-", "0", "g", "z", "."].contains(key)),
      !(Set(modifiers) == Set(["command", "shift"]) && ["g", "z", "="].contains(key)) else {
      throw DesktopConfiguration.Invalid.value("Shortcuts need one lowercase ASCII key and command, with optional option/control/shift. Standard editing and window shortcuts are reserved.")
    }
  }
  var flags: NSEvent.ModifierFlags {
    modifiers.reduce(into: NSEvent.ModifierFlags()) { result, name in
      switch name { case "command": result.insert(.command); case "option": result.insert(.option)
      case "control": result.insert(.control); case "shift": result.insert(.shift); default: break }
    }
  }
}

struct TerminalUserTheme: Codable, Equatable {
  var foreground: String
  var background: String
  var cursor: String
  var selectionBackground: String
  var selectionForeground: String
  var ansi: [String]
  init(_ colors: TerminalColorScheme = .standard) {
    func hex(_ value: UInt32) -> String { String(format: "#%06X", value & 0xffffff) }
    foreground = hex(colors.foreground); background = hex(colors.background); cursor = hex(colors.cursor)
    selectionBackground = hex(colors.selectionBackground); selectionForeground = hex(colors.selectionForeground)
    ansi = colors.ansi.map(hex)
  }
  func validate() throws {
    guard ansi.count == 16, ([foreground, background, cursor, selectionBackground, selectionForeground] + ansi)
      .allSatisfy({ $0.count == 7 && PaneChromeColor(hex: $0) != nil }) else {
      throw DesktopConfiguration.Invalid.value("Theme colors must be #RRGGBB, with exactly sixteen ANSI colors.")
    }
  }
  var colors: TerminalColorScheme {
    func rgb(_ value: String) -> UInt32 { UInt32(value.dropFirst(), radix: 16) ?? 0 }
    return TerminalColorScheme(foreground: rgb(foreground), background: rgb(background), ansi: ansi.map(rgb),
      cursor: rgb(cursor), selectionBackground: rgb(selectionBackground), selectionForeground: rgb(selectionForeground))
  }
}

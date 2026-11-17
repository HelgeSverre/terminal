import Foundation
import TerminalEngine
import TerminalHost
import TerminalUI

enum PaneInactiveDim: Int, CaseIterable {
  case off = 0
  case five = 5
  case ten = 10
  case twenty = 20
  case fifty = 50

  init(storedValue: Int) {
    self = Self(rawValue: storedValue) ?? .five
  }

  var alpha: CGFloat { 1 - CGFloat(rawValue) / 100 }
  var label: String { rawValue == 0 ? "Off" : "\(rawValue)%" }
}

/// A pane header color. A pane's own choice is ephemeral and reopening a
/// session forgets it; the color panes start with is a saved preference.
struct PaneChromeColor: Equatable, Hashable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  static let onyx = PaneChromeColor(hex: "#18191C")!
  static let charcoal = PaneChromeColor(hex: "#36383C")!
  /// What a pane uses until the preference or the pane itself says otherwise:
  /// the darkest neutral in the palette.
  static let standard = onyx

  init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  init?(hex: String) {
    let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.first == "#" else { return nil }
    let digits = String(value.dropFirst())
    let expanded: String
    switch digits.count {
    case 3:
      expanded = digits.reduce(into: "") { $0.append($1); $0.append($1) }
    case 6:
      expanded = digits
    default:
      return nil
    }
    guard expanded.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF".unicodeScalars.contains($0) }),
      let value = UInt32(expanded, radix: 16)
    else { return nil }
    self.init(red: UInt8((value >> 16) & 0xff), green: UInt8((value >> 8) & 0xff), blue: UInt8(value & 0xff))
  }

  var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

struct PaneColorChoice: Equatable {
  let name: String
  let color: PaneChromeColor

  static let palette: [PaneColorChoice] = [
    .init(name: "Onyx", color: .onyx),
    .init(name: "Graphite", color: .init(hex: "#26272B")!),
    .init(name: "Charcoal", color: .charcoal),
    .init(name: "Slate", color: .init(hex: "#4A5568")!),
    .init(name: "Steel", color: .init(hex: "#3F5E72")!),
    .init(name: "Ocean", color: .init(hex: "#2E6376")!),
    .init(name: "Teal", color: .init(hex: "#2B6A65")!),
    .init(name: "Pine", color: .init(hex: "#41684F")!),
    .init(name: "Moss", color: .init(hex: "#697044")!),
    .init(name: "Olive", color: .init(hex: "#766B3C")!),
    .init(name: "Ochre", color: .init(hex: "#826334")!),
    .init(name: "Amber", color: .init(hex: "#8A5430")!),
    .init(name: "Rust", color: .init(hex: "#82483A")!),
    .init(name: "Brick", color: .init(hex: "#7C4145")!),
    .init(name: "Berry", color: .init(hex: "#713F5D")!),
    .init(name: "Plum", color: .init(hex: "#5F466E")!),
    .init(name: "Violet", color: .init(hex: "#554F7A")!),
    .init(name: "Indigo", color: .init(hex: "#45547C")!),
  ]

  /// A palette name in any case (`"ocean"`) or a hex color (`"#2E6376"`).
  static func resolve(_ text: String) -> PaneChromeColor? {
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let choice = palette.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
      return choice.color
    }
    return PaneChromeColor(hex: name)
  }
}

struct TerminalPreferences {
  let fontSize: CGFloat
  let historyRows: Int
  let optionSendsEscape: Bool
  let followTailOnInput: Bool
  let startingDirectory: String
  let selectionWordProfile: TerminalSelectionWordProfile
  let showPaneTitles: Bool
  let inactivePaneDim: PaneInactiveDim
  /// Header color of every pane that has not been given its own.
  let defaultPaneColor: PaneChromeColor
  /// Whether an emoji sequence takes the cells of one character (mode 2027
  /// set) or each code point takes its own, as zsh counts. See "Shell line
  /// editing after emoji sequences" in BUGS.md.
  var graphemeClustering = true
  /// The font family, or nil for the bundled default.
  var fontFamily: String?
  /// Whether runs of punctuation are joined when the font has ligatures.
  var ligatures = false
  var desktop = DesktopConfiguration.standard
  enum ValidationError: LocalizedError {
    case font, history, directory, wordCharacters
    var errorDescription: String? {
      switch self {
      case .font: return "Enter a font size from 8–40 pt."
      case .history: return "Enter a scrollback limit from 0–50,000 rows."
      case .directory: return "Choose an existing starting directory."
      case .wordCharacters: return "Enter up to 64 word characters without spaces or control characters."
      }
    }
  }
  private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
  private static func directory(_ text: String) -> String? {
    let path = text.isEmpty ? home : (text as NSString).expandingTildeInPath
    guard path.hasPrefix("/") else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }
  // Check the filesystem only at launch/validation, never on keyboard reads.
  var launchDirectory: String {
    let args = Array(CommandLine.arguments.prefix { $0 != "--execute" })
    if let index = args.firstIndex(of: "--working-directory"), args.indices.contains(index + 1) {
      return (args[index + 1] as NSString).expandingTildeInPath
    }
    return Self.directory(startingDirectory) ?? Self.home
  }
  func launchDirectory(inheriting location: String?) -> String {
    guard let location, location.utf8.count <= 8192, let url = URL(string: location),
      url.isFileURL, url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil,
      url.path.hasPrefix("/"), !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return launchDirectory }
    let host = (url.host ?? "").lowercased()
    guard host.isEmpty || host == "localhost" || host == ProcessInfo.processInfo.hostName.lowercased()
    else { return launchDirectory }
    return Self.directory(url.path) ?? launchDirectory
  }
  var startingDirectoryText: String {
    let path = (startingDirectory as NSString).expandingTildeInPath
    if path == Self.home { return "~" }
    return path.hasPrefix(Self.home + "/") ? "~" + path.dropFirst(Self.home.count) : startingDirectory
  }
  var view: TerminalViewConfiguration {
    var value = TerminalViewConfiguration(
      fontSize: fontSize, fontFamily: fontFamily, optionSendsEscape: optionSendsEscape, session: session)
    value.ligatures = ligatures
    value.leftOptionSendsEscape = desktop.leftOptionSendsEscape
    value.rightOptionSendsEscape = desktop.rightOptionSendsEscape
    value.cursorStyle = desktop.cursorStyle
    return value
  }
  var session: TerminalSessionConfiguration {
    var value = TerminalSessionConfiguration(historyRows: historyRows, followTailOnInput: followTailOnInput,
      selectionWordProfile: selectionWordProfile)
    value.identity = TerminalIdentity(name: "HelgeTerminal",
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    value.graphemeClustering = graphemeClustering
    value.colors = desktop.theme?.colors ?? .standard
    return value
  }
  static func edited(fontSize: String, historyRows: String, optionSendsEscape: Bool,
                     followTailOnInput: Bool, startingDirectory: String,
                     selectionWordCharacters: String, showPaneTitles: Bool,
                     inactivePaneDim: PaneInactiveDim,
                     defaultPaneColor: PaneChromeColor,
                     fontFamily: String?? = nil, ligatures: Bool? = nil,
                     graphemeClustering: Bool? = nil,
                     desktop: DesktopConfiguration? = nil) throws -> Self {
    guard let font = Double(fontSize), font.isFinite, (8...40).contains(font) else { throw ValidationError.font }
    guard let rows = Int(historyRows), (0...50_000).contains(rows) else { throw ValidationError.history }
    guard let directory = Self.directory(startingDirectory) else { throw ValidationError.directory }
    guard let profile = TerminalSelectionWordProfile(punctuation: selectionWordCharacters)
    else { throw ValidationError.wordCharacters }
    var value = Self(fontSize: font, historyRows: rows, optionSendsEscape: optionSendsEscape,
                followTailOnInput: followTailOnInput, startingDirectory: directory,
                selectionWordProfile: profile, showPaneTitles: showPaneTitles,
                inactivePaneDim: inactivePaneDim, defaultPaneColor: defaultPaneColor)
    // An edit that does not name these keeps what is stored.
    value.graphemeClustering = graphemeClustering
      ?? ((UserDefaults.standard.object(forKey: "graphemeClustering") as? Bool) != false)
    value.fontFamily = fontFamily ?? UserDefaults.standard.string(forKey: "fontFamily")
    value.ligatures = ligatures ?? UserDefaults.standard.bool(forKey: "ligatures")
    value.desktop = desktop ?? loadDesktop(from: .standard)
    try value.desktop.validate()
    return value
  }
  // Transient launch options never modify saved preferences, nor inspect child argv.
  static func launchInteger(_ name: String, within range: ClosedRange<Int>) -> Int? {
    let args = Array(CommandLine.arguments.prefix { $0 != "--execute" })
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1),
      let value = Int(args[index + 1]), range.contains(value)
    else { return nil }
    return value
  }
  static func load() -> Self {
    let defaults = UserDefaults.standard

    if Bundle.main.bundleIdentifier == "no.helgesverre.terminal",
      let previous = defaults.persistentDomain(forName: "no.helge.terminal") {
      for key in ["fontSize", "historyRows", "optionSendsEscape"] where defaults.object(forKey: key) == nil {
        if let value = previous[key] { defaults.set(value, forKey: key) }
      }
    }
    return load(from: defaults)
  }

  // Injected defaults are read without migrating the application's domain.
  static func load(from defaults: UserDefaults) -> Self {
    let font = defaults.object(forKey: "fontSize") == nil ? 14 : defaults.double(forKey: "fontSize")
    let rows =
      defaults.object(forKey: "historyRows") == nil
      ? 50_000 : defaults.integer(forKey: "historyRows")
    var loaded = Self(
      fontSize: launchInteger("--font-size", within: 8...40).map { CGFloat($0) }
        ?? CGFloat(font.isFinite && (8...40).contains(font) ? font : 14),
      historyRows: launchInteger("--history-limit", within: 0...50_000)
        ?? ((0...50_000).contains(rows) ? rows : 50_000),
      optionSendsEscape: defaults.bool(forKey: "optionSendsEscape"),
      followTailOnInput: defaults.object(forKey: "followTailOnInput") == nil
        || defaults.bool(forKey: "followTailOnInput"),
      startingDirectory: defaults.string(forKey: "startingDirectory") ?? Self.home,
      selectionWordProfile: defaults.string(forKey: "selectionWordCharacters")
        .flatMap { TerminalSelectionWordProfile(punctuation: $0) } ?? .standard,
      showPaneTitles: defaults.object(forKey: "showPaneTitles") == nil
        || defaults.bool(forKey: "showPaneTitles"),
      inactivePaneDim: PaneInactiveDim(storedValue: defaults.object(forKey: "inactivePaneDim") == nil
        ? PaneInactiveDim.five.rawValue : defaults.integer(forKey: "inactivePaneDim")),
      defaultPaneColor: defaults.string(forKey: "defaultPaneColor")
        .flatMap { PaneChromeColor(hex: $0) } ?? .standard)
    loaded.graphemeClustering = (defaults.object(forKey: "graphemeClustering") as? Bool) != false
    loaded.fontFamily = (defaults.object(forKey: "fontFamily") as? String).flatMap { $0.isEmpty ? nil : $0 }
    loaded.ligatures = (defaults.object(forKey: "ligatures") as? Bool) == true
    loaded.desktop = loadDesktop(from: defaults)
    return loaded
  }
  func save() { save(to: .standard) }
  private static func loadDesktop(from defaults: UserDefaults) -> DesktopConfiguration {
    guard let data = defaults.data(forKey: "desktopConfiguration"),
      let value = try? DesktopConfiguration.decode(data) else { return .standard }
    return value
  }
  func save(to d: UserDefaults) {
    d.set(fontSize, forKey: "fontSize")
    d.set(historyRows, forKey: "historyRows")
    d.set(optionSendsEscape, forKey: "optionSendsEscape")
    d.set(followTailOnInput, forKey: "followTailOnInput")
    d.set(startingDirectory, forKey: "startingDirectory")
    d.set(selectionWordProfile.punctuation, forKey: "selectionWordCharacters")
    d.set(showPaneTitles, forKey: "showPaneTitles")
    d.set(inactivePaneDim.rawValue, forKey: "inactivePaneDim")
    d.set(defaultPaneColor.hex, forKey: "defaultPaneColor")
    if let fontFamily { d.set(fontFamily, forKey: "fontFamily") } else { d.removeObject(forKey: "fontFamily") }
    d.set(ligatures, forKey: "ligatures")
    if let data = try? desktop.encoded() { d.set(data, forKey: "desktopConfiguration") }
    // Written only when chosen, so the default can still change.
    if !graphemeClustering || d.object(forKey: "graphemeClustering") != nil {
      d.set(graphemeClustering, forKey: "graphemeClustering")
    }
  }
}

extension LaunchSpec {
  /// Recovery always creates a fresh login shell, independent of profiles.
  static func recoveryShell(inheriting location: String?, preferences: TerminalPreferences = .load()) -> Self {
    let launcher = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalLauncher").path
    return .loginShell(cwd: preferences.launchDirectory(inheriting: location), launcher: launcher)
  }

  /// The login shell in the starting directory the preferences name, started
  /// through the launcher this bundle carries.
  static var shell: LaunchSpec {
    let prefs = TerminalPreferences.load()
    let launcher = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalLauncher").path
    if let profile = prefs.desktop.profiles.first(where: { $0.id == prefs.desktop.defaultProfile }),
      let launch = try? profile.launch(fallbackDirectory: prefs.launchDirectory, launcher: launcher) {
      return launch
    }
    return .loginShell(cwd: prefs.launchDirectory, launcher: launcher)
  }
  func inheritingDirectory(_ location: String?) -> Self {
    Self(executable: executable, arguments: arguments,
         cwd: TerminalPreferences.load().launchDirectory(inheriting: location), launcher: launcher,
         environment: environment)
  }
}

extension TerminalSession {
  /// What a pane split from this one starts: the shell, in this pane's directory.
  @MainActor var siblingLaunch: LaunchSpec { .shell.inheritingDirectory(deliveredDirectory) }
}

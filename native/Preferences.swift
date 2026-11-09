import Foundation

enum PaneInactiveDim: Int, CaseIterable {
  case off = 0
  case five = 5
  case ten = 10

  init(storedValue: Int) {
    self = Self(rawValue: storedValue) ?? .five
  }

  var alpha: CGFloat { 1 - CGFloat(rawValue) / 100 }
  var label: String { rawValue == 0 ? "Off" : "\(rawValue)%" }
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
  var session: TerminalSessionConfiguration {
    TerminalSessionConfiguration(historyRows: historyRows, followTailOnInput: followTailOnInput,
      selectionWordProfile: selectionWordProfile)
  }
  static func edited(fontSize: String, historyRows: String, optionSendsEscape: Bool,
                     followTailOnInput: Bool, startingDirectory: String,
                     selectionWordCharacters: String, showPaneTitles: Bool,
                     inactivePaneDim: PaneInactiveDim) throws -> Self {
    guard let font = Double(fontSize), font.isFinite, (8...40).contains(font) else { throw ValidationError.font }
    guard let rows = Int(historyRows), (0...50_000).contains(rows) else { throw ValidationError.history }
    guard let directory = Self.directory(startingDirectory) else { throw ValidationError.directory }
    guard let profile = TerminalSelectionWordProfile(punctuation: selectionWordCharacters)
    else { throw ValidationError.wordCharacters }
    return Self(fontSize: font, historyRows: rows, optionSendsEscape: optionSendsEscape,
                followTailOnInput: followTailOnInput, startingDirectory: directory,
                selectionWordProfile: profile, showPaneTitles: showPaneTitles,
                inactivePaneDim: inactivePaneDim)
  }
  // Transient launch options never modify saved preferences, nor inspect child argv.
  static func launchInteger(_ name: String, within range: ClosedRange<Int>) -> Int? {
    let args = Array(CommandLine.arguments.prefix { $0 != "--execute" })
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1),
      let value = Int(args[index + 1]), range.contains(value)
    else { return nil }
    return value
  }
  static func load() -> Self { load(from: .standard, migrateLegacyDomain: true) }

  // Tests and isolated tools can inject a private defaults suite; only the app
  // performs the one-time bundle migration.
  static func load(from defaults: UserDefaults, migrateLegacyDomain: Bool = false) -> Self {
    if Bundle.main.bundleIdentifier == "no.helgesverre.terminal",
      migrateLegacyDomain,
      let previous = defaults.persistentDomain(forName: "no.helge.terminal") {
      for key in ["fontSize", "historyRows", "optionSendsEscape"] where defaults.object(forKey: key) == nil {
        if let value = previous[key] { defaults.set(value, forKey: key) }
      }
    }
    let font = defaults.object(forKey: "fontSize") == nil ? 14 : defaults.double(forKey: "fontSize")
    let rows =
      defaults.object(forKey: "historyRows") == nil
      ? 50_000 : defaults.integer(forKey: "historyRows")
    return Self(
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
        ? PaneInactiveDim.five.rawValue : defaults.integer(forKey: "inactivePaneDim")))
  }
  func save() { save(to: .standard) }
  func save(to d: UserDefaults) {
    d.set(fontSize, forKey: "fontSize")
    d.set(historyRows, forKey: "historyRows")
    d.set(optionSendsEscape, forKey: "optionSendsEscape")
    d.set(followTailOnInput, forKey: "followTailOnInput")
    d.set(startingDirectory, forKey: "startingDirectory")
    d.set(selectionWordProfile.punctuation, forKey: "selectionWordCharacters")
    d.set(showPaneTitles, forKey: "showPaneTitles")
    d.set(inactivePaneDim.rawValue, forKey: "inactivePaneDim")
  }
}

struct TerminalSessionConfiguration {
  let historyRows: Int
  let followTailOnInput: Bool
  let selectionWordProfile: TerminalSelectionWordProfile
  init(historyRows: Int = 50_000, followTailOnInput: Bool = true,
       selectionWordProfile: TerminalSelectionWordProfile = .standard) {
    self.historyRows = min(50_000, max(0, historyRows))
    self.followTailOnInput = followTailOnInput
    self.selectionWordProfile = selectionWordProfile
  }
}

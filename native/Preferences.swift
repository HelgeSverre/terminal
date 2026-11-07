import Foundation

struct TerminalPreferences {
  let fontSize: CGFloat
  let historyRows: Int
  let optionSendsEscape: Bool
  let followTailOnInput: Bool
  let startingDirectory: String
  enum ValidationError: LocalizedError {
    case font, history, directory
    var errorDescription: String? {
      switch self {
      case .font: return "Enter a font size from 8–40 pt."
      case .history: return "Enter a scrollback limit from 0–50,000 rows."
      case .directory: return "Choose an existing starting directory."
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
  var startingDirectoryText: String {
    let path = (startingDirectory as NSString).expandingTildeInPath
    if path == Self.home { return "~" }
    return path.hasPrefix(Self.home + "/") ? "~" + path.dropFirst(Self.home.count) : startingDirectory
  }
  var session: TerminalSessionConfiguration {
    TerminalSessionConfiguration(historyRows: historyRows, followTailOnInput: followTailOnInput)
  }
  static func edited(fontSize: String, historyRows: String, optionSendsEscape: Bool,
                     followTailOnInput: Bool, startingDirectory: String) throws -> Self {
    guard let font = Double(fontSize), font.isFinite, (8...40).contains(font) else { throw ValidationError.font }
    guard let rows = Int(historyRows), (0...50_000).contains(rows) else { throw ValidationError.history }
    guard let directory = Self.directory(startingDirectory) else { throw ValidationError.directory }
    return Self(fontSize: font, historyRows: rows, optionSendsEscape: optionSendsEscape,
                followTailOnInput: followTailOnInput, startingDirectory: directory)
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
      startingDirectory: defaults.string(forKey: "startingDirectory") ?? Self.home)
  }
  func save() {
    let d = UserDefaults.standard
    d.set(fontSize, forKey: "fontSize")
    d.set(historyRows, forKey: "historyRows")
    d.set(optionSendsEscape, forKey: "optionSendsEscape")
    d.set(followTailOnInput, forKey: "followTailOnInput")
    d.set(startingDirectory, forKey: "startingDirectory")
  }
}

struct TerminalSessionConfiguration {
  let historyRows: Int
  let followTailOnInput: Bool
  init(historyRows: Int = 50_000, followTailOnInput: Bool = true) {
    self.historyRows = min(50_000, max(0, historyRows))
    self.followTailOnInput = followTailOnInput
  }
}

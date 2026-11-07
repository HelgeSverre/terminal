import Foundation

struct TerminalPreferences {
  let fontSize: CGFloat
  let historyRows: Int
  let optionSendsEscape: Bool
  let followTailOnInput: Bool
  var session: TerminalSessionConfiguration {
    TerminalSessionConfiguration(historyRows: historyRows, followTailOnInput: followTailOnInput)
  }
  static func edited(fontSize: String, historyRows: String, optionSendsEscape: Bool,
                     followTailOnInput: Bool) -> Self? {
    guard let font = Double(fontSize), font.isFinite, (8...40).contains(font),
      let rows = Int(historyRows), (0...50_000).contains(rows) else { return nil }
    return Self(fontSize: font, historyRows: rows, optionSendsEscape: optionSendsEscape,
                followTailOnInput: followTailOnInput)
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
        || defaults.bool(forKey: "followTailOnInput"))
  }
  func save() {
    let d = UserDefaults.standard
    d.set(fontSize, forKey: "fontSize")
    d.set(historyRows, forKey: "historyRows")
    d.set(optionSendsEscape, forKey: "optionSendsEscape")
    d.set(followTailOnInput, forKey: "followTailOnInput")
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

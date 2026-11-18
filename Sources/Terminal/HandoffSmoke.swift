#if TERMINAL_DIAGNOSTICS
import AppKit
import TerminalHost
import TerminalUI

/// Exercises a handoff with real programs: `--handoff-smoke DIRECTORY` reads
/// `DIRECTORY/scenario.json`, opens one pane per entry, runs its command,
/// records every pane, hands off and relaunches. The relaunched app finds
/// the record, checks that each pane still shows the same running process,
/// probes it with input, and writes `round-N.json`. With `rounds` above one
/// it hands off again.
@MainActor enum HandoffSmoke {
  nonisolated static let flag = "--handoff-smoke"
  struct Scenario: Codable {
    struct Pane: Codable {
      var name: String
      /// Typed into the pane's shell, followed by Return. Empty leaves the shell.
      var command: String
      /// Typed after the handoff; `expect` must then appear on screen.
      var probe: String?
      var expect: String?
      /// The screen is expected to keep changing by itself.
      var animated: Bool?
    }
    var settle: Double
    var rounds: Int
    var keepOpen: Bool?
    /// Leave after handing off and let the caller start the next app, as an
    /// update that replaces the bundle does.
    var externalRelaunch: Bool?
    /// Windows and tabs opened besides the first window, each with a shell.
    var extraWindows: Int?
    var extraTabs: Int?
    var panes: [Pane]
  }
  struct Record: Codable {
    struct Pane: Codable {
      var id: String
      var name: String
      var pid: Int32
      var descendants: [Int32]
      var screen: String
      var columns: Int
      var rows: Int
    }
    var round: Int
    var panes: [Pane]
  }
  struct Result: Codable {
    struct Pane: Codable {
      var name: String
      var sameProcess: Bool
      var descendantsKept: Bool
      var lostDescendants: [Int32]
      var gridKept: Bool
      var gridBefore: String
      var gridRestored: String
      var rowsEqualAtRestore: Double
      var animated: Bool?
      var probed: Bool?
      var screenBefore: String
      var screenRestored: String
      var screenAfterProbe: String
    }
    var round: Int
    var passed: Bool
    var handoffMilliseconds: Double
    var appBuild: String
    var panes: [Pane]
  }

  private static var directory: URL? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
  }
  private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
    guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
  private static func save<T: Encodable>(_ value: T, _ name: String) {
    guard let directory else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
  }
  private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
  }
  /// Every process below `root`, from one `ps` listing.
  private static func descendants(of root: Int32) -> [Int32] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid="]
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    var children: [Int32: [Int32]] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: " ").compactMap { Int32($0) }
      if fields.count == 2 { children[fields[1], default: []].append(fields[0]) }
    }
    var found: [Int32] = [], queue = [root]
    while let next = queue.popLast() {
      for child in children[next] ?? [] { found.append(child); queue.append(child) }
    }
    return found.sorted()
  }
  private static func record(_ delegate: AppDelegate, names: [String: String], round: Int) -> Record {
    Record(round: round, panes: delegate.windows.flatMap(\.panes).map { pane in
      let pid = pane.session.processIdentifier ?? -1
      let grid = pane.gridSize
      return Record.Pane(id: pane.automationID, name: names[pane.automationID] ?? "", pid: pid,
        descendants: pid > 0 ? descendants(of: pid) : [], screen: pane.visibleText,
        columns: grid?.columns ?? 0, rows: grid?.rows ?? 0)
    })
  }

  static func startIfRequested(_ delegate: AppDelegate, adopted: Bool) {
    guard directory != nil, let scenario = load(Scenario.self, "scenario.json") else { return }
    if adopted, let before = load(Record.self, "before.json") { verify(delegate, scenario, before) }
    else { prepare(delegate, scenario) }
  }

  private static func prepare(_ delegate: AppDelegate, _ scenario: Scenario) {
    guard let window = delegate.windows.first else { return }
    guard let first = window.panes.first else { return }
    // A cell is about twice as tall as wide; the window is about 1.7 to 1.
    split(window, sizes: [(first, 1.7, 1.0)], remaining: scenario.panes.count - 1) {
      // Shells first reach their prompts; then each gets its command.
      for _ in 0..<(scenario.extraTabs ?? 0) { delegate.newTab(nil) }
      for _ in 0..<(scenario.extraWindows ?? 0) { delegate.newWindow(nil) }
      after(2.5) {
        var names: [String: String] = [:]
        for (pane, entry) in zip(window.panes, scenario.panes) {
          names[pane.automationID] = entry.name
          if !entry.command.isEmpty { pane.session.input(entry.command + "\r") }
        }
        for (index, extra) in delegate.windows.dropFirst().enumerated() {
          for pane in extra.panes {
            names[pane.automationID] = "extra-\(index + 1)"
            pane.session.input("echo extra-\(index + 1)\r")
          }
        }
        save(names, "names.json")
        after(scenario.settle) { handOff(delegate, scenario, names: names, round: 1) }
      }
    }
  }
  /// Splits the largest pane along its longer side until there are enough.
  /// The shares are kept here: a view's bounds lag its split by a layout pass.
  private static func split(
    _ window: TerminalWindow, sizes: [(pane: TerminalCanvasView, width: Double, height: Double)], remaining: Int,
    then done: @escaping @MainActor () -> Void
  ) {
    guard remaining > 0, let index = sizes.indices.max(by: {
      sizes[$0].width * sizes[$0].height < sizes[$1].width * sizes[$1].height
    }) else { return done() }
    var sizes = sizes
    let target = sizes[index]
    let known = Set(window.panes.map(ObjectIdentifier.init))
    window.selectActivePane(target.pane)
    window.window?.makeFirstResponder(target.pane)
    let sideBySide = target.width > target.height
    if sideBySide { window.splitVertical(nil) } else { window.splitHorizontal(nil) }
    guard let added = window.panes.first(where: { !known.contains(ObjectIdentifier($0)) }) else { return done() }
    let half = (width: sideBySide ? target.width / 2 : target.width, height: sideBySide ? target.height : target.height / 2)
    sizes[index] = (target.pane, half.width, half.height)
    sizes.append((added, half.width, half.height))
    after(0.2) { split(window, sizes: sizes, remaining: remaining - 1, then: done) }
  }

  private static func handOff(_ delegate: AppDelegate, _ scenario: Scenario, names: [String: String], round: Int) {
    save(record(delegate, names: names, round: round), "before.json")
    let started = DispatchTime.now().uptimeNanoseconds
    delegate.handOffSessions(relaunch: scenario.externalRelaunch != true) { succeeded in
      let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
      save(["succeeded": succeeded ? 1 : 0, "milliseconds": milliseconds, "round": Double(round)], "handoff.json")
    }
  }

  private static func verify(_ delegate: AppDelegate, _ scenario: Scenario, _ before: Record) {
    let names = load([String: String].self, "names.json") ?? [:]
    let handoff = load([String: Double].self, "handoff.json") ?? [:]
    let entries = Dictionary(scenario.panes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    // The first frames after adoption are the restored screens.
    after(1.0) {
      let restored = record(delegate, names: names, round: before.round)
      let panes = delegate.windows.flatMap(\.panes)
      for pane in panes {
        if let probe = entries[names[pane.automationID] ?? ""]?.probe { pane.session.input(probe) }
      }
      after(2.5) {
        let probed = record(delegate, names: names, round: before.round)
        var results: [Result.Pane] = []
        for old in before.panes {
          let now = restored.panes.first { $0.id == old.id }
          let later = probed.panes.first { $0.id == old.id }
          let entry = entries[old.name]
          let lost = old.descendants.filter { kill($0, 0) != 0 }
          let oldRows = old.screen.split(separator: "\n", omittingEmptySubsequences: false)
          let newRows = (now?.screen ?? "").split(separator: "\n", omittingEmptySubsequences: false)
          let equal = zip(oldRows, newRows).filter { $0 == $1 }.count
          results.append(Result.Pane(
            name: old.name,
            sameProcess: old.pid > 0 && now?.pid == old.pid && kill(old.pid, 0) == 0,
            descendantsKept: lost.isEmpty, lostDescendants: lost,
            gridKept: now?.columns == old.columns && now?.rows == old.rows,
            gridBefore: "\(old.columns)x\(old.rows)", gridRestored: "\(now?.columns ?? 0)x\(now?.rows ?? 0)",
            rowsEqualAtRestore: oldRows.isEmpty ? 0 : Double(equal) / Double(max(oldRows.count, newRows.count)),
            animated: entry?.animated == true ? now?.screen != later?.screen : nil,
            probed: entry?.expect.map { later?.screen.contains($0) == true },
            screenBefore: old.screen, screenRestored: now?.screen ?? "", screenAfterProbe: later?.screen ?? ""))
        }
        let expected = scenario.panes.count + (scenario.extraTabs ?? 0) + (scenario.extraWindows ?? 0)
        let passed = results.count == expected && delegate.windows.count == 1 + expected - scenario.panes.count
          && results.allSatisfy {
          $0.sameProcess && $0.descendantsKept && $0.gridKept && $0.animated != false && $0.probed != false
        }
        save(Result(round: before.round, passed: passed, handoffMilliseconds: handoff["milliseconds"] ?? -1,
          appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", panes: results),
          "round-\(before.round).json")
        if before.round < scenario.rounds {
          after(1.0) { handOff(delegate, scenario, names: names, round: before.round + 1) }
        } else if scenario.keepOpen != true {
          after(0.5) { NSApp.terminate(nil) }
        }
      }
    }
  }
}
#endif

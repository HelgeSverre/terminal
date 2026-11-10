import Foundation

/// Checks the terminfo entry: the source compiles, it holds the capabilities
/// the terminal supports and none it does not, `tput` expands them to the
/// expected bytes, the parser accepts those bytes, and the built bundle
/// carries the entry.
enum TerminfoSmoke {
  static let command = Command(
    name: "terminfo-smoke", usage: "",
    summary: "Compile the terminfo source and check its strings against tput, the parser and the built bundle.",
    run: run)

  static let entry = "helge-terminal"
  static let required = ["am", "bce", "km", "mir", "msgr", "colors#256", "pairs#32767"]
  /// Capabilities an inherited entry could bring in that the terminal does not support.
  static let unsupported = ["blink", "xenl", "Ms", "Cr", "Cs", "Ss", "XT"]

  /// What `tput` must print for each capability and its parameters.
  static let strings: [(capability: String, expected: String)] = [
    ("clear", "\u{1B}[H\u{1B}[2J"),
    ("cup 1 2", "\u{1B}[2;3H"),
    ("setaf 9", "\u{1B}[91m"),
    ("setaf 201", "\u{1B}[38;5;201m"),
    ("setab 9", "\u{1B}[101m"),
    ("setab 201", "\u{1B}[48;5;201m"),
    ("acsc", "``aaffggiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~"),
    ("smcup", "\u{1B}[?1049h"),
    ("rmcup", "\u{1B}[?1049l"),
    ("smkx", "\u{1B}[?1h\u{1B}="),
    ("rmkx", "\u{1B}[?1l\u{1B}>"),
    ("khome", "\u{1B}OH"),
    ("kend", "\u{1B}OF"),
    ("kent", "\u{1B}OM"),
    ("sgr0", "\u{1B}(B\u{1B}[0m"),
  ]

  static let lineDrawingInput = "`afgijklmnopqrstuvwxyz{|}~"
  static let lineDrawingOutput = "◆▒°±␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·"

  static func run(_ arguments: [String]) throws {
    guard arguments.isEmpty else { throw Failure.usage(command) }
    let probe = Repository.path("target/native/terminfo-probe")
    guard FileManager.default.isExecutableFile(atPath: probe) else {
      throw Failure("run just terminfo-test to compile the Swift ABI probe")
    }
    try run(source: Repository.path("Resources/Terminal/Terminal.terminfo"),
            bundleDatabase: Repository.path("dist/Terminal.app/Contents/Resources/terminfo"),
            probe: probe, directory: Repository.root)
    print("PASS terminfo: source compiles, bundle contains the entry, tput strings match, and parser accepts them")
  }

  /// `probe` replays its standard input through the parser on a grid of the
  /// given columns and rows, and prints the screen as JSON. It runs in `directory`.
  static func run(source: String, bundleDatabase: String, probe: String, directory: String) throws {
    try withTemporaryDirectory("helge-terminal-terminfo-") { temporary in
      let database = temporary + "/terminfo"
      try output(of: ["/usr/bin/tic", "-x", "-o", database, source])
      try checkListing(try output(of: ["/usr/bin/infocmp", "-x", "-1", "-A", database, entry]))
      let tput = { (capability: String) in
        try output(of: ["/usr/bin/tput", "-T", entry] + capability.split(separator: " ").map(String.init),
                   adding: ["TERMINFO": database])
      }
      for (capability, expected) in strings {
        let actual = try tput(capability)
        guard actual == expected else {
          throw Failure("\(capability): expected \(expected.debugDescription), got \(actual.debugDescription)")
        }
      }
      let replay = { (program: String, grid: [String], what: String) -> [String: Any] in
        let result = try runCommand([probe] + grid, directory: directory, input: program)
        guard result.succeeded else { throw Failure("\(what) failed:\n\(result.output)") }
        guard let screen = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else {
          throw Failure("\(what) did not print a JSON object:\n\(result.output)")
        }
        return screen
      }
      // Strings expanded by tput go through the real parser. This covers
      // screen clear, cursor, colour and the alternate screen without opening the app.
      let program = try tput("clear") + tput("cup 1 2") + tput("setaf 201") + "A" + tput("sgr0")
        + tput("smcup") + "X" + tput("rmcup")
      try checkScreen(try replay(program, ["8", "3"], "Swift ABI replay"))
      let lineDrawing = try tput("smacs") + lineDrawingInput + tput("rmacs")
      try checkLineDrawing(try replay(lineDrawing, ["40", "2"], "Swift ABI ACS replay"))
    }
    let listing = try output(of: ["/usr/bin/infocmp", "-x", "-1", "-A", bundleDatabase, entry])
    guard listing.contains(entry) else { throw Failure("built bundle is missing \(entry) terminfo") }
  }

  /// The output of a command that must succeed.
  @discardableResult
  private static func output(of command: [String], adding environment: [String: String] = [:]) throws -> String {
    let result = try runCommand(command, adding: environment)
    guard result.succeeded else { throw Failure("\(command.joined(separator: " ")) failed:\n\(result.output)") }
    return result.output
  }

  /// `listing` has one capability to a line, as `infocmp -1` prints them.
  static func checkListing(_ listing: String) throws {
    for capability in required where !listing.contains(capability) {
      throw Failure("missing \(capability) in compiled entry")
    }
    let lines = listing.split(separator: "\n").map { $0.drop(while: \.isWhitespace) }
    for capability in unsupported {
      let present = lines.contains { line in
        guard line.hasPrefix(capability) else { return false }
        let rest = line.dropFirst(capability.count)
        return rest.isEmpty || rest.first == "=" || rest.first == ","
      }
      if present { throw Failure("unsupported inherited capability \(capability) present") }
    }
  }

  private static func cells(_ screen: [String: Any], row: Int) throws -> [[String: Any]] {
    guard let rows = screen["rows"] as? [[String: Any]], rows.indices.contains(row),
          let cells = rows[row]["cells"] as? [[String: Any]] else { throw Failure("parser output has no row \(row)") }
    return cells
  }

  /// After the program, the `A` sits at row 1, column 2 in colour 201 on the main screen.
  private static func checkScreen(_ screen: [String: Any]) throws {
    let row = try cells(screen, row: 1)
    guard row.indices.contains(2) else { throw Failure("parser output has no cell 2 in row 1") }
    let cell = row[2]
    guard cell["text"] as? String == "A" else { throw Failure("tput cup/setaf did not reach the parser: \(cell)") }
    guard (cell["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 201] else {
      throw Failure("tput setaf lost indexed color: \(cell)")
    }
    guard !ReportValue.isTruthy(screen["alternate"]) else { throw Failure("tput rmcup did not restore the main screen") }
  }

  private static func checkLineDrawing(_ screen: [String: Any]) throws {
    let text = try cells(screen, row: 0).map { $0["text"] as? String ?? "" }.joined()
    guard text == lineDrawingOutput else { throw Failure("tput ACS mapping mismatch: \(text.debugDescription)") }
  }

  static let tests = [
    SelfTest.Case(name: "terminfo smoke: the source entry passes with a stand-in parser") {
      try withFakeProbe(alternate: false) { source, database, probe, directory in
        try run(source: source, bundleDatabase: database, probe: probe, directory: directory)
      }
    },
    SelfTest.Case(name: "terminfo smoke: a screen left on the alternate buffer fails") {
      try withFakeProbe(alternate: true) { source, database, probe, directory in
        let failure = try expectFailure("an alternate screen") {
          try run(source: source, bundleDatabase: database, probe: probe, directory: directory)
        }
        try expect(failure.message == "tput rmcup did not restore the main screen", "got: \(failure.message)")
      }
    },
    SelfTest.Case(name: "terminfo smoke: an unsupported capability is found only as a whole name") {
      let listing = "helge-terminal|test,\n\t" + required.joined(separator: ",\n\t") + ",\n\t"
      try checkListing(listing + "blinking,\n\tXTerm=1,")
      for line in ["blink=\\E[5m,", "xenl,", "XT"] {
        let failure = try expectFailure(line) { try checkListing(listing + line) }
        try expect(failure.message.hasPrefix("unsupported inherited capability"), "got: \(failure.message)")
      }
      let failure = try expectFailure("a missing capability") { try checkListing("helge-terminal|test,\n\tam,") }
      try expect(failure.message == "missing bce in compiled entry", "got: \(failure.message)")
    },
  ]

  /// Runs `body` with the repository's terminfo source, a database compiled
  /// from it in place of the bundle's, and a parser stand-in that prints the
  /// screens a correct parser would.
  private static func withFakeProbe(alternate: Bool,
                                    _ body: (String, String, String, String) throws -> Void) throws {
    try withTemporaryDirectory("dev-terminfo-smoke-") { directory in
      let source = Repository.path("Resources/Terminal/Terminal.terminfo")
      try output(of: ["/usr/bin/tic", "-x", "-o", directory + "/bundle", source])
      let blank: [String: Any] = ["text": " "]
      let marked: [String: Any] = ["text": "A", "style": ["foreground": ["Indexed": 201]]]
      try writeJSON(["alternate": alternate, "rows": [["cells": [Any]()], ["cells": [blank, blank, marked]]]],
                    to: directory + "/8.json")
      try writeJSON(["rows": [["cells": lineDrawingOutput.map { ["text": String($0)] }]]], to: directory + "/40.json")
      try writeScript("cat > /dev/null; cat \"\(directory)/$1.json\"", to: directory + "/probe")
      try body(source, directory + "/bundle", directory + "/probe", directory)
    }
  }
}

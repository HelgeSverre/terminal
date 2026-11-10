import Foundation

/// The synthetic `SHELL` of a rendering proof run: `dev rendering-proof fixture`.
///
/// Each pane shows the same image: a line naming the pane, a coloured
/// rectangle six cells wide and two high, and a barcode of 32 grey cells. The
/// capture helper measures the rectangle and reads the barcode from the
/// recorded pixels. The image is drawn again after every size change, and
/// every drawing is recorded with its PTY geometry and the time.
enum RenderingProofFixture {
  /// Magenta, green and cyan identify panes 0, 1 and 2.
  private static let colours = [[255, 0, 255], [0, 255, 0], [0, 255, 255]]
  private static let lifetimeSeconds: UInt64 = 60

  /// Seconds on the clock the native helpers read as `ProcessInfo.systemUptime`.
  static func hostTime() -> Double { Double(Clock.now) / 1_000_000_000 }

  /// The generation of a final image. It carries the geometry, so a captured
  /// frame proves which PTY size it shows. Rows fit seven bits and columns eight.
  static func finalGeneration(rows: Int, columns: Int) -> Int { 0x8000 | (rows << 8) | columns }

  /// Depends on the pane, so one pane's barcode is not valid in another.
  static func checksum(pane: Int, generation: Int) -> Int { (generation ^ (generation >> 8) ^ pane ^ 0xa5) & 0xff }

  /// The barcode: a sentinel in the lowest and the highest four bits, the
  /// generation's low 16 bits and the checksum between them.
  static func barcode(pane: Int, generation: Int) -> Int {
    0xa | ((generation & 0xffff) << 4) | (checksum(pane: pane, generation: generation) << 20) | (0x5 << 28)
  }

  /// What a pane draws. A negative control doubles the rectangle's width, an
  /// error the capture must detect.
  static func image(pane: Int, generation: Int, rows: Int, columns: Int, negative: Bool = false) -> String {
    let escape = "\u{1B}"
    let colour = colours[pane].map(String.init).joined(separator: ";")
    var text = "\(escape)[?25l\(escape)[0m\(escape)[2J\(escape)[H\(escape)]2;Synthetic rendering proof\u{07}"
    text += "PANE_\(pane) GEN_\(generation) \(columns)x\(rows)\r\n"
    text += "ASCII Aa09 | Ω中 café | 🐈 👩\u{200D}💻\r\n"
    for row in 0..<2 {
      text += "\(escape)[\(4 + row);3H\(escape)[48;2;\(colour)m" + String(repeating: " ", count: negative ? 12 : 6)
        + "\(escape)[0m"
    }
    let code = barcode(pane: pane, generation: generation)
    for bit in 0..<32 {
      let level = code & (1 << bit) == 0 ? 0 : 255
      text += "\(escape)[\(7 + bit / 8);\(3 + bit % 8)H\(escape)[48;2;\(level);\(level);\(level)m \(escape)[0m"
    }
    return text + "\(escape)[12;1HPANE_\(pane) FINAL=\(generation & 0x8000 != 0)\(escape)[0m"
  }

  /// Runs the fixture, or the image tests with `--self-test`. Any other
  /// arguments are the app's shell arguments and mean nothing here.
  static func main(_ arguments: [String]) throws {
    if arguments == ["--self-test"] {
      for test in imageTests {
        try test.run()
        print("PASS \(test.name)")
      }
      return
    }
    do { try run(ProcessInfo.processInfo.environment) } catch { throw Failure(wrapping: error) }
  }

  /// Draws the pane until the terminal goes away, the fixture is told to
  /// stop, or a minute has passed. The driver asks for final output by
  /// creating `final-output` in the run directory.
  private static func run(_ environment: [String: String]) throws {
    guard let directory = environment["TERMINAL_RENDER_PROOF_DIRECTORY"] else {
      throw Failure("missing environment variable TERMINAL_RENDER_PROOF_DIRECTORY")
    }
    let pane = try claimPaneNumber(counter: directory + "/pane-counter")
    guard colours.indices.contains(pane) else { throw Failure("Unexpected additional fixture pane") }
    Interruption.takeOver(resize: true)
    guard try runInherited(["/bin/stty", "raw", "-echo"]) else { throw Failure("Cannot configure fixture PTY") }
    let negative = environment["TERMINAL_RENDER_PROOF_NEGATIVE"] == "1"
    let pid = Int(getpid())

    let path = directory + "/pane-\(pane)-events.jsonl"
    let events = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard events >= 0 else { throw SystemFailure("open \(path)") }
    defer { close(events) }
    // The runner takes this file as the sign that the first pane has started.
    try (["pane": .int(pane), "pid": .int(pid)] as JSONValue).compact
      .write(toFile: directory + "/pane-\(pane).json", atomically: false, encoding: .utf8)

    var generation = 0
    var dirty = true
    var final = false
    let deadline = Clock.now + lifetimeSeconds * 1_000_000_000
    while Clock.now < deadline, !Interruption.stopRequested {
      if !final, FileManager.default.fileExists(atPath: directory + "/final-output") {
        final = true
        dirty = true
      }
      if Interruption.takeResize() { dirty = true }
      if dirty {
        dirty = false
        guard let size = terminalSize(of: STDOUT_FILENO) else { throw Failure("Fixture must run on a terminal PTY") }
        guard (1...127).contains(size.rows), (1...255).contains(size.columns) else {
          throw Failure("Fixture geometry exceeds barcode encoding")
        }
        generation = final ? finalGeneration(rows: size.rows, columns: size.columns) : generation + 1
        let drawn = image(pane: pane, generation: generation, rows: size.rows, columns: size.columns, negative: negative)
        try writeAll(STDOUT_FILENO, Data(drawn.utf8))
        let event: JSONValue = [
          "pane": .int(pane), "generation": .int(generation), "final": .bool(final), "rows": .int(size.rows),
          "columns": .int(size.columns), "host_time": .number(hostTime()), "pid": .int(pid),
        ]
        try writeAll(events, Data((event.compact + "\n").utf8))
      }
      usleep(20_000)
    }
  }

  static let tests = imageTests + terminalTests

  /// The grey cells an image draws where the barcode belongs: row, column and level of each.
  private static func barcodeCells(_ image: String) -> [(row: Int, column: Int, level: Int)] {
    let sequences = image.components(separatedBy: "\u{1B}[")
    return zip(sequences, sequences.dropFirst()).compactMap { position, colour in
      guard position.hasSuffix("H"), colour.hasPrefix("48;2;"), colour.hasSuffix("m ") else { return nil }
      let cell = position.dropLast().split(separator: ";").compactMap { Int($0) }
      let levels = colour.dropFirst(5).dropLast(2).split(separator: ";").compactMap { Int($0) }
      guard cell.count == 2, levels.count == 3, (7...10).contains(cell[0]), (3...10).contains(cell[1]),
            levels[0] == levels[1], levels[1] == levels[2] else { return nil }
      return (cell[0], cell[1], levels[0])
    }
  }

  static let imageTests = [
    SelfTest.Case(name: "rendering-proof fixture: pane IDs, sentinel/checksum barcode, explicit doubled-width negative control") {
      let generation = finalGeneration(rows: 20, columns: 80)
      for pane in 0...2 {
        let output = image(pane: pane, generation: generation, rows: 20, columns: 80)
        try expect(output.contains("PANE_\(pane) FINAL=true"), "pane \(pane) names itself and its final state")
        let cells = barcodeCells(output)
        try expect(cells.count == 32, "Wrong barcode cell count: \(cells.count)")
        let code = cells.reduce(0) { $0 + ($1.level == 255 ? 1 << (($1.row - 7) * 8 + $1.column - 3) : 0) }
        try expect((code >> 4) & 0xffff == generation && code & 0xf == 0xa && code >> 28 == 0x5, "Wrong barcode payload")
        try expect((code >> 20) & 0xff == (generation ^ (generation >> 8) ^ pane ^ 0xa5) & 0xff, "Wrong pane checksum")
      }
      let wide = String(repeating: " ", count: 12)
      try expect(image(pane: 1, generation: 1, rows: 20, columns: 80, negative: true).contains(wide),
                 "a negative control draws the rectangle twice as wide")
      try expect(!image(pane: 1, generation: 1, rows: 20, columns: 80).contains(wide), "a production image does not")
    },
  ]

  static let terminalTests = [
    SelfTest.Case(name: "rendering-proof fixture: login argument, initial geometry, WINCH, final geometry barcode, child reaped") {
      try withTemporaryDirectory("dev-rendering-proof-fixture-") { directory in
        do {
          let launcher = directory + "/fixture"
          try Tool.writeLauncher(at: launcher, subcommand: ["rendering-proof", "fixture"])
          let terminal = try PseudoTerminal()
          try terminal.setSize(rows: 24, columns: 80)
          let fixture = try spawnChild(
            [launcher, "-l"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERMINAL_RENDER_PROOF_DIRECTORY": directory],
            terminal: terminal.slavePath)
          terminal.releaseSlave()
          var status: ChildStatus?
          defer { if status == nil { kill(fixture, SIGKILL); _ = try? reap(fixture, within: 3) } }

          var received = Data()
          func waitFor(_ what: String, _ recorded: ([String: Any]) -> Bool) throws {
            let deadline = Clock.now + 5_000_000_000
            while true {
              while !readable([terminal.master], milliseconds: 0).isEmpty,
                    case .bytes(let bytes) = try readAvailable(terminal.master, limit: 16_384) { received += bytes }
              // A line still being written is not an event yet.
              let events = (FileManager.default.contents(atPath: directory + "/pane-0-events.jsonl") ?? Data())
                .split(separator: UInt8(ascii: "\n")).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
              if events.contains(where: recorded) { return }
              guard Clock.now < deadline else { throw Failure("Synthetic PTY fixture timed out waiting for \(what)") }
              usleep(10_000)
            }
          }
          func sized(_ event: [String: Any], _ rows: Int, _ columns: Int) -> Bool {
            event["rows"] as? Int == rows && event["columns"] as? Int == columns
          }
          try waitFor("the initial geometry") { sized($0, 24, 80) }
          try terminal.setSize(rows: 28, columns: 90)
          kill(fixture, SIGWINCH)
          try waitFor("the resized geometry") { sized($0, 28, 90) }
          FileManager.default.createFile(atPath: directory + "/final-output", contents: nil)
          try waitFor("the final image") {
            $0["final"] as? Bool == true && $0["generation"] as? Int == finalGeneration(rows: 28, columns: 90)
          }
          try expect(received.range(of: Data("PANE_0".utf8)) != nil, "Fixture output absent")
          let metadata = try readJSONObject(directory + "/pane-0.json")
          try expect(metadata["pane"] as? Int == 0 && metadata["pid"] as? Int == Int(fixture), "the pane names its process")

          kill(fixture, SIGTERM)
          status = try reap(fixture, within: 3)
          try expect(status?.succeeded == true, "the fixture ends cleanly after TERM: \(String(describing: status))")
        } catch { throw Failure(wrapping: error) }
      }
    },
  ]
}

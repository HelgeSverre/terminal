import Foundation

// Runs the emulator fuzzer (Tests/TerminalTests/TerminalFuzzer.swift):
//   fuzz SECONDS [FIRST-SEED]   random cases until the time is up
//   fuzz replay SEED            one case, with its bytes written beside it
// The seed being run is written to `reports/fuzz-current-seed` first, so a
// crash leaves it behind.
@main enum FuzzProgram {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let reports = URL(fileURLWithPath: "reports")
    try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    let current = reports.appendingPathComponent("fuzz-current-seed")
    if arguments.first == "replay", arguments.count == 2, let seed = UInt64(arguments[1]) {
      let fuzzCase = TerminalFuzzer.makeCase(seed: seed)
      let transcript = reports.appendingPathComponent("fuzz-\(seed).bin")
      try? TerminalFuzzer.transcript(fuzzCase).write(to: transcript)
      print("seed \(seed): \(fuzzCase.columns)x\(fuzzCase.rows), \(fuzzCase.steps.count) steps, \(fuzzCase.bytes) bytes; bytes in \(transcript.path)")
      if let failure = TerminalFuzzer.run(fuzzCase) { print("FAIL \(failure)"); exit(1) }
      print("PASS"); return
    }
    guard let seconds = arguments.first.flatMap(Double.init), seconds > 0 else {
      print("usage: fuzz SECONDS [FIRST-SEED] | fuzz replay SEED"); exit(2)
    }
    var seed = arguments.count > 1 ? UInt64(arguments[1]) ?? 1 : UInt64(Date().timeIntervalSince1970 * 1000)
    let deadline = Date().addingTimeInterval(seconds)
    var cases = 0, bytes = 0
    while Date() < deadline {
      try? String(seed).write(to: current, atomically: false, encoding: .utf8)
      let fuzzCase = TerminalFuzzer.makeCase(seed: seed)
      if let failure = TerminalFuzzer.run(fuzzCase) {
        print("FAIL seed \(seed): \(failure)\nReplay with: just fuzz-replay \(seed)"); exit(1)
      }
      cases += 1; bytes += fuzzCase.bytes; seed &+= 1
    }
    try? FileManager.default.removeItem(at: current)
    print("PASS \(cases) cases, \(bytes / 1024) KiB of input, seeds up to \(seed - 1)")
  }
}

import Foundation
import Testing

/// A fixed set of fuzz cases, so every run of the suite covers the same
/// ground. `just fuzz` explores further.
@Suite struct TerminalFuzzTests {
  @Test func aHundredAndFiftyCasesKeepTheEmulatorSound() {
    var failures: [String] = []
    for seed in UInt64(1)...150 {
      let fuzzCase = TerminalFuzzer.makeCase(seed: seed)
      if let failure = TerminalFuzzer.run(fuzzCase) { failures.append("seed \(seed): \(failure)") }
      if failures.count >= 5 { break }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))\nReplay one with: just fuzz replay <seed>")
  }

  @Test func aSeedMakesTheSameCaseEveryTime() {
    let first = TerminalFuzzer.transcript(TerminalFuzzer.makeCase(seed: 77))
    #expect(first == TerminalFuzzer.transcript(TerminalFuzzer.makeCase(seed: 77)))
    #expect(first != TerminalFuzzer.transcript(TerminalFuzzer.makeCase(seed: 78)))
  }
}

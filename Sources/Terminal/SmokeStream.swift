import Foundation

/// SplitMix64. The intense resize smoke draws its layout, its resize schedule
/// and its stream contents from it, so a run with one seed always asks for
/// the same things in the same order.
struct SmokeRandom: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  /// A value in `range`, both ends included.
  mutating func pick(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }

  /// A value in 0..<1.
  mutating func fraction() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// The child every pane of the intense resize smoke runs: this executable,
/// started with `--smoke-stream`. It writes numbered lines of seeded text
/// until its terminal goes away.
///
/// A line is its number as eight digits, a space, and a payload of colored
/// ASCII with an occasional run of wide and combining characters. The number
/// is what the smoke checks: whatever the pane's size, the lines on screen
/// must count up by one.
enum SmokeStream {
  static let flag = "--smoke-stream"
  /// Set by the smoke before it opens each pane, so the panes differ.
  static let seedVariable = "TERMINAL_SMOKE_STREAM_SEED"
  static let numberWidth = 8

  private static let ascii = Array(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:-_=+*/()[]{}<>#@!?".utf8)
  private static let wide = ["日本語", "端末", "한글", "🙂", "🚀", "e\u{301}", "👩‍💻", "→", "█▓▒░"]

  /// Runs the stream and never returns, when this process was started as one.
  static func runIfRequested() {
    guard CommandLine.arguments.dropFirst().first == flag else { return }
    let seed = ProcessInfo.processInfo.environment[seedVariable].flatMap { UInt64($0) } ?? 1
    var random = SmokeRandom(seed: seed)
    var number = 0
    while true {
      var burst = [UInt8]()
      for _ in 0..<random.pick(1...40) {
        burst += line(number, using: &random)
        number = (number + 1) % 100_000_000
      }
      guard write(burst) else { exit(0) }
      usleep(UInt32(random.pick(1_000...8_000)))
    }
  }

  private static func line(_ number: Int, using random: inout SmokeRandom) -> [UInt8] {
    let digits = String(number)
    var bytes = Array((String(repeating: "0", count: numberWidth - digits.count) + digits + " ").utf8)
    // Mostly short lines, some that wrap once or twice, a few that fill a screen.
    let length: Int
    switch random.pick(0...9) {
    case 0...5: length = random.pick(0...60)
    case 6...8: length = random.pick(60...200)
    default: length = random.pick(200...600)
    }
    var written = 0
    while written < length {
      bytes += Array("\u{1B}[38;5;\(random.pick(17...230))m".utf8)
      if random.pick(0...11) == 0 {
        bytes += Array(wide[random.pick(0...wide.count - 1)].utf8)
        written += 2
      }
      let run = random.pick(1...24)
      for _ in 0..<run { bytes.append(ascii[random.pick(0...ascii.count - 1)]) }
      written += run
    }
    bytes += Array("\u{1B}[0m\r\n".utf8)
    return bytes
  }

  /// False once the terminal is gone.
  private static func write(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes { Foundation.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
      if count > 0 { offset += count } else if errno != EINTR && errno != EAGAIN { return false }
    }
    return true
  }
}

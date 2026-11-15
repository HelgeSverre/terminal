import Foundation
import TerminalInterop
#if !FUZZ_PROGRAM
@testable import TerminalEngine
#endif

/// A fuzzer for the emulator: seeded, so every case can be made again from
/// its seed. Each case is a terminal of a random size and a list of steps:
/// byte streams built from the escape-code grammar (with random damage),
/// resizes and snapshots. After every step the emulator's invariants must
/// hold and a step must finish in bounded work.
///
/// The test suite runs a few thousand cases; `just fuzz` runs it for as long
/// as asked, with sanitizers. Both use this file.
enum TerminalFuzzer {
  struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
  }

  enum Step {
    case bytes([UInt8])
    case resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)
    case snapshot(scroll: Int?)
    case setHistory(Int)
  }
  struct Case {
    let seed: UInt64
    let columns: Int
    let rows: Int
    let steps: [Step]
    var bytes: Int { steps.reduce(0) { if case .bytes(let b) = $1 { return $0 + b.count }; return $0 } }
  }

  // MARK: Generating

  private static let finals: [UInt8] = Array("@ABCDEFGHIJKLMPSTXZ`abcdefghilmnpqrstuxyz{|}~".utf8)
  private static let privateModes = [1, 3, 5, 6, 7, 12, 25, 45, 47, 66, 67, 69, 80, 1000, 1002, 1003, 1004, 1005, 1006,
                                     1015, 1016, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 8452]
  private static let words = ["hello", "ls -la", "❯", "猫", "👩🏽‍💻", "🇳🇴", "e\u{301}", "\u{200D}", "\u{FE0F}", "क्ष",
                              "\u{10EEEE}\u{305}\u{30D}", "\t", "      ", "──┼──", "▀▄█", "\u{0}", "\u{7F}"]

  private static func number(_ random: inout Random) -> String {
    switch random.below(10) {
    case 0: return ""
    case 1: return String(random.pick([0, 65535, 65536, 99_999_999, 4_294_967_296]))
    case 2: return String(random.below(10_000))
    default: return String(random.below(300))
    }
  }
  private static func csi(_ random: inout Random) -> String {
    var text = "\u{1b}["
    if random.chance(30) { text += random.pick(["?", ">", "<", "="]) }
    let count = random.chance(5) ? random.below(40) : random.below(5)
    text += (0..<count).map { _ in number(&random) }.joined(separator: random.chance(10) ? ":" : ";")
    if random.chance(10) { text += random.pick([" ", "!", "\"", "$", "'", "*", "#"]) }
    text += String(UnicodeScalar(random.chance(90) ? random.pick(finals) : UInt8(0x40 + random.below(0x3f))))
    return text
  }
  private static func terminator(_ random: inout Random) -> String {
    random.pick(["\u{7}", "\u{1b}\\", "\u{1b}\\", "\u{18}", "", "\u{1b}["])
  }
  private static func base64(_ random: inout Random, bytes: Int) -> String {
    Data((0..<bytes).map { _ in UInt8(truncatingIfNeeded: random.next()) }).base64EncodedString()
  }
  private static func osc(_ random: inout Random) -> String {
    let body: String
    switch random.below(11) {
    case 0: body = "0;" + random.pick(words)
    case 1: body = "2;" + String(repeating: "t", count: random.below(10_000))
    case 2: body = "4;\(random.below(300));" + random.pick(["?", "rgb:ff/00/00", "#123456", "rgb:zz"])
    case 3: body = random.pick(["10", "11", "12"]) + ";" + random.pick(["?", "#ffffff", "rgb:1/2/3"])
    case 4: body = "52;c;" + random.pick(["?", base64(&random, bytes: random.below(200)), "!!"])
    case 5: body = "8;id=\(random.below(9));" + random.pick(["https://example.com", "", "file:///tmp"])
    case 6: body = "133;" + random.pick(["A", "B", "C", "D;0", "Z"])
    case 7: body = "7;file://host/" + random.pick(["tmp", "Users/x", ""])
    case 8: body = "1337;File=inline=\(random.below(2));width=\(number(&random)):" + base64(&random, bytes: random.below(300))
    case 9: body = "104;" + number(&random)
    default: body = number(&random) + ";" + random.pick(words)
    }
    return "\u{1b}]" + body + terminator(&random)
  }
  private static func dcs(_ random: inout Random) -> String {
    if random.chance(70) {
      var picture = "\u{1b}P\(number(&random));\(number(&random))q"
      if random.chance(50) { picture += "\"1;1;\(number(&random));\(number(&random))" }
      for _ in 0..<random.below(60) {
        switch random.below(6) {
        case 0: picture += "#\(random.below(300));\(random.below(3));\(random.below(400));\(random.below(120));\(random.below(120))"
        case 1: picture += "#\(random.below(300))"
        case 2: picture += "!\(number(&random))" + String(UnicodeScalar(UInt8(0x3f + random.below(64))))
        case 3: picture += random.pick(["$", "-", "-"])
        default: picture += String((0..<random.below(20)).map { _ in Character(UnicodeScalar(UInt8(0x3f + random.below(64)))) })
        }
      }
      return picture + terminator(&random)
    }
    return "\u{1b}P" + random.pick(["+q544e", "$qm", "1$r", "=1s"]) + terminator(&random)
  }
  private static func kitty(_ random: inout Random) -> String {
    var fields: [String] = []
    fields.append("a=" + random.pick(["t", "T", "p", "d", "q", "f", "a", "c", "x"]))
    let options = ["f": ["24", "32", "100", "7"], "t": ["d", "f", "t", "s"], "o": ["z", "y"], "d": ["a", "A", "i", "I", "c", "p", "q", "x", "y", "z", "r", "n", "f"],
                   "U": ["1", "0"], "C": ["1"], "m": ["0", "1"], "q": ["0", "1", "2"]]
    for _ in 0..<random.below(8) {
      // Sorted: a dictionary's order changes between runs, a seed's case must not.
      if random.chance(50) {
        let key = random.pick(options.keys.sorted())
        fields.append("\(key)=\(random.pick(options[key]!))")
      } else {
        let key = random.pick(["i", "I", "p", "s", "v", "x", "y", "w", "h", "c", "r", "X", "Y", "z", "P", "Q", "H", "V", "S", "O"])
        fields.append("\(key)=" + (random.chance(10) ? "-\(random.below(9))" : number(&random)))
      }
    }
    return "\u{1b}_G" + fields.joined(separator: ",") + ";" + base64(&random, bytes: random.below(400)) + terminator(&random)
  }
  private static func text(_ random: inout Random) -> String {
    switch random.below(5) {
    case 0: return String(repeating: random.pick(words), count: 1 + random.below(30))
    case 1: return String((0..<random.below(200)).map { _ in Character(UnicodeScalar(UInt8(0x20 + random.below(95)))) })
    case 2:
      var text = ""
      for _ in 0..<random.below(40) {
        if let scalar = Unicode.Scalar(UInt32(random.below(0x11_0000))) { text.unicodeScalars.append(scalar) }
      }
      return text
    default: return random.pick(words) + "\r\n"
    }
  }

  private static func chunk(_ random: inout Random) -> [UInt8] {
    var text = ""
    for _ in 0..<(1 + random.below(12)) {
      switch random.below(20) {
      case 0...5: text += Self.text(&random)
      case 6...10: text += csi(&random)
      case 11: text += "\u{1b}[?\(random.pick(privateModes))" + random.pick(["h", "l", "$p"])
      case 12: text += "\u{1b}" + random.pick(["7", "8", "c", "D", "E", "H", "M", "=", ">", "(0", "(B", "#8", "Z", "%G", " F"])
      case 13: text += osc(&random)
      case 14: text += dcs(&random)
      case 15: text += kitty(&random)
      case 16: text += String(UnicodeScalar(UInt8(random.below(32))))
      case 17: text += "\u{1b}[\(random.below(100_000))b"
      case 18: text += "\u{1b}[\(random.below(200));\(random.below(200))r\u{1b}[\(random.below(80));\(random.below(80))s"
      default: text += "\u{1b}[\(random.below(60) + 1);\(random.below(200) + 1)H"
      }
    }
    var bytes = Array(text.utf8)
    // Damage: flip, drop or insert bytes, so the parser meets broken input.
    if random.chance(30) {
      for _ in 0..<(1 + random.below(4)) where !bytes.isEmpty {
        let index = random.below(bytes.count)
        switch random.below(3) {
        case 0: bytes[index] ^= UInt8(1 << random.below(8))
        case 1: bytes.remove(at: index)
        default: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: index)
        }
      }
    }
    return bytes
  }

  static func makeCase(seed: UInt64) -> Case {
    var random = Random(state: seed)
    let columns = random.chance(10) ? 1 + random.below(3) : 1 + random.below(160)
    let rows = random.chance(10) ? 1 + random.below(3) : 1 + random.below(60)
    var steps: [Step] = []
    for _ in 0..<(1 + random.below(30)) {
      switch random.below(20) {
      case 0: steps.append(.resize(columns: 1 + random.below(200), rows: 1 + random.below(70),
                                   cellWidth: 1 + random.below(30), cellHeight: 1 + random.below(60)))
      case 1: steps.append(.snapshot(scroll: random.chance(50) ? nil : random.below(500)))
      case 2: steps.append(.setHistory(random.pick([0, 1, 10, 1000, 50_000])))
      default: steps.append(.bytes(chunk(&random)))
      }
    }
    steps.append(.snapshot(scroll: nil))
    return Case(seed: seed, columns: columns, rows: rows, steps: steps)
  }

  // MARK: Running

  /// Runs a case; returns what went wrong, or nil.
  static func run(_ fuzzCase: Case) -> String? {
    guard let core = helge_terminal_create(UInt32(fuzzCase.columns), UInt32(fuzzCase.rows)) else {
      return "terminal of \(fuzzCase.columns)x\(fuzzCase.rows) could not be made"
    }
    defer { helge_terminal_destroy(core) }
    var random = Random(state: fuzzCase.seed ^ 0xA5A5_A5A5)
    var now: UInt64 = 1_000
    let started = DispatchTime.now().uptimeNanoseconds
    for (index, step) in fuzzCase.steps.enumerated() {
      switch step {
      case .bytes(let bytes):
        var offset = 0, turns = 0
        while offset < bytes.count || helge_terminal_has_work(core) {
          turns += 1
          guard turns < 1_000_000 else { return "step \(index): no progress feeding" }
          let repeating = helge_terminal_has_work(core)
          let piece = min(bytes.count - offset, random.chance(30) ? 1 + random.below(8) : bytes.count)
          let used = bytes.withUnsafeBufferPointer {
            helge_terminal_feed(core, $0.baseAddress.map { $0 + offset }, piece, now)
          }
          offset += used
          now += UInt64(random.below(30))
          // The host drains replies between turns; a full reply buffer stops input.
          helge_terminal_replies(core, nil) { _, _, _ in }
          // A turn that only advanced a repeat consumes nothing and is progress.
          if used == 0 && !repeating && piece > 0 {
            return "step \(index): feed consumed nothing at \(offset) of \(bytes.count), next "
              + bytes[offset..<min(bytes.count, offset + 24)].map { String(format: "%02x", $0) }.joined(separator: " ")
          }
        }
        helge_terminal_replies(core, nil) { _, _, _ in }
        helge_terminal_take_clipboard_requests(core, nil) { _, _, _, _ in }
      case .resize(let columns, let rows, let width, let height):
        _ = helge_terminal_resize_pixels(core, UInt32(columns), UInt32(rows), UInt32(width), UInt32(height))
      case .snapshot(let scroll):
        now += 200
        let result = swiftTerminalSnapshot(core, scroll: scroll, now: now)
        if result.snapshot == nil, let error = result.error { return "step \(index): snapshot failed: \(error)" }
      case .setHistory(let rows):
        helge_terminal_set_history_limit(core, UInt32(rows))
      }
      guard helge_terminal_validate(core) else { return "step \(index): invariants broken" }
      if DispatchTime.now().uptimeNanoseconds - started > 10_000_000_000 { return "step \(index): over 10 seconds" }
    }
    return nil
  }

  /// The bytes of a case, for keeping a failure: one file a reader can
  /// replay through any terminal.
  static func transcript(_ fuzzCase: Case) -> Data {
    var data = Data()
    for step in fuzzCase.steps { if case .bytes(let bytes) = step { data.append(contentsOf: bytes) } }
    return data
  }
}

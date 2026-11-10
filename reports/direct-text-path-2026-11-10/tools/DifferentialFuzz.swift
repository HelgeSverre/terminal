import Foundation

// Differential fuzzer for the terminal core. Build this file against two source
// trees, run both binaries with the same arguments, and diff their output.
// Every line is a deterministic function of the seed and the core's behavior.

struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }
  mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
  mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
}

func fnv(_ data: Data, _ seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
  var hash = seed
  data.withUnsafeBytes { for byte in $0 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 } }
  return hash
}

let wideText = ["猫", "日本語", "한글", "全角ＡＢ", "中"]
let clusterText = [
  "e\u{301}", "é", "👩🏽‍💻", "🇳🇴", "🇳", "👍🏿", "a\u{300}\u{301}\u{302}", "\u{1100}\u{1161}\u{11a8}",
  "\u{0600}1", "क्ष", "❤️", "☺\u{fe0e}", "\u{200d}", "\u{200b}", "\u{fe0f}", "\u{301}", "👨‍👩‍👧‍👦",
  "∑─▁▂▃▄▅▆▇█", "ß", "Ω", "\u{ad}", "\u{1f1e6}\u{1f1e7}\u{1f1e8}", "\u{115f}", "\u{3000}", "\u{e0001}",
]
let asciiAlphabet = Array("abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 ~!@#$%^&*()_+{}|:<>?`-=[];',./".utf8)

func generate(_ rng: inout SplitMix64, columns: Int, rows: Int, profile: Int) -> [UInt8] {
  var out: [UInt8] = []
  func text(_ value: String) { out += Array(value.utf8) }
  func csi(_ body: String) { text("\u{1b}[" + body) }
  let n = { (rng: inout SplitMix64, limit: Int) -> Int in rng.below(limit + 2) }
  // Profiles shift the mix: 0 text-heavy, 1 control-heavy, 2 unicode-heavy, 3 everything.
  let roll = rng.below(100)
  let textShare = [70, 35, 35, 45][profile]
  let unicodeShare = [5, 10, 40, 15][profile]
  if roll < textShare {
    let length = rng.chance(10) ? rng.below(columns * 3) + 1 : rng.chance(50) ? rng.below(24) + 1 : rng.below(columns + 8) + 1
    for _ in 0..<length { out.append(asciiAlphabet[rng.below(asciiAlphabet.count)]) }
  } else if roll < textShare + unicodeShare {
    for _ in 0..<(rng.below(6) + 1) {
      switch rng.below(10) {
      case 0...2: text(rng.pick(wideText))
      case 3...7: text(rng.pick(clusterText))
      case 8: out.append(asciiAlphabet[rng.below(asciiAlphabet.count)])
      default:
        // Malformed and truncated UTF-8.
        out += rng.pick([[0xff], [0xc3], [0xe2, 0x82], [0xf0, 0x9f, 0x98], [0x80], [0xed, 0xa0, 0x80], [0xc0, 0xaf], [0xf4, 0x90, 0x80, 0x80]] as [[UInt8]])
      }
    }
  } else {
    switch rng.below(64) {
    case 0...9: text("\r\n")
    case 10...13: text("\n")
    case 14...16: text("\r")
    case 17: out.append(0x08)
    case 18, 19: out.append(0x09)
    case 20...27:
      // SGR in assorted forms.
      switch rng.below(10) {
      case 0: csi("0m")
      case 1: csi("m")
      case 2: csi("38;2;\(rng.below(256));\(rng.below(256));\(rng.below(256))m")
      case 3: csi("48;2;\(rng.below(256));\(rng.below(256));\(rng.below(256))m")
      case 4: csi("\(rng.pick([1, 2, 3, 4, 5, 7, 8, 9, 21, 22, 23, 24, 27, 53, 55]))m")
      case 5: csi("\(30 + rng.below(8));\(40 + rng.below(8))m")
      case 6: csi("38;5;\(rng.below(256))m")
      case 7: csi("4:\(rng.below(6))m")
      case 8: csi("38:2::\(rng.below(256)):\(rng.below(256)):\(rng.below(256));1m")
      default: csi("\(90 + rng.below(8));58;5;\(rng.below(256))m")
      }
    case 28...31: csi("\(n(&rng, rows));\(n(&rng, columns))H")
    case 32: csi("\(n(&rng, rows))A")
    case 33: csi("\(n(&rng, rows))B")
    case 34: csi("\(n(&rng, columns))C")
    case 35: csi("\(n(&rng, columns))D")
    case 36: csi("\(rng.below(3))K")
    case 37: csi("\(rng.below(4))J")
    case 38: csi("\(n(&rng, columns))X")
    case 39: csi("\(n(&rng, columns))@")
    case 40: csi("\(n(&rng, columns))P")
    case 41: csi("\(n(&rng, rows))L")
    case 42: csi("\(n(&rng, rows))M")
    case 43: csi("\(n(&rng, rows))S")
    case 44: csi("\(n(&rng, rows))T")
    case 45: csi("\(n(&rng, rows));\(n(&rng, rows))r")
    case 46: csi("?69\(rng.chance(60) ? "h" : "l")"); if rng.chance(70) { csi("\(n(&rng, columns));\(n(&rng, columns))s") }
    case 47: csi("?7\(rng.chance(40) ? "l" : "h")")
    case 48: csi("4\(rng.chance(50) ? "h" : "l")")
    case 49: csi("?6\(rng.chance(40) ? "h" : "l")")
    case 50: csi("?\(rng.pick([47, 1047, 1049]))\(rng.chance(50) ? "h" : "l")")
    case 51: csi("20\(rng.chance(30) ? "h" : "l")")
    case 52: csi("\(rng.chance(80) ? rng.below(columns * 2) : rng.below(5000))b")
    case 53: csi("\(rng.pick([5, 6]))n")
    case 54: text(rng.pick(["\u{1b}7", "\u{1b}8", "\u{1b}M", "\u{1b}D", "\u{1b}E", "\u{1b}H"]))
    case 55: text(rng.pick(["\u{1b}(0", "\u{1b}(B", "\u{1b})0", "\u{0e}", "\u{0f}", "\u{1b})B"]))
    case 56:
      if rng.chance(60) { text("\u{1b}]8;;https://example.com/\(rng.below(4))\u{1b}\\") } else { text("\u{1b}]8;;\u{07}") }
    case 57: text(rng.pick(["\u{1b}]0;title \(rng.below(9))\u{07}", "\u{1b}]133;A\u{07}", "\u{1b}]133;B\u{07}", "\u{1b}]133;C\u{07}", "\u{1b}]133;A;redraw=1\u{1b}\\", "\u{1b}]7;file:///tmp\u{07}"]))
    case 58: csi("\(rng.below(3))\"q"); if rng.chance(50) { csi("?\(rng.below(3))J") }
    case 59: csi("\(rng.pick(["g", "3g", "0g"]))"); if rng.chance(30) { csi("\(n(&rng, 4))I") } else if rng.chance(30) { csi("\(n(&rng, 4))Z") }
    case 60: csi("\(n(&rng, columns))G"); if rng.chance(50) { csi("\(n(&rng, rows))d") }
    case 61: csi("\(n(&rng, 3))E"); if rng.chance(50) { csi("\(n(&rng, 3))F") }
    case 62:
      if rng.chance(8) { text("\u{1b}c") } else if rng.chance(20) { csi("!p") } else { csi("?25\(rng.chance(50) ? "h" : "l")"); csi("\(rng.below(7)) q") }
    default:
      // Truncated, aborted, and malformed control sequences.
      text(rng.pick(["\u{1b}[", "\u{1b}[38;2;", "\u{1b}", "\u{18}", "\u{1b}[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17m", "\u{1b}[>1u", "\u{1b}[?u", "\u{1b}[<u", "\u{1b}[=5;2u", "\u{1b}[?69$p", "\u{1b}[99999999999m", "\u{1b}]52;c;aGVsbG8=\u{07}", "\u{1b}_Gi=1;\u{1b}\\", "\u{1b}P1$r\u{1b}\\", "\u{7f}", "\u{00}", "\u{1b}[2026h", "\u{1b}[?2026l", "\u{1b}[c", "\u{1b}[s", "\u{1b}[u"]))
    }
  }
  return out
}

final class ReplySink { var data = Data() }
let collectReplies: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
  guard let context, let bytes else { return }
  Unmanaged<ReplySink>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
}

func canonicalSnapshot(_ terminal: OpaquePointer, scroll: Int, now: UInt64) -> Data {
  guard let raw = terminal_snapshot(terminal, scroll, now) else { return Data("gated".utf8) }
  defer { terminal_string_free(raw) }
  let data = Data(bytes: raw, count: strlen(raw))
  guard let object = try? JSONSerialization.jsonObject(with: data),
        let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return data }
  return canonical
}

func runSeed(_ seed: UInt64, tokens: Int, dump: Bool) {
  var rng = SplitMix64(state: seed)
  let geometries = [(20, 6), (40, 10), (80, 24), (100, 30), (7, 3), (2, 2), (132, 12)]
  var (columns, rows) = rng.pick(geometries)
  let profile = rng.below(4)
  let terminal = terminal_create(UInt32(columns), UInt32(rows))!
  defer { terminal_destroy(terminal) }
  terminal_set_history_limit(terminal, UInt32(rng.pick([0, 5, 50, 10_000])))
  let sink = ReplySink()
  let context = Unmanaged.passUnretained(sink).toOpaque()
  var now: UInt64 = 0
  var replyHash: UInt64 = 0xcbf2_9ce4_8422_2325
  var pending: [UInt8] = []
  var fed = 0
  let checkpointEvery = max(1, tokens / 24)
  func feedAll(_ bytes: [UInt8]) {
    var offset = 0
    var guardTurns = 0
    bytes.withUnsafeBufferPointer { buffer in
      while offset < bytes.count || terminal_has_work(terminal) {
        now &+= 1
        let used = terminal_feed(terminal, buffer.baseAddress! + offset, bytes.count - offset, now)
        offset += used
        terminal_replies(terminal, context, collectReplies)
        if !sink.data.isEmpty { replyHash = fnv(sink.data, replyHash); sink.data.removeAll(keepingCapacity: true) }
        guardTurns += 1
        precondition(guardTurns < 10_000_000, "feed made no progress")
      }
    }
    fed += bytes.count
  }
  for token in 0..<tokens {
    pending += generate(&rng, columns: columns, rows: rows, profile: profile)
    // Vary transport chunking: single bytes, small pieces, and large batches.
    let mode = rng.below(10)
    if mode < 2 {
      for byte in pending { feedAll([byte]) }
      pending.removeAll(keepingCapacity: true)
    } else if mode < 5 {
      var index = 0
      while index < pending.count {
        let size = min(pending.count - index, rng.below(7) + 1)
        feedAll(Array(pending[index..<(index + size)])); index += size
      }
      pending.removeAll(keepingCapacity: true)
    } else if mode < 8 || pending.count > 20_000 {
      feedAll(pending); pending.removeAll(keepingCapacity: true)
    }
    if rng.chance(1) {
      feedAll(pending); pending.removeAll(keepingCapacity: true)
      (columns, rows) = rng.pick(geometries)
      _ = terminal_resize(terminal, UInt32(columns), UInt32(rows))
    }
    if rng.chance(1) { terminal_view_scroll(terminal, Int64(rng.below(9)) - 3) }
    if token % checkpointEvery == checkpointEvery - 1 || token == tokens - 1 {
      feedAll(pending); pending.removeAll(keepingCapacity: true)
      now &+= 1
      let live = canonicalSnapshot(terminal, scroll: 0, now: now)
      let scrolled = canonicalSnapshot(terminal, scroll: rng.below(40) + 1, now: now)
      let valid = terminal_validate(terminal)
      print("seed \(seed) token \(token) bytes \(fed) live \(String(fnv(live), radix: 16)) scrolled \(String(fnv(scrolled), radix: 16)) replies \(String(replyHash, radix: 16)) history \(terminal_history_bytes(terminal)) valid \(valid)")
      if dump, token == tokens - 1 { print(String(decoding: live, as: UTF8.self)) }
    }
  }
}

@main struct FuzzMain {
  static func main() {
    let arguments = CommandLine.arguments
    func value(_ name: String, _ fallback: UInt64) -> UInt64 {
      arguments.firstIndex(of: name).map { UInt64(arguments[$0 + 1])! } ?? fallback
    }
    let first = value("--first", 1), count = value("--count", 50), tokens = Int(value("--tokens", 3000))
    for seed in first..<(first + count) { runSeed(seed, tokens: tokens, dump: arguments.contains("--dump")) }
  }
}

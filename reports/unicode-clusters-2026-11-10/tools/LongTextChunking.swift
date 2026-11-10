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

func canonicalSnapshot(_ terminal: OpaquePointer, scroll: Int, now: UInt64) -> Data {
  guard let raw = terminal_snapshot(terminal, scroll, now) else { return Data("gated".utf8) }
  defer { terminal_string_free(raw) }
  let data = Data(bytes: raw, count: strlen(raw))
  guard let object = try? JSONSerialization.jsonObject(with: data),
        let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return data }
  return canonical
}


// Long unbroken text: pending decoded scalars cross the flush threshold many
// times, in every alignment with clusters and short ASCII runs. The same bytes
// fed whole, in pieces and one at a time must leave the same terminal.
func feed(_ terminal: OpaquePointer, _ bytes: [UInt8], piece: Int, now: inout UInt64) {
  var offset = 0
  bytes.withUnsafeBufferPointer { buffer in
    while offset < bytes.count || terminal_has_work(terminal) {
      now &+= 1
      offset += terminal_feed(terminal, buffer.baseAddress! + offset, min(piece, bytes.count - offset), now)
    }
  }
}
@main struct LongTextMain {
  static func main() {
    let words = wideText + clusterText + ["a", "bc", " ", "hello world", "0123456789abcdef", "The quick brown fox jumps over the lazy dog", "é", "猫", "x"]
    for seed in UInt64(1)...60 {
      var rng = SplitMix64(state: seed)
      let (columns, rows) = rng.pick([(20, 6), (80, 24), (100, 30), (7, 3), (132, 12)])
      var bytes: [UInt8] = []
      for line in 0..<(rng.below(4) + 2) {
        if rng.chance(30) { bytes += Array("\u{1b}[4h".utf8) } else { bytes += Array("\u{1b}[4l".utf8) }
        let target = rng.pick([900, 1024, 1500, 2048, 5000, 9000])
        var scalars = 0
        while scalars < target {
          let word = rng.chance(60) ? rng.pick(words) : rng.pick(clusterText)
          bytes += Array(word.utf8); scalars += word.unicodeScalars.count
        }
        bytes += Array((line % 2 == 0 ? "\r\n" : "\u{1b}[31m").utf8)
      }
      var hashes: [String] = []
      for piece in [bytes.count, 1, 3, 1021, 4096] {
        let terminal = terminal_create(UInt32(columns), UInt32(rows))!
        defer { terminal_destroy(terminal) }
        var now: UInt64 = 0
        feed(terminal, bytes, piece: piece, now: &now)
        now &+= 1
        let live = canonicalSnapshot(terminal, scroll: 0, now: now)
        let scrolled = canonicalSnapshot(terminal, scroll: 7, now: now)
        hashes.append("\(String(fnv(live), radix: 16)) \(String(fnv(scrolled), radix: 16)) \(terminal_history_bytes(terminal)) \(terminal_validate(terminal))")
      }
      precondition(Set(hashes).count == 1, "seed \(seed): chunking changed the result")
      print("seed \(seed) bytes \(bytes.count) \(hashes[0])")
    }
  }
}

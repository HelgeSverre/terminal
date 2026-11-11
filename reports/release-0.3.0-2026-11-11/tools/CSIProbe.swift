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


// For every CSI final byte, with every private marker and intermediate byte:
// does the terminal act on the sequence? State is compared with a terminal
// that never received it.
func observe(_ sequence: String) -> (state: UInt64, replies: String) {
  let terminal = terminal_create(40, 12)!
  defer { terminal_destroy(terminal) }
  let sink = ReplySink()
  let context = Unmanaged.passUnretained(sink).toOpaque()
  var now: UInt64 = 0
  func feed(_ text: String) {
    let bytes = Array(text.utf8); var offset = 0
    bytes.withUnsafeBufferPointer { buffer in
      while offset < bytes.count || terminal_has_work(terminal) {
        now &+= 1
        offset += terminal_feed(terminal, buffer.baseAddress! + offset, bytes.count - offset, now)
        terminal_replies(terminal, context, collectReplies)
      }
    }
  }
  // Content on several rows, a cursor away from the edges, a coloured pen.
  feed("\u{1b}[31mone\r\ntwo two\r\nthree\r\nfour\r\nfive\u{1b}[3;4H")
  sink.data.removeAll()
  feed(sequence)
  let replies = String(decoding: sink.data, as: UTF8.self).replacingOccurrences(of: "\u{1b}", with: "ESC")
  // A following character shows the pen, the cursor and any mode change.
  feed("Z\u{1b}[6n")
  now &+= 1
  let snapshot = canonicalSnapshot(terminal, scroll: 0, now: now)
  if CommandLine.arguments.contains("--dump") { print(String(decoding: snapshot, as: UTF8.self)); exit(0) }
  return (fnv(visibleState(snapshot)) ^ fnv(sink.data), replies)
}
/// What a person or program could observe: cell text and style, the cursor,
/// the modes. Counters that advance on any input are left out.
func visibleState(_ snapshot: Data) -> Data {
  let volatile: Set<String> = ["revision", "id", "geometry_epoch", "document_epoch", "history_epoch", "screen_epoch", "viewport_clamp_revision"]
  func strip(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
      return object.filter { !volatile.contains($0.key) }.mapValues(strip)
    }
    if let array = value as? [Any] { return array.map(strip) }
    return value
  }
  guard let object = try? JSONSerialization.jsonObject(with: snapshot) else { return snapshot }
  return (try? JSONSerialization.data(withJSONObject: strip(object), options: [.sortedKeys])) ?? snapshot
}
@main struct ProbeMain {
  static func main() {
    let baseline = observe("")
    var acted: [String] = []
    for prefix in ["<", "=", ">", "?"] + [" ", "!", "\"", "#", "$", "%", "&", "'", "*", "+"] {
      let isMarker = "<=>?".contains(prefix)
      for final in UInt8(0x40)...UInt8(0x7e) {
        let letter = String(UnicodeScalar(final))
        for parameters in ["", "1", "2", "4;2", "1;1;0"] {
          let sequence = isMarker ? "\u{1b}[\(prefix)\(parameters)\(letter)" : "\u{1b}[\(parameters)\(prefix)\(letter)"
          let result = observe(sequence)
          if result.state != baseline.state || !result.replies.isEmpty {
            let shown = isMarker ? "CSI \(prefix) \(parameters) \(letter)" : "CSI \(parameters) '\(prefix)' \(letter)"
            acted.append("\(shown)\t\(result.replies.isEmpty ? "changes state" : "replies " + result.replies)")
          }
        }
      }
    }
    for line in acted { print(line) }
    print("total \(acted.count)")
  }
}

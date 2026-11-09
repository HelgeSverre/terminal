import Foundation
import CryptoKit

@main enum CSIRunBoundaryProbe {
  final class Capture { var data = Data() }
  static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    if let context, let bytes { Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count) }
  }
  static func main() {
    let esc = Array("\u{1b}[".utf8)
    var cases: [[UInt8]] = []
    for size in [16382, 16383, 16384, 16385] {
      for byte: UInt8 in [0x20, 0x80] {
        for tail in [[UInt8]("mX".utf8), [0x80, 0x6d, 0x58], [0x80, 0x18, 0x6d, 0x58], [0x1b, 0x5b, 0x36, 0x6e]] {
          cases.append(esc + Array(repeating: byte, count: byte < 128 ? size : size / 2) + tail)
        }
      }
    }
    for position in [65533, 65534, 65535, 65536, 65537] {
      cases.append(Array(repeating: 0x00, count: position) + esc + Array("38;2;12;34;56mX\u{1b}[6n".utf8))
    }
    cases.append(Array(String(repeating: "\u{1b}[6n", count: 30000).utf8))
    cases.append(Array(String(repeating: "\u{1b}[?u\u{1b}[5n", count: 15000).utf8))
    cases.append(Array("X\u{1b}[9000b\u{1b}[38;2;1;2;3mY\u{1b}[6n".utf8))
    let chunks = [1, 7, 16383, 16384, 16385, 32768, 65535, 65536, 65537, 200000]
    for (index, input) in cases.enumerated() {
      for chunk in chunks {
        let core = terminal_create(20, 4)!
        let replies = Capture()
        var offset = 0, calls = 0
        var consumed: [Int] = []
        while offset < input.count {
          let offered = min(chunk, input.count - offset)
          let used = input.withUnsafeBufferPointer { terminal_feed(core, $0.baseAddress! + offset, offered, 0) }
          precondition(used >= 0 && used <= min(offered, 65536))
          consumed.append(used); offset += used; calls += 1
          precondition(calls < input.count + 100)
          // Keep replies queued across full offers; partial/zero consumption
          // exercises the owner's drain-and-replay boundary, including REP.
          if used < offered {
            terminal_replies(core, Unmanaged.passUnretained(replies).toOpaque(), collect)
          }
        }
        terminal_replies(core, Unmanaged.passUnretained(replies).toOpaque(), collect)
        let raw = terminal_snapshot(core, 0, 0)!
        let object = try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))
        terminal_string_free(raw)
        let snapshot = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let offsets = Data(consumed.map(String.init).joined(separator: ",").utf8)
        print("\(index):\(chunk):\(SHA256.hash(data: snapshot + replies.data + offsets))")
        terminal_destroy(core)
      }
    }
  }
}

import Foundation
import CryptoKit

// Compile unchanged against baseline and candidate, then compare stdout byte for byte.
@main enum CSIDifferentialProbe {
  final class Capture { var data = Data() }
  static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    if let context, let bytes { Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count) }
  }
  static func main() {
    var cases = [String](arrayLiteral: "", ";", "1;;31", "4:3;38;2;20;30;40", "38:2::1:2:3", "?25", ">+31;2", "=-1;2", "=+31;+2", "4294967295", "4294967296", "1 2", "1:2", "?1$", "!", "1\u{18}2", "1\u{1a}2", "1\u{1b}2", "1\u{7f}2").map { Array($0.utf8) }
    cases += [[0x80], [0xff], [0x31, 0x80, 0x32]]
    for size in [16383, 16384, 16385] { cases.append(Array(repeating: 0x20, count: size)); cases.append(Array(repeating: 0x80, count: size / 2) + [0x31]) }
    cases = cases.flatMap { body in Array(repeating: body, count: 10) }
    var state: UInt64 = 0x12345678
    let grammar: [UInt8] = Array("0123456789;:?>=< !\"$+-".utf8) + [0, 0x18, 0x1a, 0x1b, 0x7f, 0x80, 0xff]
    for _ in 0..<1200 {
      state = state &* 6364136223846793005 &+ 1
      let length = Int(state % 48)
      var bytes: [UInt8] = []
      for _ in 0..<length { state = state &* 6364136223846793005 &+ 1; bytes.append(grammar[Int(state % UInt64(grammar.count))]) }
      cases.append(bytes)
    }
    let finals = Array("mAuqnhlprc".utf8)
    for (index, body) in cases.enumerated() {
      let final = finals[index % finals.count]
      let input = Array("seed\u{1b}[".utf8) + body + [final] + Array("X\u{1b}[6n\u{1b}[?u".utf8)
      // Every two-part split for short cases; bytewise and irregular partitions always.
      let partitions = input.count < 90 ? Array(1..<input.count) : [1, input.count / 2, input.count - 1]
      for split in partitions + [-1, -7] {
        let core = terminal_create(20, 4)!
        var offset = 0
        while offset < input.count {
          let size = split < 0 ? min(-split, input.count - offset) : (offset == 0 ? split : input.count - offset)
          let used = input.withUnsafeBufferPointer { terminal_feed(core, $0.baseAddress! + offset, size, 0) }
          precondition(used > 0); offset += used
        }
        let raw = terminal_snapshot(core, 0, 0)!
        let object = try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))
        terminal_string_free(raw)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let replies = Capture()
        terminal_replies(core, Unmanaged.passUnretained(replies).toOpaque(), collect)
        print("\(index):\(split):\(SHA256.hash(data: data + replies.data))")
        terminal_destroy(core)
      }
    }
  }
}

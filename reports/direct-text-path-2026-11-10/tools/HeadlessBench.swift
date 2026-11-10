import Foundation
func runBench() {
let workloads: [(String, String)] = [
  ("ascii_short_lines", "0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n"),
  ("ascii_long_lines", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ "),
  ("ansi_truecolor", "\u{1b}[38;2;84;210;160mcolored\u{1b}[0m \u{1b}[48;2;18;35;70mbackground\u{1b}[0m\r\n"),
  ("unicode", "Unicode: 猫 é 👩🏽‍💻 🇳🇴 ∑─▁▂▃▄▅▆▇█\r\n"),
  ("uni_singletons", "Unicode: 猫 é ∑─▁▂▃▄▅▆▇█ 日本語のテキスト\r\n"),
  ("uni_cjk", "日本語のテキストと漢字がたくさん並んでいる行です。\r\n"),
  ("uni_clusters", "👩🏽‍💻 🇳🇴 ❤️ e\u{301} 👍🏿\r\n"),
]
let arguments = CommandLine.arguments
let only = arguments.firstIndex(of: "--only").map { arguments[$0 + 1] }
let total = (arguments.firstIndex(of: "--mib").map { Int(arguments[$0 + 1])! } ?? 64) * 1024 * 1024
let rounds = arguments.firstIndex(of: "--rounds").map { Int(arguments[$0 + 1])! } ?? 3
let chunk = Int(arguments.dropFirst().first ?? "16384")!
let snapshots = arguments.contains("--snapshots")
for (name, pattern) in workloads where only == nil || only == name {
  let unit = Array(pattern.utf8)
  var block: [UInt8] = []
  while block.count + unit.count <= 32768 { block += unit }
  var stream: [UInt8] = []
  stream.reserveCapacity(total + block.count)
  while stream.count < total { stream += block }
  stream.removeLast(stream.count - total)
  var best = 0.0
  var snapNs: UInt64 = 0, snapCount = 0
  for _ in 0..<rounds {
    let t = terminal_create(100, 30)!
    let pre = Array((arguments.contains("--primary") ? "" : "\u{1b}[?1049h") .utf8) + Array("\u{1b}[2J\u{1b}[H".utf8)
    _ = pre.withUnsafeBufferPointer { terminal_feed(t, $0.baseAddress, $0.count, 0) }
    let start = DispatchTime.now().uptimeNanoseconds
    var nextSnap = start
    stream.withUnsafeBufferPointer { buffer in
      var offset = 0
      while offset < total {
        let n = min(chunk, total - offset)
        var used = 0
        while used < n { used += terminal_feed(t, buffer.baseAddress! + offset + used, n - used, 0) }
        offset += n
        if snapshots {
          let now = DispatchTime.now().uptimeNanoseconds
          if now >= nextSnap {
            _ = swiftTerminalSnapshot(t, scroll: nil, now: 0)
            let after = DispatchTime.now().uptimeNanoseconds
            snapNs += after - now; snapCount += 1; nextSnap = after + 8_000_000
          }
        }
      }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    best = max(best, Double(total) / 1048576 / elapsed)
    terminal_destroy(t)
  }
  print(name.padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: " %8.1f MiB/s", best) + (snapshots ? String(format: "  snapshot avg %.1f us (n=%d)", Double(snapNs) / 1000 / Double(max(1, snapCount)), snapCount) : ""))
}
}
@main struct BenchMain { static func main() { runBench() } }

import Foundation
@main enum FeedBench {
 static func main() {
  let fixtures = ["ascii": "hello terminal 1234567890 ", "unicode": "Καλημέρα κόσμε 日本語 한국어 Привет мир ", "ansi": "\u{1b}[38;2;120;60;200mcolored terminal\u{1b}[0m ", "clusters": "e\u{301} ©\u{FE0F} 👩\u{200D}💻 🇳🇴 👍🏽 "]
  for name in fixtures.keys.sorted() {
   let data = Data(String(repeating: fixtures[name]! + "\r\n", count: 16000).utf8)
   for chunk in [1, 1023, 4096] {
    var times: [Double] = []
    for _ in 0..<7 {
     let core = terminal_create(120, 40)!
     let start = DispatchTime.now().uptimeNanoseconds
     data.withUnsafeBytes { raw in
      var offset = 0
      while offset < data.count {
       let count = min(chunk, data.count - offset)
       let used = terminal_feed(core, raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), count, 0)
       precondition(used == count)
       offset += count
      }
     }
     times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
     terminal_destroy(core)
    }
    print("\(name) chunk=\(chunk) bytes=\(data.count) ms=\(times.map { String(format: "%.3f", $0) }.joined(separator: ","))")
   }
  }
 }
}

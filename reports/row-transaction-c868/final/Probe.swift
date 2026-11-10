import Foundation
@main enum ASCIIBorrowProbe {
  final class Replies { var data = Data() }
  static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    guard let context, let bytes, count > 0 else { return }
    Unmanaged<Replies>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
  }
  static func drain(_ core: OpaquePointer, _ replies: Replies) {
    terminal_replies(core, Unmanaged.passUnretained(replies).toOpaque(), collect)
  }
  static func feed(_ core: OpaquePointer, _ data: Data, partitions: [Int], replies: Replies) -> [Int] {
    var offset = 0, part = 0, trace: [Int] = []
    data.withUnsafeBytes { raw in
      let base = raw.bindMemory(to: UInt8.self).baseAddress!
      while offset < data.count {
        let end = min(data.count, offset + partitions[part % partitions.count]); part += 1
        while offset < end || terminal_has_work(core) {
          let pending = terminal_has_work(core)
          let used = terminal_feed(core, base.advanced(by: offset), end - offset, 0)
          precondition(used >= 0 && used <= end - offset && (used > 0 || pending))
          offset += used; trace.append(used); drain(core, replies)
        }
      }
    }
    return trace
  }
  static func differential() throws {
    let ascii = String(repeating: "abcdef0123456789XYZ ", count: 85)
    let fixtures: [(String, Data)] = [
      ("long", Data(ascii.utf8)),
      ("mixed", Data(("猫e\u{301}" + ascii + "\u{301}👩🏽‍💻" + ascii + "\u{1b}[6n").utf8)),
      ("invalid", Data([0xe1,0x80]) + Data(ascii.utf8) + Data([0xff,0xc2])),
      ("charset", Data(("\u{1b}(0" + ascii + "\u{1b}(B" + ascii + "\u{1b})0\u{e}" + ascii + "\u{f}" + ascii).utf8)),
      ("rep", Data((ascii + "\u{1b}[5000b" + ascii + "\u{1b}[6n").utf8)),
      ("margins", Data(("\u{1b}[?69h\u{1b}[2;5s\u{1b}[2;3r\u{1b}[?6h" + ascii + "\r\n" + ascii + "\u{1b}[4h" + ascii + "\u{1b}[4l\u{1b}[?7l" + ascii).utf8)),
      ("styles", Data(("\u{1b}]8;;https://example.test/\u{7}\u{1b}[38;2;14;28;42m" + ascii + "\u{1b}[0m\u{1b}]8;;\u{7}" + ascii).utf8)),
      ("alt", Data((ascii + "\u{1b}[?1049h" + ascii + "\u{1b}[?1049l" + ascii).utf8))
    ]
    let partitions = [[1],[15],[16],[1023],[4096],[65536],[3,17,1,1024,2,19,7]]
    var records: [[String: Any]] = []
    for width: UInt32 in [1,7,80] {
      for budget: UInt64 in [0,12000] {
        for (name, data) in fixtures {
          for parts in partitions {
            let core = terminal_create(width, 4)!
            terminal_set_history_byte_limit(core, budget)
            let replies = Replies()
            let trace = feed(core, data, partitions: parts, replies: replies)
            precondition(terminal_validate(core))
            let before = EmulatorTests.snapshot(core)
            terminal_finish(core)
            records.append(["name":name,"width":width,"budget":budget,"parts":parts,
              "consumption":trace,"replies":replies.data.base64EncodedString(),
              "before_finish":before,"after_finish":EmulatorTests.snapshot(core),
              "history_bytes":terminal_history_bytes(core)])
            terminal_destroy(core)
          }
        }
      }
    }
    let core = terminal_create(100,30)!
    terminal_set_history_limit(core,0)
    let replies=Replies()
    let trace=feed(core,Data(repeating:65,count:131075),partitions:[131075],replies:replies)
    records.append(["name":"feed-cap","consumption":trace,"snapshot":EmulatorTests.snapshot(core)])
    terminal_destroy(core)
    let out=try JSONSerialization.data(withJSONObject:records,options:[.sortedKeys])
    FileHandle.standardOutput.write(out)
  }
  static let workloads: [(String,String)] = [
    ("ascii_short_lines","0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ\n"),
    ("ascii_long_lines","0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ "),
    ("ansi_truecolor","\u{1b}[38;2;84;210;160mcolored\u{1b}[0m \u{1b}[48;2;18;35;70mbackground\u{1b}[0m\n"),
    ("unicode","Unicode: 猫 é 👩🏽‍💻 🇳🇴 ∑─▁▂▃▄▅▆▇█\n")
  ]
  static func benchmark() throws {
    let size=2*1024*1024
    var records:[[String:Any]]=[]
    for (name,pattern) in workloads {
      let unit=Data(pattern.utf8)
      var data=Data(); data.reserveCapacity(size)
      while data.count<size { data.append(unit.prefix(min(unit.count,size-data.count))) }
      for chunk in [1,1023,4096,65536] {
        var seconds:[Double]=[]
        for iteration in 0..<6 {
          let core=terminal_create(100,30)!
          EmulatorTests.feed(core,"\u{1b}[?1049h")
          let started=DispatchTime.now().uptimeNanoseconds
          data.withUnsafeBytes { raw in
            let pointer=raw.bindMemory(to:UInt8.self).baseAddress!
            var offset=0
            while offset<data.count {
              let count=min(chunk,data.count-offset)
              let used=terminal_feed(core,pointer.advanced(by:offset),count,0)
              precondition(used==count)
              offset+=used
            }
          }
          let elapsed=Double(DispatchTime.now().uptimeNanoseconds-started)/1e9
          if iteration>0 { seconds.append(elapsed) }
          precondition(terminal_validate(core));terminal_destroy(core)
        }
        records.append(["workload":name,"chunk":chunk,"bytes":size,"seconds":seconds])
      }
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:records,options:[.sortedKeys]))
  }
  static func main() throws {
    switch CommandLine.arguments[1] {
    case "--tests": EmulatorTests.main()
    case "--deep-tests":
      RowTransactionTests.main()
      TerminalDocumentOwnershipTests.main()
      TerminalSemanticRegressionTests.main()
      TerminalBoundaryRegressionTests.main()
      TerminalTextTests.main()
      try Unicode18CorpusTests.main()
      TerminalSelectionTests.main()
      TerminalReflowSemanticTests.main()
    case "--rows": try RowStorageCompatibilityProbe.main()
    case "--diff": try differential()
    case "--bench": try benchmark()
    default: fatalError("mode")
    }
  }
}

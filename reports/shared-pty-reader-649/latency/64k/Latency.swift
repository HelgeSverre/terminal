import Foundation
import Darwin

@main struct Latency {
  @MainActor static func main() {
    let root = CommandLine.arguments[1], producer = CommandLine.arguments[2], output = CommandLine.arguments[3]
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("terminal-io-latency-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    var results: [[String: Any]] = []
    for workload in ["unicode", "sql"] {
      for mode in ["input", "resize"] {
        let ack = temporary.appendingPathComponent("\(workload)-\(mode).ack")
        let session = Session(launch: LaunchSpec(executable: producer,
          arguments: [producer, ack.path, workload], cwd: "/tmp",
          launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher"))
        session.resize(cols: 100, rows: 30)
        var starts: [Int: UInt64] = [:], expectedColumns: [Int: Int] = [:]
        var inputMS: [Double] = [], probeMS: [Double] = []
        var next = 1, lastAck = 0, readyAt: UInt64 = 0, lastSubmit: UInt64 = 0
        var mismatches = 0, admissionFailures = 0
        let deadline = Date().addingTimeInterval(20)
        while inputMS.count < 128 && Date() < deadline {
          let now = DispatchTime.now().uptimeNanoseconds
          if let text = try? String(contentsOf: ack, encoding: .utf8) {
            for line in text.split(separator: "\n") {
              let fields = line.split(separator: " ").compactMap { UInt64($0) }
              guard fields.count == 4 else { continue }
              let id = Int(fields[0])
              if id == 0 && readyAt == 0 { readyAt = now }
              guard id > lastAck, let start = starts[id] else { continue }
              precondition(fields[1] >= start)
              inputMS.append(Double(fields[1] - start) / 1_000_000)
              if Int(fields[2]) != expectedColumns[id] || fields[3] != 30 { mismatches += 1 }
              lastAck = id
            }
          }
          if readyAt > 0 && now - readyAt >= 300_000_000 && next == lastAck + 1
             && next <= 128 && (lastSubmit == 0 || now - lastSubmit >= 16_666_667) {
            let id = next, columns = mode == "resize" ? (id % 2 == 0 ? 100 : 101) : 100
            starts[id] = now; expectedColumns[id] = columns; lastSubmit = now
            if mode == "resize" { session.resize(cols: columns, rows: 30) }
            if !session.input("\(id)\n") { admissionFailures += 1 }
            session.semanticProbe { probeMS.append($0) }
            next += 1
          }
          RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        let probeDeadline = Date().addingTimeInterval(3)
        while probeMS.count < inputMS.count && Date() < probeDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        var stats: [String: Any] = [:]
        session.statistics { stats = $0 }
        let statDeadline = Date().addingTimeInterval(3)
        while stats.isEmpty && Date() < statDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        session.close()
        var reaped = false
        let reapDeadline = Date().addingTimeInterval(4)
        while !reaped && Date() < reapDeadline {
          session.statistics { reaped = $0["child_reaped"] as? Bool == true }
          RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        results.append(["workload":workload,"mode":mode,"input_ms":inputMS,"probe_ms":probeMS,
          "geometry_mismatches":mismatches,"admission_failures":admissionFailures,"reaped":reaped,"statistics":stats])
        print("\(workload)/\(mode) samples=\(inputMS.count) mismatches=\(mismatches) reaped=\(reaped)")
      }
    }
    try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
    try? FileManager.default.removeItem(at: temporary)
  }
}

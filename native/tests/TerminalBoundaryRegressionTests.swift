import Foundation

// ABI regressions at resource/transport boundaries, independent of private
// parser, screen and grapheme representations. Each case can run separately
// so a failure does not hide evidence from the remaining cases.
@main enum TerminalBoundaryRegressionTests {
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
  static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() { return }
    throw Failure(message)
  }
  static func feed(_ terminal: OpaquePointer, _ bytes: Data) throws {
    var offset = 0
    var turns = 0
    while offset < bytes.count || terminal_has_work(terminal) {
      let offered = min(65_536, bytes.count - offset)
      let consumed = bytes.withUnsafeBytes { buffer in
        terminal_feed(terminal, offered == 0 ? nil : buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), offered, 0)
      }
      try expect(consumed >= 0 && consumed <= offered, "invalid ingress consumption")
      try expect(consumed > 0 || terminal_has_work(terminal) || offset == bytes.count, "ingress stalled")
      offset += consumed
      turns += 1
      try expect(turns < 100_000, "work did not yield progress")
    }
    try expect(terminal_validate(terminal), "document invariants")
  }
  static func feed(_ terminal: OpaquePointer, _ text: String) throws { try feed(terminal, Data(text.utf8)) }
  private final class Capture {
    var value: [String: Any]?
  }
  private static let receive: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
    UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int
  ) -> Void = { context, metadata, metadataCount, cells, cellCount, wraps, rowCount in
    guard let context, let metadata, let cells, let wraps,
      var value = (try? JSONSerialization.jsonObject(with: Data(bytes: metadata, count: metadataCount))) as? [String: Any],
      let columns = value["cols"] as? Int, columns > 0, columns * rowCount == cellCount else { return }
    let kinds = ["Empty", "Lead1", "Lead2", "Continuation", "WrapSpacer"]
    var rows: [[String: Any]] = []
    for row in 0..<rowCount {
      var output: [[String: Any]] = []
      for column in 0..<columns {
        let cell = cells[row * columns + column]
        guard Int(cell.kind) < kinds.count else { return }
        let text = String(decoding: UnsafeBufferPointer(start: cell.text, count: cell.text_len), as: UTF8.self)
        output.append(["text": text, "kind": kinds[Int(cell.kind)], "flags": Int(cell.cell_flags)])
      }
      rows.append(["cells": output, "soft_wrapped": wraps[row] != 0])
    }
    value["rows"] = rows
    Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().value = value
  }
  static func snapshot(_ terminal: OpaquePointer) throws -> [String: Any] {
    let capture = Capture()
    guard terminal_view_snapshot_binary(terminal, 0, Unmanaged.passUnretained(capture).toOpaque(), receive),
      let result = capture.value else { throw Failure("missing owner-view snapshot") }
    return result
  }
  static func cells(_ snapshot: [String: Any], row: Int = 0) -> [[String: Any]] {
    (snapshot["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]]
  }
  static func lines(_ snapshot: [String: Any]) -> [String] {
    (snapshot["rows"] as! [[String: Any]]).map { row in
      (row["cells"] as! [[String: Any]]).map { $0["text"] as! String }.joined().trimmingCharacters(in: .whitespaces)
    }
  }
  static func utf8() throws {
    let cases: [[UInt8]] = [
      [0xf0, 0x9f, 0x41], [0xf0, 0x9f, 0x92, 0x41], [0xe1, 0x80, 0x41],
      [0xf0, 0x41], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80],
      [0xf4, 0x90, 0x80, 0x80], [0xf0, 0x9f], [0xe1, 0x80], [0xc2, 0xa2, 0x41]
    ]
    for bytes in cases {
      let expected = String(decoding: bytes, as: UTF8.self)
      for split in 0...bytes.count {
        let terminal = terminal_create(40, 2)!
        defer { terminal_destroy(terminal) }
        try feed(terminal, Data(bytes.prefix(split)))
        try feed(terminal, Data(bytes.suffix(bytes.count - split)))
        terminal_finish(terminal)
        let actual = lines(try snapshot(terminal))[0]
        try expect(actual == expected, "UTF8 \(bytes) split\(split): \(actual.debugDescription) != \(expected.debugDescription)")
      }
    }
  }
  static func stringCaps() throws {
    for (prefix, terminator) in [("\u{1b}]2;", "\u{7}"), ("\u{1b}]2;", "\u{1b}\\"), ("\u{1b}_", "\u{1b}\\")] {
      for size in 65_533...65_537 {
        for splitTerminator in [false, true] {
          let terminal = terminal_create(8, 2)!
          defer { terminal_destroy(terminal) }
          let payload = "A" + prefix + String(repeating: "x", count: size)
          if splitTerminator {
            try feed(terminal, payload)
            try feed(terminal, String(terminator.prefix(1)))
            try feed(terminal, String(terminator.dropFirst()) + "Z")
          } else {
            try feed(terminal, payload + terminator + "Z")
          }
          try expect(lines(try snapshot(terminal))[0] == "AZ", "string termination size\(size), prefix\(prefix.debugDescription), split\(splitTerminator)")
        }
      }
    }
  }
  static func survivingAnchor() throws {
    let terminal = terminal_create(8, 3)!
    defer { terminal_destroy(terminal) }
    terminal_set_history_limit(terminal, 5)
    try feed(terminal, (0...8).map(String.init).joined(separator: "\r\n"))
    terminal_view_scroll(terminal, 3)
    let before = try snapshot(terminal)
    try expect(lines(before) == ["3", "4", "5"], "viewport fixture")
    try feed(terminal, "\r\n9") // Evicts 1; the viewport begins at retained row 3.
    let after = try snapshot(terminal)
    try expect(lines(after) == lines(before), "surviving anchor moved on unrelated eviction")
    try expect(after["viewport_clamp_revision"] as? Int == before["viewport_clamp_revision"] as? Int, "unnecessary viewport clamp")
    try expect(after["following_tail"] as? Bool == false, "viewport unexpectedly follows tail")
  }
  static func resizeRetention() throws {
    let terminal = terminal_create(8, 2)!
    defer { terminal_destroy(terminal) }
    terminal_set_history_limit(terminal, 3)
    try feed(terminal, "abcdefghijklmnop\r\nqrstuvwxyz\r\nlast")
    try expect(terminal_resize(terminal, 2, 2), "narrow resize rejected")
    try expect(((try snapshot(terminal))["history_rows"] as! Int) <= 3, "reflow exceeded row retention")
  }
  #if !RUST_BASELINE
  // The Rust production ABI has no byte-limit setter; its internal byte-limit
  // fixture remains separate. Do not report this Swift adapter case as shared.
  static func resizeByteRetention() throws {
    let bytesTerminal = terminal_create(8, 2)!
    defer { terminal_destroy(bytesTerminal) }
    try feed(bytesTerminal, "a\r\nb\r\nc\r\nd")
    let limit = terminal_history_bytes(bytesTerminal)
    try expect(limit > 0, "history byte fixture")
    terminal_set_history_byte_limit(bytesTerminal, limit)
    try expect(terminal_resize(bytesTerminal, 32, 2), "wide resize rejected")
    try expect(terminal_history_bytes(bytesTerminal) <= limit, "reflow exceeded byte retention")
  }
  #endif
  static func readiness() throws {
    let terminal = terminal_create(12, 3)!
    defer { terminal_destroy(terminal) }
    try feed(terminal, "\u{1b}]133;A\u{7}> \u{1b}]133;B\u{7}")
    for width: UInt32 in [5, 16, 8] {
      try expect(terminal_resize(terminal, width, 3), "prompt resize")
      try expect((try snapshot(terminal))["input_ready"] as? Bool == true, "reflow lost input readiness")
    }
  }
  static func cappedClusters() throws {
    let terminal = terminal_create(12, 2)!
    defer { terminal_destroy(terminal) }
    try feed(terminal, "A" + String(repeating: "\u{301}", count: 64) + "\u{200d}👩")
    let first = cells(try snapshot(terminal))
    try expect(first[1]["text"] as? String == "👩", "capped non-emoji ZWJ swallowed new pictograph")
    try expect((first[0]["text"] as! String).unicodeScalars.count == 64, "retained cluster exceeds cap")
    try feed(terminal, "\rB\u{301}")
    let replaced = cells(try snapshot(terminal))[0]
    try expect(replaced["text"] as? String == "B\u{301}", "cap state survived carriage return")
    try expect((replaced["flags"] as! Int) & 4 == 0, "new glyph inherited cap flag")
  }
  static func segmenterIntegration() throws {
    for cluster in ["\u{1100}\u{1161}\u{11a8}", "क्‍ष", "\u{600}A", "क\u{903}"] {
      let terminal = terminal_create(16, 2)!
      defer { terminal_destroy(terminal) }
      for scalar in cluster.unicodeScalars { try feed(terminal, String(scalar)) }
      let output = cells(try snapshot(terminal))
      try expect(output[0]["text"] as? String == cluster, "segmenter not used by emulator for \(cluster.debugDescription)")
      let leads = output.filter { let kind = $0["kind"] as? String; return kind == "Lead1" || kind == "Lead2" }
      try expect(leads.count == 1, "cluster occupies multiple leading cells")
    }
  }
  static func continuationWidth() throws {
    let terminal = terminal_create(16, 2)!
    defer { terminal_destroy(terminal) }
    try feed(terminal, "\u{600}猫")
    let joined = try snapshot(terminal)
    let output = cells(joined)
    try expect(output[0]["text"] as? String == "\u{600}猫", "wide continuation text")
    try expect(output[0]["kind"] as? String == "Lead2" && output[1]["kind"] as? String == "Continuation", "wide continuation did not repair occupancy")
    try expect((joined["cursor"] as! [String: Any])["col"] as? Int == 2, "wide continuation did not advance cursor")
    try feed(terminal, "X")
    try expect(cells(try snapshot(terminal))[2]["text"] as? String == "X", "next glyph overlaps widened cluster")
  }
  static func repeatClusters() throws {
    for (cluster, width) in [("e\u{301}", 1), ("🇳🇴", 2), ("\u{1100}\u{1161}\u{11a8}", 2)] {
      let terminal = terminal_create(20, 2)!
      defer { terminal_destroy(terminal) }
      try feed(terminal, cluster + "\u{1b}[2b")
      let value = try snapshot(terminal)
      let output = cells(value)
      for index in 0..<3 {
        try expect(output[index * width]["text"] as? String == cluster, "REP lost or merged cluster \(cluster.debugDescription), copy\(index)")
      }
      try expect((value["cursor"] as! [String: Any])["col"] as? Int == width * 3, "REP cluster occupancy")
    }
  }
  static func combiningAfterMovement() throws {
    for (prefix, row, column) in [
      ("A\n", 1, 1), ("A\t", 0, 8), ("A\u{1b}[H", 0, 0),
      ("A\u{1b}[?1049h", 0, 0)
    ] {
      let terminal = terminal_create(20, 3)!
      defer { terminal_destroy(terminal) }
      try feed(terminal, prefix + "\u{301}X")
      let value = try snapshot(terminal)
      let output = cells(value, row: row)
      try expect(output[column]["text"] as? String == "\u{301}" && output[column]["kind"] as? String == "Lead1", "orphan combining placement after \(prefix.debugDescription)")
      try expect(output[column + 1]["text"] as? String == "X", "orphan combining was overwritten after movement")
      try expect((value["cursor"] as! [String: Any])["col"] as? Int == column + 2, "orphan combining cursor")
    }
  }
  static func main() {
    var cases: [(String, () throws -> Void)] = [
      ("utf8", utf8), ("strings", stringCaps), ("anchor", survivingAnchor),
      ("retention", resizeRetention), ("readiness", readiness),
      ("cap", cappedClusters), ("segmenter", segmenterIntegration),
      ("width", continuationWidth), ("rep", repeatClusters), ("movement", combiningAfterMovement)
    ]
    #if !RUST_BASELINE
    cases.append(("byte-retention", resizeByteRetention))
    #endif
    do {
      let selected = CommandLine.arguments.dropFirst().first
      if let selected, !cases.contains(where: { $0.0 == selected }) { throw Failure("unknown case \(selected)") }
      for (name, run) in cases where selected == nil || selected == name {
        try run()
        print("PASS boundary \(name)")
      }
    } catch {
      fputs("FAIL boundary: \(error)\n", stderr)
      exit(1)
    }
  }
}

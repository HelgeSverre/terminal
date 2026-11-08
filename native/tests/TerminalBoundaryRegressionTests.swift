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
  static func snapshot(_ terminal: OpaquePointer) throws -> [String: Any] {
    guard let raw = terminal_snapshot(terminal, Int.max, 0) else { throw Failure("missing snapshot") }
    defer { terminal_string_free(raw) }
    guard let result = try JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any] else {
      throw Failure("snapshot object")
    }
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

    let bytesTerminal = terminal_create(8, 2)!
    defer { terminal_destroy(bytesTerminal) }
    try feed(bytesTerminal, "a\r\nb\r\nc\r\nd")
    let limit = terminal_history_bytes(bytesTerminal)
    try expect(limit > 0, "history byte fixture")
    terminal_set_history_byte_limit(bytesTerminal, limit)
    try expect(terminal_resize(bytesTerminal, 32, 2), "wide resize rejected")
    try expect(terminal_history_bytes(bytesTerminal) <= limit, "reflow exceeded byte retention")
  }
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
  static func main() {
    let cases: [(String, () throws -> Void)] = [
      ("utf8", utf8), ("strings", stringCaps), ("anchor", survivingAnchor),
      ("retention", resizeRetention), ("readiness", readiness),
      ("cap", cappedClusters), ("segmenter", segmenterIntegration)
    ]
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

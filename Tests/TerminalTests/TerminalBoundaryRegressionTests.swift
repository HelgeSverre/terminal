import Foundation
import Testing
@testable import TerminalApp

// ABI regressions at resource/transport boundaries, independent of private
// parser, screen and grapheme representations. Each case is its own test, so a
// failure does not hide evidence from the remaining cases.
@Suite enum TerminalBoundaryRegressionTests {
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
  static func feed(_ terminal: OpaquePointer, _ bytes: Data) throws {
    var offset = 0
    var turns = 0
    while offset < bytes.count || terminal_has_work(terminal) {
      let offered = min(65_536, bytes.count - offset)
      let consumed = bytes.withUnsafeBytes { buffer in
        terminal_feed(terminal, offered == 0 ? nil : buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), offered, 0)
      }
      try #require(consumed >= 0 && consumed <= offered, "invalid ingress consumption")
      try #require(consumed > 0 || terminal_has_work(terminal) || offset == bytes.count, "ingress stalled")
      offset += consumed
      turns += 1
      try #require(turns < 100_000, "work did not yield progress")
    }
    #expect(terminal_validate(terminal), "document invariants")
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
  @Test static func utf8() throws {
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
        #expect(actual == expected, "UTF8 \(bytes) split\(split): \(actual.debugDescription) != \(expected.debugDescription)")
      }
    }
  }
  @Test static func stringCaps() throws {
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
          #expect(lines(try snapshot(terminal))[0] == "AZ", "string termination size\(size), prefix\(prefix.debugDescription), split\(splitTerminator)")
        }
      }
    }
  }
  @Test static func survivingAnchor() throws {
    let terminal = terminal_create(8, 3)!
    defer { terminal_destroy(terminal) }
    terminal_set_history_limit(terminal, 5)
    try feed(terminal, (0...8).map(String.init).joined(separator: "\r\n"))
    terminal_view_scroll(terminal, 3)
    let before = try snapshot(terminal)
    #expect(lines(before) == ["3", "4", "5"], "viewport fixture")
    try feed(terminal, "\r\n9") // Evicts 1; the viewport begins at retained row 3.
    let after = try snapshot(terminal)
    #expect(lines(after) == lines(before), "surviving anchor moved on unrelated eviction")
    #expect(after["viewport_clamp_revision"] as? Int == before["viewport_clamp_revision"] as? Int, "unnecessary viewport clamp")
    #expect(after["following_tail"] as? Bool == false, "viewport unexpectedly follows tail")
  }
  @Test static func resizeRetention() throws {
    let terminal = terminal_create(8, 2)!
    defer { terminal_destroy(terminal) }
    terminal_set_history_limit(terminal, 3)
    try feed(terminal, "abcdefghijklmnop\r\nqrstuvwxyz\r\nlast")
    #expect(terminal_resize(terminal, 2, 2), "narrow resize rejected")
    #expect(((try snapshot(terminal))["history_rows"] as! Int) <= 3, "reflow exceeded row retention")
  }
  @Test static func resizeByteRetention() throws {
    let bytesTerminal = terminal_create(8, 2)!
    defer { terminal_destroy(bytesTerminal) }
    try feed(bytesTerminal, "a\r\nb\r\nc\r\nd")
    let limit = terminal_history_bytes(bytesTerminal)
    #expect(limit > 0, "history byte fixture")
    terminal_set_history_byte_limit(bytesTerminal, limit)
    #expect(terminal_resize(bytesTerminal, 32, 2), "wide resize rejected")
    #expect(terminal_history_bytes(bytesTerminal) <= limit, "reflow exceeded byte retention")
  }
  @Test static func historyStorageCharge() throws {
    let wide = terminal_create(80, 1)!
    defer { terminal_destroy(wide) }
    // A retained row cannot cost less than its fixed cell slots, even when
    // almost every cell is blank. Keep the budget below that lower bound.
    let belowCellStorage = UInt64(80 * MemoryLayout<TerminalCell>.stride - 1)
    terminal_set_history_byte_limit(wide, belowCellStorage)
    try feed(wide, "A\r\nB\r\nC")
    #expect((try snapshot(wide))["history_rows"] as? Int == 0, "history budget omitted fixed cell storage")
    #expect(terminal_history_bytes(wide) == 0, "evicted cell storage remained charged")

    let linked = terminal_create(4, 1)!
    defer { terminal_destroy(linked) }
    terminal_set_history_byte_limit(linked, 1_024)
    let url = "https://example.test/" + String(repeating: "x", count: 4_096)
    try feed(linked, "\u{1b}]8;;\(url)\u{7}A\u{1b}]8;;\u{7}\r\nB")
    #expect((try snapshot(linked))["history_rows"] as? Int == 0, "history budget omitted hyperlink content")
    #expect(terminal_history_bytes(linked) == 0, "evicted hyperlink remained charged")
  }
  @Test static func historyByteThresholds() throws {
    // Non-round widths exercise the old rich-array capacity rounding. Exact
    // admission must retain one row at the charge, and evict at charge - 1.
    for width: UInt32 in [3, 7, 17] {
      let measured = terminal_create(width, 1)!
      defer { terminal_destroy(measured) }
      try feed(measured, "A\r\nB")
      let charge = terminal_history_bytes(measured)
      #expect(try charge > 0 && (try snapshot(measured))["history_rows"] as? Int == 1,
                 "history threshold fixture width \(width)")
      for delta: Int64 in [-1, 0, 1] {
        let terminal = terminal_create(width, 1)!
        defer { terminal_destroy(terminal) }
        terminal_set_history_byte_limit(terminal, UInt64(Int64(charge) + delta))
        try feed(terminal, "A\r\nB")
        let retained = delta >= 0
        #expect(((try snapshot(terminal))["history_rows"] as? Int == (retained ? 1 : 0)),
                   "history threshold \(delta) width \(width)")
        #expect(terminal_history_bytes(terminal) == (retained ? charge : 0),
                   "history byte threshold \(delta) width \(width)")
      }
    }
  }
  @Test static func readiness() throws {
    let terminal = terminal_create(12, 3)!
    defer { terminal_destroy(terminal) }
    try feed(terminal, "\u{1b}]133;A\u{7}> \u{1b}]133;B\u{7}")
    for width: UInt32 in [5, 16, 8] {
      #expect(terminal_resize(terminal, width, 3), "prompt resize")
      #expect((try snapshot(terminal))["input_ready"] as? Bool == true, "reflow lost input readiness")
    }
  }
  @Test static func cappedClusters() throws {
    let terminal = terminal_create(12, 2)!
    defer { terminal_destroy(terminal) }
    try feed(terminal, "A" + String(repeating: "\u{301}", count: 64) + "\u{200d}👩")
    let first = cells(try snapshot(terminal))
    #expect(first[1]["text"] as? String == "👩", "capped non-emoji ZWJ swallowed new pictograph")
    #expect((first[0]["text"] as! String).unicodeScalars.count == 64, "retained cluster exceeds cap")
    try feed(terminal, "\rB\u{301}")
    let replaced = cells(try snapshot(terminal))[0]
    #expect(replaced["text"] as? String == "B\u{301}", "cap state survived carriage return")
    #expect((replaced["flags"] as! Int) & 4 == 0, "new glyph inherited cap flag")
  }
  @Test static func segmenterIntegration() throws {
    for cluster in ["\u{1100}\u{1161}\u{11a8}", "क्‍ष", "\u{600}A", "क\u{903}"] {
      let terminal = terminal_create(16, 2)!
      defer { terminal_destroy(terminal) }
      for scalar in cluster.unicodeScalars { try feed(terminal, String(scalar)) }
      let output = cells(try snapshot(terminal))
      #expect(output[0]["text"] as? String == cluster, "segmenter not used by emulator for \(cluster.debugDescription)")
      let leads = output.filter { let kind = $0["kind"] as? String; return kind == "Lead1" || kind == "Lead2" }
      #expect(leads.count == 1, "cluster occupies multiple leading cells")
    }
  }
  @Test static func continuationWidth() throws {
    let terminal = terminal_create(16, 2)!
    defer { terminal_destroy(terminal) }
    try feed(terminal, "\u{600}猫")
    let joined = try snapshot(terminal)
    let output = cells(joined)
    #expect(output[0]["text"] as? String == "\u{600}猫", "wide continuation text")
    #expect(output[0]["kind"] as? String == "Lead2" && output[1]["kind"] as? String == "Continuation", "wide continuation did not repair occupancy")
    #expect((joined["cursor"] as! [String: Any])["col"] as? Int == 2, "wide continuation did not advance cursor")
    try feed(terminal, "X")
    #expect(cells(try snapshot(terminal))[2]["text"] as? String == "X", "next glyph overlaps widened cluster")
  }
  @Test static func repeatClusters() throws {
    for (cluster, width) in [("e\u{301}", 1), ("🇳🇴", 2), ("\u{1100}\u{1161}\u{11a8}", 2)] {
      let terminal = terminal_create(20, 2)!
      defer { terminal_destroy(terminal) }
      try feed(terminal, cluster + "\u{1b}[2b")
      let value = try snapshot(terminal)
      let output = cells(value)
      for index in 0..<3 {
        #expect(output[index * width]["text"] as? String == cluster, "REP lost or merged cluster \(cluster.debugDescription), copy\(index)")
      }
      #expect((value["cursor"] as! [String: Any])["col"] as? Int == width * 3, "REP cluster occupancy")
    }
  }
  @Test static func combiningAfterMovement() throws {
    for (prefix, row, column) in [
      ("A\n", 1, 1), ("A\t", 0, 8), ("A\u{1b}[H", 0, 0),
      ("A\u{1b}[?1049h", 0, 0)
    ] {
      let terminal = terminal_create(20, 3)!
      defer { terminal_destroy(terminal) }
      try feed(terminal, prefix + "\u{301}X")
      let value = try snapshot(terminal)
      let output = cells(value, row: row)
      #expect(output[column]["text"] as? String == "\u{301}" && output[column]["kind"] as? String == "Lead1", "orphan combining placement after \(prefix.debugDescription)")
      #expect(output[column + 1]["text"] as? String == "X", "orphan combining was overwritten after movement")
      #expect((value["cursor"] as! [String: Any])["col"] as? Int == column + 2, "orphan combining cursor")
    }
  }
  // These ingress limits describe the emulator adapter, not a shared VT grammar.
  static func offer(_ terminal: OpaquePointer, _ bytes: Data) -> Int {
    bytes.withUnsafeBytes { terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 0) }
  }
  private final class ReplyCapture { var bytes = Data() }
  private static let receiveReply: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    if let context, let bytes {
      Unmanaged<ReplyCapture>.fromOpaque(context).takeUnretainedValue().bytes.append(bytes, count: count)
    }
  }
  static func drainReplies(_ terminal: OpaquePointer) -> Data {
    let capture = ReplyCapture()
    terminal_replies(terminal, Unmanaged.passUnretained(capture).toOpaque(), receiveReply)
    return capture.bytes
  }
  static func ingressLine(_ terminal: OpaquePointer) throws -> String {
    cells(try snapshot(terminal)).map { cell in
      let text = cell["text"] as! String
      return text.isEmpty ? " " : text
    }.joined().trimmingCharacters(in: .whitespaces)
  }
  @Test static func csiParameterBudget() throws {
    // The filler is the digit zero: a parameter byte that leaves the value
    // alone. A space would be an intermediate byte and name another command.
    let asciiCap = Data(repeating: 0x30, count: 16_384)
    let highCap = Data(repeating: 0x80, count: 8_192)
    let overshoot = Data(repeating: 0x30, count: 16_383) + Data([0x80])
    let fixtures: [(Data, String)] = [
      (asciiCap, "X Z"), // Final C is accepted at the exact budget.
      (Data(repeating: 0x30, count: 16_383) + Data("3".utf8), "X   Z"),
      (asciiCap + Data("1".utf8), "XCZ"), // Overflow consumes 1; C is now printable.
      (highCap, "XZ"), // High bytes charge two and reject the completed packet.
      (highCap + Data("1".utf8), "XCZ"),
      (overshoot, "XZ"), // A final is accepted even after the last byte costs two.
      (overshoot + Data("1".utf8), "XCZ")
    ]
    for (index, fixture) in fixtures.enumerated() {
      let input = Data("X\u{1b}[".utf8) + fixture.0 + Data("CZ".utf8)
      for split in [0, 3, input.count - 3, input.count - 2, input.count - 1, input.count] {
        let terminal = terminal_create(12, 2)!
        defer { terminal_destroy(terminal) }
        try feed(terminal, Data(input.prefix(split)))
        try feed(terminal, Data(input.dropFirst(split)))
        #expect(try ingressLine(terminal) == fixture.1, "CSI budget fixture\(index), split\(split)")
      }
    }
  }
  @Test static func csiIngressYields() throws {
    let terminal = terminal_create(20, 2)!
    defer { terminal_destroy(terminal) }
    let packet = Data("X".utf8) + Data(repeating: 0, count: 65_532) + Data("\u{1b}[3CZ".utf8)
    #expect(offer(terminal, packet) == 65_536, "CSI ignored offer bound")
    #expect(lines(try snapshot(terminal))[0] == "X", "CSI suffix admitted before next offer")
    #expect(offer(terminal, Data(packet.dropFirst(65_536))) == 2, "CSI split final consumption")
    #expect(cells(try snapshot(terminal))[4]["text"] as? String == "Z", "CSI split parameters lost")

    let repeatPacket = Data("\u{1b}[2bY".utf8)
    #expect(offer(terminal, repeatPacket) == 4, "REP must yield immediately after final")
    #expect(offer(terminal, Data("Y".utf8)) == 0, "REP work must precede suffix admission")
    #expect(offer(terminal, Data("Y".utf8)) == 1, "REP suffix was not replayable")
    #expect(try ingressLine(terminal) == "X   ZZZY", "REP changed last printed or suffix")

    let query = Data("\u{1b}[5n".utf8), reply = Data("\u{1b}[0n".utf8)
    let queued = Data(String(repeating: "\u{1b}[5n", count: 8_193).utf8) + Data("Q".utf8)
    #expect(offer(terminal, queued) == 32_768, "reply queue did not yield at command boundary")
    let suffix = Data(queued.dropFirst(32_768))
    #expect(offer(terminal, suffix) == 0, "full reply queue admitted suffix")
    #expect(drainReplies(terminal) == Data(String(repeating: "\u{1b}[0n", count: 8_192).utf8), "reply queue lost replies")
    #expect(offer(terminal, suffix) == query.count + 1, "drained reply suffix consumption")
    #expect(drainReplies(terminal) == reply, "replayed query count")
    #expect(try ingressLine(terminal) == "X   ZZZYQ", "reply backpressure lost printable suffix")
    #expect(terminal_validate(terminal), "CSI ingress document invariants")
  }
}

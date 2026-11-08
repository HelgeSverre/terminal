import Foundation

@main enum EmulatorTests {
  private final class Bytes { var value = Data() }
  private final class Metadata { var value = Data() }
  private static let collect: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int
  ) -> Void = { context, bytes, count in
    guard let context, let bytes, count > 0 else { return }
    Unmanaged<Bytes>.fromOpaque(context).takeUnretainedValue().value.append(bytes, count: count)
  }
  private static let collectMetadata: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
    UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int
  ) -> Void = { context, metadata, count, _, _, _, _ in
    guard let context, let metadata, count > 0 else { return }
    Unmanaged<Metadata>.fromOpaque(context).takeUnretainedValue().value = Data(bytes: metadata, count: count)
  }
  static func binaryHeader(_ core: OpaquePointer, scroll: Int) -> [String: Any] {
    let capture = Metadata()
    precondition(terminal_snapshot_binary(
      core, scroll, 0, Unmanaged.passUnretained(capture).toOpaque(), collectMetadata))
    return try! JSONSerialization.jsonObject(with: capture.value) as! [String: Any]
  }
  static func viewHeader(_ core: OpaquePointer) -> [String: Any] {
    let capture = Metadata()
    precondition(terminal_view_snapshot_binary(core, 0, Unmanaged.passUnretained(capture).toOpaque(), collectMetadata))
    return try! JSONSerialization.jsonObject(with: capture.value) as! [String: Any]
  }
  static func snapshot(_ core: OpaquePointer) -> [String: Any] {
    guard let snapshot = TerminalSnapshotTestSupport.ownerSnapshot(core) else { fatalError("missing snapshot") }
    return snapshot
  }
  static func legacySnapshot(_ core: OpaquePointer, scroll: Int) -> [String: Any] {
    guard let raw = terminal_snapshot(core, scroll, 0) else { fatalError("missing legacy snapshot") }
    defer { terminal_string_free(raw) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as! [String: Any]
  }
  static func feed(_ core: OpaquePointer, _ text: String) {
    let data = Data(text.utf8)
    _ = data.withUnsafeBytes { terminal_feed(core, $0.bindMemory(to: UInt8.self).baseAddress, data.count, 0) }
  }
  static func input(_ core: OpaquePointer, text: String = "", key: UInt32, modifiers: UInt32 = 0,
                    event: UInt32 = 0) -> Data {
    let capture = Bytes()
    let accepted = text.withCString {
      terminal_input(
        core, $0, key, modifiers, event, Unmanaged.passUnretained(capture).toOpaque(), collect)
    }
    precondition(accepted)
    return capture.value
  }
  static func replies(_ core: OpaquePointer) -> Data {
    let capture = Bytes()
    terminal_replies(core, Unmanaged.passUnretained(capture).toOpaque(), collect)
    return capture.value
  }
  static func nativeInput(_ core: OpaquePointer, text: String = "", key: UInt32,
                          modifiers: UInt32 = 0, event: UInt32 = 0) -> Data {
    let capture = Bytes()
    let accepted = text.withCString {
      terminal_input_with_metadata(core, $0, key, modifiers, event, nil, nil, 0, 0,
                                   Unmanaged.passUnretained(capture).toOpaque(), collect)
    }
    precondition(accepted)
    return capture.value
  }
  static func nativeModifierWire() {
    let core = terminal_create(8, 2)!
    defer { terminal_destroy(core) }
    feed(core, "\u{1b}[>11u") // Full key reporting plus press/repeat/release.
    for (mask, encoded) in [(UInt32(64), 65), (128, 129), (192, 193)] {
      let expected = Data("\u{1b}[97;\(encoded):1u".utf8)
      precondition(nativeInput(core, text: "a", key: 200, modifiers: mask) == expected)
      precondition(input(core, text: "a", key: 200, modifiers: mask) == expected)
    }
    for code: UInt32 in 400...412 {
      let wireCode = code == 412 ? 57358 : 57441 + code - 400
      precondition(nativeInput(core, key: code, modifiers: 1) == Data("\u{1b}[\(wireCode);2:1u".utf8))
      precondition(nativeInput(core, key: code, event: 2) == Data("\u{1b}[\(wireCode);1:3u".utf8))
    }
    feed(core, "\u{1b}[<u\u{1b}[>2u")
    precondition(nativeInput(core, key: 400, modifiers: 1).isEmpty)
    precondition(nativeInput(core, key: 400, event: 2).isEmpty)
  }
  static func cells(_ snapshot: [String: Any], _ row: Int) -> [[String: Any]] {
    ((snapshot["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]])
  }
  static func lines(_ snapshot: [String: Any]) -> [String] {
    (snapshot["rows"] as! [[String: Any]]).map { row in
      (row["cells"] as! [[String: Any]]).map { $0["text"] as! String }.joined()
        .trimmingCharacters(in: .whitespaces)
    }
  }
  static func JSON(_ value: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  static func stableSnapshot(_ core: OpaquePointer) -> Data {
    try! JSONSerialization.data(withJSONObject: snapshot(core), options: [.sortedKeys])
  }
  static func feed(_ core: OpaquePointer, bytes: Data, partitions: [Int]) {
    var offset = 0
    for requested in partitions where offset < bytes.count {
      let end = min(bytes.count, offset + requested)
      while offset < end || terminal_has_work(core) {
        let wasWorking = terminal_has_work(core)
        let count: Int = bytes.withUnsafeBytes { buffer in
          let pointer = offset < end ? buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset) : nil
          return terminal_feed(core, pointer, end - offset, 0)
        }
        precondition(count >= 0 && count <= end - offset)
        precondition(count > 0 || wasWorking)
        offset += count
      }
    }
    while offset < bytes.count || terminal_has_work(core) {
      let wasWorking = terminal_has_work(core)
      let count: Int = bytes.withUnsafeBytes { buffer in
        let pointer = offset < bytes.count ? buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset) : nil
        return terminal_feed(core, pointer, bytes.count - offset, 0)
      }
      precondition(count >= 0 && count <= bytes.count - offset)
      precondition(count > 0 || wasWorking)
      offset += count
    }
  }
  static func rawFeed(_ core: OpaquePointer, _ bytes: Data) -> Int {
    bytes.withUnsafeBytes {
      terminal_feed(core, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 0)
    }
  }
  static func asciiByteAdmission() {
    // The whole-buffer path admits long ASCII in bulk to the same decoder
    // scratch. One-byte and irregular feeds retain per-byte decoding; their
    // complete snapshots must nevertheless remain identical.
    let text = "\u{1b}]8;;https://ascii.example\u{7}\u{1b}[31m\u{0600}" +
      String(repeating: "A", count: 1_024) +
      "\u{1b}]8;;https://current.example\u{7}\u{1b}[32m\u{301}\u{1b}[3b\u{1b}]8;;\u{7}\u{1b}[0m"
    let payload = Data(text.utf8)
    let whole = terminal_create(8, 2)!, bytewise = terminal_create(8, 2)!, irregular = terminal_create(8, 2)!
    defer { terminal_destroy(whole); terminal_destroy(bytewise); terminal_destroy(irregular) }
    feed(whole, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [3, 17, 1_023, 2, 19, 7, 53])
    let expected = stableSnapshot(whole)
    precondition(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)

    // A viable prefix must force its following ASCII through UTF-8 rejection
    // first; bulk admission resumes only after the decoder becomes idle.
    let pending = Data([0xe1, 0x80]) + Data(repeating: UInt8(ascii: "B"), count: 32)
    let pendingWhole = terminal_create(8, 2)!, pendingBytes = terminal_create(8, 2)!
    defer { terminal_destroy(pendingWhole); terminal_destroy(pendingBytes) }
    feed(pendingWhole, bytes: pending, partitions: [pending.count])
    feed(pendingBytes, bytes: pending, partitions: [1, 1] + Array(repeating: 1, count: 32))
    precondition(stableSnapshot(pendingWhole) == stableSnapshot(pendingBytes))

    // DEC Special Graphics maps printable bytes, so its run remains on the
    // ordinary decoder path; normal charset resumes borrowed admission.
    let dec = Data(("\u{1b}(0" + String(repeating: "q", count: 32) +
      "\u{1b}(B" + String(repeating: "x", count: 32)).utf8)
    let decWhole = terminal_create(8, 2)!, decBytes = terminal_create(8, 2)!
    defer { terminal_destroy(decWhole); terminal_destroy(decBytes) }
    feed(decWhole, bytes: dec, partitions: [dec.count])
    feed(decBytes, bytes: dec, partitions: Array(repeating: 1, count: dec.count))
    precondition(stableSnapshot(decWhole) == stableSnapshot(decBytes))

    // Runs below the admission threshold stay on the existing decoder path.
    // Repeated Unicode and ANSI boundaries must not change their partition
    // semantics while avoiding a fresh scan for every ASCII byte.
    let shortMixed = Data((String(repeating: "a", count: 15) + "猫" +
      "\u{1b}[31m" + String(repeating: "b", count: 15) + "\u{1b}[0m" +
      String(repeating: "c", count: 15) + "\u{301}").utf8)
    let shortWhole = terminal_create(8, 2)!, shortBytes = terminal_create(8, 2)!, shortIrregular = terminal_create(8, 2)!
    defer { terminal_destroy(shortWhole); terminal_destroy(shortBytes); terminal_destroy(shortIrregular) }
    feed(shortWhole, bytes: shortMixed, partitions: [shortMixed.count])
    feed(shortBytes, bytes: shortMixed, partitions: Array(repeating: 1, count: shortMixed.count))
    feed(shortIrregular, bytes: shortMixed, partitions: [4, 11, 3, 15, 2, 7, 9])
    let shortExpected = stableSnapshot(shortWhole)
    precondition(stableSnapshot(shortBytes) == shortExpected && stableSnapshot(shortIrregular) == shortExpected)

    // Feed consumes no more than 64 KiB even when that first chunk is one
    // bulk ASCII run. History is disabled to keep this ABI boundary small.
    let boundary = terminal_create(8, 2)!
    defer { terminal_destroy(boundary) }
    terminal_set_history_limit(boundary, 0)
    let bytes = Data(repeating: UInt8(ascii: "z"), count: 65_537)
    precondition(rawFeed(boundary, bytes) == 65_536)
    precondition(rawFeed(boundary, Data(bytes.suffix(1))) == 1)
    precondition(terminal_validate(boundary))

    // REP remains a resumable input boundary even after a bulk ASCII run:
    // the final CSI byte is admitted, then both repeat budgets drain before
    // the withheld suffix can become last-printed text.
    let repeatCore = terminal_create(128, 2)!
    defer { terminal_destroy(repeatCore) }
    let repeatPrefix = Data((String(repeating: "A", count: 32) + "\u{1b}[5000bZ").utf8)
    let suffixOffset = repeatPrefix.firstIndex(of: UInt8(ascii: "Z"))!
    precondition(rawFeed(repeatCore, repeatPrefix) == suffixOffset)
    func visibleZCount() -> Int {
      (snapshot(repeatCore)["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }
        .filter { $0["text"] as? String == "Z" }.count
    }
    precondition(visibleZCount() == 0)
    precondition(rawFeed(repeatCore, Data("Z".utf8)) == 0) // first 4,096 repeats
    precondition(visibleZCount() == 0)
    precondition(rawFeed(repeatCore, Data("Z".utf8)) == 0) // remaining 904
    precondition(visibleZCount() == 0)
    precondition(rawFeed(repeatCore, Data("Z".utf8)) == 1)
    let afterSuffix = snapshot(repeatCore)
    precondition((afterSuffix["revision"] as? Int) == 5_035)
    precondition((afterSuffix["document_epoch"] as? Int) == 5_035)
    precondition(visibleZCount() == 1)
    precondition(rawFeed(repeatCore, Data("\u{1b}[1b".utf8)) == 4)
    precondition(terminal_feed(repeatCore, nil, 0, 0) == 0)
    precondition(visibleZCount() == 2)
  }
  static func decodedBatchEquivalence() {
    // The whole-buffer case reaches the <=1024 decoded scalar writer, while
    // the byte and irregular cases force ordinary feed boundaries.  A full
    // snapshot comparison includes rich cells/styles/links, cursor, wrap,
    // row IDs, revisions/epochs, history and viewport anchors.
    let long = String(repeating: "x", count: 1023) + "\u{600}A" +
      String(repeating: "\u{301}", count: 64) + "👩क्‍ष"
    let text = "\u{1b}(0q\u{1b}(B\u{1b}[31m\u{1b}]8;;https://example.test/batch\u{7}" +
      long + "\u{1b}]8;;\u{7}\u{1b}[0m\r\nZ\u{1b}[2b\u{1b}[5n"
    let payload = Data(text.utf8)
    let all = terminal_create(8, 2)!
    let bytewise = terminal_create(8, 2)!
    let irregular = terminal_create(8, 2)!
    defer { terminal_destroy(all); terminal_destroy(bytewise); terminal_destroy(irregular) }
    feed(all, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [3, 1021, 2, 17, 5, 31, 7, 509])
    let expected = stableSnapshot(all)
    precondition(stableSnapshot(bytewise) == expected)
    precondition(stableSnapshot(irregular) == expected)
    let expectedReplies = replies(all)
    precondition(replies(bytewise) == expectedReplies && replies(irregular) == expectedReplies)

    // Extending a styled/hyperlinked cluster must retain its base attributes
    // for REP, rather than using the SGR/OSC 8 state current at the mark.
    let richRepeat = terminal_create(16, 2)!
    defer { terminal_destroy(richRepeat) }
    feed(richRepeat, bytes: Data("\u{1b}]8;;https://one.example\u{1b}\\\u{1b}[31mA\u{1b}]8;;https://two.example\u{1b}\\\u{1b}[32m\u{301}\u{1b}[2b".utf8), partitions: [4, 1, 7, 2, 99])
    let repeated = cells(snapshot(richRepeat), 0)
    for index in 0..<3 {
      precondition(repeated[index]["text"] as? String == "A\u{301}")
      precondition(repeated[index]["link"] as? String == "https://one.example")
      precondition((repeated[index]["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 1])
    }

    // An incomplete UTF-8 prefix is only finished by an actual control/ESC,
    // never by an ordinary scratch/feed boundary.
    let interrupted = Data([0xf0, 0x9f, 0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x41])
    let once = terminal_create(8, 2)!, split = terminal_create(8, 2)!
    defer { terminal_destroy(once); terminal_destroy(split) }
    feed(once, bytes: interrupted, partitions: [interrupted.count])
    feed(split, bytes: interrupted, partitions: [1, 1, 1, 2, 3])
    precondition(stableSnapshot(once) == stableSnapshot(split))

    // E1 80 + B emits two scalars (replacement and B).  The replacement
    // lands exactly at capacity after 1023 ASCII scalars, so this guards the
    // decoder's `.two` path when its emission straddles scratch draining.
    let twoEmission = Data(repeating: UInt8(ascii: "x"), count: 1023) + Data([0xe1, 0x80, 0x42])
    let twoWhole = terminal_create(8, 2)!, twoBytes = terminal_create(8, 2)!, twoIrregular = terminal_create(8, 2)!
    defer { terminal_destroy(twoWhole); terminal_destroy(twoBytes); terminal_destroy(twoIrregular) }
    feed(twoWhole, bytes: twoEmission, partitions: [twoEmission.count])
    feed(twoBytes, bytes: twoEmission, partitions: Array(repeating: 1, count: twoEmission.count))
    feed(twoIrregular, bytes: twoEmission, partitions: [1023, 1, 2])
    let twoExpected = stableSnapshot(twoWhole)
    precondition(stableSnapshot(twoBytes) == twoExpected && stableSnapshot(twoIrregular) == twoExpected)

    // Exercise a pinned viewport while every newly scrolled row is evicted
    // by a zero/tiny byte budget.  Snapshot equality covers history bytes,
    // anchors, clamp revision and all epochs in addition to rich cells.
    let bufferedWrap = Data((String(repeating: "w", count: 1_129) + "\u{1b}[5n").utf8)
    for budget: UInt64 in [0, 1] {
      func constrained() -> OpaquePointer {
        let core = terminal_create(4, 2)!
        terminal_set_history_limit(core, 8)
        feed(core, bytes: Data("0\r\n1\r\n2\r\n3".utf8), partitions: [8])
        terminal_view_scroll(core, 1)
        terminal_set_history_byte_limit(core, budget)
        return core
      }
      let whole = constrained(), bytewise = constrained(), irregular = constrained()
      defer { terminal_destroy(whole); terminal_destroy(bytewise); terminal_destroy(irregular) }
      feed(whole, bytes: bufferedWrap, partitions: [bufferedWrap.count])
      feed(bytewise, bytes: bufferedWrap, partitions: Array(repeating: 1, count: bufferedWrap.count))
      feed(irregular, bytes: bufferedWrap, partitions: [5, 1023, 2, 17, 11, 71])
      let expected = stableSnapshot(whole)
      precondition(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)
      precondition((snapshot(whole)["history_rows"] as? Int) == 0)
      let reply = replies(whole)
      precondition(replies(bytewise) == reply && replies(irregular) == reply)
    }
  }
  static func indexHistoryUsesMutatedPrimaryForViewportClamp() {
    for budget in ["count", "bytes-zero", "bytes-one"] {
      let core = terminal_create(4, 2)!
      defer { terminal_destroy(core) }
      feed(core, "A\r\nB\r\nC")
      terminal_view_scroll(core, 1) // Pin the row identity for A.
      precondition(terminal_resize(core, 4, 3)) // A becomes primary, not history.
      switch budget {
      case "count": terminal_set_history_limit(core, 0)
      case "bytes-zero": terminal_set_history_byte_limit(core, 0)
      default: terminal_set_history_byte_limit(core, 1)
      }
      // No retained row exists to evict yet, so the anchor remains live.
      let before = snapshot(core)
      let revision = before["viewport_clamp_revision"] as! Int
      feed(core, "\r\nD") // Appends old primary A, then immediately evicts it.
      let after = snapshot(core)
      precondition(after["viewport_clamp_revision"] as! Int == revision + 1, budget)
      precondition(after["following_tail"] as? Bool == false && after["scroll_offset"] as? Int == 0, budget)
      precondition(after["history_rows"] as? Int == 0 && lines(after) == ["B", "C", "D"], budget)
      precondition((snapshot(core)["viewport_clamp_revision"] as! Int) == after["viewport_clamp_revision"] as! Int, budget)
    }
  }
  static func csiASCIIParsing() {
    let core = terminal_create(8, 2)!
    defer { terminal_destroy(core) }
    // Empty fields retain default-zero semantics; max UInt32 is valid while
    // an overflowing contiguous parameter ignores its whole CSI command.
    feed(core, "\u{1b}[31mR\u{1b}[;mD\u{1b}[4294967295CZ\u{1b}[4294967296DQ")
    let first = cells(snapshot(core), 0)
    precondition((first[0]["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 1])
    precondition((first[1]["style"] as? [String: Any])?["foreground"] as? String == "Default")
    precondition(first[7]["text"] as? String == "Z")
    // Overflowing D was ignored, so Q follows the max-valid C movement.
    precondition(cells(snapshot(core), 1)[0]["text"] as? String == "Q")

    let rendition = terminal_create(8, 2)!
    defer { terminal_destroy(rendition) }
    feed(rendition, "\u{1b}[38:2::255:255:255;4:3;48;5;7mX")
    let style = cells(snapshot(rendition), 0)[0]["style"] as! [String: Any]
    precondition(style["foreground"] as? [String: [Int]] == ["Rgb": [255, 255, 255]])
    precondition(style["background"] as? [String: Int] == ["Indexed": 7])
    precondition(style["underline"] as? Int == 3)

    // Keyboard prefixes and private/intermediate CSI syntax remain byte
    // syntax, rather than becoming Unicode Character classification work.
    feed(core, "\u{1b}[>31u")
    precondition(nativeInput(core, text: "a", key: 200) == Data("\u{1b}[97;1:1;97u".utf8))
    // Kitty's set-flags command parses its first field before generic CSI
    // filtering. Colons make that field invalid rather than concatenating it.
    feed(core, "\u{1b}[>1:1u")
    precondition(nativeInput(core, text: "a", key: 200) == Data("a".utf8))
    feed(core, "\u{1b}[>31u")
    feed(core, "\u{1b}[>429496729:6u")
    precondition(nativeInput(core, text: "a", key: 200) == Data("a".utf8))
    feed(core, "\u{1b}[?1049hA\u{1b}[?1049l\u{1b}[1\"q猫\u{1b}[?2J")
    let afterPrivate = snapshot(core)
    precondition(afterPrivate["alternate"] as? Bool == false)
    precondition((afterPrivate["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }
      .contains { $0["text"] as? String == "猫" })

    // A non-ASCII parameter byte used to be rejected by the UInt32 numeric
    // validation. It must not become a defaulted cursor-down command.
    let malformed = terminal_create(4, 2)!
    defer { terminal_destroy(malformed) }
    feed(malformed, "X")
    feed(malformed, bytes: Data([0x1b, 0x5b, 0xb2, 0x42]), partitions: [4])
    feed(malformed, "Y")
    precondition(cells(snapshot(malformed), 0)[0]["text"] as? String == "X")
    precondition(cells(snapshot(malformed), 0)[1]["text"] as? String == "Y")
    precondition(cells(snapshot(malformed), 1).allSatisfy { ($0["text"] as? String)?.isEmpty == true })

    // Individual digit runs fit UInt32 here, but the old flattened value was
    // Int.max and could overflow cursor arithmetic. It is one invalid CSI.
    let concatenated = terminal_create(4, 2)!
    defer { terminal_destroy(concatenated) }
    feed(concatenated, "X\u{1b}[922337203:6:854775807CY")
    precondition(cells(snapshot(concatenated), 0)[0]["text"] as? String == "X")
    precondition(cells(snapshot(concatenated), 0)[1]["text"] as? String == "Y")

    // `>` only has its raw-first-field rule for keyboard `u`; ordinary CSI
    // commands continue to use the legacy flattened parameter stream.
    let prefixedMotion = terminal_create(8, 2)!
    defer { terminal_destroy(prefixedMotion) }
    feed(prefixedMotion, "X\u{1b}[>31CY")
    precondition(cells(snapshot(prefixedMotion), 0)[7]["text"] as? String == "Y")
  }
  static func csiScratchReuseEquivalence() {
    let grown = Array(repeating: "1", count: 256).joined(separator: ";")
    let text = "\u{1b}[" + grown + "mA" +
      "\u{1b}[1;2;4294967296;3mB" + // invalid after partial scratch values
      "\u{1b}[2;4H\u{1b}[32mC" +
      "\u{1b}[38:2::255:1:2;48;5;7;4:3mD" +
      "\u{1b}[0mE\u{1b}[5n"
    let payload = Data(text.utf8)
    let whole = terminal_create(8, 3)!, bytewise = terminal_create(8, 3)!, irregular = terminal_create(8, 3)!
    defer { terminal_destroy(whole); terminal_destroy(bytewise); terminal_destroy(irregular) }
    feed(whole, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [5, 63, 2, 127, 17, 3, 71])
    let expected = stableSnapshot(whole)
    precondition(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)
    let first = cells(snapshot(whole), 0)[0]
    precondition(first["text"] as? String == "A")
    precondition((first["style"] as? [String: Any])?["bold"] as? Bool == true)
    let second = cells(snapshot(whole), 0)[1]
    precondition(second["text"] as? String == "B")
    precondition((second["style"] as? [String: Any])?["bold"] as? Bool == true)
    let styled = cells(snapshot(whole), 1)
    precondition(styled[3]["text"] as? String == "C")
    precondition((styled[3]["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 2])
    precondition(styled[4]["text"] as? String == "D")
    let rich = styled[4]["style"] as! [String: Any]
    precondition(rich["foreground"] as? [String: [Int]] == ["Rgb": [255, 1, 2]])
    precondition(rich["background"] as? [String: Int] == ["Indexed": 7])
    precondition(rich["underline"] as? Int == 3)
    precondition(styled[5]["text"] as? String == "E")
    precondition((styled[5]["style"] as? [String: Any])?["foreground"] as? String == "Default")
    let expectedReplies = replies(whole)
    precondition(replies(bytewise) == expectedReplies && replies(irregular) == expectedReplies)
  }
  static func carriageReturnEquivalence() {
    let text = "\u{1b}[?69h\u{1b}[3;6s\u{1b}[4GQ\rR\r\nS" +
      "\u{1b}[3;1He\u{301}\rZ\u{1b}(0q\u{1b}(B\rT"
    let payload = Data(text.utf8)
    let whole = terminal_create(8, 3)!, bytewise = terminal_create(8, 3)!, irregular = terminal_create(8, 3)!
    defer { terminal_destroy(whole); terminal_destroy(bytewise); terminal_destroy(irregular) }
    feed(whole, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [1, 4, 2, 7, 3, 11, 5, 19])
    let expected = stableSnapshot(whole)
    precondition(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)
    let rows = snapshot(whole)["rows"] as! [[String: Any]]
    let first = rows[0]["cells"] as! [[String: Any]]
    let second = rows[1]["cells"] as! [[String: Any]]
    precondition(first[2]["text"] as? String == "R")
    precondition(second[2]["text"] as? String == "S")
    let third = rows[2]["cells"] as! [[String: Any]]
    precondition(third[0]["text"] as? String == "Z")
    precondition(third[1]["text"] as? String == "─")
    precondition(third[2]["text"] as? String == "T")
  }
  static func searchABI() {
    func create(_ core: OpaquePointer, _ query: String) -> OpaquePointer? {
      let bytes = Array(query.utf8)
      return bytes.withUnsafeBufferPointer { terminal_search_create(core, $0.baseAddress, $0.count) }
    }
    func runTask(_ core: OpaquePointer, _ task: OpaquePointer) -> UInt32 {
      for _ in 0..<10_000 {
        switch terminal_search_fill(core, task) {
        case 0:
          precondition([UInt32(0), 1, 2].contains(terminal_search_step(task)))
        case 2: return terminal_search_accept(core, task)
        case 3, 4: return terminal_search_fill(core, task)
        default: preconditionFailure("unexpected search status")
        }
      }
      preconditionFailure("search did not finish")
    }
    func run(_ core: OpaquePointer, _ query: String) -> UInt32 {
      guard let task = create(core, query) else { return UInt32.max }
      defer { terminal_search_destroy(task) }
      return runTask(core, task)
    }

    let soft = terminal_create(4, 3)!
    defer { terminal_destroy(soft) }
    feed(soft, "abcdEFGH\r\nnext  ")
    precondition(run(soft, "dEf") == 5)
    precondition((snapshot(soft)["search"] as! [[String: Int]]).count == 2)
    precondition(run(soft, "GHnext") == 2)
    precondition(run(soft, "GH\nnext") == 5)
    precondition(run(soft, "next  ") == 5)
    precondition(run(soft, "\n") == 5) // A zero-width hard-break proof still navigates.

    let history = terminal_create(8, 2)!
    defer { terminal_destroy(history) }
    feed(history, "target\r\nsecond\r\nTARGET\r\nlater\r\nlast")
    precondition(run(history, "target") == 5)
    let anchored = snapshot(history)
    precondition(anchored["scroll_offset"] as? Int == 1)
    precondition((anchored["search"] as! [[String: Int]]) == [["row": 0, "start": 0, "end": 6]])
    precondition((binaryHeader(history, scroll: 0)["search"] as! [[String: Int]]).isEmpty)

    let alternate = terminal_create(8, 2)!
    defer { terminal_destroy(alternate) }
    feed(alternate, "needle")
    feed(alternate, "\u{1b}[?1049hALT")
    precondition(run(alternate, "needle") == 2)
    precondition(run(alternate, "alt") == 5)

    let unicode = terminal_create(5, 3)!
    defer { terminal_destroy(unicode) }
    feed(unicode, "Ée\u{301}猫👩🏽‍💻")
    precondition(run(unicode, "éE\u{301}猫") == 5)
    precondition(run(unicode, "猫👩🏽‍💻") == 5)
    precondition((snapshot(unicode)["search"] as! [[String: Int]]).count == 2) // Wrap spacer excluded.
    precondition(run(unicode, "👩") == 5)
    precondition((snapshot(unicode)["search"] as! [[String: Int]]).contains {
      $0["end", default: 0] - $0["start", default: 0] == 2
    })

    // Accepted decorations retain their complete row proofs: unrelated output
    // leaves them visible, while a changed matched row silently drops them.
    let decoration = terminal_create(8, 3)!
    defer { terminal_destroy(decoration) }
    feed(decoration, "target\r\nmiddle\r\nlater")
    precondition(run(decoration, "target") == 5)
    precondition(!(snapshot(decoration)["search"] as! [[String: Int]]).isEmpty)
    feed(decoration, "\u{1b}[3;1Hother")
    precondition(!(snapshot(decoration)["search"] as! [[String: Int]]).isEmpty)
    feed(decoration, "\u{1b}[1;1HX")
    precondition((snapshot(decoration)["search"] as! [[String: Int]]).isEmpty)

    // A task captures its final row identity at creation. Later output is not
    // chased, while a changed matched row is still rejected by row proof.
    let future = terminal_create(8, 2)!
    defer { terminal_destroy(future) }
    feed(future, "first\r\nend")
    guard let futureTask = create(future, "future") else { preconditionFailure("future task") }
    defer { terminal_search_destroy(futureTask) }
    feed(future, "\r\nfuture")
    precondition(runTask(future, futureTask) == 2)

    let staleCore = terminal_create(8, 2)!
    defer { terminal_destroy(staleCore) }
    feed(staleCore, "target")
    guard let stale = create(staleCore, "target") else { preconditionFailure("search create") }
    defer { terminal_search_destroy(stale) }
    // Fill lends an immutable old row; overwriting that row before its worker
    // step must be rejected by proof at owner acceptance, not mis-highlighted.
    precondition(terminal_search_fill(staleCore, stale) == 0)
    feed(staleCore, "\rX")
    precondition([UInt32(0), 1, 2].contains(terminal_search_step(stale)))
    precondition(runTask(staleCore, stale) == 3)

    let transition = terminal_create(8, 2)!
    defer { terminal_destroy(transition) }
    feed(transition, "target")
    guard let transitionTask = create(transition, "target") else { preconditionFailure("transition task") }
    defer { terminal_search_destroy(transitionTask) }
    precondition(terminal_search_fill(transition, transitionTask) == 0)
    feed(transition, "\u{1b}[?1049hALT\u{1b}[?1049l")
    _ = terminal_search_step(transitionTask)
    precondition(runTask(transition, transitionTask) == 3)

    let cleared = terminal_create(8, 2)!
    defer { terminal_destroy(cleared) }
    feed(cleared, "target")
    guard let clearTask = create(cleared, "target") else { preconditionFailure("clear task") }
    defer { terminal_search_destroy(clearTask) }
    precondition(terminal_search_fill(cleared, clearTask) == 0)
    _ = terminal_clear_display(cleared)
    _ = terminal_search_step(clearTask)
    precondition(runTask(cleared, clearTask) == 3)

    let resized = terminal_create(8, 2)!
    defer { terminal_destroy(resized) }
    feed(resized, "target")
    guard let resizedTask = create(resized, "target") else { preconditionFailure("resize task") }
    defer { terminal_search_destroy(resizedTask) }
    precondition(terminal_resize(resized, 9, 2))
    precondition(terminal_search_fill(resized, resizedTask) == 3)

    let pendingResize = terminal_create(8, 2)!
    defer { terminal_destroy(pendingResize) }
    feed(pendingResize, "target")
    guard let pendingResizeTask = create(pendingResize, "target") else { preconditionFailure("pending resize task") }
    defer { terminal_search_destroy(pendingResizeTask) }
    precondition(terminal_resize(pendingResize, 9, 2))
    precondition(terminal_search_accept(pendingResize, pendingResizeTask) == 3)

    let evicted = terminal_create(8, 2)!
    defer { terminal_destroy(evicted) }
    feed(evicted, "target\r\none\r\ntwo")
    guard let evictedTask = create(evicted, "target") else { preconditionFailure("eviction task") }
    defer { terminal_search_destroy(evictedTask) }
    terminal_set_history_limit(evicted, 0)
    precondition(terminal_search_fill(evicted, evictedTask) == 3)

    // Raising or reapplying a scrollback limit without evicting a proven row
    // does not change Rust's search stamp. The task remains acceptable.
    let unchangedLimit = terminal_create(8, 2)!
    defer { terminal_destroy(unchangedLimit) }
    feed(unchangedLimit, "target")
    guard let unchangedLimitTask = create(unchangedLimit, "target") else { preconditionFailure("limit task") }
    defer { terminal_search_destroy(unchangedLimitTask) }
    terminal_set_history_limit(unchangedLimit, 10_000)
    precondition(runTask(unchangedLimit, unchangedLimitTask) == 5)

    // A captured final row does not chase later output, but if later output
    // makes it soft-wrap it still keeps that successor in its proof.
    let extendedStop = terminal_create(4, 2)!
    defer { terminal_destroy(extendedStop) }
    feed(extendedStop, "aaaaBBBB")
    guard let extendedStopTask = create(extendedStop, "BBBB") else { preconditionFailure("stop task") }
    defer { terminal_search_destroy(extendedStopTask) }
    feed(extendedStop, "C")
    precondition(runTask(extendedStop, extendedStopTask) == 5)

    // RIS restarts document row IDs; the dedicated generation prevents an ABA
    // match when a fresh terminal prints identical text into the same grid.
    let reset = terminal_create(8, 2)!
    defer { terminal_destroy(reset) }
    feed(reset, "same")
    guard let resetTask = create(reset, "same") else { preconditionFailure("reset task") }
    defer { terminal_search_destroy(resetTask) }
    precondition(terminal_search_fill(reset, resetTask) == 0)
    feed(reset, "\u{1b}csame")
    _ = terminal_search_step(resetTask)
    precondition(runTask(reset, resetTask) == 3)
    let tooLong = [UInt8](repeating: 120, count: 4_097)
    precondition(tooLong.withUnsafeBufferPointer { terminal_search_create(soft, $0.baseAddress, $0.count) } == nil)

    let overlaps = terminal_create(4_096, 2)!
    defer { terminal_destroy(overlaps) }
    feed(overlaps, String(repeating: "a", count: 4_096))
    precondition(run(overlaps, String(repeating: "a", count: 2_048)) == 5)
    precondition((snapshot(overlaps)["search"] as! [[String: Int]]) == [
      ["row": 0, "start": 2_048, "end": 4_096]
    ])

    let detached = terminal_create(80, 2)!
    feed(detached, String(repeating: "x", count: 80))
    guard let workerOnly = create(detached, "x") else { preconditionFailure("worker task") }
    precondition(terminal_search_fill(detached, workerOnly) == 0)
    terminal_destroy(detached)
    precondition([UInt32(0), 1, 2].contains(terminal_search_step(workerOnly)))
    terminal_search_destroy(workerOnly)
  }
  static func binarySnapshotOffsetsRemainIndependentOfOwnerViewport() {
    let core = terminal_create(4, 2)!
    defer { terminal_destroy(core) }
    feed(core, "A\r\nB\r\nC")
    precondition(binaryHeader(core, scroll: 1)["scroll_offset"] as? Int == 1)
    terminal_view_scroll(core, 1)
    precondition(viewHeader(core)["following_tail"] as? Bool == false)
    precondition(binaryHeader(core, scroll: 0)["following_tail"] as? Bool == true)
    precondition(terminal_resize(core, 4, 3)) // The anchor moves into the live grid.
    precondition(viewHeader(core)["scroll_offset"] as? Int == 0)
    precondition(viewHeader(core)["following_tail"] as? Bool == false)
    precondition(binaryHeader(core, scroll: 0)["following_tail"] as? Bool == true)
  }
  static func legacySnapshotHonorsExplicitNumericScroll() {
    let core = terminal_create(8, 3)!
    defer { terminal_destroy(core) }
    feed(core, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive")

    let tail = legacySnapshot(core, scroll: 0)
    let previous = legacySnapshot(core, scroll: 1)
    let oldest = legacySnapshot(core, scroll: Int.max)
    let historyRows = tail["history_rows"] as! Int
    precondition(historyRows > 1)
    precondition(tail["scroll_offset"] as? Int == 0 && tail["following_tail"] as? Bool == true)
    precondition(previous["scroll_offset"] as? Int == 1 && previous["following_tail"] as? Bool == false)
    precondition(oldest["scroll_offset"] as? Int == historyRows && oldest["following_tail"] as? Bool == false)
    precondition(JSON(tail["cursor"]!) == JSON(previous["cursor"]!))
    precondition(JSON(previous["cursor"]!) == JSON(oldest["cursor"]!))
    for key in ["revision", "document_epoch", "history_epoch", "screen_epoch", "geometry_epoch", "cols", "history_rows"] {
      precondition(tail[key] as? Int == previous[key] as? Int && previous[key] as? Int == oldest[key] as? Int)
    }
    let tailRows = tail["rows"] as! [[String: Any]]
    let previousRows = previous["rows"] as! [[String: Any]]
    let oldestRows = oldest["rows"] as! [[String: Any]]
    precondition((tailRows.last?["id"] as? Int) != (previousRows.last?["id"] as? Int))
    precondition((previousRows.first?["id"] as? Int) != (oldestRows.first?["id"] as? Int))

    let wrapped = terminal_create(4, 2)!
    defer { terminal_destroy(wrapped) }
    feed(wrapped, "abcdefghijkl")
    let wrappedOldest = legacySnapshot(wrapped, scroll: Int.max)
    precondition((wrappedOldest["rows"] as! [[String: Any]]).contains { $0["soft_wrapped"] as? Bool == true })

    terminal_view_scroll(core, 1)
    precondition(terminal_resize(core, 8, 4))
    let owner = snapshot(core)
    let explicitTail = legacySnapshot(core, scroll: 0)
    precondition(owner["scroll_offset"] as? Int == 0 && owner["following_tail"] as? Bool == false)
    precondition(explicitTail["scroll_offset"] as? Int == 0 && explicitTail["following_tail"] as? Bool == true)
    precondition(JSON(owner["rows"]!) == JSON(explicitTail["rows"]!))
  }
  static func defaultHistoryBudgetSurvivesContinuousOutput() {
    let core = terminal_create(4_096, 1)!
    defer { terminal_destroy(core) }
    let limit: UInt64 = 64 * 1_048_576
    let line = Data((String(repeating: "x", count: 4_096) + "\r\n").utf8)
    for _ in 0..<200 {
      precondition(rawFeed(core, line) == line.count)
      precondition(terminal_history_bytes(core) <= limit)
    }
    terminal_view_scroll(core, Int64.max) // Retain the oldest available row.
    let before = viewHeader(core)["viewport_clamp_revision"] as! Int
    for _ in 0..<300 {
      precondition(rawFeed(core, line) == line.count)
      precondition(terminal_history_bytes(core) <= limit)
    }
    let after = viewHeader(core)
    precondition((after["viewport_clamp_revision"] as! Int) > before)
    precondition(after["following_tail"] as? Bool == false)
    precondition((after["history_rows"] as! Int) < 500)
    precondition(terminal_resize(core, 2_048, 2))
    precondition(terminal_history_bytes(core) <= limit)
    precondition(terminal_resize(core, 4_096, 1))
    precondition(terminal_history_bytes(core) <= limit)
    precondition(terminal_validate(core))
  }

  static func geometryABIContract() {
    // Rust returns a null ABI handle for invalid creation geometry; silently
    // clamping here would make a malformed host request look valid.
    let invalid: [(UInt32, UInt32)] = [(0, 1), (1, 0), (4_097, 1), (1, 4_097), (4_096, 257)]
    for (columns, rows) in invalid {
      if let terminal = terminal_create(columns, rows) {
        terminal_destroy(terminal)
        preconditionFailure("terminal_create accepted invalid geometry \(columns)x\(rows)")
      }
    }
    // Exercise Rust's exact maximum once, releasing it before the rejection
    // checks so the ABI contract does not retain a large fixture.
    guard let maximum = terminal_create(4_096, 256) else {
      preconditionFailure("terminal_create rejected valid maximum geometry")
    }
    terminal_destroy(maximum)
    let resized = terminal_create(8, 2)!
    defer { terminal_destroy(resized) }
    for (columns, rows) in invalid {
      precondition(!terminal_resize(resized, columns, rows))
    }
    precondition(viewHeader(resized)["cols"] as? Int == 8)
    // Rust validates pixel metrics before applying either geometry or cell
    // dimensions; malformed metrics must not be normalized into a resize.
    let invalidPixels: [(UInt32, UInt32)] = [(0, 16), (16, 0), (1_025, 16), (16, 1_025)]
    for (width, height) in invalidPixels {
      precondition(!terminal_resize_pixels(resized, 8, 2, width, height))
    }
    precondition(viewHeader(resized)["cols"] as? Int == 8)
  }

  static func main() {
    nativeModifierWire()
    asciiByteAdmission()
    decodedBatchEquivalence()
    indexHistoryUsesMutatedPrimaryForViewportClamp()
    csiASCIIParsing()
    csiScratchReuseEquivalence()
    carriageReturnEquivalence()
    searchABI()
    binarySnapshotOffsetsRemainIndependentOfOwnerViewport()
    legacySnapshotHonorsExplicitNumericScroll()
    defaultHistoryBudgetSurvivesContinuousOutput()
    geometryABIContract()
    guard let core = terminal_create(8, 3) else { fatalError("create") }
    defer { terminal_destroy(core) }
    feed(core, "one\ntwo")
    var value = snapshot(core)
    let first = cells(value, 0)
    precondition(first[0]["text"] as? String == "o")
    feed(core, "\u{1b}[31mR\u{1b}[0m")
    value = snapshot(core)
    let second = cells(value, 1)
    let red = second.first { $0["text"] as? String == "R" }
    precondition((red?["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 1])

    // Alternate-screen switching must isolate the primary grid.
    feed(core, "\u{1b}[?1049hALT")
    value = snapshot(core)
    precondition(value["alternate"] as? Bool == true)
    precondition((value["rows"] as! [[String: Any]]).contains {
      ($0["cells"] as! [[String: Any]]).contains { $0["text"] as? String == "A" }
    })
    feed(core, "\u{1b}[?1049l")
    value = snapshot(core)
    precondition(value["alternate"] as? Bool == false)
    precondition(cells(value, 0)[0]["text"] as? String == "o")

    // The C-facing input and reply callbacks are the Session's only wire path.
    precondition(input(core, text: "AUTOMATION_TEXT\n", key: 0) == Data("AUTOMATION_TEXT\n".utf8))
    precondition(input(core, key: 10) == Data("\u{1b}[A".utf8))
    precondition(input(core, text: "x\n\u{1b}y", key: 1) == Data("x\ry".utf8))
    feed(core, "\u{1b}[?2004h")
    precondition(input(core, text: "paste", key: 1) == Data("\u{1b}[200~paste\u{1b}[201~".utf8))
    feed(core, "\u{1b}[5n\u{1b}[6n")
    let response = replies(core)
    precondition(response.starts(with: Data("\u{1b}[0n".utf8)))
    precondition(response.contains(Data("R".utf8)))

    // The parser owns Kitty APC hand-off; snapshots expose only finalized
    // generation-addressable graphics state.
    feed(core, "\u{1b}_Ga=T,i=42,f=32,s=1,v=1;AP8A/w==\u{1b}\\")
    value = snapshot(core)
    let images = value["images"] as! [[String: Any]]
    precondition(images.count == 1 && images[0]["image"] as? Int == 42)

    precondition(terminal_resize(core, 4, 2))
    let euro = Array("€".utf8)
    for byte in euro { var b = byte; _ = terminal_feed(core, &b, 1, 0) }
    value = snapshot(core)
    precondition(value["cols"] as? Int == 4)
    // This is a safety/reentrancy smoke only: semantic maximal-subpart UTF-8
    // equivalence remains a documented parity gap.
    print("PASS Swift core smoke: grid, SGR, alternate screen, wire input/replies, resize")
  }
}

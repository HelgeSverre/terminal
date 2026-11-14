import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalEngine
import TerminalInterop
@testable import TerminalHost
@testable import TerminalUI

@Suite enum EmulatorTests {
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
    #expect(helge_terminal_snapshot_binary(
      core, scroll, 0, Unmanaged.passUnretained(capture).toOpaque(), collectMetadata))
    return try! JSONSerialization.jsonObject(with: capture.value) as! [String: Any]
  }
  static func viewHeader(_ core: OpaquePointer) -> [String: Any] {
    let capture = Metadata()
    #expect(helge_terminal_view_snapshot_binary(core, 0, Unmanaged.passUnretained(capture).toOpaque(), collectMetadata))
    return try! JSONSerialization.jsonObject(with: capture.value) as! [String: Any]
  }
  static func snapshot(_ core: OpaquePointer) -> [String: Any] {
    guard let snapshot = TerminalSnapshotTestSupport.ownerSnapshot(core) else { Issue.record("missing snapshot"); return [:] }
    return snapshot
  }
  static func legacySnapshot(_ core: OpaquePointer, scroll: Int) -> [String: Any] {
    guard let raw = helge_terminal_snapshot(core, scroll, 0) else { Issue.record("missing legacy snapshot"); return [:] }
    defer { helge_terminal_string_free(raw) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as! [String: Any]
  }
  static func feed(_ core: OpaquePointer, _ text: String) {
    let data = Data(text.utf8)
    _ = data.withUnsafeBytes { helge_terminal_feed(core, $0.bindMemory(to: UInt8.self).baseAddress, data.count, 0) }
  }
  static func input(_ core: OpaquePointer, text: String = "", key: UInt32, modifiers: UInt32 = 0,
                    event: UInt32 = 0) -> Data {
    let capture = Bytes()
    let accepted = text.withCString {
      helge_terminal_input(
        core, $0, key, modifiers, event, Unmanaged.passUnretained(capture).toOpaque(), collect)
    }
    #expect(accepted)
    return capture.value
  }
  static func replies(_ core: OpaquePointer) -> Data {
    let capture = Bytes()
    helge_terminal_replies(core, Unmanaged.passUnretained(capture).toOpaque(), collect)
    return capture.value
  }
  static func nativeInput(_ core: OpaquePointer, text: String = "", key: UInt32,
                          modifiers: UInt32 = 0, event: UInt32 = 0) -> Data {
    let capture = Bytes()
    let accepted = text.withCString {
      helge_terminal_input_with_metadata(core, $0, key, modifiers, event, nil, nil, 0, 0,
                                   Unmanaged.passUnretained(capture).toOpaque(), collect)
    }
    #expect(accepted)
    return capture.value
  }
  @Test static func nativeModifierWire() {
    let core = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(core) }
    feed(core, "\u{1b}[>11u") // Full key reporting plus press/repeat/release.
    for (mask, encoded) in [(UInt32(64), 65), (128, 129), (192, 193)] {
      let expected = Data("\u{1b}[97;\(encoded):1u".utf8)
      #expect(nativeInput(core, text: "a", key: 200, modifiers: mask) == expected)
      #expect(input(core, text: "a", key: 200, modifiers: mask) == expected)
    }
    for code: UInt32 in 400...412 {
      let wireCode = code == 412 ? 57358 : 57441 + code - 400
      #expect(nativeInput(core, key: code, modifiers: 1) == Data("\u{1b}[\(wireCode);2:1u".utf8))
      #expect(nativeInput(core, key: code, event: 2) == Data("\u{1b}[\(wireCode);1:3u".utf8))
    }
    feed(core, "\u{1b}[<u\u{1b}[>2u")
    #expect(nativeInput(core, key: 400, modifiers: 1).isEmpty)
    #expect(nativeInput(core, key: 400, event: 2).isEmpty)
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
      while offset < end || helge_terminal_has_work(core) {
        let wasWorking = helge_terminal_has_work(core)
        let count: Int = bytes.withUnsafeBytes { buffer in
          let pointer = offset < end ? buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset) : nil
          return helge_terminal_feed(core, pointer, end - offset, 0)
        }
        #expect(count >= 0 && count <= end - offset)
        #expect(count > 0 || wasWorking)
        offset += count
      }
    }
    while offset < bytes.count || helge_terminal_has_work(core) {
      let wasWorking = helge_terminal_has_work(core)
      let count: Int = bytes.withUnsafeBytes { buffer in
        let pointer = offset < bytes.count ? buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset) : nil
        return helge_terminal_feed(core, pointer, bytes.count - offset, 0)
      }
      #expect(count >= 0 && count <= bytes.count - offset)
      #expect(count > 0 || wasWorking)
      offset += count
    }
  }
  static func rawFeed(_ core: OpaquePointer, _ bytes: Data) -> Int {
    bytes.withUnsafeBytes {
      helge_terminal_feed(core, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 0)
    }
  }
  @Test static func asciiByteAdmission() {
    // The whole-buffer path admits long ASCII in bulk to the same decoder
    // scratch. One-byte and irregular feeds retain per-byte decoding; their
    // complete snapshots must nevertheless remain identical.
    let text = "\u{1b}]8;;https://ascii.example\u{7}\u{1b}[31m\u{0600}" +
      String(repeating: "A", count: 1_024) +
      "\u{1b}]8;;https://current.example\u{7}\u{1b}[32m\u{301}\u{1b}[3b\u{1b}]8;;\u{7}\u{1b}[0m"
    let payload = Data(text.utf8)
    let whole = helge_terminal_create(8, 2)!, bytewise = helge_terminal_create(8, 2)!, irregular = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(whole); helge_terminal_destroy(bytewise); helge_terminal_destroy(irregular) }
    feed(whole, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [3, 17, 1_023, 2, 19, 7, 53])
    let expected = stableSnapshot(whole)
    #expect(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)

    // A viable prefix must force its following ASCII through UTF-8 rejection
    // first; bulk admission resumes only after the decoder becomes idle.
    let pending = Data([0xe1, 0x80]) + Data(repeating: UInt8(ascii: "B"), count: 32)
    let pendingWhole = helge_terminal_create(8, 2)!, pendingBytes = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(pendingWhole); helge_terminal_destroy(pendingBytes) }
    feed(pendingWhole, bytes: pending, partitions: [pending.count])
    feed(pendingBytes, bytes: pending, partitions: [1, 1] + Array(repeating: 1, count: 32))
    #expect(stableSnapshot(pendingWhole) == stableSnapshot(pendingBytes))

    // DEC Special Graphics maps printable bytes, so its run remains on the
    // ordinary decoder path; normal charset resumes borrowed admission.
    let dec = Data(("\u{1b}(0" + String(repeating: "q", count: 32) +
      "\u{1b}(B" + String(repeating: "x", count: 32)).utf8)
    let decWhole = helge_terminal_create(8, 2)!, decBytes = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(decWhole); helge_terminal_destroy(decBytes) }
    feed(decWhole, bytes: dec, partitions: [dec.count])
    feed(decBytes, bytes: dec, partitions: Array(repeating: 1, count: dec.count))
    #expect(stableSnapshot(decWhole) == stableSnapshot(decBytes))

    // Runs below the admission threshold stay on the existing decoder path.
    // Repeated Unicode and ANSI boundaries must not change their partition
    // semantics while avoiding a fresh scan for every ASCII byte.
    let shortMixed = Data((String(repeating: "a", count: 15) + "猫" +
      "\u{1b}[31m" + String(repeating: "b", count: 15) + "\u{1b}[0m" +
      String(repeating: "c", count: 15) + "\u{301}").utf8)
    let shortWhole = helge_terminal_create(8, 2)!, shortBytes = helge_terminal_create(8, 2)!, shortIrregular = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(shortWhole); helge_terminal_destroy(shortBytes); helge_terminal_destroy(shortIrregular) }
    feed(shortWhole, bytes: shortMixed, partitions: [shortMixed.count])
    feed(shortBytes, bytes: shortMixed, partitions: Array(repeating: 1, count: shortMixed.count))
    feed(shortIrregular, bytes: shortMixed, partitions: [4, 11, 3, 15, 2, 7, 9])
    let shortExpected = stableSnapshot(shortWhole)
    #expect(stableSnapshot(shortBytes) == shortExpected && stableSnapshot(shortIrregular) == shortExpected)

    // Feed consumes no more than 64 KiB even when that first chunk is one
    // bulk ASCII run. History is disabled to keep this ABI boundary small.
    let boundary = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(boundary) }
    helge_terminal_set_history_limit(boundary, 0)
    let bytes = Data(repeating: UInt8(ascii: "z"), count: 65_537)
    #expect(rawFeed(boundary, bytes) == 65_536)
    #expect(rawFeed(boundary, Data(bytes.suffix(1))) == 1)
    #expect(helge_terminal_validate(boundary))

    // REP remains a resumable input boundary even after a bulk ASCII run:
    // the final CSI byte is admitted, then both repeat budgets drain before
    // the withheld suffix can become last-printed text.
    let repeatCore = helge_terminal_create(128, 2)!
    defer { helge_terminal_destroy(repeatCore) }
    let repeatPrefix = Data((String(repeating: "A", count: 32) + "\u{1b}[5000bZ").utf8)
    let suffixOffset = repeatPrefix.firstIndex(of: UInt8(ascii: "Z"))!
    #expect(rawFeed(repeatCore, repeatPrefix) == suffixOffset)
    func visibleZCount() -> Int {
      (snapshot(repeatCore)["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }
        .filter { $0["text"] as? String == "Z" }.count
    }
    #expect(visibleZCount() == 0)
    #expect(rawFeed(repeatCore, Data("Z".utf8)) == 0) // first 4,096 repeats
    #expect(visibleZCount() == 0)
    #expect(rawFeed(repeatCore, Data("Z".utf8)) == 0) // remaining 904
    #expect(visibleZCount() == 0)
    #expect(rawFeed(repeatCore, Data("Z".utf8)) == 1)
    let afterSuffix = snapshot(repeatCore)
    #expect((afterSuffix["revision"] as? Int) == 5_035)
    #expect((afterSuffix["document_epoch"] as? Int) == 5_035)
    #expect(visibleZCount() == 1)
    #expect(rawFeed(repeatCore, Data("\u{1b}[1b".utf8)) == 4)
    #expect(helge_terminal_feed(repeatCore, nil, 0, 0) == 0)
    #expect(visibleZCount() == 2)
  }
  @Test static func borrowedASCIIContinuationEquivalence() {
    // Bytewise feeds never enter the >=16-byte shortcut. Compare complete
    // owner snapshots (including revisions), replies, and history charges.
    // Short cases keep the preceding cluster visible; long cases cross both
    // the 1024-scalar transaction boundary and bounded history eviction.
    let short = String(repeating: "a", count: 16)
    let long = String(repeating: "bcdef0123456789 ", count: 73)
    let fixtures: [(String, Data)] = [
      ("prepend", Data(("\u{600}" + short + "\u{301}").utf8)),
      ("combining", Data(("e\u{301}" + short + "\u{301}").utf8)),
      ("emoji", Data(("👩🏽‍💻" + short + "\u{fe0f}").utf8)),
      ("pending-utf8", Data([0xe1, 0x80]) + Data((short + long).utf8) + Data([0xc2])),
      ("long-mixed", Data(("猫e\u{301}" + long + "👩🏽‍💻" + long).utf8)),
      ("charset", Data(("\u{1b}(0" + short + "\u{1b}(B" + long +
        "\u{1b})0\u{e}" + short + "\u{f}" + long).utf8)),
      ("margins-insert-nowrap", Data(("\u{1b}[?69h\u{1b}[3;14s\u{1b}[2;3r\u{1b}[?6h" + long +
        "\u{1b}[4h" + short + "\u{1b}[4l\u{1b}[?7l" + long).utf8)),
      ("rep-suffix", Data(("e\u{301}" + long + "\u{1b}[5000bZ\u{1b}[6n").utf8)),
    ]
    for (name, body) in fixtures {
      let payload = body + Data("\u{1b}[6n".utf8)
      for budget: UInt64 in [0, 4096] {
        func run(_ partitions: [Int]) -> (Data, Data, UInt64) {
          let core = helge_terminal_create(32, 4)!
          defer { helge_terminal_destroy(core) }
          helge_terminal_set_history_byte_limit(core, budget)
          feed(core, bytes: payload, partitions: partitions)
          helge_terminal_finish(core)
          #expect(helge_terminal_validate(core), "ASCII continuation invariants: \(name)")
          return (stableSnapshot(core), replies(core), helge_terminal_history_bytes(core))
        }
        let expected = run(Array(repeating: 1, count: payload.count))
        var partitions = [[payload.count], [3, 17, 1, 1023, 2, 19, 7]]
        for size in [15, 16, 1024] {
          partitions.append(Array(repeating: size, count: (payload.count + size - 1) / size))
        }
        for chunks in partitions {
          let actual = run(chunks)
          #expect(actual.0 == expected.0, "ASCII continuation snapshot: \(name), budget \(budget), chunks \(chunks.prefix(8))")
          #expect(actual.1 == expected.1, "ASCII continuation replies: \(name)")
          #expect(actual.2 == expected.2, "ASCII continuation history charge: \(name)")
        }
      }
    }
  }
  @Test static func decodedBatchEquivalence() {
    // The whole-buffer case reaches the <=1024 decoded scalar writer, while
    // the byte and irregular cases force ordinary feed boundaries.  A full
    // snapshot comparison includes rich cells/styles/links, cursor, wrap,
    // row IDs, revisions/epochs, history and viewport anchors.
    let long = String(repeating: "x", count: 1023) + "\u{600}A" +
      String(repeating: "\u{301}", count: 64) + "👩क्‍ष"
    let text = "\u{1b}(0q\u{1b}(B\u{1b}[31m\u{1b}]8;;https://example.test/batch\u{7}" +
      long + "\u{1b}]8;;\u{7}\u{1b}[0m\r\nZ\u{1b}[2b\u{1b}[5n"
    let payload = Data(text.utf8)
    let all = helge_terminal_create(8, 2)!
    let bytewise = helge_terminal_create(8, 2)!
    let irregular = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(all); helge_terminal_destroy(bytewise); helge_terminal_destroy(irregular) }
    feed(all, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [3, 1021, 2, 17, 5, 31, 7, 509])
    let expected = stableSnapshot(all)
    #expect(stableSnapshot(bytewise) == expected)
    #expect(stableSnapshot(irregular) == expected)
    let expectedReplies = replies(all)
    #expect(replies(bytewise) == expectedReplies && replies(irregular) == expectedReplies)

    // Extending a styled/hyperlinked cluster must retain its base attributes
    // for REP, rather than using the SGR/OSC 8 state current at the mark.
    let richRepeat = helge_terminal_create(16, 2)!
    defer { helge_terminal_destroy(richRepeat) }
    feed(richRepeat, bytes: Data("\u{1b}]8;;https://one.example\u{1b}\\\u{1b}[31mA\u{1b}]8;;https://two.example\u{1b}\\\u{1b}[32m\u{301}\u{1b}[2b".utf8), partitions: [4, 1, 7, 2, 99])
    let repeated = cells(snapshot(richRepeat), 0)
    for index in 0..<3 {
      #expect(repeated[index]["text"] as? String == "A\u{301}")
      #expect(repeated[index]["link"] as? String == "https://one.example")
      #expect((repeated[index]["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 1])
    }

    // An incomplete UTF-8 prefix is only finished by an actual control/ESC,
    // never by an ordinary scratch/feed boundary.
    let interrupted = Data([0xf0, 0x9f, 0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x41])
    let once = helge_terminal_create(8, 2)!, split = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(once); helge_terminal_destroy(split) }
    feed(once, bytes: interrupted, partitions: [interrupted.count])
    feed(split, bytes: interrupted, partitions: [1, 1, 1, 2, 3])
    #expect(stableSnapshot(once) == stableSnapshot(split))

    // E1 80 + B emits two scalars (replacement and B).  The replacement
    // lands exactly at capacity after 1023 ASCII scalars, so this guards the
    // decoder's `.two` path when its emission straddles scratch draining.
    let twoEmission = Data(repeating: UInt8(ascii: "x"), count: 1023) + Data([0xe1, 0x80, 0x42])
    let twoWhole = helge_terminal_create(8, 2)!, twoBytes = helge_terminal_create(8, 2)!, twoIrregular = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(twoWhole); helge_terminal_destroy(twoBytes); helge_terminal_destroy(twoIrregular) }
    feed(twoWhole, bytes: twoEmission, partitions: [twoEmission.count])
    feed(twoBytes, bytes: twoEmission, partitions: Array(repeating: 1, count: twoEmission.count))
    feed(twoIrregular, bytes: twoEmission, partitions: [1023, 1, 2])
    let twoExpected = stableSnapshot(twoWhole)
    #expect(stableSnapshot(twoBytes) == twoExpected && stableSnapshot(twoIrregular) == twoExpected)

    // Exercise a pinned viewport while every newly scrolled row is evicted
    // by a zero/tiny byte budget.  Snapshot equality covers history bytes,
    // anchors, clamp revision and all epochs in addition to rich cells.
    let bufferedWrap = Data((String(repeating: "w", count: 1_129) + "\u{1b}[5n").utf8)
    for budget: UInt64 in [0, 1] {
      func constrained() -> OpaquePointer {
        let core = helge_terminal_create(4, 2)!
        helge_terminal_set_history_limit(core, 8)
        feed(core, bytes: Data("0\r\n1\r\n2\r\n3".utf8), partitions: [8])
        helge_terminal_view_scroll(core, 1)
        helge_terminal_set_history_byte_limit(core, budget)
        return core
      }
      let whole = constrained(), bytewise = constrained(), irregular = constrained()
      defer { helge_terminal_destroy(whole); helge_terminal_destroy(bytewise); helge_terminal_destroy(irregular) }
      feed(whole, bytes: bufferedWrap, partitions: [bufferedWrap.count])
      feed(bytewise, bytes: bufferedWrap, partitions: Array(repeating: 1, count: bufferedWrap.count))
      feed(irregular, bytes: bufferedWrap, partitions: [5, 1023, 2, 17, 11, 71])
      let expected = stableSnapshot(whole)
      #expect(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)
      #expect((snapshot(whole)["history_rows"] as? Int) == 0)
      let reply = replies(whole)
      #expect(replies(bytewise) == reply && replies(irregular) == reply)
    }
  }
  @Test static func indexHistoryUsesMutatedPrimaryForViewportClamp() {
    for budget in ["count", "bytes-zero", "bytes-one"] {
      let core = helge_terminal_create(4, 2)!
      defer { helge_terminal_destroy(core) }
      feed(core, "A\r\nB\r\nC")
      helge_terminal_view_scroll(core, 1) // Pin the row identity for A.
      #expect(helge_terminal_resize(core, 4, 3)) // A becomes primary, not history.
      switch budget {
      case "count": helge_terminal_set_history_limit(core, 0)
      case "bytes-zero": helge_terminal_set_history_byte_limit(core, 0)
      default: helge_terminal_set_history_byte_limit(core, 1)
      }
      // No retained row exists to evict yet, so the anchor remains live.
      let before = snapshot(core)
      let revision = before["viewport_clamp_revision"] as! Int
      feed(core, "\r\nD") // Appends old primary A, then immediately evicts it.
      let after = snapshot(core)
      #expect(after["viewport_clamp_revision"] as! Int == revision + 1, "\(budget)")
      #expect(after["following_tail"] as? Bool == false && after["scroll_offset"] as? Int == 0, "\(budget)")
      #expect(after["history_rows"] as? Int == 0 && lines(after) == ["B", "C", "D"], "\(budget)")
      #expect((snapshot(core)["viewport_clamp_revision"] as! Int) == after["viewport_clamp_revision"] as! Int, "\(budget)")
    }
  }
  @Test static func csiASCIIParsing() {
    let core = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(core) }
    // Empty fields retain default-zero semantics; max UInt32 is valid while
    // an overflowing contiguous parameter ignores its whole CSI command.
    feed(core, "\u{1b}[31mR\u{1b}[;mD\u{1b}[4294967295CZ\u{1b}[4294967296DQ")
    let first = cells(snapshot(core), 0)
    #expect((first[0]["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 1])
    #expect((first[1]["style"] as? [String: Any])?["foreground"] as? String == "Default")
    #expect(first[7]["text"] as? String == "Z")
    // Overflowing D was ignored, so Q follows the max-valid C movement.
    #expect(cells(snapshot(core), 1)[0]["text"] as? String == "Q")

    let rendition = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(rendition) }
    feed(rendition, "\u{1b}[38:2::255:255:255;4:3;48;5;7mX")
    let style = cells(snapshot(rendition), 0)[0]["style"] as! [String: Any]
    #expect(style["foreground"] as? [String: [Int]] == ["Rgb": [255, 255, 255]])
    #expect(style["background"] as? [String: Int] == ["Indexed": 7])
    #expect(style["underline"] as? Int == 3)

    // Keyboard prefixes and private/intermediate CSI syntax remain byte
    // syntax, rather than becoming Unicode Character classification work.
    feed(core, "\u{1b}[>31u")
    #expect(nativeInput(core, text: "a", key: 200) == Data("\u{1b}[97;1:1u".utf8),
      "explicit absent metadata must omit associated text")
    #expect(input(core, text: "a", key: 200) == Data("\u{1b}[97;1:1;97u".utf8),
      "convenience input must synthesize associated text")
    // Kitty's set-flags command parses its first field before generic CSI
    // filtering. Colons make that field invalid rather than concatenating it.
    feed(core, "\u{1b}[>1:1u")
    #expect(nativeInput(core, text: "a", key: 200) == Data("a".utf8))
    feed(core, "\u{1b}[>31u")
    feed(core, "\u{1b}[>429496729:6u")
    #expect(nativeInput(core, text: "a", key: 200) == Data("a".utf8))
    feed(core, "\u{1b}[?1049hA\u{1b}[?1049l\u{1b}[1\"q猫\u{1b}[?2J")
    let afterPrivate = snapshot(core)
    #expect(afterPrivate["alternate"] as? Bool == false)
    #expect((afterPrivate["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }
      .contains { $0["text"] as? String == "猫" })

    // A non-ASCII parameter byte used to be rejected by the UInt32 numeric
    // validation. It must not become a defaulted cursor-down command.
    let malformed = helge_terminal_create(4, 2)!
    defer { helge_terminal_destroy(malformed) }
    feed(malformed, "X")
    feed(malformed, bytes: Data([0x1b, 0x5b, 0xb2, 0x42]), partitions: [4])
    feed(malformed, "Y")
    #expect(cells(snapshot(malformed), 0)[0]["text"] as? String == "X")
    #expect(cells(snapshot(malformed), 0)[1]["text"] as? String == "Y")
    #expect(cells(snapshot(malformed), 1).allSatisfy { ($0["text"] as? String)?.isEmpty == true })

    // Individual digit runs fit UInt32 here, but the old flattened value was
    // Int.max and could overflow cursor arithmetic. It is one invalid CSI.
    let concatenated = helge_terminal_create(4, 2)!
    defer { helge_terminal_destroy(concatenated) }
    feed(concatenated, "X\u{1b}[922337203:6:854775807CY")
    #expect(cells(snapshot(concatenated), 0)[0]["text"] as? String == "X")
    #expect(cells(snapshot(concatenated), 0)[1]["text"] as? String == "Y")

    // `>` belongs to the keyboard `u` commands and secondary device
    // attributes. Before any other final byte it names a command this terminal
    // does not have, so the cursor stays where it is.
    let prefixedMotion = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(prefixedMotion) }
    feed(prefixedMotion, "X\u{1b}[>31CY")
    #expect(cells(snapshot(prefixedMotion), 0)[1]["text"] as? String == "Y")
  }
  @Test static func sgrCompatibility() {
    // Check the normal immutable publication and the legacy ABI alike.
    func style(_ foreground: UInt32 = 0, _ background: UInt32 = 0,
               _ underlineColor: UInt32 = 0, bold: Bool = false,
               conceal: Bool = false, blink: Bool = false, underline: Int = 0) -> CellStyle {
      CellStyle(foreground: TerminalColor(packed: foreground), background: TerminalColor(packed: background),
        underline_color: TerminalColor(packed: underlineColor), underline: underline,
        bold: bold, faint: false, italic: false, inverse: false, conceal: conceal,
        strike: false, overline: false, blink: blink)
    }
    var fixtures: [(String, String, [CellStyle])] = [
      ("empty parameter resets before colon color", "\u{1b}[31;44;1mA\u{1b}[;38:2::10:20:30mB",
        [style(0x0100_0001, 0x0100_0004, bold: true), style(0x020a_141e)]),
      ("SGR 28 reveals", "\u{1b}[8mA\u{1b}[28mB", [style(conceal: true), style()]),
      ("SGR 6 blinks", "\u{1b}[6mA\u{1b}[25mB", [style(blink: true), style()]),
      ("SGR 21 double underline", "\u{1b}[21mA\u{1b}[24mB", [style(underline: 2), style()]),
      ("incomplete colon RGB ignored", "\u{1b}[31mA\u{1b}[38:2:1:2mB", [style(0x0100_0001), style(0x0100_0001)]),
      ("colon RGB takes its three channels", "\u{1b}[38:2::1:2:3:99mA", [style(0x0201_0203)]),
      // xterm's key-modifier options end in `m` too, behind a private marker.
      ("modifyOtherKeys is not underline and faint", "\u{1b}[>4;2mA", [style()]),
      ("a key-modifier reset keeps the pen", "\u{1b}[31mA\u{1b}[>4mB", [style(0x0100_0001), style(0x0100_0001)]),
      ("private markers and intermediates before m are not SGR",
        "\u{1b}[?4mA\u{1b}[<1mB\u{1b}[=1mC\u{1b}[1 mD", [style(), style(), style(), style()]),
    ]
    // A private marker or an intermediate byte names another command. Those
    // this terminal lacks leave the screen, cursor, margins and replies alone.
    do {
      let prepared = "one\r\ntwo\r\nthree\r\nfour\u{1b}[2;3H"
      func observed(_ sequence: String) -> (rows: [String], replies: String) {
        let terminal = helge_terminal_create(12, 4)!
        defer { helge_terminal_destroy(terminal) }
        feed(terminal, prepared + sequence + "Z")
        let reply = String(decoding: replies(terminal), as: UTF8.self)
        guard let snapshot = swiftTerminalSnapshot(terminal, scroll: 0, now: 0).snapshot else {
          Issue.record("missing snapshot for \(sequence.debugDescription)"); return ([], reply)
        }
        return (snapshot.rows.map { $0.cells.map(\.text).joined() }, reply)
      }
      let untouched = observed("")
      let foreign = [
        "\u{1b}[?1;1;0S", "\u{1b}[?1000r", "\u{1b}[#P", "\u{1b}[>1T", "\u{1b}[2 A", "\u{1b}[1;2$r",
        "\u{1b}[>0q", "\u{1b}[=c", "\u{1b}[>2A", "\u{1b}[?3@", "\u{1b}[<2L", "\u{1b}[1?J", "\u{1b}[!\"p",
      ]
      for sequence in foreign {
        let result = observed(sequence)
        #expect(result.rows == untouched.rows && result.replies.isEmpty,
                     "foreign CSI acted: \(sequence.debugDescription)")
      }
      // An ignored command does not touch a pending wrap either: the next
      // character still starts the next line.
      let wrapping = helge_terminal_create(4, 2)!
      defer { helge_terminal_destroy(wrapping) }
      feed(wrapping, "abcd\u{1b}[>0qe")
      #expect(cells(snapshot(wrapping), 0)[3]["text"] as? String == "d", "last column kept")
      #expect(cells(snapshot(wrapping), 1)[0]["text"] as? String == "e", "wrap still pending")
      // The commands that share those final bytes still work.
      #expect(observed("\u{1b}[S").rows != untouched.rows, "CSI S scrolls")
      #expect(observed("\u{1b}[?J").rows != untouched.rows, "DECSED erases")
      #expect(observed("\u{1b}[c").replies == "\u{1b}[?62;22c", "primary device attributes")
      #expect(observed("\u{1b}[>c").replies == "\u{1b}[>1;10;0c", "secondary device attributes")
      #expect(observed("\u{1b}[?u").replies == "\u{1b}[?0u", "keyboard flags query")
      #expect(observed("\u{1b}[?69$p").replies == "\u{1b}[?69;2$y", "DECRQM for a private mode")
    }
    for command in [38, 48, 58] {
      for invalid in [256, 4_294_967_295] {
        for parameter in ["\(command);5;\(invalid)", "\(command):5:\(invalid)",
                          "\(command);2;\(invalid);1;2", "\(command):2::1:\(invalid):2"] {
          fixtures.append(("invalid extended color \(parameter)",
            "\u{1b}[31;44;58;5;2mA\u{1b}[\(parameter);1mB",
            [style(0x0100_0001, 0x0100_0004, 0x0100_0002),
             style(0x0100_0001, 0x0100_0004, 0x0100_0002, bold: true)]))
        }
      }
      let indexed = style(command == 38 ? 0x0100_00ff : 0,
                          command == 48 ? 0x0100_00ff : 0, command == 58 ? 0x0100_00ff : 0)
      let rgb = style(command == 38 ? 0x02ff_00ff : 0,
                      command == 48 ? 0x02ff_00ff : 0, command == 58 ? 0x02ff_00ff : 0)
      fixtures.append(("valid channel boundary \(command)",
        "\u{1b}[\(command);5;255mA\u{1b}[\(command);2;255;0;255mB\u{1b}[\(command):5:255mC\u{1b}[\(command):2::255:0:255mD",
        [indexed, rgb, indexed, rgb]))
    }
    for (name, wire, expected) in fixtures {
      let terminal = helge_terminal_create(32, 2)!
      defer { helge_terminal_destroy(terminal) }
      feed(terminal, wire)
      guard let direct = swiftTerminalSnapshot(terminal, scroll: 0, now: 0).snapshot else {
        Issue.record("missing direct SGR snapshot: \(name)"); return
      }
      let json = try! JSONSerialization.data(withJSONObject: legacySnapshot(terminal, scroll: 0)["rows"]!)
      let legacy = try! JSONDecoder().decode([RowSnapshot].self, from: json)
      #expect(direct.rows == legacy, "direct/legacy SGR snapshot mismatch: \(name)")
      let actual = direct.rows.flatMap(\.cells).filter { !$0.text.isEmpty }.map(\.style)
      #expect(actual == expected, "SGR style mismatch: \(name)")
    }
  }
  @Test static func csiScratchReuseEquivalence() {
    let grown = Array(repeating: "1", count: 256).joined(separator: ";")
    let text = "\u{1b}[" + grown + "mA" +
      "\u{1b}[1;2;4294967296;3mB" + // invalid after partial scratch values
      "\u{1b}[2;4H\u{1b}[32mC" +
      "\u{1b}[38:2::255:1:2;48;5;7;4:3mD" +
      "\u{1b}[0mE\u{1b}[5n"
    let payload = Data(text.utf8)
    let whole = helge_terminal_create(8, 3)!, bytewise = helge_terminal_create(8, 3)!, irregular = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(whole); helge_terminal_destroy(bytewise); helge_terminal_destroy(irregular) }
    feed(whole, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [5, 63, 2, 127, 17, 3, 71])
    let expected = stableSnapshot(whole)
    #expect(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)
    let first = cells(snapshot(whole), 0)[0]
    #expect(first["text"] as? String == "A")
    #expect((first["style"] as? [String: Any])?["bold"] as? Bool == true)
    let second = cells(snapshot(whole), 0)[1]
    #expect(second["text"] as? String == "B")
    #expect((second["style"] as? [String: Any])?["bold"] as? Bool == true)
    let styled = cells(snapshot(whole), 1)
    #expect(styled[3]["text"] as? String == "C")
    #expect((styled[3]["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 2])
    #expect(styled[4]["text"] as? String == "D")
    let rich = styled[4]["style"] as! [String: Any]
    #expect(rich["foreground"] as? [String: [Int]] == ["Rgb": [255, 1, 2]])
    #expect(rich["background"] as? [String: Int] == ["Indexed": 7])
    #expect(rich["underline"] as? Int == 3)
    #expect(styled[5]["text"] as? String == "E")
    #expect((styled[5]["style"] as? [String: Any])?["foreground"] as? String == "Default")
    let expectedReplies = replies(whole)
    #expect(replies(bytewise) == expectedReplies && replies(irregular) == expectedReplies)
  }
  @Test static func carriageReturnEquivalence() {
    let text = "\u{1b}[?69h\u{1b}[3;6s\u{1b}[4GQ\rR\r\nS" +
      "\u{1b}[3;1He\u{301}\rZ\u{1b}(0q\u{1b}(B\rT"
    let payload = Data(text.utf8)
    let whole = helge_terminal_create(8, 3)!, bytewise = helge_terminal_create(8, 3)!, irregular = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(whole); helge_terminal_destroy(bytewise); helge_terminal_destroy(irregular) }
    feed(whole, bytes: payload, partitions: [payload.count])
    feed(bytewise, bytes: payload, partitions: Array(repeating: 1, count: payload.count))
    feed(irregular, bytes: payload, partitions: [1, 4, 2, 7, 3, 11, 5, 19])
    let expected = stableSnapshot(whole)
    #expect(stableSnapshot(bytewise) == expected && stableSnapshot(irregular) == expected)
    let rows = snapshot(whole)["rows"] as! [[String: Any]]
    let first = rows[0]["cells"] as! [[String: Any]]
    let second = rows[1]["cells"] as! [[String: Any]]
    #expect(first[2]["text"] as? String == "R")
    #expect(second[2]["text"] as? String == "S")
    let third = rows[2]["cells"] as! [[String: Any]]
    #expect(third[0]["text"] as? String == "Z")
    #expect(third[1]["text"] as? String == "─")
    #expect(third[2]["text"] as? String == "T")
  }
  @Test static func searchABI() {
    func create(_ core: OpaquePointer, _ query: String) -> OpaquePointer? {
      let bytes = Array(query.utf8)
      return bytes.withUnsafeBufferPointer { helge_terminal_search_create(core, $0.baseAddress, $0.count) }
    }
    func runTask(_ core: OpaquePointer, _ task: OpaquePointer) -> UInt32 {
      for _ in 0..<10_000 {
        switch helge_terminal_search_fill(core, task) {
        case 0:
          #expect([UInt32(0), 1, 2].contains(helge_terminal_search_step(task)))
        case 2: return helge_terminal_search_accept(core, task)
        case 3, 4: return helge_terminal_search_fill(core, task)
        default: Issue.record("unexpected search status"); return UInt32.max
        }
      }
      Issue.record("search did not finish"); return UInt32.max
    }
    func run(_ core: OpaquePointer, _ query: String) -> UInt32 {
      guard let task = create(core, query) else { return UInt32.max }
      defer { helge_terminal_search_destroy(task) }
      return runTask(core, task)
    }

    let soft = helge_terminal_create(4, 3)!
    defer { helge_terminal_destroy(soft) }
    feed(soft, "abcdEFGH\r\nnext  ")
    #expect(run(soft, "dEf") == 5)
    #expect((snapshot(soft)["search"] as! [[String: Int]]).count == 2)
    #expect(run(soft, "GHnext") == 2)
    #expect(run(soft, "GH\nnext") == 5)
    #expect(run(soft, "next  ") == 5)
    #expect(run(soft, "\n") == 5) // A zero-width hard-break proof still navigates.

    let history = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(history) }
    feed(history, "target\r\nsecond\r\nTARGET\r\nlater\r\nlast")
    #expect(run(history, "target") == 5)
    // The newest match is selected and centered, clear of a bar docked over
    // the first rows; the older match is published as a secondary highlight.
    let anchored = snapshot(history)
    #expect(anchored["scroll_offset"] as? Int == 2)
    #expect((anchored["search"] as! [[String: Int]]) == [["row": 1, "start": 0, "end": 6]])
    #expect((anchored["search_matches"] as! [[String: Int]]).isEmpty)
    #expect((binaryHeader(history, scroll: 0)["search"] as! [[String: Int]]).isEmpty)
    func position(_ core: OpaquePointer) -> [UInt32]? {
      var index: UInt32 = 0, total: UInt32 = 0, capped = true
      guard helge_terminal_search_position(core, &index, &total, &capped), !capped else { return nil }
      return [index, total]
    }
    func navigate(_ core: OpaquePointer, older: Bool) -> [UInt32]? {
      var index: UInt32 = 0, total: UInt32 = 0, capped = true
      guard helge_terminal_search_navigate(core, older, &index, &total, &capped), !capped else { return nil }
      return [index, total]
    }
    #expect(position(history) == [1, 2])
    #expect(navigate(history, older: true) == [2, 2])
    let older = snapshot(history)
    #expect(older["scroll_offset"] as? Int == 3)
    #expect((older["search"] as! [[String: Int]]) == [["row": 0, "start": 0, "end": 6]])
    let both = binaryHeader(history, scroll: 2)
    #expect((both["search"] as! [[String: Int]]).isEmpty)
    #expect((both["search_matches"] as! [[String: Int]]) == [["row": 1, "start": 0, "end": 6]])
    // Navigation wraps in both directions.
    #expect(navigate(history, older: true) == [1, 2])
    #expect(navigate(history, older: false) == [2, 2])
    #expect(navigate(history, older: false) == [1, 2])
    helge_terminal_search_clear(history)
    #expect(position(history) == nil && navigate(history, older: true) == nil)
    #expect((snapshot(history)["search"] as! [[String: Int]]).isEmpty)

    // Several matches on one row: one navigated, the others secondary.
    let sameRow = helge_terminal_create(12, 2)!
    defer { helge_terminal_destroy(sameRow) }
    feed(sameRow, "ab ab ab")
    #expect(run(sameRow, "ab") == 5 && position(sameRow) == [1, 3])
    #expect((snapshot(sameRow)["search"] as! [[String: Int]]) == [["row": 0, "start": 6, "end": 8]])
    #expect((snapshot(sameRow)["search_matches"] as! [[String: Int]]).count == 2)
    // A rewritten row drops its matches; navigation then reports none left.
    feed(sameRow, "\rX")
    #expect((snapshot(sameRow)["search_matches"] as! [[String: Int]]).isEmpty)
    #expect(navigate(sameRow, older: true) == nil && position(sameRow) == nil)

    // Navigation skips a match whose row changed and lands on a live one.
    let skipping = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(skipping) }
    feed(skipping, "hit\r\nhit\r\nhit")
    #expect(run(skipping, "hit") == 5 && position(skipping) == [1, 3])
    feed(skipping, "\u{1b}[2;1HX")
    #expect(navigate(skipping, older: true) == [3, 3])

    let alternate = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(alternate) }
    feed(alternate, "needle")
    feed(alternate, "\u{1b}[?1049hALT")
    #expect(run(alternate, "needle") == 2)
    #expect(run(alternate, "alt") == 5)

    let unicode = helge_terminal_create(5, 3)!
    defer { helge_terminal_destroy(unicode) }
    feed(unicode, "Ée\u{301}猫👩🏽‍💻")
    #expect(run(unicode, "éE\u{301}猫") == 5)
    #expect(run(unicode, "猫👩🏽‍💻") == 5)
    #expect((snapshot(unicode)["search"] as! [[String: Int]]).count == 2) // Wrap spacer excluded.
    #expect(run(unicode, "👩") == 5)
    #expect((snapshot(unicode)["search"] as! [[String: Int]]).contains {
      $0["end", default: 0] - $0["start", default: 0] == 2
    })

    // Accepted decorations retain their complete row proofs: unrelated output
    // leaves them visible, while a changed matched row silently drops them.
    let decoration = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(decoration) }
    feed(decoration, "target\r\nmiddle\r\nlater")
    #expect(run(decoration, "target") == 5)
    #expect(!(snapshot(decoration)["search"] as! [[String: Int]]).isEmpty)
    feed(decoration, "\u{1b}[3;1Hother")
    #expect(!(snapshot(decoration)["search"] as! [[String: Int]]).isEmpty)
    feed(decoration, "\u{1b}[1;1HX")
    #expect((snapshot(decoration)["search"] as! [[String: Int]]).isEmpty)

    // A task captures its final row identity at creation. Later output is not
    // chased, while a changed matched row is still rejected by row proof.
    let future = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(future) }
    feed(future, "first\r\nend")
    guard let futureTask = create(future, "future") else { Issue.record("future task"); return }
    defer { helge_terminal_search_destroy(futureTask) }
    feed(future, "\r\nfuture")
    #expect(runTask(future, futureTask) == 2)

    let staleCore = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(staleCore) }
    feed(staleCore, "target")
    guard let stale = create(staleCore, "target") else { Issue.record("search create"); return }
    defer { helge_terminal_search_destroy(stale) }
    // Fill lends an immutable old row; overwriting that row before its worker
    // step must be rejected by proof at owner acceptance, not mis-highlighted.
    #expect(helge_terminal_search_fill(staleCore, stale) == 0)
    feed(staleCore, "\rX")
    #expect([UInt32(0), 1, 2].contains(helge_terminal_search_step(stale)))
    #expect(runTask(staleCore, stale) == 3)

    let transition = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(transition) }
    feed(transition, "target")
    guard let transitionTask = create(transition, "target") else { Issue.record("transition task"); return }
    defer { helge_terminal_search_destroy(transitionTask) }
    #expect(helge_terminal_search_fill(transition, transitionTask) == 0)
    feed(transition, "\u{1b}[?1049hALT\u{1b}[?1049l")
    _ = helge_terminal_search_step(transitionTask)
    #expect(runTask(transition, transitionTask) == 3)

    let cleared = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(cleared) }
    feed(cleared, "target")
    guard let clearTask = create(cleared, "target") else { Issue.record("clear task"); return }
    defer { helge_terminal_search_destroy(clearTask) }
    #expect(helge_terminal_search_fill(cleared, clearTask) == 0)
    _ = helge_terminal_clear_display(cleared)
    _ = helge_terminal_search_step(clearTask)
    #expect(runTask(cleared, clearTask) == 3)

    let resized = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(resized) }
    feed(resized, "target")
    guard let resizedTask = create(resized, "target") else { Issue.record("resize task"); return }
    defer { helge_terminal_search_destroy(resizedTask) }
    #expect(helge_terminal_resize(resized, 9, 2))
    #expect(helge_terminal_search_fill(resized, resizedTask) == 3)

    let pendingResize = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(pendingResize) }
    feed(pendingResize, "target")
    guard let pendingResizeTask = create(pendingResize, "target") else { Issue.record("pending resize task"); return }
    defer { helge_terminal_search_destroy(pendingResizeTask) }
    #expect(helge_terminal_resize(pendingResize, 9, 2))
    #expect(helge_terminal_search_accept(pendingResize, pendingResizeTask) == 3)

    let evicted = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(evicted) }
    feed(evicted, "target\r\none\r\ntwo")
    guard let evictedTask = create(evicted, "target") else { Issue.record("eviction task"); return }
    defer { helge_terminal_search_destroy(evictedTask) }
    helge_terminal_set_history_limit(evicted, 0)
    #expect(helge_terminal_search_fill(evicted, evictedTask) == 3)

    // Raising or reapplying a scrollback limit without evicting a proven row
    // does not change the search stamp. The task remains acceptable.
    let unchangedLimit = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(unchangedLimit) }
    feed(unchangedLimit, "target")
    guard let unchangedLimitTask = create(unchangedLimit, "target") else { Issue.record("limit task"); return }
    defer { helge_terminal_search_destroy(unchangedLimitTask) }
    helge_terminal_set_history_limit(unchangedLimit, 10_000)
    #expect(runTask(unchangedLimit, unchangedLimitTask) == 5)

    // A captured final row does not chase later output, but if later output
    // makes it soft-wrap it still keeps that successor in its proof.
    let extendedStop = helge_terminal_create(4, 2)!
    defer { helge_terminal_destroy(extendedStop) }
    feed(extendedStop, "aaaaBBBB")
    guard let extendedStopTask = create(extendedStop, "BBBB") else { Issue.record("stop task"); return }
    defer { helge_terminal_search_destroy(extendedStopTask) }
    feed(extendedStop, "C")
    #expect(runTask(extendedStop, extendedStopTask) == 5)

    // RIS restarts document row IDs; the dedicated generation prevents an ABA
    // match when a fresh terminal prints identical text into the same grid.
    let reset = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(reset) }
    feed(reset, "same")
    guard let resetTask = create(reset, "same") else { Issue.record("reset task"); return }
    defer { helge_terminal_search_destroy(resetTask) }
    #expect(helge_terminal_search_fill(reset, resetTask) == 0)
    feed(reset, "\u{1b}csame")
    _ = helge_terminal_search_step(resetTask)
    #expect(runTask(reset, resetTask) == 3)
    let tooLong = [UInt8](repeating: 120, count: 4_097)
    #expect(tooLong.withUnsafeBufferPointer { helge_terminal_search_create(soft, $0.baseAddress, $0.count) } == nil)

    let overlaps = helge_terminal_create(4_096, 2)!
    defer { helge_terminal_destroy(overlaps) }
    feed(overlaps, String(repeating: "a", count: 4_096))
    #expect(run(overlaps, String(repeating: "a", count: 2_048)) == 5)
    #expect((snapshot(overlaps)["search"] as! [[String: Int]]) == [
      ["row": 0, "start": 2_048, "end": 4_096]
    ])

    let detached = helge_terminal_create(80, 2)!
    feed(detached, String(repeating: "x", count: 80))
    guard let workerOnly = create(detached, "x") else { Issue.record("worker task"); return }
    #expect(helge_terminal_search_fill(detached, workerOnly) == 0)
    helge_terminal_destroy(detached)
    #expect([UInt32(0), 1, 2].contains(helge_terminal_search_step(workerOnly)))
    helge_terminal_search_destroy(workerOnly)
  }
  @Test static func binarySnapshotOffsetsRemainIndependentOfOwnerViewport() {
    let core = helge_terminal_create(4, 2)!
    defer { helge_terminal_destroy(core) }
    feed(core, "A\r\nB\r\nC")
    #expect(binaryHeader(core, scroll: 1)["scroll_offset"] as? Int == 1)
    helge_terminal_view_scroll(core, 1)
    #expect(viewHeader(core)["following_tail"] as? Bool == false)
    #expect(binaryHeader(core, scroll: 0)["following_tail"] as? Bool == true)
    #expect(helge_terminal_resize(core, 4, 3)) // The anchor moves into the live grid.
    #expect(viewHeader(core)["scroll_offset"] as? Int == 0)
    #expect(viewHeader(core)["following_tail"] as? Bool == false)
    #expect(binaryHeader(core, scroll: 0)["following_tail"] as? Bool == true)
  }
  @Test static func legacySnapshotHonorsExplicitNumericScroll() {
    let core = helge_terminal_create(8, 3)!
    defer { helge_terminal_destroy(core) }
    feed(core, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive")

    let tail = legacySnapshot(core, scroll: 0)
    let previous = legacySnapshot(core, scroll: 1)
    let oldest = legacySnapshot(core, scroll: Int.max)
    let historyRows = tail["history_rows"] as! Int
    #expect(historyRows > 1)
    #expect(tail["scroll_offset"] as? Int == 0 && tail["following_tail"] as? Bool == true)
    #expect(previous["scroll_offset"] as? Int == 1 && previous["following_tail"] as? Bool == false)
    #expect(oldest["scroll_offset"] as? Int == historyRows && oldest["following_tail"] as? Bool == false)
    #expect(JSON(tail["cursor"]!) == JSON(previous["cursor"]!))
    #expect(JSON(previous["cursor"]!) == JSON(oldest["cursor"]!))
    for key in ["revision", "document_epoch", "history_epoch", "screen_epoch", "geometry_epoch", "cols", "history_rows"] {
      #expect(tail[key] as? Int == previous[key] as? Int && previous[key] as? Int == oldest[key] as? Int)
    }
    let tailRows = tail["rows"] as! [[String: Any]]
    let previousRows = previous["rows"] as! [[String: Any]]
    let oldestRows = oldest["rows"] as! [[String: Any]]
    #expect((tailRows.last?["id"] as? Int) != (previousRows.last?["id"] as? Int))
    #expect((previousRows.first?["id"] as? Int) != (oldestRows.first?["id"] as? Int))

    let wrapped = helge_terminal_create(4, 2)!
    defer { helge_terminal_destroy(wrapped) }
    feed(wrapped, "abcdefghijkl")
    let wrappedOldest = legacySnapshot(wrapped, scroll: Int.max)
    #expect((wrappedOldest["rows"] as! [[String: Any]]).contains { $0["soft_wrapped"] as? Bool == true })

    helge_terminal_view_scroll(core, 1)
    #expect(helge_terminal_resize(core, 8, 4))
    let owner = snapshot(core)
    let explicitTail = legacySnapshot(core, scroll: 0)
    #expect(owner["scroll_offset"] as? Int == 0 && owner["following_tail"] as? Bool == false)
    #expect(explicitTail["scroll_offset"] as? Int == 0 && explicitTail["following_tail"] as? Bool == true)
    #expect(JSON(owner["rows"]!) == JSON(explicitTail["rows"]!))
  }
  @Test static func defaultHistoryBudgetSurvivesContinuousOutput() {
    let core = helge_terminal_create(4_096, 1)!
    defer { helge_terminal_destroy(core) }
    let limit: UInt64 = 64 * 1_048_576
    let line = Data((String(repeating: "x", count: 4_096) + "\r\n").utf8)
    for _ in 0..<200 {
      #expect(rawFeed(core, line) == line.count)
      #expect(helge_terminal_history_bytes(core) <= limit)
    }
    helge_terminal_view_scroll(core, Int64.max) // Retain the oldest available row.
    let before = viewHeader(core)["viewport_clamp_revision"] as! Int
    for _ in 0..<300 {
      #expect(rawFeed(core, line) == line.count)
      #expect(helge_terminal_history_bytes(core) <= limit)
    }
    let after = viewHeader(core)
    #expect((after["viewport_clamp_revision"] as! Int) > before)
    #expect(after["following_tail"] as? Bool == false)
    #expect((after["history_rows"] as! Int) < 500)
    #expect(helge_terminal_resize(core, 2_048, 2))
    #expect(helge_terminal_history_bytes(core) <= limit)
    #expect(helge_terminal_resize(core, 4_096, 1))
    #expect(helge_terminal_history_bytes(core) <= limit)
    #expect(helge_terminal_validate(core))
  }

  @Test static func geometryABIContract() {
    // Invalid creation geometry returns a null ABI handle; silently
    // clamping here would make a malformed host request look valid.
    let invalid: [(UInt32, UInt32)] = [(0, 1), (1, 0), (4_097, 1), (1, 4_097), (4_096, 257)]
    for (columns, rows) in invalid {
      if let terminal = helge_terminal_create(columns, rows) {
        helge_terminal_destroy(terminal)
        Issue.record("helge_terminal_create accepted invalid geometry \(columns)x\(rows)"); return
      }
    }
    // Exercise the exact maximum once, releasing it before the rejection
    // checks so the ABI contract does not retain a large fixture.
    guard let maximum = helge_terminal_create(4_096, 256) else {
      Issue.record("helge_terminal_create rejected valid maximum geometry"); return
    }
    helge_terminal_destroy(maximum)
    let resized = helge_terminal_create(8, 2)!
    defer { helge_terminal_destroy(resized) }
    for (columns, rows) in invalid {
      #expect(!helge_terminal_resize(resized, columns, rows))
    }
    #expect(viewHeader(resized)["cols"] as? Int == 8)
    // Pixel metrics are validated before applying either geometry or cell
    // dimensions; malformed metrics must not be normalized into a resize.
    let invalidPixels: [(UInt32, UInt32)] = [(0, 16), (16, 0), (1_025, 16), (16, 1_025)]
    for (width, height) in invalidPixels {
      #expect(!helge_terminal_resize_pixels(resized, 8, 2, width, height))
    }
    #expect(viewHeader(resized)["cols"] as? Int == 8)
  }

  /// Feeds `input` to a fresh terminal and returns its text rows, replies and cursor.
  static func observe(_ input: String, columns: UInt32 = 10, rows: UInt32 = 3)
    -> (rows: [String], replies: String, cursor: (row: Int, column: Int)) {
    let terminal = helge_terminal_create(columns, rows)!
    defer { helge_terminal_destroy(terminal) }
    feed(terminal, input)
    let reply = String(decoding: replies(terminal), as: UTF8.self)
    // Synchronized output withholds publication; such inputs check replies only.
    let published = swiftTerminalSnapshot(terminal, scroll: 0, now: 0).snapshot
    let text = (published?.rows ?? []).map { row in
      String(row.cells.map { $0.text.isEmpty ? " " : $0.text }.joined().reversed().drop { $0 == " " }.reversed())
    }
    guard published != nil, let cursor = Self.snapshot(terminal)["cursor"] as? [String: Any] else {
      return (text, reply, (-1, -1))
    }
    return (text, reply, (cursor["row"] as! Int, cursor["col"] as! Int))
  }
  // Mode and position reports must describe the real state, and device
  // attributes must not advertise features the terminal lacks.
  @Test static func deviceReplies() {
    let expected: [(String, String, String)] = [
      ("\u{1b}[c", "\u{1b}[?62;22c", "DA1 without sixel"),
      ("\u{1b}[3;5H\u{1b}[?6n", "\u{1b}[?3;5R", "DECXCPR keeps its marker"),
      ("\u{1b}[3;5H\u{1b}[6n", "\u{1b}[3;5R", "CPR has no marker"),
      ("\u{1b}[?2004$p", "\u{1b}[?2004;2$y", "DECRQM reset private mode"),
      ("\u{1b}[?2004h\u{1b}[?2004$p", "\u{1b}[?2004;1$y", "DECRQM set private mode"),
      ("\u{1b}[?25$p", "\u{1b}[?25;1$y", "DECRQM cursor visible"),
      ("\u{1b}[?7l\u{1b}[?7$p", "\u{1b}[?7;2$y", "DECRQM autowrap off"),
      ("\u{1b}[?1049h\u{1b}[?1049$p", "\u{1b}[?1049;1$y", "DECRQM alternate screen"),
      ("\u{1b}[?1002h\u{1b}[?1000$p\u{1b}[?1002$p", "\u{1b}[?1000;2$y\u{1b}[?1002;1$y", "DECRQM mouse modes"),
      ("\u{1b}[?2026h\u{1b}[?2026$p", "\u{1b}[?2026;1$y", "DECRQM synchronized output"),
      ("\u{1b}[?69$p", "\u{1b}[?69;2$y", "DECRQM left/right margins"),
      ("\u{1b}[?2027$p", "\u{1b}[?2027;3$y", "DECRQM grapheme clustering is permanently set"),
      ("\u{1b}[?2027l\u{1b}[?2027$p", "\u{1b}[?2027;3$y", "DECRQM grapheme clustering cannot be reset"),
      ("\u{1b}[?12345$p", "\u{1b}[?12345;0$y", "DECRQM unknown private mode"),
      ("\u{1b}[4h\u{1b}[4$p", "\u{1b}[4;1$y", "DECRQM ANSI insert mode"),
      ("\u{1b}[20$p", "\u{1b}[20;2$y", "DECRQM ANSI newline mode"),
      ("\u{1b}[3$p", "\u{1b}[3;0$y", "DECRQM unknown ANSI mode"),
    ]
    for (input, reply, label) in expected {
      let actual = observe(input, rows: 4).replies
      #expect(actual == reply, "\(label): got \(actual.debugDescription)")
    }
  }
  // Strings the terminal does not interpret are consumed to ST, and an
  // escape sequence is cancelled, restarted or interleaved with C0 controls
  // as in xterm. None of it may leak onto the screen.
  @Test static func escapeSequenceParsing() {
    let e = "\u{1b}"
    let screens: [(String, [String], String)] = [
      ("a\(e)P1zhello\(e)\\b", ["ab", "", ""], "DCS body is not printed"),
      ("a\(e)P+q544e\(e)\\b", ["ab", "", ""], "XTGETTCAP is not printed"),
      ("a\(e)Pq#0;2;0;0;0~~-\(e)\\b", ["ab", "", ""], "sixel data is not printed"),
      ("a\(e)Ptmux;\(e)\(e)]0;t\u{7}\(e)\\b", ["ab", "", ""], "tmux passthrough is consumed whole"),
      ("a\(e)Xhello\(e)\\b", ["ab", "", ""], "SOS body is not printed"),
      ("a\(e)^hello\(e)\\b", ["ab", "", ""], "PM body is not printed"),
      ("a\(e)Phello\u{18}b", ["ab", "", ""], "CAN ends a DCS"),
      ("a\(e)[1;2\u{18}b", ["ab", "", ""], "CAN cancels a CSI"),
      ("a\(e)[1;2\u{1a}b", ["ab", "", ""], "SUB cancels a CSI"),
      ("a\(e)[1;\(e)[2Cb", ["a  b", "", ""], "ESC restarts a CSI"),
      ("a\(e)[\n2Cb", ["a", "   b", ""], "LF inside a CSI executes"),
      ("ab\(e)[\r3Cc", ["ab c", "", ""], "CR inside a CSI executes"),
      ("\(e)#8", ["EEEE", "EEEE", "EEEE"], "DECALN fills the screen"),
      ("\(e)*Bx\(e)%Gy\(e) Fz", ["xyz", "", ""], "other escape intermediates take their final"),
      ("a\(e)#\u{18}b", ["ab", "", ""], "CAN cancels an escape intermediate"),
    ]
    for (input, rows, label) in screens {
      let columns: UInt32 = input.hasSuffix("#8") ? 4 : 20
      let actual = observe(input, columns: columns, rows: 3).rows
      #expect(actual == rows, "\(label): got \(actual)")
    }
    let aligned = observe("\(e)[2;3r\(e)[1;31m\(e)[3;4H\(e)#8\(e)[6nX", columns: 4, rows: 3)
    #expect(aligned.replies == "\(e)[1;1R" && aligned.rows[0] == "XEEE", "DECALN homes the cursor")
    // Reverse index at row 1 scrolls only when the region reaches the top.
    let margins = observe("\(e)[2;3r\(e)#8\(e)[1;1H\(e)M", columns: 4, rows: 3)
    #expect(margins.rows == ["", "EEEE", "EEEE"], "DECALN resets the scroll region: \(margins.rows)")
  }
  @Test static func swiftCoreSmoke() {
    guard let core = helge_terminal_create(8, 3) else { Issue.record("create"); return }
    defer { helge_terminal_destroy(core) }
    feed(core, "one\ntwo")
    var value = snapshot(core)
    let first = cells(value, 0)
    #expect(first[0]["text"] as? String == "o")
    feed(core, "\u{1b}[31mR\u{1b}[0m")
    value = snapshot(core)
    let second = cells(value, 1)
    let red = second.first { $0["text"] as? String == "R" }
    #expect((red?["style"] as? [String: Any])?["foreground"] as? [String: Int] == ["Indexed": 1])

    // Alternate-screen switching must isolate the primary grid.
    feed(core, "\u{1b}[?1049hALT")
    value = snapshot(core)
    #expect(value["alternate"] as? Bool == true)
    #expect((value["rows"] as! [[String: Any]]).contains {
      ($0["cells"] as! [[String: Any]]).contains { $0["text"] as? String == "A" }
    })
    feed(core, "\u{1b}[?1049l")
    value = snapshot(core)
    #expect(value["alternate"] as? Bool == false)
    #expect(cells(value, 0)[0]["text"] as? String == "o")

    // The C-facing input and reply callbacks are the Session's only wire path.
    #expect(input(core, text: "AUTOMATION_TEXT\n", key: 0) == Data("AUTOMATION_TEXT\n".utf8))
    #expect(input(core, key: 10) == Data("\u{1b}[A".utf8))
    #expect(input(core, text: "x\n\u{1b}y", key: 1) == Data("x\ry".utf8))
    feed(core, "\u{1b}[?2004h")
    #expect(input(core, text: "paste", key: 1) == Data("\u{1b}[200~paste\u{1b}[201~".utf8))
    feed(core, "\u{1b}[5n\u{1b}[6n")
    let response = replies(core)
    #expect(response.starts(with: Data("\u{1b}[0n".utf8)))
    #expect(response.contains(Data("R".utf8)))

    // The parser owns Kitty APC hand-off; snapshots expose only finalized
    // generation-addressable graphics state.
    feed(core, "\u{1b}_Ga=T,i=42,f=32,s=1,v=1;AP8A/w==\u{1b}\\")
    value = snapshot(core)
    let images = value["images"] as! [[String: Any]]
    #expect(images.count == 1 && images[0]["image"] as? Int == 42)

    #expect(helge_terminal_resize(core, 4, 2))
    let euro = Array("€".utf8)
    for byte in euro { var b = byte; _ = helge_terminal_feed(core, &b, 1, 0) }
    value = snapshot(core)
    #expect(value["cols"] as? Int == 4)
    // This is a safety/reentrancy smoke only: semantic maximal-subpart UTF-8
    // equivalence remains a documented parity gap.
  }
}

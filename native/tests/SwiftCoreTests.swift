import Foundation

@main enum SwiftCoreTests {
  private final class Bytes { var value = Data() }
  private static let collect: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int
  ) -> Void = { context, bytes, count in
    guard let context, let bytes, count > 0 else { return }
    Unmanaged<Bytes>.fromOpaque(context).takeUnretainedValue().value.append(bytes, count: count)
  }
  static func snapshot(_ core: OpaquePointer) -> [String: Any] {
    guard let raw = terminal_snapshot(core, Int.max, 0) else { fatalError("missing snapshot") }
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
  static func main() {
    nativeModifierWire()
    decodedBatchEquivalence()
    indexHistoryUsesMutatedPrimaryForViewportClamp()
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

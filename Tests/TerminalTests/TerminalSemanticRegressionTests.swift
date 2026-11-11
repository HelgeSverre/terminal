import Foundation
import Testing
@testable import TerminalApp

// Observable semantics cases that are not already owned by the
// margin, viewport, reflow, prompt/clear, input, or scheduler ABI oracles.
@Suite enum TerminalSemanticRegressionTests {
  private final class Bytes { var value = Data() }
  private static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    guard let context, let bytes, count > 0 else { return }
    Unmanaged<Bytes>.fromOpaque(context).takeUnretainedValue().value.append(bytes, count: count)
  }
  static func make(_ columns: UInt32 = 8, _ rows: UInt32 = 3) -> OpaquePointer { terminal_create(columns, rows)! }
  static func feed(_ terminal: OpaquePointer, _ data: Data, now: UInt64 = 0) {
    var offset = 0
    while offset < data.count || terminal_has_work(terminal) {
      let used: Int = data.withUnsafeBytes { buffer in
        terminal_feed(terminal, offset < data.count ? buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset) : nil, data.count - offset, now)
      }
      #expect(used > 0 || terminal_has_work(terminal) || offset == data.count)
      if used <= 0 && !terminal_has_work(terminal) && offset != data.count { return }
      offset += used
      #expect(terminal_validate(terminal))
    }
  }
  static func feed(_ terminal: OpaquePointer, _ text: String, now: UInt64 = 0) { feed(terminal, Data(text.utf8), now: now) }
  static func snapshot(_ terminal: OpaquePointer, now: UInt64 = 0) -> [String: Any] {
    TerminalSnapshotTestSupport.ownerSnapshot(terminal, now: now)!
  }
  static func line(_ snapshot: [String: Any], _ row: Int) -> String {
    (((snapshot["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]]).map { ($0["text"] as! String).isEmpty ? " " : ($0["text"] as! String) }.joined())
  }
  static func cell(_ snapshot: [String: Any], _ row: Int, _ column: Int) -> [String: Any] {
    ((snapshot["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]])[column]
  }
  static func stable(_ value: Any) -> Any {
    if var object = value as? [String: Any] {
      ["id", "revision", "geometry_epoch", "document_epoch", "history_epoch", "screen_epoch", "viewport_clamp_revision"].forEach { object.removeValue(forKey: $0) }
      for (key, child) in object { object[key] = stable(child) }
      return object
    }
    if let values = value as? [Any] { return values.map(stable) }
    return value
  }
  static func input(_ terminal: OpaquePointer, text: String, key: UInt32, modifiers: UInt32 = 0,
                    event: UInt32 = 0, associated: String? = nil, legacy: String? = nil,
                    shifted: UInt32 = 0, baseLayout: UInt32 = 0) -> Data {
    let capture = Bytes()
    return text.withCString { textPointer in
      (associated ?? "").withCString { associatedPointer in
        (legacy ?? "").withCString { legacyPointer in
          #expect(terminal_input_with_metadata(
            terminal, textPointer, key, modifiers, event,
            associated == nil ? nil : associatedPointer, legacy == nil ? nil : legacyPointer,
            shifted, baseLayout, Unmanaged.passUnretained(capture).toOpaque(), collect))
          return capture.value
        }
      }
    }
  }

  @Test static func deferredWrapLFAndUTF8() {
    for (input, expected, row, column, pending) in [
      ("abcd", "abcd", 0, 3, true), ("abcde", "e", 1, 1, false),
      ("abcd\rZ", "Zbcd", 0, 1, false), ("abcd\u{8}Z", "abZd", 0, 3, false),
      ("abcd\u{1b}[31me", "e", 1, 1, false), ("abcd\u{301}", "abcd\u{301}", 0, 3, true),
    ] {
      let terminal = make(4, 2); defer { terminal_destroy(terminal) }; feed(terminal, input)
      let value = snapshot(terminal), cursor = value["cursor"] as! [String: Any]
      guard line(value, row).contains(expected) else { Issue.record("deferred-wrap \(input.debugDescription): \(line(value, row).debugDescription)"); return }
      #expect(cursor["row"] as! Int == row && cursor["col"] as! Int == column && cursor["pending_wrap"] as! Bool == pending)
    }
    let lf = make(); defer { terminal_destroy(lf) }; feed(lf, "abc\nX"); #expect(line(snapshot(lf), 1).hasPrefix("   X"))
    let c1 = make(20, 2); defer { terminal_destroy(c1) }; feed(c1, "a\u{009b}31mb"); #expect(line(snapshot(c1), 0).hasPrefix("a31mb"))
  }

  @Test static func renditionSaveEraseAndOverflow() {
    let combining = make(); defer { terminal_destroy(combining) }
    feed(combining, "a\u{1b}[31m\u{301}b"); let combined = snapshot(combining)
    #expect(cell(combined, 0, 0)["text"] as? String == "a\u{301}")
    #expect((cell(combined, 0, 0)["style"] as! [String: Any])["foreground"] as? String == "Default")
    #expect((cell(combined, 0, 1)["style"] as! [String: Any])["foreground"] as? [String: Int] == ["Indexed": 1])
    let saved = make(4, 2); defer { terminal_destroy(saved) }
    feed(saved, "\u{1b}[31mabcd\u{1b}7\u{1b}[0m\rX\u{1b}8e")
    #expect(line(snapshot(saved), 0).hasPrefix("Xbcd") && (cell(snapshot(saved), 1, 0)["style"] as! [String: Any])["foreground"] as? [String: Int] == ["Indexed": 1])
    for code in ["38;2;12;34;56", "38:2::12:34:56", "38:2:12:34:56"] {
      let colors = make(); defer { terminal_destroy(colors) }
      feed(colors, "\u{1b}[\(code)mX")
      #expect((cell(snapshot(colors), 0, 0)["style"] as! [String: Any])["foreground"] as? [String: [Int]] == ["Rgb": [12, 34, 56]])
    }
    let overflow = make(); defer { terminal_destroy(overflow) }
    feed(overflow, "abc\u{1b}[4294967296DZ"); #expect(line(snapshot(overflow), 0).hasPrefix("abcZ"))
    let protected = make(); defer { terminal_destroy(protected) }
    feed(protected, "\u{1b}[1\"q猫\u{1b}[0\"qabc\u{1b}[?2J"); #expect(line(snapshot(protected), 0).hasPrefix("猫"))
  }

  @Test static func alternateAndStringSafety() {
    let alternate = make(); defer { terminal_destroy(alternate) }
    feed(alternate, "abc\u{1b}[31m\u{1b}[?1049hALT\u{1b}[?1049h!\u{1b}[?1049lZ")
    #expect(line(snapshot(alternate), 0).hasPrefix("abcZ"))
    feed(alternate, "\u{1b}[?1049hA\r\nB\r\nC\u{1b}[?1049l")
    #expect(snapshot(alternate)["history_rows"] as! Int == 0)
    let strings = make(); defer { terminal_destroy(strings) }
    feed(strings, Data("a\u{1b}_foo\u{1b}[2Jbar\u{7}oops\u{1b}\\b".utf8)); #expect(line(snapshot(strings), 0).hasPrefix("ab"))
    feed(strings, Data("\u{1b}]2;bad\u{18}b\u{1b}]2;good\u{1b}\\".utf8)); #expect(snapshot(strings)["title"] as? String == "good")
  }

  @Test static func cursorAppearanceAndClippedWideRepair() {
    let terminal = make(); defer { terminal_destroy(terminal) }
    feed(terminal, "abc\u{1b}7\u{1b}[?25l\u{1b}[5 q\u{1b}8")
    let cursor = snapshot(terminal)["cursor"] as! [String: Any]
    #expect(cursor["visible"] as? Bool == false && cursor["shape"] as? Int == 5)
    let clipped = make(1, 2); defer { terminal_destroy(clipped) }
    feed(clipped, "猫"); #expect(terminal_resize(clipped, 4, 2))
    let repaired = cell(snapshot(clipped), 0, 0)
    #expect(repaired["kind"] as? String == "Lead2" && ((repaired["flags"] as! Int) & 1) == 0)
  }

  @Test static func eraseCharactersAndLineRelativeCursorMotion() {
    // ECH is deliberately checked at the emulator boundary: prompt redraws
    // commonly use it after moving onto a wide glyph, where a text-only test
    // could miss an orphaned continuation cell.
    for sequence in ["\u{1b}[X", "\u{1b}[0X", "\u{1b}[1X"] {
      let terminal = make(8, 2); defer { terminal_destroy(terminal) }
      feed(terminal, "A猫BC\u{1b}[1;2H\(sequence)")
      let value = snapshot(terminal), cursor = value["cursor"] as! [String: Any]
      #expect(cell(value, 0, 0)["text"] as? String == "A")
      #expect(cell(value, 0, 1)["kind"] as? String == "Empty")
      #expect(cell(value, 0, 2)["kind"] as? String == "Empty")
      #expect(cell(value, 0, 3)["text"] as? String == "B")
      #expect(cursor["row"] as? Int == 0 && cursor["col"] as? Int == 1)
    }
    let continuation = make(8, 2); defer { terminal_destroy(continuation) }
    feed(continuation, "A猫BC\u{1b}[1;3H\u{1b}[2X")
    let continuationValue = snapshot(continuation)
    #expect((1...3).allSatisfy { cell(continuationValue, 0, $0)["kind"] as? String == "Empty" })
    #expect(cell(continuationValue, 0, 4)["text"] as? String == "C")
    #expect(terminal_resize(continuation, 10, 2))
    let reflowed = snapshot(continuation)
    #expect((1...3).allSatisfy { cell(reflowed, 0, $0)["kind"] as? String == "Empty" })
    #expect(cell(reflowed, 0, 4)["text"] as? String == "C" && terminal_validate(continuation))

    let clamped = make(8, 2); defer { terminal_destroy(clamped) }
    feed(clamped, "abcdef\u{1b}[1;5H\u{1b}[999X")
    let clampedValue = snapshot(clamped)
    #expect(line(clampedValue, 0).hasPrefix("abcd    "))
    #expect((clampedValue["cursor"] as! [String: Any])["col"] as? Int == 4)

    let deferredWrap = make(4, 2); defer { terminal_destroy(deferredWrap) }
    feed(deferredWrap, "abcd\u{1b}[X")
    let deferredValue = snapshot(deferredWrap), deferredCursor = deferredValue["cursor"] as! [String: Any]
    #expect(cell(deferredValue, 0, 3)["kind"] as? String == "Empty")
    #expect(deferredCursor["row"] as? Int == 0 && deferredCursor["col"] as? Int == 3
      && deferredCursor["pending_wrap"] as? Bool == false)

    let styled = make(8, 2); defer { terminal_destroy(styled) }
    feed(styled, "abcdef\u{1b}[1;3H\u{1b}[31;44m\u{1b}[2X")
    let styledValue = snapshot(styled)
    for column in 2...3 {
      let cellStyle = cell(styledValue, 0, column)["style"] as! [String: Any]
      #expect(cell(styledValue, 0, column)["kind"] as? String == "Empty")
      #expect(cellStyle["foreground"] as? String == "Default")
      #expect(cellStyle["background"] as? [String: Int] == ["Indexed": 4])
    }

    // Splitting anywhere in the cursor/edit sequence is equivalent to feeding
    // it whole, including splits between ESC, parameter bytes and the final X.
    let fixture = Data("A猫BC\u{1b}[1;3H\u{1b}[2X".utf8)
    let whole = make(8, 2); defer { terminal_destroy(whole) }; feed(whole, fixture)
    let expected = stable(snapshot(whole)) as! NSDictionary
    for split in 0...fixture.count {
      let terminal = make(8, 2); defer { terminal_destroy(terminal) }
      feed(terminal, Data(fixture.prefix(split))); feed(terminal, Data(fixture.suffix(fixture.count - split)))
      #expect(expected.isEqual(stable(snapshot(terminal))))
    }

    let vertical = make(8, 4); defer { terminal_destroy(vertical) }
    feed(vertical, "\u{1b}[2;5H\u{1b}[E")
    var cursor = snapshot(vertical)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 2 && cursor["col"] as? Int == 0)
    feed(vertical, "\u{1b}[0F")
    cursor = snapshot(vertical)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 0)
    feed(vertical, "\u{1b}[999F")
    cursor = snapshot(vertical)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 0 && cursor["col"] as? Int == 0)

    // CNL/CPL share CUD/CUU's region-aware bounds, then apply CR's margin
    // policy. They must neither scroll nor leap over a scrolling margin when
    // origin mode is disabled.
    let margins = make(8, 5); defer { terminal_destroy(margins) }
    feed(margins, "\u{1b}[2;4r\u{1b}[?69h\u{1b}[3;6s\u{1b}[2;4H\u{1b}[99E")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 3 && cursor["col"] as? Int == 2)
    feed(margins, "\u{1b}[99F")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 2)
    feed(margins, "\u{1b}[?6h\u{1b}[99E")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 3 && cursor["col"] as? Int == 2)
    feed(margins, "\u{1b}[99F")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 2)

    // CUU/CUD use those same bounds without applying CR. Check each direction
    // from both sides of the region while DECOM is disabled.
    feed(margins, "\u{1b}[?6l")
    feed(margins, "\u{1b}[2;4H\u{1b}[99B")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 3 && cursor["col"] as? Int == 3)
    feed(margins, "\u{1b}[99A")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 3)
    feed(margins, "\u{1b}[5;4H\u{1b}[99B")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 4 && cursor["col"] as? Int == 3)
    feed(margins, "\u{1b}[5;4H\u{1b}[99A")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 3)
    feed(margins, "\u{1b}[1;4H\u{1b}[99B")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 3 && cursor["col"] as? Int == 3)
    feed(margins, "\u{1b}[1;4H\u{1b}[99A")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 0 && cursor["col"] as? Int == 3)
    feed(margins, "\u{1b}[?6h\u{1b}[99B")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 3 && cursor["col"] as? Int == 2)
    feed(margins, "\u{1b}[99A")
    cursor = snapshot(margins)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 2)
  }

  @Test static func decCharsetPartitionsAndHistoryBounds() {
    let source = "_`abcdefghijklmnopqrstuvwxyz{|}~"
    let expected = "\u{a0}◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·"
    for designation in ["\u{1b}(0", "\u{1b})0\u{0e}"] {
      let bytes = Data("\(designation)\(source)\u{0f}\u{1b}(B\(source)".utf8)
      for split in [0, 1, bytes.count / 2, bytes.count] {
        let terminal = make(64, 2); defer { terminal_destroy(terminal) }
        feed(terminal, bytes.prefix(split)); feed(terminal, bytes.suffix(bytes.count - split))
        let cells = ((snapshot(terminal)["rows"] as! [[String: Any]])[0]["cells"] as! [[String: Any]])
        #expect(cells[0..<32].map { $0["text"] as! String }.joined() == expected)
        #expect(cells[32..<64].map { $0["text"] as! String }.joined() == source)
      }
    }
    let history = make(4, 2); defer { terminal_destroy(history) }
    terminal_set_history_limit(history, 3); feed(history, "a\r\nb\r\nc\r\nd\r\ne\r\nf")
    #expect(snapshot(history)["history_rows"] as! Int == 3)
    terminal_set_history_byte_limit(history, 1)
    #expect(snapshot(history)["history_rows"] as! Int == 0)
  }

  @Test static func utf8EOFEditingAndResetSemantics() {
    for bytes in [[UInt8](arrayLiteral: 0xe0, 0x80, 0x80), [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xc2, 0x41, 0xf0, 0x9f]] {
      let terminal = make(40, 2); defer { terminal_destroy(terminal) }; feed(terminal, Data(bytes)); terminal_finish(terminal)
      let rendered = line(snapshot(terminal), 0).trimmingCharacters(in: .whitespaces)
      guard rendered == String(decoding: bytes, as: UTF8.self) else { Issue.record("utf8 \(bytes): \(rendered.debugDescription) != \(String(decoding: bytes, as: UTF8.self).debugDescription)"); return }
    }
    for (bytes, expected) in [([UInt8](arrayLiteral: 0xf0, 0x41), "�A"), ([0xe0, 0x80], "��"), ([0xe1, 0x80, 0x41], "�A")] {
      let whole = make(40, 2); defer { terminal_destroy(whole) }; feed(whole, Data(bytes)); terminal_finish(whole)
      let chunked = make(40, 2); defer { terminal_destroy(chunked) }
      for byte in bytes { feed(chunked, Data([byte])) }
      terminal_finish(chunked)
      let wholeText = line(snapshot(whole), 0).trimmingCharacters(in: .whitespaces)
      let chunkedText = line(snapshot(chunked), 0).trimmingCharacters(in: .whitespaces)
      #expect(wholeText == expected && chunkedText == expected)
    }
    let eof = make(); defer { terminal_destroy(eof) }
    feed(eof, "a\u{1b}[12;"); terminal_finish(eof); #expect(line(snapshot(eof), 0).hasPrefix("a"))
    let edit = make(4, 3); defer { terminal_destroy(edit) }
    feed(edit, "abcdef\u{1b}[1;2HZ"); #expect(((snapshot(edit)["rows"] as! [[String: Any]])[0]["soft_wrapped"] as! Bool))
    let reset = make(); defer { terminal_destroy(reset) }
    feed(reset, "\u{1b}[?25l\u{1b}[?1049h\u{1b}[5 q\u{1b}c\u{1b}[?47h")
    let cursor = snapshot(reset)["cursor"] as! [String: Any]
    #expect(cursor["visible"] as? Bool == true && cursor["shape"] as? Int == 0)
  }

  @Test static func displayClusterAndMalformedOSC() {
    let display = make(4, 2); defer { terminal_destroy(display) }
    feed(display, "ab\u{1b}[S\u{301}")
    #expect(cell(snapshot(display), 0, 2)["text"] as? String == "\u{301}")
    let osc = make(); defer { terminal_destroy(osc) }
    feed(osc, "\u{1b}]10;#aéabc\u{1b}\\X"); #expect(line(snapshot(osc), 0).hasPrefix("X"))
    let ed = make(4, 2); defer { terminal_destroy(ed) }
    feed(ed, "a\r\nb\r\nc"); let before = snapshot(ed)["history_rows"] as! Int
    feed(ed, "\u{1b}[2J"); #expect(snapshot(ed)["history_rows"] as! Int == before)
    feed(ed, "\u{1b}[3J"); #expect(snapshot(ed)["history_rows"] as! Int == 0)
    let edge = make(4, 2); defer { terminal_destroy(edge) }
    feed(edge, "abc猫"); #expect(cell(snapshot(edge), 0, 3)["kind"] as? String == "WrapSpacer")
  }

  @Test static func bytePartitionsAgree() {
    let fixtures = [
      "a\u{1b}[38:2::12:34:56m猫👩🏽‍💻e\u{301}\u{1b}]8;;https://example.com\u{1b}\\X\u{1b}]8;;\u{1b}\\\u{1b}[6n",
      "abcd\u{1b}[?1049hhello\u{1b}[?1049h!\u{1b}[?1049lZ",
      "a\u{1b}Pstuff\u{1b}[31mignored\u{1b}\\b\u{1b}_unsupported\u{7}garbage\u{1b}\\c",
      "a\u{1b}P+q544e\u{1b}\\b\u{1b}[1;\u{18}c\u{1b}[\r2Cd\u{1b}^pm\u{1b}\\\u{1b}*Be\u{1b}#8f",
      "\u{1b}]2;title\u{1b}\\abcd\r\n猫猫cat\u{1b}[2;3HX\u{1b}[0J",
    ]
    for fixture in fixtures {
      let bytes = Data(fixture.utf8)
      let baseline = make(8, 4); defer { terminal_destroy(baseline) }; feed(baseline, bytes)
      let expected = stable(snapshot(baseline)) as! NSDictionary
      for split in 0...bytes.count {
        let terminal = make(8, 4); defer { terminal_destroy(terminal) }
        feed(terminal, Data(bytes.prefix(split))); feed(terminal, Data(bytes.suffix(bytes.count - split)))
        #expect(expected.isEqual(stable(snapshot(terminal))))
      }
      let terminal = make(8, 4); defer { terminal_destroy(terminal) }
      for byte in bytes { feed(terminal, Data([byte])) }
      #expect(expected.isEqual(stable(snapshot(terminal))))
    }
  }

  @Test static func clustersAndDiscardBound() {
    for text in ["👩🏽‍💻", "🇳🇴", "e\u{301}", "가", "猫"] {
      let terminal = make(); defer { terminal_destroy(terminal) }; feed(terminal, text)
      #expect(cell(snapshot(terminal), 0, 0)["text"] as? String == text)
    }
    let strings = make(); defer { terminal_destroy(strings) }
    var payload = Data("a\u{1b}]2;".utf8)
    payload.append(Data(repeating: UInt8(ascii: "x"), count: 70_000))
    payload.append(Data("\u{1b}[2J\u{1b}\\b".utf8))
    feed(strings, payload)
    guard line(snapshot(strings), 0).hasPrefix("ab") else { Issue.record("discard \(line(snapshot(strings), 0).debugDescription)"); return }
    let bel = make(); defer { terminal_destroy(bel) }
    var oversizedBEL = Data("a\u{1b}]2;".utf8)
    oversizedBEL.append(Data(repeating: UInt8(ascii: "x"), count: 70_000))
    oversizedBEL.append(Data("\u{7}b".utf8))
    feed(bel, oversizedBEL)
    #expect(line(snapshot(bel), 0).hasPrefix("ab"))
  }

  @Test static func viewportStaysAnchoredWithoutEviction() {
    let terminal = make(4, 2); defer { terminal_destroy(terminal) }
    feed(terminal, "a\r\nb\r\nc\r\nd")
    terminal_view_scroll(terminal, 1)
    feed(terminal, "\r\ne")
    let value = snapshot(terminal)
    #expect(line(value, 0).hasPrefix("b") && line(value, 1).hasPrefix("c"))
  }

  @Test static func cappedGraphemeKeepsIncrementalBoundaryState() {
    let terminal = make(); defer { terminal_destroy(terminal) }
    feed(terminal, "👩" + String(repeating: "\u{301}", count: 100) + "\u{200d}👩X")
    let value = snapshot(terminal)
    #expect(cell(value, 0, 2)["text"] as? String == "X")
    #expect((cell(value, 0, 0)["text"] as! String).unicodeScalars.count == 64)
    #expect(((cell(value, 0, 0)["flags"] as! Int) & 4) != 0)
    let exactCap = make(); defer { terminal_destroy(exactCap) }
    feed(exactCap, "👩" + String(repeating: "\u{301}", count: 62) + "\u{200d}👩X")
    let exact = snapshot(exactCap)
    #expect((cell(exact, 0, 0)["text"] as! String).unicodeScalars.count == 64)
    #expect(((cell(exact, 0, 0)["flags"] as! Int) & 4) != 0 && cell(exact, 0, 2)["text"] as? String == "X")
    let nonEmoji = make(); defer { terminal_destroy(nonEmoji) }
    feed(nonEmoji, "a\u{200d}👩X")
    let separated = snapshot(nonEmoji)
    #expect(cell(separated, 0, 0)["text"] as? String == "a\u{200d}")
    #expect(cell(separated, 0, 1)["kind"] as? String == "Lead2" && cell(separated, 0, 3)["text"] as? String == "X")
  }

  @Test static func physicalKeyMetadataUsesABI() {
    let compatibility = make(); defer { terminal_destroy(compatibility) }
    #expect(input(compatibility, text: "", key: 57_442).isEmpty)
    #expect(input(compatibility, text: "", key: 10, modifiers: 64 | 128) == Data("\u{1b}[A".utf8))

    let enhanced = make(); defer { terminal_destroy(enhanced) }
    feed(enhanced, "\u{1b}[=31u")
    #expect(input(enhanced, text: "с", key: 200, modifiers: 4, associated: "с", baseLayout: 99) == Data("\u{1b}[1089::99;5:1u".utf8))
    #expect(input(enhanced, text: "=", key: 200, modifiers: 1, associated: "+", shifted: 43, baseLayout: 61) == Data("\u{1b}[61:43:61;2:1;43u".utf8))
    #expect(input(enhanced, text: "x", key: 200, associated: "") == Data("\u{1b}[120;1:1u".utf8))
    #expect(input(enhanced, text: "", key: 57_442, modifiers: 4 | 64) == Data("\u{1b}[57442;69:1u".utf8))
    #expect(input(enhanced, text: "", key: 57_442, modifiers: 64, event: 2) == Data("\u{1b}[57442;65:3u".utf8))
    #expect(input(enhanced, text: "", key: 57_358, modifiers: 64) == Data("\u{1b}[57358;65:1u".utf8))

    let legacy = make(); defer { terminal_destroy(legacy) }
    #expect(input(legacy, text: "a", key: 200, modifiers: 1, associated: "A") == Data("A".utf8))
    #expect(input(legacy, text: "1", key: 200, modifiers: 1, associated: "!") == Data("!".utf8))
    #expect(input(legacy, text: "a", key: 200, associated: "æ") == Data("æ".utf8))
    #expect(input(legacy, text: "å", key: 200, modifiers: 64, associated: "Å") == Data("Å".utf8))
    #expect(input(legacy, text: "1", key: 200, modifiers: 1 | 8, associated: "!") == Data("\u{1b}[49;10u".utf8))
    #expect(input(legacy, text: "c", key: 200, modifiers: 4, associated: "ç") == Data([3]))
    #expect(input(legacy, text: "a", key: 200, modifiers: 2, associated: "æ") == Data("\u{1b}a".utf8))
    #expect(input(legacy, text: "1", key: 200, modifiers: 1 | 2, associated: "¡", legacy: "!", shifted: 33) == Data("\u{1b}!".utf8))
    #expect(input(legacy, text: "a", key: 200, modifiers: 2 | 64, associated: "å", legacy: "A") == Data("\u{1b}A".utf8))
  }

  @Test static func cursorRestoreOrphansDefaultIgnorable() {
    let terminal = make(); defer { terminal_destroy(terminal) }
    // CSI u intentionally does not reset Core's cluster boundary. It leaves
    // the segmenter after B while restoring the cursor before A, so FE0F is a
    // continuation with no extendable physical owner. The frozen a19 ABI
    // behavior resets it: the following acute is visible at the restored
    // cursor rather than silently dropped, then X follows it.
    feed(terminal, "\u{1b}[sA\r\nB\u{1b}[u\u{fe0f}\u{301}X")
    let value = snapshot(terminal)
    #expect(cell(value, 0, 0)["text"] as? String == "\u{301}")
    #expect(cell(value, 0, 1)["text"] as? String == "X")
    #expect(cell(value, 1, 0)["text"] as? String == "B")
  }

  @Test static func snapshotsAreImmutableAndIngressIsPartitionIndependent() {
    let immutable = make(); defer { terminal_destroy(immutable) }
    feed(immutable, "abc")
    let before = snapshot(immutable)
    feed(immutable, "\rX")
    #expect(line(before, 0).hasPrefix("abc"))
    #expect(line(snapshot(immutable), 0).hasPrefix("Xbc"))

    for fixture in [
      "abcd\u{1b}[31me fghi\r\n0123456789012345",
      "abc猫e\u{301} xyz\u{1b}[2G!!!\u{1b}[?7lmore than a row\u{1b}[?7hwrap now",
      "\u{600}xyz\u{1b}[4hINSERT\u{1b}[4lfast\u{1b}[?1049hALT\r\ntext\u{1b}[?1049lback",
    ] {
      let bulk = make(4, 3); defer { terminal_destroy(bulk) }; feed(bulk, fixture)
      let scalar = make(4, 3); defer { terminal_destroy(scalar) }
      for character in fixture { feed(scalar, String(character)) }
      #expect((stable(snapshot(bulk)) as! NSDictionary).isEqual(stable(snapshot(scalar))))
    }
  }

  @Test static func randomPartitionsRetainInvariants() {
    var seed: UInt64 = 0x55aa
    var bytes = Data(); bytes.reserveCapacity(20_000)
    for _ in 0..<20_000 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; bytes.append(UInt8(truncatingIfNeeded: seed)) }
    let baseline = make(40, 10); defer { terminal_destroy(baseline) }; feed(baseline, bytes); terminal_finish(baseline)
    let expected = stable(snapshot(baseline)) as! NSDictionary
    let terminal = make(40, 10); defer { terminal_destroy(terminal) }
    for offset in stride(from: 0, to: bytes.count, by: 37) { feed(terminal, Data(bytes[offset..<min(bytes.count, offset + 37)])); #expect(terminal_validate(terminal)) }
    terminal_finish(terminal)
    #expect(expected.isEqual(stable(snapshot(terminal))))
  }

  @Test static func repRetainsOriginalClusterAttributesAfterExtension() {
    let terminal = make(); defer { terminal_destroy(terminal) }
    feed(terminal, "\u{1b}]8;;https://one.example\u{1b}\\\u{1b}[31m\u{1b}[1\"qA\u{1b}[32m\u{301}\u{1b}[2b")
    let value = snapshot(terminal)
    for column in 0...2 {
      let value = cell(value, 0, column)
      #expect(value["text"] as? String == "A\u{301}")
      #expect((value["style"] as! [String: Any])["foreground"] as? [String: Int] == ["Indexed": 1])
      #expect(value["link"] as? String == "https://one.example")
      #expect(((value["flags"] as! Int) & 2) != 0)
    }
  }

}

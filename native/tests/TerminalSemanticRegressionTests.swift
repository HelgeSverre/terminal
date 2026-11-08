import Foundation

// Observable a9b3c98 semantics.rs cases that are not already owned by the
// margin, viewport, reflow, prompt/clear, input, or scheduler ABI oracles.
@main enum TerminalSemanticRegressionTests {
  static func make(_ columns: UInt32 = 8, _ rows: UInt32 = 3) -> OpaquePointer { terminal_create(columns, rows)! }
  static func feed(_ terminal: OpaquePointer, _ data: Data, now: UInt64 = 0) {
    var offset = 0
    while offset < data.count || terminal_has_work(terminal) {
      let used: Int = data.withUnsafeBytes { buffer in
        terminal_feed(terminal, offset < data.count ? buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset) : nil, data.count - offset, now)
      }
      precondition(used > 0 || terminal_has_work(terminal) || offset == data.count)
      offset += used
      precondition(terminal_validate(terminal))
    }
  }
  static func feed(_ terminal: OpaquePointer, _ text: String, now: UInt64 = 0) { feed(terminal, Data(text.utf8), now: now) }
  static func snapshot(_ terminal: OpaquePointer, now: UInt64 = 0) -> [String: Any] {
    let raw = terminal_snapshot(terminal, Int.max, now)!
    defer { terminal_string_free(raw) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as! [String: Any]
  }
  static func line(_ snapshot: [String: Any], _ row: Int) -> String {
    (((snapshot["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]]).map { ($0["text"] as! String).isEmpty ? " " : ($0["text"] as! String) }.joined())
  }
  static func cell(_ snapshot: [String: Any], _ row: Int, _ column: Int) -> [String: Any] {
    ((snapshot["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]])[column]
  }

  static func deferredWrapLFAndUTF8() {
    for (input, expected, row, column, pending) in [
      ("abcd", "abcd", 0, 3, true), ("abcde", "e", 1, 1, false),
      ("abcd\rZ", "Zbcd", 0, 1, false), ("abcd\u{8}Z", "abZd", 0, 3, false),
      ("abcd\u{1b}[31me", "e", 1, 1, false), ("abcd\u{301}", "abcd\u{301}", 0, 3, true),
    ] {
      let terminal = make(4, 2); defer { terminal_destroy(terminal) }; feed(terminal, input)
      let value = snapshot(terminal), cursor = value["cursor"] as! [String: Any]
      guard line(value, row).contains(expected) else { fatalError("deferred-wrap \(input.debugDescription): \(line(value, row).debugDescription)") }
      precondition(cursor["row"] as! Int == row && cursor["col"] as! Int == column && cursor["pending_wrap"] as! Bool == pending)
    }
    let lf = make(); defer { terminal_destroy(lf) }; feed(lf, "abc\nX"); precondition(line(snapshot(lf), 1).hasPrefix("   X"))
    let c1 = make(20, 2); defer { terminal_destroy(c1) }; feed(c1, "a\u{009b}31mb"); precondition(line(snapshot(c1), 0).hasPrefix("a31mb"))
  }

  static func renditionSaveEraseAndOverflow() {
    let combining = make(); defer { terminal_destroy(combining) }
    feed(combining, "a\u{1b}[31m\u{301}b"); let combined = snapshot(combining)
    precondition(cell(combined, 0, 0)["text"] as? String == "a\u{301}")
    precondition((cell(combined, 0, 0)["style"] as! [String: Any])["foreground"] as? String == "Default")
    precondition((cell(combined, 0, 1)["style"] as! [String: Any])["foreground"] as? [String: Int] == ["Indexed": 1])
    let saved = make(4, 2); defer { terminal_destroy(saved) }
    feed(saved, "\u{1b}[31mabcd\u{1b}7\u{1b}[0m\rX\u{1b}8e")
    precondition(line(snapshot(saved), 0).hasPrefix("Xbcd") && (cell(snapshot(saved), 1, 0)["style"] as! [String: Any])["foreground"] as? [String: Int] == ["Indexed": 1])
    let colors = make(); defer { terminal_destroy(colors) }
    for code in ["38;2;12;34;56", "38:2::12:34:56", "38:2:12:34:56"] { feed(colors, "\u{1b}[\(code)mX") }
    precondition((cell(snapshot(colors), 0, 2)["style"] as! [String: Any])["foreground"] as? [String: [Int]] == ["Rgb": [12, 34, 56]])
    let overflow = make(); defer { terminal_destroy(overflow) }
    feed(overflow, "abc\u{1b}[4294967296DZ"); precondition(line(snapshot(overflow), 0).hasPrefix("abcZ"))
    let protected = make(); defer { terminal_destroy(protected) }
    feed(protected, "\u{1b}[1\"q猫\u{1b}[0\"qabc\u{1b}[?2J"); precondition(line(snapshot(protected), 0).hasPrefix("猫"))
  }

  static func alternateAndStringSafety() {
    let alternate = make(); defer { terminal_destroy(alternate) }
    feed(alternate, "abc\u{1b}[31m\u{1b}[?1049hALT\u{1b}[?1049h!\u{1b}[?1049lZ")
    precondition(line(snapshot(alternate), 0).hasPrefix("abcZ"))
    feed(alternate, "\u{1b}[?1049hA\r\nB\r\nC\u{1b}[?1049l")
    precondition(snapshot(alternate)["history_rows"] as! Int == 0)
    let strings = make(); defer { terminal_destroy(strings) }
    feed(strings, Data("a\u{1b}_foo\u{1b}[2Jbar\u{7}oops\u{1b}\\b".utf8)); precondition(line(snapshot(strings), 0).hasPrefix("ab"))
    feed(strings, Data("\u{1b}]2;bad\u{18}b\u{1b}]2;good\u{1b}\\".utf8)); precondition(snapshot(strings)["title"] as? String == "good")
  }

  static func cursorAppearanceAndClippedWideRepair() {
    let terminal = make(); defer { terminal_destroy(terminal) }
    feed(terminal, "abc\u{1b}7\u{1b}[?25l\u{1b}[5 q\u{1b}8")
    let cursor = snapshot(terminal)["cursor"] as! [String: Any]
    precondition(cursor["visible"] as? Bool == false && cursor["shape"] as? Int == 5)
    let clipped = make(1, 2); defer { terminal_destroy(clipped) }
    feed(clipped, "猫"); precondition(terminal_resize(clipped, 4, 2))
    let repaired = cell(snapshot(clipped), 0, 0)
    precondition(repaired["kind"] as? String == "Lead2" && ((repaired["flags"] as! Int) & 1) == 0)
  }

  static func main() {
    deferredWrapLFAndUTF8(); renditionSaveEraseAndOverflow(); alternateAndStringSafety(); cursorAppearanceAndClippedWideRepair()
    print("PASS Terminal semantic regression oracle: wrap, UTF-8, rendition, alternates, strings, cursor, wide repair")
  }
}

import Foundation

// The seven Rust viewport.rs scenarios, executed through the emulator ABI.
@main enum TerminalViewportOracleTests {
  static func make(_ columns: UInt32 = 8, _ rows: UInt32 = 3) -> OpaquePointer { terminal_create(columns, rows)! }
  static func feed(_ terminal: OpaquePointer, _ text: String) { let data = Data(text.utf8); _ = data.withUnsafeBytes { terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress, data.count, 0) } }
  static func snapshot(_ terminal: OpaquePointer) -> [String: Any]? {
    guard let pointer = terminal_snapshot(terminal, Int.max, 0) else { return nil }
    defer { terminal_string_free(pointer) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any]
  }
  static func lines(_ value: [String: Any]) -> [String] {
    (value["rows"] as! [[String: Any]]).map { row in
      (row["cells"] as! [[String: Any]]).map { $0["text"] as! String }.joined().trimmingCharacters(in: .whitespaces)
    }
  }
  static func history() -> OpaquePointer { let t = make(); feed(t, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive"); return t }
  static func scroll(_ terminal: OpaquePointer, _ amount: Int64) { terminal_view_scroll(terminal, amount) }
  static func setLimit(_ terminal: OpaquePointer, _ count: UInt32) { terminal_set_history_limit(terminal, count) }

  static func outputPreservesAnchor() {
    let t = history(); defer { terminal_destroy(t) }; scroll(t, 2)
    let first = snapshot(t)!; precondition(lines(first) == ["one", "two", "three"] && !(first["following_tail"] as! Bool))
    feed(t, "\r\nsix\r\nseven"); let later = snapshot(t)!
    precondition(lines(later) == lines(first)); precondition(later["scroll_offset"] as! Int == (first["scroll_offset"] as! Int) + 2)
    scroll(t, -1); precondition(lines(snapshot(t)!) == ["two", "three", "four"])
    scroll(t, Int64.min); precondition(snapshot(t)! ["following_tail"] as! Bool)
    scroll(t, Int64.max); precondition(snapshot(t)! ["scroll_offset"] as! Int == snapshot(t)! ["history_rows"] as! Int)
  }

  static func evictionClampsOnce() {
    let t = history(); defer { terminal_destroy(t) }; setLimit(t, 3); scroll(t, 3)
    let before = snapshot(t)!; feed(t, "\r\nsix\r\nseven"); let after = snapshot(t)!
    precondition(lines(after) == ["two", "three", "four"] && !(after["following_tail"] as! Bool))
    precondition(after["viewport_clamp_revision"] as! Int == (before["viewport_clamp_revision"] as! Int) + 1)
    precondition(snapshot(t)! ["viewport_clamp_revision"] as! Int == after["viewport_clamp_revision"] as! Int)
    setLimit(t, 0); let empty = snapshot(t)!; precondition(empty["scroll_offset"] as! Int == 0 && !(empty["following_tail"] as! Bool))
    scroll(t, -1); precondition(snapshot(t)! ["following_tail"] as! Bool)
  }

  static func alternateRetainsPrimaryView() {
    let t = history(); defer { terminal_destroy(t) }; scroll(t, 2); let primary = snapshot(t)!
    feed(t, "\u{1b}[?1049hALT"); let alternate = snapshot(t)!
    precondition(alternate["alternate"] as! Bool && alternate["following_tail"] as! Bool && (alternate["screen_epoch"] as! Int) > (primary["screen_epoch"] as! Int))
    scroll(t, 100); terminal_view_follow_tail(t); feed(t, "\u{1b}[?1049l")
    let returned = snapshot(t)!; precondition(lines(returned) == lines(primary) && !(returned["following_tail"] as! Bool))
    let epoch = returned["screen_epoch"] as! Int; feed(t, "\u{1b}[?1049l"); precondition(snapshot(t)! ["screen_epoch"] as! Int == epoch)
  }

  static func richReflowMapsAnchorsAndWideAtoms() {
    let t = make(4, 2); defer { terminal_destroy(t) }; feed(t, "abcdefghijkl\r\n猫猫猫猫\r\nlast")
    // The second history row is efgh, selected through a relative viewport.
    scroll(t, 3); precondition(terminal_resize(t, 8, 2)); let wide = snapshot(t)!
    precondition(lines(wide).first == "abcdefgh" && !(wide["following_tail"] as! Bool))
    precondition(terminal_resize(t, 4, 2)); let back = snapshot(t)!; precondition(lines(back).first == "abcd")
    terminal_view_follow_tail(t)
    // Rust's partition after 4→8→4 is history [abcd, efgh, ijkl, 猫猫]
    // and live [猫猫, last], so offset one selects the retained first cat row.
    scroll(t, 1)
    precondition(lines(snapshot(t)!).first == "猫猫" && !(snapshot(t)! ["following_tail"] as! Bool))
    precondition(terminal_resize(t, 3, 2)); let narrow = snapshot(t)!; precondition(lines(narrow).first == "猫")
  }

  static func heightGrowthAndEpochs() {
    let t = history(); defer { terminal_destroy(t) }; scroll(t, 1); precondition(terminal_resize(t, 8, 6)); let grown = snapshot(t)!
    precondition(grown["scroll_offset"] as! Int == 0 && lines(grown).first == "zero" && !(grown["following_tail"] as! Bool))
    feed(t, "\r\nsix"); let later = snapshot(t)!; precondition(later["scroll_offset"] as! Int == 1 && lines(later).first == "zero")
    let old = later; feed(t, "\u{1b}[3J"); let clear = snapshot(t)!; precondition(clear["history_epoch"] as! Int == (old["history_epoch"] as! Int) + 1 && !(clear["following_tail"] as! Bool))
    feed(t, "\u{1b}]10;#ffffff\u{7}\u{1b}c"); let reset = snapshot(t)!; precondition(reset["following_tail"] as! Bool && (reset["document_epoch"] as! Int) > (old["document_epoch"] as! Int))
  }

  static func publicationGateAndAtomicInvalidResize() {
    let t = history(); defer { terminal_destroy(t) }; scroll(t, 2); let before = snapshot(t)!
    feed(t, "\u{1b}[?2026h\r\nsix"); precondition(snapshot(t) == nil); precondition(!terminal_resize(t, 0, 3))
    feed(t, "\u{1b}[?2026l"); let after = snapshot(t)!
    precondition(lines(after) == lines(before)); precondition(after["geometry_epoch"] as! Int == before["geometry_epoch"] as! Int)
    precondition(after["scroll_offset"] as! Int == (before["scroll_offset"] as! Int) + 1)
  }

  static func main() {
    outputPreservesAnchor(); evictionClampsOnce(); alternateRetainsPrimaryView(); richReflowMapsAnchorsAndWideAtoms(); heightGrowthAndEpochs(); publicationGateAndAtomicInvalidResize()
    print("PASS TerminalDocument viewport oracle: 7 Rust viewport scenarios through Swift emulator")
  }
}

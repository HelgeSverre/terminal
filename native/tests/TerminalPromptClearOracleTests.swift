import Foundation

// Production OSC 133 prompt/reflow and Command-K display-clear cases run via
// the Swift C ABI, not a document helper.
@main enum TerminalPromptClearOracleTests {
  static func make(_ columns: UInt32 = 8, _ rows: UInt32 = 4) -> OpaquePointer { terminal_create(columns, rows)! }
  static func feed(_ terminal: OpaquePointer, _ text: String) {
    let bytes = Data(text.utf8)
    _ = bytes.withUnsafeBytes { terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 0) }
    while terminal_has_work(terminal) { _ = terminal_feed(terminal, nil, 0, 0) }
  }
  static func snapshot(_ terminal: OpaquePointer) -> [String: Any] {
    let pointer = terminal_snapshot(terminal, Int.max, 0)!
    defer { terminal_string_free(pointer) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as! [String: Any]
  }
  static func replies(_ terminal: OpaquePointer) -> Data {
    final class Box { var value = Data() }
    let box = Box()
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().value.append(bytes, count: count)
    }
    terminal_replies(terminal, Unmanaged.passUnretained(box).toOpaque(), callback)
    return box.value
  }
  static func text(_ value: [String: Any]) -> String {
    (value["rows"] as! [[String: Any]]).flatMap { $0["cells"] as! [[String: Any]] }.map { $0["text"] as! String }.joined()
  }
  static func count(_ needle: String, _ value: [String: Any]) -> Int { text(value).components(separatedBy: needle).count - 1 }
  static func cellsEmpty(_ value: [String: Any]) -> Bool { text(value).isEmpty }

  static func promptClearsBeforeShellRedraw() {
    let t = make(64, 12); defer { terminal_destroy(t) }
    feed(t, "\u{1b}]133;A;redraw=1\u{7}RESIZE_PROMPT\r\n> RESIZE_BUFFER\u{1b}[K\u{1b}[46CRESIZE_RPROMPT\u{1b}[60D")
    let wide = "\r\r\u{1b}[A\u{1b}[JRESIZE_PROMPT\r\n> RESIZE_BUFFER\u{1b}[K\u{1b}[80CRESIZE_RPROMPT\u{1b}[94D"
    let narrow = "\r\r\u{1b}[A\u{1b}[JRESIZE_PROMPT\r\n> RESIZE_BUFFER"
    for _ in 0..<5 { precondition(terminal_resize(t, 111, 12)); feed(t, wide); precondition(terminal_resize(t, 17, 12)); feed(t, narrow); precondition(count("RESIZE_PROMPT", snapshot(t)) == 1) }
  }
  static func plainPromptAndPrefixSurvive() {
    let plain = make(16, 5); defer { terminal_destroy(plain) }
    feed(plain, "\u{1b}]133;A\u{7}PROMPT\r\n> BUFFER"); precondition(terminal_resize(plain, 8, 5))
    precondition(text(snapshot(plain)).contains("PROMPT") && text(snapshot(plain)).contains("BUFFER"))
    let styled = make(16, 4); defer { terminal_destroy(styled) }
    feed(styled, "\u{1b}]8;;https://example.test\u{1b}\\\u{1b}[31mKEEP\u{1b}[0m\u{1b}]8;;\u{1b}\\  \u{1b}]133;A;redraw=1\u{7}PROMPT\r\n> BUFFER")
    precondition(terminal_resize(styled, 8, 4)); let value = snapshot(styled)
    let cell = ((value["rows"] as! [[String: Any]])[0]["cells"] as! [[String: Any]])[0]
    precondition(text(value).contains("KEEP  ") && !text(value).contains("PROMPT"))
    precondition((cell["style"] as! [String: Any])["foreground"] as? [String: Int] == ["Indexed": 1])
    precondition(cell["link"] as? String == "https://example.test")
  }
  static func fullWidthAndWidePrefixesSurvive() {
    for (prefix, widths) in [("KEEP", [8, 4, 8]), ("猫猫", [8, 4, 8]), ("LASTCELL", [4, 8])] {
      let t = make(4, 4); defer { terminal_destroy(t) }
      feed(t, "\(prefix)\u{1b}]133;A;redraw=1\u{7}PROMPT")
      for width in widths { precondition(terminal_resize(t, UInt32(width), 4)) }
      precondition(text(snapshot(t)).contains(prefix))
    }
  }
  static func alternatePixelEvictionAndCommandBoundaries() {
    let alternate = make(16, 5); defer { terminal_destroy(alternate) }
    feed(alternate, "\u{1b}]133;A;redraw=1\u{7}PROMPT\r\n> BUFFER\u{1b}[?1049hALT")
    precondition(terminal_resize(alternate, 8, 5)); feed(alternate, "\u{1b}[?1049l"); precondition(text(snapshot(alternate)).contains("PROMPT"))
    let pixel = make(16, 5); defer { terminal_destroy(pixel) }
    feed(pixel, "\u{1b}]133;A;redraw=1\u{7}PROMPT\r\n> BUFFER")
    precondition(terminal_resize_pixels(pixel, 16, 5, 12, 24)); precondition(text(snapshot(pixel)).contains("PROMPT"))
    let evicted = make(8, 4); defer { terminal_destroy(evicted) }
    feed(evicted, "\u{1b}]133;A;redraw=1\u{7}PROMPT\r\nrow one\r\nrow two\r\nrow three")
    precondition(terminal_resize(evicted, 8, 2)); precondition(terminal_resize(evicted, 8, 4))
    // Geometry can retire a redraw anchor; OSC 133 still owns prompt phase.
    precondition(snapshot(evicted)["at_prompt"] as! Bool)
    precondition(!(snapshot(evicted)["input_ready"] as! Bool))
    let command = make(16, 5); defer { terminal_destroy(command) }
    feed(command, "OUTPUT\r\n\u{1b}]133;A;redraw=1\u{7}PROMPT\r\n> BUFFER")
    precondition(terminal_resize(command, 8, 5)); precondition(text(snapshot(command)).contains("OUTPUT") && !text(snapshot(command)).contains("PROMPT"))
    feed(command, "\u{1b}]133;C\u{7}RUNNING"); precondition(terminal_resize(command, 16, 5)); precondition(text(snapshot(command)).contains("RUNNING"))
  }
  static func promptClearPreservesModesAndRebasesAnchor() {
    let t = make(8, 3); defer { terminal_destroy(t) }
    feed(t, "old\r\nold\r\nold\r\n\u{1b}]133;A\u{7}prompt>\u{1b}]133;B\u{7}\u{1b}[?2004h\u{1b}[>3u")
    terminal_view_scroll(t, 1); let before = snapshot(t); precondition(terminal_clear_display(t) == 2); let after = snapshot(t)
    precondition(after["following_tail"] as! Bool && after["at_prompt"] as! Bool && after["history_rows"] as! Int == 0 && cellsEmpty(after))
    let cursor = after["cursor"] as! [String: Any]
    precondition(cursor["row"] as! Int == 0 && cursor["col"] as! Int == 0)
    precondition((before["modes"] as! NSDictionary).isEqual(to: after["modes"] as! NSDictionary))
    precondition(after["document_epoch"] as! Int == before["document_epoch"] as! Int)
    precondition(after["history_epoch"] as! Int == (before["history_epoch"] as! Int) + 1)
    precondition(after["screen_epoch"] as! Int > before["screen_epoch"] as! Int && replies(t).isEmpty)
    let redraw = make(64, 12); defer { terminal_destroy(redraw) }
    feed(redraw, "\u{1b}]133;A;redraw=1\u{7}RESIZE_PROMPT\r\n> RESIZE_BUFFER"); precondition(terminal_clear_display(redraw) == 2)
    precondition(terminal_resize(redraw, 17, 12)); feed(redraw, "\r\r\u{1b}[A\u{1b}[JRESIZE_PROMPT\r\n> RESIZE_BUFFER")
    precondition(count("RESIZE_PROMPT", snapshot(redraw)) == 1)
  }
  static func unmarkedAlternateAndMarkers() {
    let t = make(8, 4); defer { terminal_destroy(t) }
    feed(t, "old\r\ncurrent\r\nbelow\u{1b}[2;4H"); let currentID = ((snapshot(t)["rows"] as! [[String: Any]])[1]["id"] as! Int)
    precondition(terminal_clear_display(t) == 1); let clear = snapshot(t)
    precondition(((clear["rows"] as! [[String: Any]])[0]["id"] as! Int) == currentID && text(clear).contains("current") && text(clear).contains("below"))
    let cursor = clear["cursor"] as! [String: Any]
    precondition(cursor["row"] as! Int == 0 && cursor["col"] as! Int == 3 && replies(t).isEmpty)
    let alternate = make(8, 2); defer { terminal_destroy(alternate) }
    feed(alternate, "old\r\nold\r\nlast\u{1b}]133;A\u{7}"); terminal_view_scroll(alternate, 1); let primary = snapshot(alternate)
    feed(alternate, "\u{1b}[?1049hALT"); let old = snapshot(alternate); precondition(terminal_clear_display(alternate) == 0); precondition(snapshot(alternate) as NSDictionary == old as NSDictionary)
    feed(alternate, "\u{1b}[?1049l"); precondition(snapshot(alternate)["scroll_offset"] as! Int == primary["scroll_offset"] as! Int)
    let markers = make(8, 2); defer { terminal_destroy(markers) }
    for (marker, expected) in [("A", true), ("B", true), ("C", false), ("D;0", false), ("A;k=v", true)] { feed(markers, "\u{1b}]133;\(marker)\u{7}"); precondition(snapshot(markers)["at_prompt"] as! Bool == expected) }
    feed(markers, "\u{1b}c"); precondition(!(snapshot(markers)["at_prompt"] as! Bool))
  }
  static func promptPhasePublishesInputReadiness() {
    let terminal = make(); defer { terminal_destroy(terminal) }
    feed(terminal, "\u{1b}]133;A;redraw=1\u{7}")
    var value = snapshot(terminal)
    precondition(value["at_prompt"] as? Bool == true && value["input_ready"] as? Bool == false)
    feed(terminal, "\u{1b}]133;B\u{7}")
    value = snapshot(terminal)
    precondition(value["at_prompt"] as? Bool == true && value["input_ready"] as? Bool == true)
    for marker in ["C", "D;0"] {
      feed(terminal, "\u{1b}]133;\(marker)\u{7}")
      value = snapshot(terminal)
      precondition(value["at_prompt"] as? Bool == false && value["input_ready"] as? Bool == false)
    }
  }
  static func clearDropsOnlyPrimaryImages() {
    let t = make(8, 3); defer { terminal_destroy(t) }
    feed(t, "\u{1b}_Ga=T,f=24,s=1,v=1,i=1,C=1;AQID\u{1b}\\")
    feed(t, "\u{1b}[?1049h\u{1b}_Ga=T,f=24,s=1,v=1,i=2,C=1;BAUG\u{1b}\\\u{1b}[?1049l")
    precondition(terminal_clear_display(t) == 1)
    precondition((snapshot(t)["images"] as! [[String: Any]]).isEmpty)
    feed(t, "\u{1b}_Ga=p,i=1,C=1\u{1b}\\")
    precondition((snapshot(t)["images"] as! [[String: Any]]).isEmpty)
    feed(t, "\u{1b}[?47h")
    precondition(((snapshot(t)["images"] as! [[String: Any]])[0]["image"] as! Int) == 2)
  }
  static func readinessSurvivesHistoricalPromptAnchor() {
    let terminal = make(8, 3); defer { terminal_destroy(terminal) }
    feed(terminal, "\u{1b}[3;1H\u{1b}]133;A;redraw=1\u{7}one\r\ntwo\r\nthree\r\n\u{1b}]133;B\u{7}")
    let before = snapshot(terminal)
    precondition(before["history_rows"] as! Int > 0)
    precondition(before["at_prompt"] as! Bool && before["input_ready"] as! Bool)
    for (columns, rows) in [(16, 3), (4, 2), (12, 4)] {
      precondition(terminal_resize(terminal, UInt32(columns), UInt32(rows)))
      let resized = snapshot(terminal)
      precondition(resized["at_prompt"] as! Bool && resized["input_ready"] as! Bool)
    }
    feed(terminal, "\u{1b}]133;C\u{7}")
    let executing = snapshot(terminal)
    precondition(!(executing["at_prompt"] as! Bool) && !(executing["input_ready"] as! Bool))
  }
  static func clearActionValuesMatchABI() {
    let terminal = make(); defer { terminal_destroy(terminal) }
    feed(terminal, "running output")
    let document = snapshot(terminal)["document_epoch"] as! Int
    precondition(terminal_clear_display(terminal) == 1) // Cleared, no shell redraw.
    precondition(snapshot(terminal)["document_epoch"] as! Int == document)
    feed(terminal, "\u{1b}]133;A\u{7}prompt\u{1b}]133;B\u{7}")
    precondition(terminal_clear_display(terminal) == 2) // Ask the shell to redraw.
    feed(terminal, "\u{1b}[?1049h")
    precondition(terminal_clear_display(terminal) == 0) // Alternate remains intact.
  }
  static func main() {
    promptClearsBeforeShellRedraw(); plainPromptAndPrefixSurvive(); fullWidthAndWidePrefixesSurvive()
    alternatePixelEvictionAndCommandBoundaries(); promptClearPreservesModesAndRebasesAnchor(); unmarkedAlternateAndMarkers(); promptPhasePublishesInputReadiness(); clearDropsOnlyPrimaryImages()
    readinessSurvivesHistoricalPromptAnchor()
    clearActionValuesMatchABI()
    print("PASS Prompt/reflow and display-clear oracles: phase/readiness survives anchor retirement")
  }
}

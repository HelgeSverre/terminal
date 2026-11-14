import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
import TerminalInterop
@testable import TerminalSession
@testable import TerminalView

// Nine executable margin integration scenarios. These cross the C-shaped emulator seam, not a helper grid: snapshots
// therefore prove that protocol parsing mutates the canonical rich document.
@Suite enum TerminalDocumentOracleTests {
  static func make(_ columns: UInt32 = 8, _ rows: UInt32 = 4) -> OpaquePointer {
    return terminal_create(columns, rows)!
  }
  static func feed(_ terminal: OpaquePointer, _ string: String) {
    let bytes = Data(string.utf8)
    _ = bytes.withUnsafeBytes { terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 0) }
  }
  static func snapshot(_ terminal: OpaquePointer) -> [String: Any] {
    TerminalSnapshotTestSupport.ownerSnapshot(terminal)!
  }
  static func replies(_ terminal: OpaquePointer) -> Data {
    final class Box { var bytes = Data() }
    let box = Box()
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().bytes.append(bytes, count: count)
    }
    terminal_replies(terminal, Unmanaged.passUnretained(box).toOpaque(), callback)
    return box.bytes
  }
  static func line(_ value: [String: Any], _ row: Int) -> String {
    let cells = ((value["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]])
    return cells.map { ($0["text"] as! String).isEmpty ? " " : ($0["text"] as! String) }.joined()
  }
  static func cell(_ value: [String: Any], _ row: Int, _ column: Int) -> [String: Any] {
    ((value["rows"] as! [[String: Any]])[row]["cells"] as! [[String: Any]])[column]
  }
  static func cursor(_ value: [String: Any]) -> [String: Any] { value["cursor"] as! [String: Any] }
  static func seed(_ terminal: OpaquePointer) {
    feed(terminal, "\u{1b}[1;1Hab0000yz\u{1b}[2;1Hcd1111wx\u{1b}[3;1Hef2222uv\u{1b}[4;1Hgh3333st")
  }
  static func expectLines(_ terminal: OpaquePointer, _ expected: [String]) {
    let value = snapshot(terminal)
    #expect(expected.enumerated().allSatisfy { line(value, $0.offset) == $0.element }, "expected \(expected), got \((0..<expected.count).map { line(value, $0) })")
  }

  @Test static func originHomeQueriesAndSaveConflict() {
    let t = make(10, 5); defer { terminal_destroy(t) }
    feed(t, "\u{1b}[?69h\u{1b}[3;8s\u{1b}[2;4r\u{1b}[?6h")
    var value = snapshot(t)
    #expect(value["primary_margins"] as? [Int] == [2, 7])
    #expect(cursor(value)["row"] as? Int == 1 && cursor(value)["col"] as? Int == 2)
    feed(t, "\u{1b}[3;4H\u{1b}7\u{1b}[99B\u{1b}[99C\u{1b}[6n")
    #expect(replies(t) == Data("\u{1b}[3;6R".utf8))
    feed(t, "\u{1b}[8;3s\u{1b}[1;99s")
    #expect(snapshot(t)["primary_margins"] as? [Int] == [2, 7])
    feed(t, "\u{1b}[s\u{1b}8")
    value = snapshot(t)
    #expect(value["primary_margins"] as? [Int] == [0, 9])
    #expect(cursor(value)["row"] as? Int == 3 && cursor(value)["col"] as? Int == 5)
    feed(t, "\u{1b}[?69l\u{1b}[?69$p\u{1b}[2;2H\u{1b}[s\u{1b}[4;4H\u{1b}[u")
    #expect(replies(t) == Data("\u{1b}[?69;2$y".utf8))
    value = snapshot(t); #expect(cursor(value)["row"] as? Int == 1 && cursor(value)["col"] as? Int == 1)
  }

  @Test static func regionalWrapAndMotions() {
    let t = make(); defer { terminal_destroy(t) }; seed(t)
    feed(t, "\u{1b}[?69h\u{1b}[3;6s\u{1b}[?6h12345")
    expectLines(t, ["ab1234yz", "cd5111wx", "ef2222uv", "gh3333st"])
    feed(t, "\u{1b}[1;1H\u{1b}[?7lABCDE")
    var value = snapshot(t)
    #expect(line(value, 0) == "abABCEyz")
    feed(t, "猫")
    value = snapshot(t)
    #expect((cell(value, 0, 5)["flags"] as! Int) & 1 == 1)
    #expect(cell(value, 0, 6)["text"] as? String == "y")
    feed(t, "\u{1b}[?7h\u{1b}[1;4H❤️")
    value = snapshot(t)
    #expect(cell(value, 0, 5)["kind"] as? String == "Empty")
    #expect(cell(value, 1, 2)["kind"] as? String == "Lead2")
    #expect(cell(value, 1, 2)["text"] as? String == "❤️")
    #expect(snapshot(t)["history_rows"] as? Int == 0)
  }

  @Test static func rectangularIndexIdentityAndNoHistory() {
    let t = make(); defer { terminal_destroy(t) }; seed(t)
    let rowIDs = (snapshot(t)["rows"] as! [[String: Any]]).map { $0["id"] as! Int }
    feed(t, "\u{1b}[?69h\u{1b}[3;6s\u{1b}[2;4r\u{1b}[4;3H\n")
    expectLines(t, ["ab0000yz", "cd2222wx", "ef3333uv", "gh    st"])
    #expect((snapshot(t)["rows"] as! [[String: Any]]).map { $0["id"] as! Int } == rowIDs)
    #expect(snapshot(t)["history_rows"] as? Int == 0)
    let before = (0..<4).map { line(snapshot(t), $0) }
    feed(t, "\u{1b}[4;1H\n\u{1b}[2;1H\u{1b}M")
    expectLines(t, before)
    feed(t, "\u{1b}[2;3H\u{1b}M")
    expectLines(t, ["ab0000yz", "cd    wx", "ef2222uv", "gh3333st"])
  }

  @Test static func rectangularInsertDeleteAndEraseBackground() {
    let t = make(); defer { terminal_destroy(t) }; seed(t)
    feed(t, "\u{1b}[?69h\u{1b}[3;6s\u{1b}[2;4r\u{1b}[3;4H\u{1b}[44m\u{1b}[L")
    expectLines(t, ["ab0000yz", "cd1111wx", "ef    uv", "gh2222st"])
    let value = snapshot(t)
    for column in 2..<6 {
      let style = cell(value, 2, column)["style"] as! [String: Any]
      #expect(style["background"] as? [String: Int] == ["Indexed": 4])
    }
    feed(t, "\u{1b}[M"); expectLines(t, ["ab0000yz", "cd1111wx", "ef2222uv", "gh    st"])
  }

  @Test static func horizontalInsertDeleteAndWideEdges() {
    let t = make(8, 3); defer { terminal_destroy(t) }
    feed(t, "ABCDWXYZ\u{1b}[?69h\u{1b}[3;6s\u{1b}[4G\u{1b}[@")
    #expect(line(snapshot(t), 0) == "ABC DWYZ")
    feed(t, "\u{1b}[?69l\u{1b}[1GABCDWXYZ\u{1b}[?69h\u{1b}[3;6s\u{1b}[4G\u{1b}[2P")
    #expect(line(snapshot(t), 0) == "ABCX  YZ")
    feed(t, "\u{1b}[8G!\u{1b}[P")
    #expect(cursor(snapshot(t))["pending_wrap"] as? Bool == true)
    feed(t, "\u{1b}[@")
    #expect(cursor(snapshot(t))["pending_wrap"] as? Bool == false)
    feed(t, "\u{1b}[?69l\u{1b}[2J\u{1b}[2;2H猫\u{1b}[?69h\u{1b}[3;6s\u{1b}[S")
    let repaired = snapshot(t)
    #expect(cell(repaired, 0, 2)["kind"] as? String == "Empty")
    #expect(cell(repaired, 1, 1)["kind"] as? String == "Empty")
  }

  @Test static func richRectangularScroll() {
    let t = make(8, 3); defer { terminal_destroy(t) }
    feed(t, "\u{1b}[2;3H\u{1b}[38;2;10;20;30m\u{1b}[1\"q\u{1b}]8;;https://example.test/\u{1b}\\猫é\u{1b}]8;;\u{1b}\\\u{1b}[0m\u{1b}[?69h\u{1b}[3;7s\u{1b}[S")
    let value = snapshot(t); let cat = cell(value, 0, 2)
    #expect(cat["text"] as? String == "猫")
    #expect(cat["link"] as? String == "https://example.test/")
    #expect(cat["flags"] as? Int == 2)
    #expect((cat["style"] as! [String: Any])["foreground"] as? [String: [Int]] == ["Rgb": [10, 20, 30]])
    #expect(snapshot(t)["history_rows"] as? Int == 0)
  }

  @Test static func screenScopeResetResizeAndMarginDisable() {
    let t = make(8, 3); defer { terminal_destroy(t) }
    feed(t, "\u{1b}[?69h\u{1b}[3;6s\u{1b}[?47h\u{1b}[2;7s\u{1b}[?47l")
    var value = snapshot(t); #expect(value["primary_margins"] as? [Int] == [2, 5]); #expect(value["alternate_margins"] as? [Int] == [1, 6])
    feed(t, "\u{1b}[?69l"); value = snapshot(t); #expect(value["primary_margins"] as? [Int] == [0, 7] && value["alternate_margins"] as? [Int] == [0, 7])
    feed(t, "\u{1b}[?69h\u{1b}[3;6s"); #expect(terminal_resize(t, 9, 4)); value = snapshot(t); #expect(value["primary_margins"] as? [Int] == [0, 8] && value["alternate_margins"] as? [Int] == [0, 8])
    feed(t, "\u{1b}[3;6s\u{1b}[!p"); #expect((value["modes"] as? [String: Any]) != nil)
    value = snapshot(t); #expect((value["modes"] as! [String: Any])["left_right_margins"] as? Bool == false)
  }

  @Test static func chunkingAndRegionalTabs() {
    let fixture = "abcdefgh\u{1b}[2;1Hijklmnop\u{1b}[3;1Hqrstuvwx\u{1b}[?69h\u{1b}[3;6s\u{1b}[?6h12345猫é\u{1b}[1;1H\u{1b}[@Z\u{1b}[2P\u{1b}[S\u{1b}[T\u{1b}[L\u{1b}[M\u{1b}[2;2H\r\n\u{1b}[6n\u{1b}[?69$p"
    let expected = make(); defer { terminal_destroy(expected) }; feed(expected, fixture); let baseline = snapshot(expected)
    for split in 0...fixture.utf8.count {
      let t = make(); defer { terminal_destroy(t) }; let bytes = Array(fixture.utf8)
      bytes[0..<split].withUnsafeBytes { _ = terminal_feed(t, $0.bindMemory(to: UInt8.self).baseAddress, split, 0) }
      bytes[split..<bytes.count].withUnsafeBytes { _ = terminal_feed(t, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count - split, 0) }
      #expect((0..<4).allSatisfy { line(snapshot(t), $0) == line(baseline, $0) })
    }
    let t = make(20, 3); defer { terminal_destroy(t) }; feed(t, "\u{1b}[?69h\u{1b}[5;13s\u{1b}[1;7H\r\u{8}")
    #expect(cursor(snapshot(t))["col"] as? Int == 4); feed(t, "\t\t\u{1b}[2Z"); #expect(cursor(snapshot(t))["col"] as? Int == 4)
  }
}

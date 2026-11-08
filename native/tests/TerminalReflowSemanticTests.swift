import Foundation

@main enum TerminalReflowSemanticTests {
  static func feed(_ t: OpaquePointer, _ text: String) { let d = Data(text.utf8); _ = d.withUnsafeBytes { terminal_feed(t, $0.bindMemory(to: UInt8.self).baseAddress, d.count, 0) } }
  static func snapshot(_ t: OpaquePointer) -> [String: Any] { TerminalSnapshotTestSupport.ownerSnapshot(t)! }
  static func text(_ s: [String: Any]) -> String { (s["rows"] as! [[String: Any]]).map { ($0["cells"] as! [[String: Any]]).map { $0["text"] as! String }.joined() }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
  static func main() {
    let inactive = terminal_create(8, 3)!; defer { terminal_destroy(inactive) }
    feed(inactive, "abcdef\u{1b}7\u{1b}[?1049h猫猫"); precondition(terminal_resize(inactive, 4, 4)); feed(inactive, "\u{1b}[?1049l")
    let cursor = snapshot(inactive)["cursor"] as! [String: Any]
    precondition(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 2)
    let roundtrip = terminal_create(8, 4)!; defer { terminal_destroy(roundtrip) }
    feed(roundtrip, "abcd猫efghij   "); let before = text(snapshot(roundtrip)); precondition(terminal_resize(roundtrip, 4, 8)); precondition(terminal_resize(roundtrip, 8, 4)); let after = text(snapshot(roundtrip))
    precondition(after == before, "reflow roundtrip mismatch: before=\(before.debugDescription) after=\(after.debugDescription)")
    print("PASS TerminalDocument semantic reflow: inactive primary and rich roundtrip")
  }
}

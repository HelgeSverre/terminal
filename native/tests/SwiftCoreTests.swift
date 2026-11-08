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
  static func main() {
    nativeModifierWire()
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

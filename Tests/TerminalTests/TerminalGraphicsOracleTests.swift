import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
import TerminalInterop
@testable import TerminalSession
@testable import TerminalView

// Public ABI regressions for kitty graphics.
// Each case is its own test so a failure cannot hide the remaining red
// controls. No graphics-store inspection or test-only ABI.
@Suite enum TerminalGraphicsOracleTests {
  final class Bytes { var data = Data() }
  static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, count in
    guard let context, let bytes else { return }
    Unmanaged<Bytes>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
  }
  static func feed(_ core: OpaquePointer, _ bytes: Data, now: UInt64 = 0) {
    var offset = 0
    while offset < bytes.count || terminal_has_work(core) {
      let used = bytes.withUnsafeBytes { raw in
        terminal_feed(core, raw.bindMemory(to: UInt8.self).baseAddress?.advanced(by: offset), bytes.count - offset, now)
      }
      guard used > 0 || terminal_has_work(core) || offset == bytes.count else {
        Issue.record("terminal_feed made no progress at offset \(offset)")
        return
      }
      offset += used
    }
    #expect(terminal_validate(core))
  }
  static func feed(_ core: OpaquePointer, _ text: String, now: UInt64 = 0) { feed(core, Data(text.utf8), now: now) }
  static func command(_ header: String, _ pixels: [UInt8] = []) -> String {
    "\u{1b}_G\(header);\(Data(pixels).base64EncodedString())\u{1b}\\"
  }
  static func snapshot(_ core: OpaquePointer, scroll: Int = 0, now: UInt64 = 0) -> [String: Any]? {
    guard let raw = terminal_snapshot(core, scroll, now) else { return nil }
    defer { terminal_string_free(raw) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any]
  }
  static func images(_ core: OpaquePointer, scroll: Int = 0) -> [[String: Any]] { snapshot(core, scroll: scroll)!["images"] as! [[String: Any]] }
  static func replies(_ core: OpaquePointer) -> String {
    let result = Bytes(); terminal_replies(core, Unmanaged.passUnretained(result).toOpaque(), collect)
    return String(decoding: result.data, as: UTF8.self)
  }
  static func rgba(_ core: OpaquePointer, _ image: [String: Any]) -> Data? {
    let result = Bytes()
    guard terminal_image_rgba(core, UInt32(image["image"] as! Int), UInt64(image["generation"] as! Int), Unmanaged.passUnretained(result).toOpaque(), collect) else { return nil }
    return result.data
  }
  static func withTerminal(_ body: (OpaquePointer) -> Void) {
    let core = terminal_create(8, 3)!; defer { terminal_destroy(core) }; body(core)
  }
  @Test static func ignoredPngMetadata() { withTerminal { core in
    // Two compressed 512 KiB ancillary values are ignored before ImageIO.
    let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAACHGlDQ1Bwcm9maWxlAAB4nO3BgQAAAADDIO3h3+AEVQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB8A0xbOEH8vR2gAAACHHpUWHRjb21tZW50AAB4nO3BgQAAAADDIO3h3+AEVQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB8A0xbOEFYkL7mAAAADUlEQVR4nGOoEJFLBgACwAEOotbinwAAAABJRU5ErkJggg=="
    feed(core, command("a=T,f=100,i=1,C=1", Array(Data(base64Encoded: encoded)!)))
    #expect(rgba(core, images(core)[0]) == Data([120, 20, 30, 99]))
  }}
  @Test static func paddedChunks() { withTerminal { core in
    // chafa's shape: a header-only first chunk, padded data chunks that
    // still carry m=1, and an empty m=0 chunk to finish.
    let pixels = Data([1, 2, 3, 4, 5, 6])
    feed(core, "\u{1b}_Ga=T,f=24,s=2,v=1,i=7,C=1,q=2,m=1\u{1b}\\")
    feed(core, "\u{1b}_Gm=1;\(pixels.prefix(4).base64EncodedString())\u{1b}\\")
    feed(core, "\u{1b}_Gm=1;\(pixels.suffix(2).base64EncodedString())\u{1b}\\")
    #expect(images(core).isEmpty)
    feed(core, "\u{1b}_Gm=0\u{1b}\\")
    let image = images(core).first { $0["image"] as? Int == 7 }
    #expect(image.flatMap { rgba(core, $0) } == Data([1, 2, 3, 255, 4, 5, 6, 255]), "padded chunks assemble")
    #expect(replies(core).isEmpty, "q=2 stays quiet")
  }}
  @Test static func axisLimit() { withTerminal { core in
    let encoded = Data(repeating: 42, count: 4_097 * 4).base64EncodedString()
    var remaining = encoded[...]
    var first = true
    while !remaining.isEmpty {
      let chunk = remaining.prefix(4096); remaining = remaining.dropFirst(chunk.count)
      let header = first ? "a=T,f=32,s=4097,v=1,i=1,C=1," : ""
      feed(core, "\u{1b}_G\(header)m=\(remaining.isEmpty ? 0 : 1);\(chunk)\u{1b}\\")
      first = false
    }
    #expect(images(core).isEmpty && replies(core).contains("E2BIG"))
    let tooWidePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAEAEAAAABCAYAAACx4wBCAAAAJ0lEQVR4nO3BMQEAAADCoPVPbQ0PoAAAAAAAAAAAAAAAAAAAAIALA0AFAAFdEb2kAAAAAElFTkSuQmCC")!
    feed(core, command("a=T,f=100,i=2,C=1", Array(tooWidePNG)))
    #expect(images(core).isEmpty && replies(core).contains("E2BIG"))
  }}
  @Test static func transportFields() {
    for field in ["U=1", "P=1", "Q=1", "I=0", "q=3"] { withTerminal { core in
      feed(core, command("a=T,f=24,s=1,v=1,i=1,C=1", [1, 2, 3])); let original = images(core)[0]
      _ = replies(core)
      feed(core, command("a=T,f=24,s=1,v=1,i=1,C=1,\(field)", [4, 5, 6]))
      #expect(images(core)[0]["generation"] as? Int == original["generation"] as? Int)
      #expect(replies(core).contains(field == "q=3" ? "EINVAL" : "ENOTSUP"))
    }}
  }
  @Test static func retiredAnchorCap() { withTerminal { core in
    feed(core, command("a=T,f=24,s=1,v=1,i=1,p=1,C=1", [1, 2, 3]))
    for id in 2...256 { feed(core, command("a=p,i=1,p=\(id),C=1")) }
    #expect(images(core).count == 256)
    terminal_set_history_limit(core, 0)
    feed(core, "\r\n\r\n\r\n")
    #expect(images(core).isEmpty)
    _ = replies(core)
    feed(core, command("a=p,i=1,p=257,C=1"))
    #expect(images(core).count == 1 && replies(core).contains("OK"))
    feed(core, "\u{1b}[?1049h")
    for id in 1...255 { feed(core, command("a=p,i=1,p=\(id),C=1")) }
    #expect(images(core).count == 255)
    feed(core, String(repeating: "x", count: 40)) // Discard the alternate anchor by ordinary wrapping.
    #expect(images(core).isEmpty)
    _ = replies(core)
    feed(core, command("a=p,i=1,p=258,C=1"))
    #expect(images(core).count == 1 && replies(core).contains("OK"))
  }}
  @Test static func pngZlib() { withTerminal { core in
    let variants: [(String, String, [UInt8])] = [
      ("gray1", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQAAAAA3bvkkAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg==", [255, 255, 255, 255]),
      ("gray2", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAgAAAABwzoP0AAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg==", [170, 170, 170, 255]),
      ("gray4", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABBAAAAAD/jnZUAAAACklEQVR4nGMoAAAAcgBxO7+GAwAAAABJRU5ErkJggg==", [119, 119, 119, 255]),
      ("gray8", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNQBAAAIwAi4LUekAAAAABJRU5ErkJggg==", [33, 33, 33, 255]),
      ("gray16", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABEAAAAABq7kcWAAAAC0lEQVR4nGMQMgEAAFsAR5b7G2UAAAAASUVORK5CYII=", [18, 18, 18, 255]),
      ("rgba16", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABEAYAAABPhRjKAAAAEUlEQVR4nGOo4BThkGNPZgMABgEBLLK5KlYAAAAASUVORK5CYII=", [120, 20, 30, 99]),
      ("palette", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAABlBMVEX/AAAA/wDSh+9xAAAACklEQVR4nGNgBAAAAwACS/Xd6gAAAABJRU5ErkJggg==", [0, 255, 0, 255]),
      ("palette-alpha", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAMAAAAoyzS7AAAABlBMVEX/AAAA/wDSh+9xAAAAAnRSTlP/YzEMAKgAAAAKSURBVHicY2AEAAADAAJL9d3qAAAAAElFTkSuQmCC", [0, 255, 0, 99]),
      ("rgb-transparent", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAABnRSTlMADAAiADi4ncCAAAAADElEQVR4nGPgUbIAAACkAGeY0OCYAAAAAElFTkSuQmCC", [12, 34, 56, 0])
    ]
    for (name, encoded, expected) in variants {
      feed(core, command("a=T,f=100,i=3,C=1", Array(Data(base64Encoded: encoded)!)))
      let image = images(core).first { $0["image"] as? Int == 3 }!
      #expect(rgba(core, image) == Data(expected), "PNG samples: \(name)")
    }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGOoEJFLBgACwAEOotbinwAAAABJRU5ErkJggg==")!
    feed(core, command("a=T,f=100,i=1,C=1", Array(png)))
    #expect(rgba(core, images(core)[0]) == Data([120, 20, 30, 99]))
    feed(core, command("a=T,f=32,s=1,v=1,o=z,i=2,C=1", [120, 1, 99, 100, 98, 102, 1, 0, 0, 24, 0, 11]))
    let original = images(core).first { $0["image"] as? Int == 2 }!
    #expect(rgba(core, original) == Data([1, 2, 3, 4]))
    feed(core, command("a=T,f=32,s=1,v=1,o=z,i=2,C=1", [120, 1, 99, 100, 98, 102, 1, 0, 0, 24, 0, 12]))
    #expect(images(core).first { $0["image"] as? Int == 2 }!["generation"] as? Int == original["generation"] as? Int)
    _ = replies(core)
    feed(core, command("a=t,f=32,s=1,v=1,o=z,i=11", Array(repeating: 0, count: 4096)))
    #expect(replies(core).contains("EINVAL"))
    #expect(images(core).allSatisfy { $0["image"] as? Int != 11 })
  }}
  @Test static func heightIdentity() { withTerminal { core in
    var document = TerminalDocument(columns: 8, rows: 3)
    let retained = document.primary
    let anchor = retained.rows[0].id
    let resize = DocumentReflowTransaction(source: document,
      geometry: TerminalResizeGeometry(columns: 8, rows: 4, cellWidth: 8, cellHeight: 16),
      anchor: anchor, promptEraseStyle: nil, historyRows: 50_000, historyBytes: 64 * 1024 * 1024)
    var replacement: DocumentReflowTransaction.Replacement?
    while replacement == nil {
      switch resize.advance() {
      case .pending: continue
      case .pressure: Issue.record("unexpected pressure in small direct fixture"); return
      case .ready(let value): replacement = value
      case .rejected(let reason): Issue.record("height reflow rejected: \(reason)"); return
      }
    }
    document = replacement!.document
    let mapping = replacement!.mapping
    resize.retire()
    #expect(mapping.anchor == anchor && document.primary.rows.prefix(3).elementsEqual(retained.rows))
    #expect(document.primary.rows[0].revision == retained.rows[0].revision)
    feed(core, command("a=T,f=24,s=1,v=1,i=1,C=1", [1, 2, 3]))
    let rows = snapshot(core)!["rows"] as! [[String: Any]]
    let firstID = rows[0]["id"] as! Int
    #expect(terminal_resize(core, 8, 4))
    #expect((snapshot(core)!["rows"] as! [[String: Any]])[0]["id"] as? Int == firstID)
    #expect(images(core).count == 1 && images(core)[0]["row"] as? Int == 0)
    #expect(terminal_resize(core, 4, 4))
    #expect(images(core).isEmpty)
  }}
  @Test static func partitions() {
    let packet = Data(command("a=T,f=32,s=2,v=1,i=4294967295,C=1", [1, 2, 3, 4, 5, 6, 7, 8]).utf8)
    for split in 0...packet.count { withTerminal { core in
      feed(core, Data(packet.prefix(split))); feed(core, Data(packet.suffix(packet.count - split)))
      #expect(images(core).count == 1 && rgba(core, images(core)[0]) == Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }}
    withTerminal { core in for byte in packet { feed(core, Data([byte])) }; #expect(images(core).count == 1) }
  }
  @Test static func atomicChunks() { withTerminal { core in
    let encoded = Data(repeating: 42, count: 6_000).base64EncodedString()
    feed(core, "\u{1b}_Ga=T,f=24,s=2000,v=1,i=99,C=1,m=1;\(encoded.prefix(4096))\u{1b}\\")
    #expect(images(core).isEmpty && replies(core).isEmpty)
    feed(core, "\u{1b}[2;6H\u{1b}_Gm=0;\(encoded.dropFirst(4096))\u{1b}\\")
    let image = images(core)[0]
    #expect(image["row"] as? Int == 1 && image["col"] as? Int == 5 && rgba(core, image)?.count == 8_000)
    #expect(replies(core) == "\u{1b}_Gi=99;OK\u{1b}\\")
    let rgbaBytes = Data(repeating: 42, count: 12)
    let rgbaEncoded = rgbaBytes.base64EncodedString()
    feed(core, "\u{1b}_Ga=T,f=32,s=3,v=1,i=100,C=1,m=1;\(rgbaEncoded.prefix(8))\u{1b}\\")
    #expect(images(core).count == 1)
    feed(core, "\u{1b}_Gm=0;\(rgbaEncoded.dropFirst(8))\u{1b}\\")
    let rgbaImage = images(core).first { $0["image"] as? Int == 100 }!
    #expect(rgba(core, rgbaImage) == rgbaBytes)
  }}
  @Test static func malformedAtomic() { withTerminal { core in
    feed(core, command("a=T,f=24,s=1,v=1,i=1,C=1", [1, 2, 3])); let original = images(core)[0]
    _ = replies(core)
    for packet in [command("a=T,f=24,s=4294967295,v=4294967295,i=1", [1, 2, 3]),
                   command("a=T,f=24,s=2,v=2,i=1", [1, 2, 3]),
                   command("a=T,f=100,t=f,i=1", [1]), "\u{1b}_Ga=T,f=24,s=1,v=1,i=1;%%%\u{1b}\\"] {
      feed(core, packet); #expect(images(core)[0]["generation"] as? Int == original["generation"] as? Int)
    }
    let errors = replies(core); #expect(errors.contains("E2BIG") && errors.contains("EINVAL") && errors.contains("ENOTSUP"))
    feed(core, "\u{1b}_G" + String(repeating: "x", count: 100_000) + "\u{1b}[2J\u{1b}\\Z")
    #expect(images(core).count == 1)
  }}
  @Test static func crossScreenDelete() { withTerminal { core in
    feed(core, command("a=T,f=24,s=1,v=1,i=2,C=1", [4, 5, 6])); let cached = images(core)[0]
    feed(core, command("a=d,d=i,i=2"))
    feed(core, command("a=T,f=24,s=1,v=1,i=1,C=1,z=7", [1, 2, 3])); let shared = images(core)[0]
    feed(core, "\u{1b}[?47h"); feed(core, command("a=p,i=1,C=1,z=7"))
    feed(core, command("a=d,d=Z,z=7")); #expect(images(core).isEmpty && rgba(core, shared) != nil && rgba(core, cached) != nil)
    feed(core, "\u{1b}[?47l"); #expect(images(core).count == 1)
    feed(core, command("a=d,d=Z,z=7")); #expect(rgba(core, shared) == nil && rgba(core, cached) != nil)
    feed(core, command("a=d,d=I,i=2")); #expect(rgba(core, cached) == nil)
  }}
  @Test static func checkedIds() { withTerminal { core in
    for header in ["a=d,d=i,i=4294967296", "a=d,d=I,i=-1", "a=p,i=4294967296", "a=T,f=24,s=1,v=1,i=1,p=4294967296"] {
      feed(core, command(header, [1, 2, 3]))
      #expect(images(core).isEmpty)
    }
  }}
  @Test static func cursorLayout() { withTerminal { core in
    feed(core, command("a=T,f=24,s=2,v=1,i=1,p=7,c=3,r=2,C=1", [255, 0, 0, 0, 255, 0]))
    let image = images(core).first!; let cursor = snapshot(core)!["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 0 && cursor["col"] as? Int == 0)
    #expect(rgba(core, image) == Data([255, 0, 0, 255, 0, 255, 0, 255]))
    #expect(replies(core).contains("i=1,p=7;OK"))
    feed(core, command("a=p,i=1,C=1,c=3"))
    #expect(images(core).count == 2)
    feed(core, command("a=p,i=1,x=1,y=0,w=0,h=0,C=1"))
    #expect(images(core).last!["source"] as? [Int] == [1, 0, 1, 1])
    feed(core, command("a=T,f=24,s=1,v=1,C=1", [3, 2, 1]))
    #expect(images(core).contains { $0["image"] as? Int == Int(UInt32.max) })
  }}
  @Test static func resetScroll() { withTerminal { core in
    feed(core, command("a=T,f=24,s=1,v=1,i=1,C=1,c=2,r=2", [1, 2, 3]))
    let resource = images(core)[0]
    feed(core, "\u{1b}[?47h"); #expect(images(core).isEmpty)
    feed(core, "\u{1b}[?47l"); #expect(images(core).count == 1)
    feed(core, "\u{1b}[3S")
    #expect(images(core).isEmpty && images(core, scroll: 3).count == 1)
    feed(core, "\u{1b}[3J"); #expect(images(core, scroll: 3).isEmpty)
    feed(core, "\u{1b}c"); #expect(rgba(core, resource) == nil)
  }}
  @Test static func uploadLifecycle() { withTerminal { core in
    let begin = "\u{1b}_Ga=T,f=24,s=2,v=1,i=1,C=1,m=1;AQID\u{1b}\\"
    feed(core, begin, now: 1)
    feed(core, "\u{1b}_Gm=0;BAUG\u{1b}\\", now: 10_002)
    #expect(images(core).isEmpty)
    feed(core, begin, now: 20_000)
    feed(core, "\u{1b}_Gm=0;BAUG\u{18}", now: 20_001)
    feed(core, "\u{1b}_Gm=0;BAUG\u{1b}\\", now: 20_002)
    #expect(images(core).isEmpty)
    feed(core, begin); terminal_finish(core)
    feed(core, "\u{1b}_Gm=0;BAUG\u{1b}\\")
    #expect(images(core).isEmpty)
    feed(core, begin); feed(core, "\u{1b}_Gm=0;BAUG\u{1b}\\")
    #expect(images(core).count == 1)
    // A completed upload must not remain a continuation source.
    feed(core, "\u{1b}_Gm=0;BAUG\u{1b}\\")
    #expect(images(core).count == 1)
  }}
  @Test static func deleteCache() { withTerminal { core in
    feed(core, command("a=T,f=24,s=1,v=1,i=1,C=1", [1, 2, 3]))
    let image = images(core)[0]
    feed(core, command("a=d,d=i,i=1")); #expect(images(core).isEmpty && rgba(core, image) != nil)
    feed(core, command("a=d,d=I,i=1")); #expect(rgba(core, image) == nil)
  }}
  @Test static func featureQuery() { withTerminal { core in
    feed(core, "\u{1b}_Ga=q,i=10,e=T,U=1,C=1,t=d,f=24\u{1b}\\")
    let reply = replies(core)
    #expect(reply.contains("e=T") && reply.contains("C=1") && !reply.contains("U=1"))
    feed(core, command("a=q,f=24,s=1,v=1,i=2,q=1", [1, 2, 3]))
    #expect(replies(core).isEmpty && images(core).isEmpty)
  }}
  @Test static func dmscene() { withTerminal { core in
    var previous: [String: Any]?
    for n in 0..<20 {
      let id = 100 + n % 2
      feed(core, "\u{1b}[?2026h\u{1b}[H")
      feed(core, command("a=T,t=d,f=24,s=2,v=1,i=\(id),p=1,c=8,r=2,C=1,q=2,m=0", [UInt8(n), 2, 3, 4, 5, 6]))
      if n > 0 { feed(core, command("a=d,d=I,i=\(100 + (n + 1) % 2),q=2")) }
      #expect(snapshot(core) == nil)
      feed(core, "\u{1b}[?2026l")
      let image = images(core); #expect(image.count == 1 && image[0]["image"] as? Int == id)
      if let previous { #expect(rgba(core, previous) == nil) }
      previous = image[0]; #expect(replies(core).isEmpty)
    }
  }}
}

import Foundation
import Testing
@testable import TerminalEngine
@testable import TerminalUI
import TerminalInterop

#if GLYPH_RESIDENCY_TESTING
/// A deterministic engine-to-Metal oracle: production parser, placement and
/// texture bytes feed the renderer's offscreen production draw path.
@Suite(.serialized) @MainActor struct GraphicsRenderedGapTests {
  private typealias Oracle = TerminalGraphicsOracleTests
  private let esc = "\u{1b}"
  private final class Captured {
    private let lock = NSLock()
    private var value: [UInt8]?
    var pixels: [UInt8]? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ pixels: [UInt8]?) { lock.lock(); value = pixels; lock.unlock() }
  }

  @Test func cropAlphaZOrderRelativeAndPlaceholderPixels() async throws {
    let core = try #require(helge_terminal_create(3, 2)); defer { helge_terminal_destroy(core) }
    #expect(helge_terminal_resize_pixels(core, 3, 2, 8, 8))
    Oracle.feed(core, "\(esc)[?25l\(esc)]11;#000000\(esc)\\")
    // Red parent, half-transparent blue over it, cropped green relative child.
    Oracle.feed(core, Oracle.command("a=T,f=32,s=1,v=1,i=1,p=1,c=1,r=1,C=1,z=0", [255, 0, 0, 255]))
    Oracle.feed(core, Oracle.command("a=T,f=32,s=1,v=1,i=2,p=1,c=1,r=1,C=1,z=1", [0, 0, 255, 128]))
    Oracle.feed(core, Oracle.command("a=T,f=24,s=2,v=1,i=3,p=1,P=1,Q=1,H=1,x=1,w=1,c=1,r=1,C=1", [255, 0, 0, 0, 255, 0]))
    // Virtual one-cell placement, emitted as a real Unicode placeholder.
    Oracle.feed(core, Oracle.command("a=T,f=24,s=1,v=1,i=4,p=1,U=1,c=1,r=1,C=1", [255, 255, 0]))
    let mark = String(UnicodeScalar(KittyPlaceholder.diacritics[0])!)
    Oracle.feed(core, "\(esc)[2;1H\(esc)[38;5;4m\u{10eeee}\(mark)\(mark)\(esc)[0m")
    var snapshot = try #require(swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot)
    for image in snapshot.images {
      let bytes = Oracle.Bytes()
      #expect(helge_terminal_image_rgba(core, image.image, image.generation,
        Unmanaged.passUnretained(bytes).toOpaque(), Oracle.collect))
      snapshot.imagePixels[image.key] = ImagePixels(bytes.data)
    }
    let renderer = try TerminalRendering()
    let captured = Captured()
    renderer.renderPixelsForTesting(RenderRequest(snapshot: snapshot, width: 24, height: 16, inset: 0,
      cellWidth: 8, cellHeight: 8, fontSize: 8, focused: false, marked: "", linkUnderline: [])) { captured.set($0) }
    #expect(await TestEnvironment.wait { captured.pixels != nil })
    let pixels = try #require(captured.pixels)
    func bgra(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[((y * 24 + x) * 4)..<((y * 24 + x) * 4 + 4)]) }
    let blended = bgra(4, 4)
    #expect(abs(Int(blended[0]) - 188) <= 2 && blended[1] == 0 && abs(Int(blended[2]) - 187) <= 2 && blended[3] == 255)
    #expect(bgra(12, 4) == [0, 255, 0, 255], "relative child's cropped green sample")
    #expect(bgra(4, 12) == [0, 255, 255, 255], "placeholder image slice")
    #expect(bgra(20, 12) == [0, 0, 0, 255], "clear background outside placements")
  }
}
#endif

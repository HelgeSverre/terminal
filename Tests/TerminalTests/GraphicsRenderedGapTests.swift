import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TerminalEngine
@testable import TerminalUI
import TerminalInterop

#if GLYPH_RESIDENCY_TESTING
/// A deterministic engine-to-Metal oracle: production parser, placement and
/// texture bytes feed the renderer's offscreen production draw path.
@Suite(.serialized) @MainActor struct GraphicsRenderedGapTests {
  private typealias Oracle = TerminalGraphicsOracleTests
  private let esc = "\u{1b}"
  private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UInt8]?
    var pixels: [UInt8]? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ pixels: [UInt8]?) { lock.lock(); value = pixels; lock.unlock() }
  }

  private func render(_ core: OpaquePointer, with renderer: TerminalRendering,
                      width: Int, height: Int, cellWidth: Int = 8, cellHeight: Int = 8,
                      now: UInt64 = 0) async throws -> (snapshot: TerminalSnapshot, pixels: [UInt8]) {
    var snapshot = try #require(swiftTerminalSnapshot(core, scroll: nil, now: now).snapshot)
    for image in snapshot.images {
      let bytes = Oracle.Bytes()
      #expect(helge_terminal_image_rgba(core, image.image, image.generation,
        Unmanaged.passUnretained(bytes).toOpaque(), Oracle.collect))
      snapshot.imagePixels[image.key] = ImagePixels(bytes.data)
    }
    let captured = Captured()
    renderer.renderPixelsForTesting(RenderRequest(snapshot: snapshot, width: width, height: height, inset: 0,
      cellWidth: cellWidth, cellHeight: cellHeight, fontSize: CGFloat(cellHeight), focused: false, marked: "", linkUnderline: [])) {
      captured.set($0)
    }
    #expect(await TestEnvironment.wait { captured.pixels != nil })
    return (snapshot, try #require(captured.pixels))
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
    let png = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
    let provider = try #require(CGDataProvider(data: Data([0, 255, 255, 255]) as CFData))
    let cyan = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    CGImageDestinationAddImage(destination, cyan, nil)
    #expect(CGImageDestinationFinalize(destination))
    Oracle.feed(core, "\(esc)]1337;File=inline=1;width=2;height=1;preserveAspectRatio=0:\((png as Data).base64EncodedString())\u{7}")
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
    #expect(bgra(20, 4) == [0, 0, 0, 255], "clear background outside placements")
    #expect(bgra(9, 12) == [255, 255, 0, 255] && bgra(22, 12) == [255, 255, 0, 255],
      "preserveAspectRatio=0 stretches to both horizontal edges")
  }

  @Test func kittyCropAlphaOverCellBackgroundAndZOrderRelativeToText() async throws {
    let core = try #require(helge_terminal_create(3, 2)); defer { helge_terminal_destroy(core) }
    #expect(helge_terminal_resize_pixels(core, 3, 2, 8, 8))
    Oracle.feed(core, "\(esc)[?25l\(esc)]11;#000000\(esc)\\")

    // Source-rectangle cropping (x, y, w, h) on a 2x2 RGBA image:
    // (0,0)=red, (1,0)=green, (0,1)=blue, (1,1)=cyan.
    let quadrants: [UInt8] = [
      255, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 0, 255, 255, 255,
    ]
    // Col 0, Row 0: bottom-right quadrant (x=1, y=1, w=1, h=1) -> cyan.
    Oracle.feed(core, "\(esc)[1;1H" + Oracle.command("a=T,f=32,s=2,v=2,i=1,p=1,x=1,y=1,w=1,h=1,c=1,r=1,C=1", quadrants))
    // Col 1, Row 0: bottom-left quadrant (x=0, y=1, w=1, h=1) -> blue.
    Oracle.feed(core, "\(esc)[1;2H" + Oracle.command("a=p,i=1,p=2,x=0,y=1,w=1,h=1,c=1,r=1,C=1"))

    // Alpha compositing over a colored SGR cell background:
    // Col 2, Row 0 has a red cell background with a half-transparent blue Kitty image over it.
    Oracle.feed(core, "\(esc)[1;3H\(esc)[48;2;255;0;0m \(esc)[0m")
    Oracle.feed(core, "\(esc)[1;3H" + Oracle.command("a=T,f=32,s=1,v=1,i=2,p=1,c=1,r=1,C=1,z=0", [0, 0, 255, 128]))

    // Z-order layering relative to text and cell backgrounds:
    // Full block U+2588 draws as a solid yellow text quad in scratchTextQuads.
    // Col 0, Row 1: negative z (-1) renders behind yellow text -> yellow wins.
    Oracle.feed(core, "\(esc)[2;1H\(esc)[38;2;255;255;0m\u{2588}\(esc)[0m")
    Oracle.feed(core, "\(esc)[2;1H" + Oracle.command("a=T,f=32,s=1,v=1,i=3,p=1,c=1,r=1,C=1,z=-1", [255, 0, 255, 255]))
    // Col 1, Row 1: positive z (1) renders in front of yellow text -> magenta wins.
    Oracle.feed(core, "\(esc)[2;2H\(esc)[38;2;255;255;0m\u{2588}\(esc)[0m")
    Oracle.feed(core, "\(esc)[2;2H" + Oracle.command("a=p,i=3,p=2,c=1,r=1,C=1,z=1"))
    // Col 2, Row 1: z < -1_073_741_824 renders behind cell backgrounds -> green background wins.
    Oracle.feed(core, "\(esc)[2;3H\(esc)[48;2;0;255;0m \(esc)[0m")
    Oracle.feed(core, "\(esc)[2;3H" + Oracle.command("a=p,i=3,p=3,c=1,r=1,C=1,z=-1073741825"))

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

    #expect(bgra(6, 6) == [255, 255, 0, 255], "cropped (x=1, y=1, w=1, h=1) selects cyan bottom-right pixel")
    #expect(bgra(9, 6) == [255, 0, 0, 255], "cropped (x=0, y=1, w=1, h=1) selects blue bottom-left pixel")
    let blended = bgra(20, 4)
    #expect(abs(Int(blended[0]) - 188) <= 2 && blended[1] == 0 && abs(Int(blended[2]) - 187) <= 2 && blended[3] == 255,
      "half-transparent blue image composites over red cell background")
    #expect(bgra(4, 12) == [0, 255, 255, 255], "negative z (-1) renders behind yellow text")
    #expect(bgra(12, 12) == [255, 0, 255, 255], "positive z (1) renders in front of yellow text")
    #expect(bgra(20, 12) == [0, 255, 0, 255], "z < -1_073_741_824 renders behind green cell background")
  }

  @Test func sixelPaletteAspectBackgroundAndTransparentHolesPixels() async throws {
    let core = try #require(helge_terminal_create(6, 3)); defer { helge_terminal_destroy(core) }
    #expect(helge_terminal_resize_pixels(core, 6, 3, 8, 8))
    Oracle.feed(core, "\(esc)[?25l\(esc)]11;#000000\(esc)\\")
    // Paint rows 1-2 with an explicit blue SGR cell background so SIXEL transparency
    // (P2=1) and opaque background fill (P2=0) are visually distinct through Metal.
    Oracle.feed(core, "\(esc)[1;1H\(esc)[48;2;0;0;255m      \(esc)[0m")
    Oracle.feed(core, "\(esc)[2;1H\(esc)[48;2;0;0;255m      \(esc)[0m")

    // Image 1 (cols 0..<3, row 0, pixels x=0..<24, y=0..<6):
    // P2=1 leaves unset sixel pixels transparent; #1 is red, #2 is green.
    Oracle.feed(core, "\(esc)[1;1H\(esc)P7;1q\"1;1;24;6#1;2;100;0;0#2;2;0;100;0#1!8~!8?#2!8~\(esc)\\")

    // Image 2 (cols 3..<5, rows 0..<2, pixels x=24..<40, y=0..<12):
    // P2=0 fills unset sixel pixels with the terminal's OSC 11 background (yellow),
    // raster "2;1;16;6 doubles the 6px height to 12px, and #1 reuses the persisted red register.
    Oracle.feed(core, "\(esc)]11;#ffff00\(esc)\\\(esc)[1;4H\(esc)P7;0q\"2;1;16;6#1!8~!8?\(esc)\\")

    let renderer = try TerminalRendering()
    let (snapshot, pixels) = try await render(core, with: renderer, width: 48, height: 24)
    func bgra(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[((y * 48 + x) * 4)..<((y * 48 + x) * 4 + 4)]) }

    #expect(snapshot.images.count == 2)
    #expect(bgra(4, 3) == [0, 0, 255, 255], "SIXEL explicit red register #1 renders opaque red")
    #expect(bgra(12, 3) == [255, 0, 0, 255], "SIXEL P2=1 transparent hole reveals underlying blue SGR cell background")
    #expect(bgra(20, 3) == [0, 255, 0, 255], "SIXEL explicit green register #2 renders opaque green")
    #expect(bgra(28, 3) == [0, 0, 255, 255], "SIXEL register #1 persists into the second image")
    #expect(bgra(28, 10) == [0, 0, 255, 255], "SIXEL 2:1 raster aspect doubles 6px height to 12px into row 2")
    #expect(bgra(36, 3) == [0, 255, 255, 255], "SIXEL P2=0 fills unset pixels with opaque yellow background over blue cell")
    #expect(bgra(36, 10) == [0, 255, 255, 255], "SIXEL P2=0 opaque yellow fill extends across the aspect-scaled lower half")
    #expect(bgra(28, 14) == [255, 0, 0, 255], "pixels below the 12px SIXEL image remain the blue SGR cell background")
  }

  @Test func kittyAnimatedFramesAdvanceAndCompositeOnClockTick() async throws {
    let core = try #require(helge_terminal_create(2, 2)); defer { helge_terminal_destroy(core) }
    #expect(helge_terminal_resize_pixels(core, 2, 2, 8, 8))
    Oracle.feed(core, "\(esc)[?25l\(esc)]11;#000000\(esc)\\", now: 0)

    // Root frame 1 (red), appended frame 2 (green, 50 ms gap), then loop twice
    // with a 50 ms gap on frame 1 (emulator clock `now` is in milliseconds).
    Oracle.feed(core, Oracle.command("a=T,f=32,s=1,v=1,i=10,c=1,r=1,C=1,q=2", [255, 0, 0, 255]), now: 0)
    Oracle.feed(core, Oracle.command("a=f,i=10,z=50,f=32,s=1,v=1,q=2", [0, 255, 0, 255]), now: 0)
    Oracle.feed(core, Oracle.command("a=a,i=10,r=1,z=50,s=3,v=3,q=2"), now: 0)

    let renderer = try TerminalRendering()
    func bgra(_ pixels: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
      Array(pixels[((y * 16 + x) * 4)..<((y * 16 + x) * 4 + 4)])
    }

    let tick0 = try await render(core, with: renderer, width: 16, height: 16, now: 0)
    let gen1 = try #require(tick0.snapshot.images.first?.generation)
    #expect(bgra(tick0.pixels, 4, 4) == [0, 0, 255, 255], "root frame renders red at now=0ms")

    let tick1 = try await render(core, with: renderer, width: 16, height: 16, now: 60)
    let gen2 = try #require(tick1.snapshot.images.first?.generation)
    #expect(gen2 != gen1, "advancing past the 50ms gap switches to frame 2 generation")
    #expect(bgra(tick1.pixels, 4, 4) == [0, 255, 0, 255], "frame 2 renders green at now=60ms")

    let tick2 = try await render(core, with: renderer, width: 16, height: 16, now: 110)
    #expect(tick2.snapshot.images.first?.generation == gen1, "second loop wraps back to frame 1 generation")
    #expect(bgra(tick2.pixels, 4, 4) == [0, 0, 255, 255], "looped animation renders red again at now=110ms")

    // Append frame 3 (half-transparent blue) and alpha-compose it onto frame 1 with a=c.
    Oracle.feed(core, Oracle.command("a=f,i=10,z=50,f=32,s=1,v=1,q=2", [0, 0, 255, 128]), now: 110)
    Oracle.feed(core, Oracle.command("a=c,i=10,r=3,c=1,X=0,Y=0,x=0,y=0,w=1,h=1,C=0,q=2"), now: 110)
    Oracle.feed(core, Oracle.command("a=a,i=10,s=1,c=1,q=2"), now: 110)

    let composed = try await render(core, with: renderer, width: 16, height: 16, now: 110)
    let genComposed = try #require(composed.snapshot.images.first?.generation)
    #expect(genComposed != gen1 && genComposed != gen2, "a=c publishes a fresh generation for the composed frame")
    let blended = bgra(composed.pixels, 4, 4)
    #expect(abs(Int(blended[0]) - 128) <= 2 && blended[1] == 0 && abs(Int(blended[2]) - 127) <= 2 && blended[3] == 255,
      "a=c blends half-transparent blue onto red root frame")
  }
}
#endif

import Foundation
import Compression
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TerminalEngine
import TerminalInterop

@Suite(.serialized) struct GraphicsGapTests {
  private typealias Oracle = TerminalGraphicsOracleTests
  private let esc = "\u{1b}"

  @Test func indexedSamplesFollowPaletteAndDefaultColors() throws {
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    Oracle.feed(core, "\(esc)]4;1;#123456\(esc)\\\(esc)]10;#abcdef\(esc)\\\(esc)]11;#102030\(esc)\\")
    Oracle.feed(core, Oracle.command("a=T,f=16,s=3,v=1,i=1,C=1", [1, 99, 248, 255, 249, 0]))
    let first = try #require(Oracle.images(core).first)
    #expect(Oracle.rgba(core, first) == Data([18, 52, 86, 99, 16, 32, 48, 255, 171, 205, 239, 0]))
    Oracle.feed(core, "\(esc)]4;1;#654321\(esc)\\")
    let refreshed = try #require(Oracle.images(core).first)
    #expect(first["generation"] as? Int != refreshed["generation"] as? Int)
    #expect(Oracle.rgba(core, refreshed)?.prefix(4) == Data([101, 67, 33, 99]))
    Oracle.feed(core, Oracle.command("a=f,f=32,s=1,v=1,i=1", [1, 2, 3, 4]))
    #expect(Oracle.replies(core).contains("OK"))
    Oracle.feed(core, Oracle.command("a=T,f=8,s=1,v=1,i=2,C=1", [1]))
    #expect(Oracle.images(core).first { $0["image"] as? Int == 2 }.flatMap { Oracle.rgba(core, $0) } == Data([101, 67, 33, 255]))
  }

  @Test func indexedAnimationFramesPlayAndRebakeOnPaletteUpdate() throws {
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    func rgba(at now: UInt64) throws -> (generation: UInt64, data: Data) {
      let image = try #require(swiftTerminalSnapshot(core, scroll: nil, now: now).snapshot?.images.first)
      let pixels = Oracle.Bytes()
      #expect(helge_terminal_image_rgba(core, image.image, image.generation,
        Unmanaged.passUnretained(pixels).toOpaque(), Oracle.collect))
      return (image.generation, pixels.data)
    }

    Oracle.feed(core, "\(esc)]4;1;#ff0000\(esc)\\\(esc)]4;2;#00ff00\(esc)\\\(esc)]11;#102030\(esc)\\", now: 0)
    Oracle.feed(core, Oracle.command("a=T,f=8,s=2,v=1,i=1,C=1", [1, 2]), now: 0)
    Oracle.feed(core, Oracle.command("a=f,f=16,s=2,v=1,i=1,z=50", [2, 128, 248, 255]), now: 0)
    Oracle.feed(core, Oracle.command("a=a,i=1,r=1,z=50,s=3,v=1"), now: 0)
    let replies = Oracle.replies(core)
    #expect(!replies.contains("ENOTSUP") && replies.contains("OK"))

    let frame1Before = try rgba(at: 0)
    #expect(frame1Before.data == Data([255, 0, 0, 255, 0, 255, 0, 255]))
    let frame2Before = try rgba(at: 60)
    #expect(frame2Before.generation != frame1Before.generation)
    #expect(frame2Before.data == Data([0, 255, 0, 128, 16, 32, 48, 255]))

    Oracle.feed(core, "\(esc)]4;1;#112233\(esc)\\\(esc)]4;2;#445566\(esc)\\\(esc)]11;#778899\(esc)\\", now: 60)
    let frame2After = try rgba(at: 60)
    #expect(frame2After.generation != frame2Before.generation)
    #expect(frame2After.data == Data([0x44, 0x55, 0x66, 128, 0x77, 0x88, 0x99, 255]))

    Oracle.feed(core, Oracle.command("a=a,i=1,s=1,c=1"), now: 60)
    let frame1After = try rgba(at: 60)
    #expect(frame1After.generation != frame1Before.generation)
    #expect(frame1After.data == Data([0x11, 0x22, 0x33, 255, 0x44, 0x55, 0x66, 255]))

    Oracle.feed(core, "\(esc)_Ga=q,i=9,e=f,f=8\(esc)\\\(esc)_Ga=q,i=9,e=f,f=16\(esc)\\", now: 60)
    let featureReplies = Oracle.replies(core)
    #expect(featureReplies.contains("e=f,f=8;OK") && featureReplies.contains("e=f,f=16;OK"))
  }

  @Test func indexedComposeOverwritePreservesPaletteAndAlphaBlendBakesRGBA() throws {
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    func currentFrame() throws -> (generation: UInt64, data: Data) {
      let image = try #require(swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot?.images.first)
      let pixels = Oracle.Bytes()
      #expect(helge_terminal_image_rgba(core, image.image, image.generation,
        Unmanaged.passUnretained(pixels).toOpaque(), Oracle.collect))
      return (image.generation, pixels.data)
    }

    Oracle.feed(core, "\(esc)]4;1;#ff0000\(esc)\\\(esc)]4;2;#0000ff\(esc)\\\(esc)]4;3;#00ff00\(esc)\\")
    Oracle.feed(core, Oracle.command("a=T,f=8,s=2,v=1,i=1,C=1", [1, 1]))
    Oracle.feed(core, Oracle.command("a=f,f=16,s=2,v=1,i=1", [2, 128, 3, 255]))
    Oracle.feed(core, Oracle.command("a=f,f=8,s=2,v=1,i=1", [1, 1]))

    // C=1 overwrite from indexed f=16 frame 2 onto indexed f=8 frame 1 keeps palette reactivity and upgrades alpha.
    Oracle.feed(core, Oracle.command("a=c,i=1,r=2,c=1,X=0,Y=0,x=1,y=0,w=1,h=1,C=1"))
    // C=0 alpha blend from f=16 frame 2 onto f=8 frame 3 bakes RGBA and drops palette reactivity on frame 3.
    Oracle.feed(core, Oracle.command("a=c,i=1,r=2,c=3,X=0,Y=0,x=0,y=0,w=1,h=1,C=0"))
    #expect(!Oracle.replies(core).contains("ENOTSUP"))

    let frame1Before = try currentFrame()
    #expect(frame1Before.data == Data([255, 0, 0, 255, 0, 0, 255, 128]))

    Oracle.feed(core, Oracle.command("a=a,i=1,s=1,c=3"))
    let frame3Before = try currentFrame()
    #expect(frame3Before.data[0] > 120 && frame3Before.data[0] < 135)
    #expect(frame3Before.data[1] == 0)
    #expect(frame3Before.data[2] > 120 && frame3Before.data[2] < 135)
    #expect(frame3Before.data[3] == 255)

    // Update palette: frame 1 updates, frame 3 remains baked.
    Oracle.feed(core, "\(esc)]4;1;#102030\(esc)\\\(esc)]4;2;#405060\(esc)\\")
    let frame3After = try currentFrame()
    #expect(frame3After.generation == frame3Before.generation)
    #expect(frame3After.data == frame3Before.data)

    Oracle.feed(core, Oracle.command("a=a,i=1,s=1,c=1"))
    let frame1After = try currentFrame()
    #expect(frame1After.generation != frame1Before.generation)
    #expect(frame1After.data == Data([0x10, 0x20, 0x30, 255, 0x40, 0x50, 0x60, 128]))
  }

  @Test func indexedDeleteRootPromotesIndexedFrameAndAccountsBytes() throws {
    let store = KittyGraphicsStore()
    var palette = [[Int]](repeating: [0, 0, 0], count: 256)
    palette[1] = [255, 0, 0]
    palette[2] = [0, 255, 0]
    store.setPalette(palette)
    let context = KittyGraphicsContext(alternate: false, row: 1, column: 0, cellWidth: 8, cellHeight: 16)
    func send(_ header: String, _ bytes: [UInt8] = []) {
      let payload = Data(bytes).base64EncodedString()
      let packet = Data("G\(header);\(payload)".utf8)
      _ = store.consume(packet, context: context, now: 0)
    }

    // Root f=8 (2x1): 8 rgba + 2 indexed = 10 bytes.
    send("a=T,f=8,s=2,v=1,i=1,C=1", [1, 1])
    #expect(store.accountedBytes == 10)
    // Frame 2 f=16 (2x1): 8 rgba + 4 indexed = 12 bytes -> total 22.
    send("a=f,f=16,s=2,v=1,i=1", [2, 200, 2, 100])
    #expect(store.accountedBytes == 22)
    // Frame 3 f=32 (2x1): 8 rgba + 0 indexed = 8 bytes -> total 30.
    send("a=f,f=32,s=2,v=1,i=1", [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(store.accountedBytes == 30)

    // Delete root frame 1: promotes indexed f=16 frame 2 to root, frees 10 bytes -> total 20.
    send("a=d,d=f,i=1,r=1")
    #expect(store.accountedBytes == 20)
    let promotedBefore = try #require(store.visible(alternate: false, positions: [1: 0], height: 4).first)
    #expect(store.imageRGBA(id: promotedBefore.image, generation: promotedBefore.generation) == Data([0, 255, 0, 200, 0, 255, 0, 100]))

    // Palette change must re-bake the promoted root frame and advance its generation.
    palette[2] = [10, 20, 30]
    store.setPalette(palette)
    let promotedAfter = try #require(store.visible(alternate: false, positions: [1: 0], height: 4).first)
    #expect(promotedAfter.generation != promotedBefore.generation)
    #expect(store.imageRGBA(id: promotedAfter.image, generation: promotedAfter.generation) == Data([10, 20, 30, 200, 10, 20, 30, 100]))

    // Delete frame 2 (the f=32 frame, 8 bytes) -> total 12.
    send("a=d,d=f,i=1,r=2")
    #expect(store.accountedBytes == 12)
    // Delete last frame with d=F -> frees image completely.
    send("a=d,d=F,i=1,r=1")
    #expect(store.accountedBytes == 0)
  }

  @Test func ordinaryAndRelativePlacementsFollowWidthReflow() throws {
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    Oracle.feed(core, "abcdef\(esc)[1;6H")
    Oracle.feed(core, Oracle.command("a=T,f=24,s=1,v=1,i=1,p=1,C=1", [1, 2, 3]))
    Oracle.feed(core, Oracle.command("a=T,f=24,s=1,v=1,i=2,p=1,P=1,Q=1,H=1,C=1", [4, 5, 6]))
    #expect(helge_terminal_resize(core, 4, 4))
    let images = Oracle.images(core)
    let parent = try #require(images.first { $0["image"] as? Int == 1 })
    let child = try #require(images.first { $0["image"] as? Int == 2 })
    #expect(parent["row"] as? Int == 1 && parent["col"] as? Int == 1)
    #expect(child["row"] as? Int == 1 && child["col"] as? Int == 2)
    #expect(Oracle.rgba(core, parent) == Data([1, 2, 3, 255]))
  }

  @Test func placeholderPlacementAndItsChildFollowReflowAndPartialScroll() throws {
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    let mark = String(UnicodeScalar(KittyPlaceholder.diacritics[0])!)
    Oracle.feed(core, Oracle.command("a=T,f=24,s=1,v=1,i=1,p=1,U=1,c=1,r=1,C=1", [1, 2, 3]))
    Oracle.feed(core, "abcde\(esc)[38;5;1m\u{10eeee}\(mark)\(mark)\(esc)[0m")
    Oracle.feed(core, Oracle.command("a=T,f=24,s=1,v=1,i=2,p=1,P=1,Q=1,H=1,C=1", [4, 5, 6]))
    #expect(helge_terminal_resize(core, 4, 4))
    var child = try #require(Oracle.images(core).first { $0["image"] as? Int == 2 })
    #expect(child["row"] as? Int == 1 && child["col"] as? Int == 2)
    Oracle.feed(core, "\(esc)[?69h\(esc)[2;4s\(esc)[S")
    child = try #require(Oracle.images(core).first { $0["image"] as? Int == 2 })
    #expect(child["row"] as? Int == 0 && child["col"] as? Int == 2)
  }

  @Test func partialWidthScrollMovesAndClipsPlacements() throws {
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    Oracle.feed(core, "\(esc)[2;2H")
    Oracle.feed(core, Oracle.command("a=T,f=32,s=1,v=4,c=2,r=2,i=1,p=1,C=1", Array(repeating: 99, count: 16)))
    Oracle.feed(core, Oracle.command("a=T,f=24,s=1,v=1,i=2,p=1,P=1,Q=1,H=1,C=1", [4, 5, 6]))
    Oracle.feed(core, "\(esc)[H" + Oracle.command("a=T,f=24,s=1,v=1,i=3,C=1", [7, 8, 9]))
    Oracle.feed(core, "\(esc)[?69h\(esc)[2;7s\(esc)[1;3r\(esc)[S")
    #expect(Oracle.images(core).first { $0["image"] as? Int == 1 }?["row"] as? Int == 0)
    #expect(Oracle.images(core).first { $0["image"] as? Int == 2 }?["row"] as? Int == 0)
    #expect(Oracle.images(core).first { $0["image"] as? Int == 3 }?["row"] as? Int == 0)
    Oracle.feed(core, "\(esc)[S")
    let clipped = try #require(Oracle.images(core).first { $0["image"] as? Int == 1 })
    #expect(clipped["source"] as? [Int] == [0, 2, 1, 2])
    #expect(clipped["rows"] as? Int == 1)
  }

  @Test func sixelBackgroundAspectPaletteAndDisplayModes() throws {
    let terminal = try #require(HeadlessTerminal(columns: 8, rows: 4))
    terminal.feed("\(esc)]11;#102030\(esc)\\\(esc)P7;0q\"1;1;2;6#5;2;100;0;0#5@\(esc)\\")
    var image = try #require(terminal.screen()?.images.first)
    var pixels = try #require(terminal.pixels(of: image))
    #expect(pixels.prefix(8) == Data([255, 0, 0, 255, 16, 32, 48, 255]))
    var before = try #require(terminal.screen()).images
    terminal.feed("\(esc)P7;1q\"2;1;2;6#5@\(esc)\\")
    image = try #require(terminal.screen()?.images.first { !before.contains($0) })
    pixels = try #require(terminal.pixels(of: image))
    #expect(image.pixelHeight == 12)
    #expect(pixels.prefix(8) == Data([255, 0, 0, 255, 0, 0, 0, 0]), "palette registers persist, P2=1 leaves holes")
    before = try #require(terminal.screen()).images
    terminal.feed("\(esc)[3;4H\(esc)[?80h\(esc)P7q#5~\(esc)\\")
    let screen = try #require(terminal.screen())
    #expect(screen.cursorRow == 2 && screen.cursorColumn == 3)
    let displayImage = try #require(screen.images.first { !before.contains($0) })
    #expect(displayImage.row == 0 && displayImage.column == 0)
    terminal.feed("\(esc)[?80l\(esc)[?8452h\(esc)P7q#5~\(esc)\\")
    #expect(terminal.screen()?.cursorRow == 2 && terminal.screen()?.cursorColumn == 4)
  }

  @Test func sharedMemoryTransportReadsOffsetAndUnlinksObject() throws {
    let name = "/htg" + String(UUID().uuidString.prefix(16))
    let descriptor = name.withCString { helge_terminal_graphics_shm_open($0, O_CREAT | O_EXCL | O_RDWR, 0o600) }
    #expect(descriptor >= 0); guard descriptor >= 0 else { return }
    defer { close(descriptor); shm_unlink(name) }
    #expect(ftruncate(descriptor, 4096) == 0)
    let mapped = try #require(mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0))
    #expect(mapped != MAP_FAILED); guard mapped != MAP_FAILED else { return }
    defer { munmap(mapped, 4096) }
    let bytes: [UInt8] = [9, 8, 1, 2, 3, 4]
    bytes.withUnsafeBytes { mapped.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    Oracle.feed(core, Oracle.command("a=T,t=s,f=32,s=1,v=1,O=2,S=4,i=1,C=1", Array(name.utf8)))
    #expect(Oracle.replies(core).contains("OK"), "shared memory must be readable with its explicit creation permissions")
    let image = try #require(Oracle.images(core).first)
    #expect(Oracle.rgba(core, image) == Data([1, 2, 3, 4]))
    #expect(shm_unlink(name) < 0 && errno == ENOENT)
  }

  @Test @MainActor func slowTransportYieldsAndCancellationDropsItsResult() async throws {
    let gate = DispatchSemaphore(value: 0)
    let store = KittyGraphicsStore { _, _, _ in gate.wait(); return Data([1, 2, 3, 4]) }
    store.asynchronousTransport = true
    let context = KittyGraphicsContext(alternate: false, row: 1, column: 0, cellWidth: 8, cellHeight: 16)
    let packet = Data("Ga=T,t=f,f=32,s=1,v=1,i=1;L2ZpbGU=".utf8)
    let start = DispatchTime.now().uptimeNanoseconds
    let result = store.consume(packet, context: context, now: 0)
    #expect(result.reply == nil && store.transportPending)
    #expect(DispatchTime.now().uptimeNanoseconds - start < 100_000_000, "owner must not wait on the blocked reader")
    #expect(store.completeTransport() == nil)
    store.abort()
    gate.signal()
    #expect(!store.transportPending)
    #expect(store.visible(alternate: false, positions: [1: 0], height: 4).isEmpty)
    let completed = KittyTransport.Read(fields: [:], payload: Data(), limit: 4) { Data([1]) }
    #expect(await TestEnvironment.wait { completed.take() != nil })
  }

  @Test @MainActor func transportTimeoutAndSuccessfulAsyncReplyAreBounded() async throws {
    let gate = DispatchSemaphore(value: 0)
    let blocked = KittyTransport.Read(fields: [:], payload: Data(), limit: 4, timeout: .milliseconds(10)) {
      gate.wait(); return Data([9])
    }
    defer { gate.signal() }
    #expect(await TestEnvironment.wait { blocked.take() != nil })
    if case .failure(.notFound) = blocked.take() {} else { Issue.record("slow filesystem did not time out") }
    let store = KittyGraphicsStore { _, _, _ in Data([1, 2, 3, 4]) }
    store.asynchronousTransport = true
    let context = KittyGraphicsContext(alternate: false, row: 1, column: 0, cellWidth: 8, cellHeight: 16)
    _ = store.consume(Data("Ga=T,t=f,f=32,s=1,v=1,I=7,C=1;L2ZpbGU=".utf8), context: context, now: 0)
    var result: KittyGraphicsOutcome?
    #expect(await TestEnvironment.wait {
      if result == nil { result = store.completeTransport() }
      return result != nil
    })
    let reply = String(decoding: try #require(result?.reply), as: UTF8.self)
    #expect(reply.contains("I=7;OK") && reply.contains("i="))
    #expect(store.visible(alternate: false, positions: [1: 0], height: 4).count == 1)
  }

  @Test func lineFeedAndDeferredWrapMovePartialWidthGraphics() throws {
    for output in ["\n", "1234567"] {
      let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
      Oracle.feed(core, "\(esc)[2;2H")
      Oracle.feed(core, Oracle.command("a=T,f=24,s=1,v=1,c=1,r=1,i=1,C=1", [1, 2, 3]))
      Oracle.feed(core, "\(esc)[?69h\(esc)[2;7s\(esc)[1;3r\(esc)[3;2H" + output)
      let image = try #require(Oracle.images(core).first)
      #expect(image["row"] as? Int == 0, "partial-width scroll from \(output.debugDescription)")
    }
  }

  @Test func multipartInlineIsAtomicAndReportsCellSize() throws {
    let terminal = try #require(HeadlessTerminal(columns: 8, rows: 4))
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGOoEJFLBgACwAEOotbinwAAAABJRU5ErkJggg=="
    terminal.feed("\(esc)]1337;MultipartFile=inline=1;width=2\u{7}")
    for chunk in [String(png.prefix(20)), String(png.dropFirst(20))] {
      terminal.feed("\(esc)]1337;FilePart=\(chunk)\u{7}")
      #expect(terminal.screen()?.images.isEmpty == true)
    }
    terminal.feed("\(esc)]1337;FileEnd\u{7}")
    #expect(terminal.screen()?.images.count == 1)
    #expect(terminal.setCellSize(width: 10, height: 20))
    terminal.feed("\(esc)]1337;ReportCellSize\u{7}\(esc)]1337;Capabilities\u{7}")
    let replies = String(decoding: terminal.takeReplies(), as: UTF8.self)
    #expect(replies.contains("ReportCellSize=20;10") && replies.contains("Capabilities="))
    terminal.feed("\(esc)]1337;MultipartFile=inline=1\u{7}\(esc)]1337;FilePart=\(png)\u{18}\(esc)]1337;FileEnd\u{7}")
    #expect(terminal.screen()?.images.count == 1, "cancelled multipart must not display")
  }

  @Test func inlineGifFramesUseTheTerminalClock() throws {
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.gif.identifier as CFString, 2, nil))
    let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255]]
    for color in colors {
      let provider = try #require(CGDataProvider(data: Data(color) as CFData))
      let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      CGImageDestinationAddImage(destination, image,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    let core = try #require(helge_terminal_create(8, 4)); defer { helge_terminal_destroy(core) }
    Oracle.feed(core, "\(esc)]1337;File=inline=1:\((encoded as Data).base64EncodedString())\u{7}", now: 1000)
    let first = try #require(swiftTerminalSnapshot(core, scroll: nil, now: 1000).snapshot?.images.first)
    let second = try #require(swiftTerminalSnapshot(core, scroll: nil, now: 1100).snapshot?.images.first)
    #expect(first.generation != second.generation)
    let pixels = Oracle.Bytes()
    #expect(helge_terminal_image_rgba(core, second.image, second.generation,
      Unmanaged.passUnretained(pixels).toOpaque(), Oracle.collect))
    #expect(pixels.data == Data([0, 255, 0, 255]))
  }

  private static func encodeTestPNG(
    width: Int,
    height: Int,
    colorType: UInt8,
    samples: [UInt8],
    filterForRow: (Int) -> UInt8,
    extraChunks: [(String, [UInt8])] = [],
    splitIDAT: Bool = false
  ) throws -> Data {
    func crc32(_ bytes: [UInt8]) -> UInt32 {
      var crc = UInt32.max
      for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) == 0 ? (crc >> 1) : ((crc >> 1) ^ 0xEDB8_8320) }
      }
      return crc ^ UInt32.max
    }
    func adler32(_ bytes: [UInt8]) -> UInt32 {
      var a: UInt32 = 1, b: UInt32 = 0
      for byte in bytes {
        a = (a + UInt32(byte)) % 65_521
        b = (b + a) % 65_521
      }
      return (b << 16) | a
    }
    func appendBE32(_ out: inout [UInt8], _ value: UInt32) {
      out.append(UInt8((value >> 24) & 0xFF))
      out.append(UInt8((value >> 16) & 0xFF))
      out.append(UInt8((value >> 8) & 0xFF))
      out.append(UInt8(value & 0xFF))
    }
    func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
      var body = Array(type.utf8)
      body.append(contentsOf: payload)
      var out = [UInt8]()
      out.reserveCapacity(12 + payload.count)
      appendBE32(&out, UInt32(payload.count))
      out.append(contentsOf: body)
      appendBE32(&out, crc32(body))
      return out
    }
    func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
      let ia = Int(a), ib = Int(b), ic = Int(c)
      let p = ia + ib - ic
      let pa = abs(p - ia), pb = abs(p - ib), pc = abs(p - ic)
      if pa <= pb && pa <= pc { return a }
      if pb <= pc { return b }
      return c
    }

    let bpp = colorType == 6 ? 4 : (colorType == 2 ? 3 : 1)
    let rowBytes = width * bpp
    var raw = [UInt8]()
    raw.reserveCapacity(height * (1 + rowBytes))
    for y in 0..<height {
      let filter = filterForRow(y)
      raw.append(filter)
      let currBase = y * rowBytes
      let prevBase = (y - 1) * rowBytes
      for x in 0..<rowBytes {
        let orig = samples[currBase + x]
        let left: UInt8 = x >= bpp ? samples[currBase + x - bpp] : 0
        let up: UInt8 = y > 0 ? samples[prevBase + x] : 0
        let upLeft: UInt8 = (y > 0 && x >= bpp) ? samples[prevBase + x - bpp] : 0
        let encoded: UInt8
        switch filter {
        case 0: encoded = orig
        case 1: encoded = orig &- left
        case 2: encoded = orig &- up
        case 3: encoded = orig &- UInt8((Int(left) + Int(up)) >> 1)
        case 4: encoded = orig &- paeth(left, up, upLeft)
        default: encoded = orig
        }
        raw.append(encoded)
      }
    }

    var deflateBuffer = [UInt8](repeating: 0, count: raw.count + 1024)
    let deflateCount = raw.withUnsafeBytes { src in
      deflateBuffer.withUnsafeMutableBytes { dst in
        compression_encode_buffer(
          dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
          src.bindMemory(to: UInt8.self).baseAddress!, src.count,
          nil, COMPRESSION_ZLIB)
      }
    }
    try #require(deflateCount > 0)
    var zlib = [UInt8]()
    zlib.reserveCapacity(2 + deflateCount + 4)
    zlib.append(contentsOf: [0x78, 0x01])
    zlib.append(contentsOf: deflateBuffer[0..<deflateCount])
    appendBE32(&zlib, adler32(raw))

    var ihdr = [UInt8]()
    appendBE32(&ihdr, UInt32(width))
    appendBE32(&ihdr, UInt32(height))
    ihdr.append(contentsOf: [8, colorType, 0, 0, 0])

    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png.append(contentsOf: chunk("IHDR", ihdr))
    for (type, payload) in extraChunks {
      png.append(contentsOf: chunk(type, payload))
    }
    if splitIDAT && zlib.count > 4 {
      let mid = zlib.count / 2
      png.append(contentsOf: chunk("IDAT", Array(zlib[0..<mid])))
      png.append(contentsOf: chunk("IDAT", Array(zlib[mid..<zlib.count])))
    } else {
      png.append(contentsOf: chunk("IDAT", zlib))
    }
    png.append(contentsOf: chunk("IEND", []))
    return Data(png)
  }

  @Test func fastPNGDecoderHandlesRGBAAndRGBWithAllFiveFilters() throws {
    let width = 64, height = 32
    var rgbaSamples = [UInt8]()
    rgbaSamples.reserveCapacity(width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        rgbaSamples.append(UInt8((x &* 7 &+ y &* 13 &+ 17) & 0xFF))
        rgbaSamples.append(UInt8((x &* 19 &+ y &* 5 &+ 83) & 0xFF))
        rgbaSamples.append(UInt8((x &* 31 &+ y &* 29 &+ 211) & 0xFF))
        rgbaSamples.append(UInt8((x &* 11 &+ y &* 37 &+ 41) & 0xFF))
      }
    }
    let rgbaPNG = try Self.encodeTestPNG(
      width: width, height: height, colorType: 6, samples: rgbaSamples,
      filterForRow: { UInt8($0 % 5) },
      extraChunks: [("sRGB", [0])],
      splitIDAT: false
    )

    var rgbSamples = [UInt8]()
    var expectedRGBAsRGBA = [UInt8]()
    rgbSamples.reserveCapacity(width * height * 3)
    expectedRGBAsRGBA.reserveCapacity(width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let r = UInt8((x &* 13 &+ y &* 23 &+ 5) & 0xFF)
        let g = UInt8((x &* 29 &+ y &* 7 &+ 127) & 0xFF)
        let b = UInt8((x &* 3 &+ y &* 43 &+ 199) & 0xFF)
        rgbSamples.append(contentsOf: [r, g, b])
        expectedRGBAsRGBA.append(contentsOf: [r, g, b, 255])
      }
    }
    let rgbPNG = try Self.encodeTestPNG(
      width: width, height: height, colorType: 2, samples: rgbSamples,
      filterForRow: { UInt8(($0 + 4) % 5) },
      extraChunks: [("pHYs", [0, 0, 0x0B, 0x13, 0, 0, 0x0B, 0x13, 1])],
      splitIDAT: true
    )

    let store = KittyGraphicsStore()
    let context = KittyGraphicsContext(alternate: false, row: 1, column: 0, cellWidth: 8, cellHeight: 16)

    let rgbaOutcome = store.consume(
      Data("Ga=T,f=100,i=1,C=1;\(rgbaPNG.base64EncodedString())".utf8),
      context: context, now: 0)
    #expect(String(decoding: try #require(rgbaOutcome.reply), as: UTF8.self).contains("OK"))
    let rgbaPlacement = try #require(store.visible(alternate: false, positions: [1: 0], height: 4).first { $0.image == 1 })
    #expect(rgbaPlacement.width == width && rgbaPlacement.height == height)
    #expect(store.imageRGBA(id: rgbaPlacement.image, generation: rgbaPlacement.generation) == Data(rgbaSamples))

    let rgbOutcome = store.consume(
      Data("Ga=T,f=100,i=2,C=1;\(rgbPNG.base64EncodedString())".utf8),
      context: context, now: 0)
    #expect(String(decoding: try #require(rgbOutcome.reply), as: UTF8.self).contains("OK"))
    let rgbPlacement = try #require(store.visible(alternate: false, positions: [1: 0], height: 4).first { $0.image == 2 })
    #expect(rgbPlacement.width == width && rgbPlacement.height == height)
    #expect(store.imageRGBA(id: rgbPlacement.image, generation: rgbPlacement.generation) == Data(expectedRGBAsRGBA))
  }

  @Test func pngFallbackHandlesTRNSGrayscaleAndPalette() throws {
    let rgbTRNS = try Self.encodeTestPNG(
      width: 2, height: 1, colorType: 2,
      samples: [12, 34, 56, 78, 90, 102],
      filterForRow: { _ in 0 },
      extraChunks: [("tRNS", [0, 12, 0, 34, 0, 56])]
    )
    let grayscale = try Self.encodeTestPNG(
      width: 2, height: 1, colorType: 0,
      samples: [42, 200],
      filterForRow: { _ in 0 }
    )
    let palette = try Self.encodeTestPNG(
      width: 2, height: 1, colorType: 3,
      samples: [0, 1],
      filterForRow: { _ in 0 },
      extraChunks: [("PLTE", [255, 0, 0, 0, 255, 0]), ("tRNS", [255, 99])]
    )

    let store = KittyGraphicsStore()
    let context = KittyGraphicsContext(alternate: false, row: 1, column: 0, cellWidth: 8, cellHeight: 16)
    let cases: [(UInt32, Data, [UInt8])] = [
      (1, rgbTRNS, [12, 34, 56, 0, 78, 90, 102, 255]),
      (2, grayscale, [42, 42, 42, 255, 200, 200, 200, 255]),
      (3, palette, [255, 0, 0, 255, 0, 255, 0, 99]),
    ]
    for (id, png, expected) in cases {
      let outcome = store.consume(
        Data("Ga=T,f=100,i=\(id),C=1;\(png.base64EncodedString())".utf8),
        context: context, now: 0)
      #expect(String(decoding: try #require(outcome.reply), as: UTF8.self).contains("OK"))
      let placement = try #require(store.visible(alternate: false, positions: [1: 0], height: 4).first { $0.image == id })
      #expect(store.imageRGBA(id: placement.image, generation: placement.generation) == Data(expected))
    }
  }
}

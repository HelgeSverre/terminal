import Foundation
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
    #expect(Oracle.replies(core).contains("ENOTSUP"))
    Oracle.feed(core, Oracle.command("a=T,f=8,s=1,v=1,i=2,C=1", [1]))
    #expect(Oracle.images(core).first { $0["image"] as? Int == 2 }.flatMap { Oracle.rgba(core, $0) } == Data([101, 67, 33, 255]))
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
    terminal.feed("\(esc)P7;1q\"2;1;2;6#5@\(esc)\\")
    image = try #require(terminal.screen()?.images.last)
    pixels = try #require(terminal.pixels(of: image))
    #expect(image.pixelHeight == 12)
    #expect(pixels.prefix(8) == Data([255, 0, 0, 255, 0, 0, 0, 0]), "palette registers persist, P2=1 leaves holes")
    terminal.feed("\(esc)[3;4H\(esc)[?80h\(esc)P7q#5~\(esc)\\")
    let screen = try #require(terminal.screen())
    #expect(screen.cursorRow == 2 && screen.cursorColumn == 3)
    #expect(screen.images.last?.row == 0 && screen.images.last?.column == 0)
    terminal.feed("\(esc)[?80l\(esc)[?8452h\(esc)P7q#5~\(esc)\\")
    #expect(terminal.screen()?.cursorRow == 2 && terminal.screen()?.cursorColumn == 4)
  }

  @Test func sharedMemoryTransportReadsOffsetAndUnlinksObject() throws {
    let name = "/htg" + String(UUID().uuidString.prefix(16))
    let create = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open")!,
      to: (@convention(c) (UnsafePointer<CChar>, Int32, mode_t) -> Int32).self)
    let descriptor = name.withCString { create($0, O_CREAT | O_EXCL | O_RDWR, 0o600) }
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
    #expect(await TestEnvironment.wait { result = store.completeTransport(); return result != nil })
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
    for color: [UInt8] in [[255, 0, 0, 255], [0, 255, 0, 255]] {
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
}

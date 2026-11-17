import Foundation
import Testing
@testable import TerminalEngine
import TerminalInterop

/// The parts of the Kitty graphics protocol beyond transmit, place and
/// delete-by-id: image numbers, file transport, every delete selector and
/// Unicode placeholders.
@Suite struct KittyGraphicsExtensionTests {
  private let esc = "\u{1b}"

  /// A terminal of 40 by 10 cells of 10 by 20 pixels.
  private final class Terminal {
    let core: OpaquePointer
    init() {
      core = helge_terminal_create(40, 10)!
      _ = helge_terminal_resize_pixels(core, 40, 10, 10, 20)
    }
    deinit { helge_terminal_destroy(core) }
    func feed(_ text: String, at now: UInt64 = 0) {
      let bytes = Array(text.utf8)
      bytes.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < buffer.count || helge_terminal_has_work(core) {
          let count = helge_terminal_feed(core, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, now)
          offset += count
          if count == 0 && !helge_terminal_has_work(core) { break }
        }
      }
    }
    func replies() -> String {
      final class Box { var data = Data() }
      let box = Box()
      helge_terminal_replies(core, Unmanaged.passUnretained(box).toOpaque()) { context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().data.append(bytes, count: count)
      }
      return String(decoding: box.data, as: UTF8.self)
    }
    var images: [ImagePlacementSnapshot] { swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot?.images ?? [] }
  }

  /// `width` by `height` pixels of RGBA, all `byte`.
  private func pixels(_ width: Int, _ height: Int, _ byte: UInt8 = 200) -> String {
    Data(repeating: byte, count: width * height * 4).base64EncodedString()
  }
  private func transmit(_ keys: String, _ width: Int = 20, _ height: Int = 20) -> String {
    "\(esc)_Ga=T,f=32,s=\(width),v=\(height),\(keys);\(pixels(width, height))\(esc)\\"
  }

  @Test func imageNumbersNameTheNewestImage() {
    let terminal = Terminal()
    terminal.feed(transmit("I=7"))
    let reply = terminal.replies()
    #expect(reply.hasPrefix("\(esc)_Gi=") && reply.hasSuffix(",I=7;OK\(esc)\\"), "\(reply.debugDescription)")
    terminal.feed("\(esc)[5;1H\(esc)_Ga=p,I=7,q=2\(esc)\\")
    #expect(terminal.images.count == 2)
    terminal.feed("\(esc)_Ga=d,d=N,I=7,q=2\(esc)\\")
    #expect(terminal.images.isEmpty)
    terminal.feed("\(esc)_Ga=T,f=32,s=1,v=1,i=3,I=4;AAAAAA==\(esc)\\")
    #expect(terminal.replies().contains("EINVAL"), "an id and a number together are refused")
  }

  @Test func filesAndTemporaryFilesAreRead() throws {
    let terminal = Terminal()
    let directory = FileManager.default.temporaryDirectory
    let raw = Data(repeating: 90, count: 4 * 4 * 4)
    let file = directory.appendingPathComponent("kitty-file-\(UUID().uuidString).rgba")
    try raw.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    func path(_ url: URL) -> String { Data(url.path.utf8).base64EncodedString() }

    terminal.feed("\(esc)_Ga=T,t=f,f=32,s=4,v=4,i=11;\(path(file))\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=11;OK\(esc)\\")
    #expect(terminal.images.count == 1)
    #expect(FileManager.default.fileExists(atPath: file.path), "a plain file is left alone")

    // A temporary file is deleted once read, but only one that says what it is.
    let temporary = directory.appendingPathComponent("tty-graphics-protocol-\(UUID().uuidString)")
    try raw.write(to: temporary)
    terminal.feed("\(esc)_Ga=t,t=t,f=32,s=4,v=4,i=12;\(path(temporary))\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=12;OK\(esc)\\")
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    terminal.feed("\(esc)_Ga=t,t=t,f=32,s=4,v=4,i=13;\(path(file))\(esc)\\")
    #expect(terminal.replies().contains("EINVAL"))
    #expect(FileManager.default.fileExists(atPath: file.path))

    // Offset and size pick a part of the file; devices and missing files are refused.
    try (Data(repeating: 1, count: 16) + raw).write(to: file)
    terminal.feed("\(esc)_Ga=t,t=f,f=32,s=4,v=4,O=16,S=64,i=14;\(path(file))\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=14;OK\(esc)\\")
    terminal.feed("\(esc)_Ga=t,t=f,f=32,s=4,v=4,i=15;\(Data("/dev/zero".utf8).base64EncodedString())\(esc)\\")
    #expect(terminal.replies().contains("EINVAL"))
    terminal.feed("\(esc)_Ga=t,t=f,f=32,s=4,v=4,i=16;\(Data("/no/such/file".utf8).base64EncodedString())\(esc)\\")
    #expect(terminal.replies().contains("ENOENT"))
  }

  @Test func everyDeleteSelectorFindsItsPlacements() {
    // Three 2-by-1-cell images: at row 1 column 1, row 1 column 11, and row 4 column 1 with z=5.
    func scene() -> Terminal {
      let terminal = Terminal()
      terminal.feed("\(esc)[1;1H" + transmit("i=1,q=2"))
      terminal.feed("\(esc)[1;11H" + transmit("i=2,q=2"))
      terminal.feed("\(esc)[4;1H" + transmit("i=3,z=5,q=2"))
      #expect(terminal.images.count == 3)
      return terminal
    }
    func left(_ delete: String, cursor: String = "") -> [UInt32] {
      let terminal = scene()
      terminal.feed(cursor + "\(esc)_Ga=d,q=2,\(delete)\(esc)\\")
      return terminal.images.map(\.image).sorted()
    }
    #expect(left("d=p,x=12,y=1") == [1, 3], "the cell x,y, counted from 1")
    #expect(left("d=p,x=20,y=1") == [1, 2, 3], "a cell no image covers")
    #expect(left("d=q,x=1,y=4,z=5") == [1, 2])
    #expect(left("d=q,x=1,y=4,z=0") == [1, 2, 3], "the z must match")
    #expect(left("d=x,x=2") == [2], "a column")
    #expect(left("d=y,y=1") == [3], "a row")
    #expect(left("d=c", cursor: "\(esc)[4;2H") == [1, 2], "the cursor's cell")
    #expect(left("d=r,x=2,y=3") == [1], "a range of ids")
    #expect(left("d=z,z=5") == [1, 2])
    #expect(left("d=a") == [])
    #expect(left("d=f") == [1, 2, 3], "no animation frames to delete")
  }

  @Test func uppercaseDeletesFreeTheImageToo() {
    let terminal = Terminal()
    terminal.feed(transmit("i=1,q=2"))
    terminal.feed("\(esc)_Ga=d,d=y,y=1,q=2\(esc)\\")
    terminal.feed("\(esc)_Ga=p,i=1\(esc)\\")
    #expect(terminal.replies().contains("OK"), "lowercase keeps the image")
    terminal.feed("\(esc)_Ga=d,d=Y,y=2,q=2\(esc)\\")
    terminal.feed("\(esc)_Ga=p,i=1\(esc)\\")
    #expect(terminal.replies().contains("ENOENT"), "uppercase frees it")
  }

  /// A placeholder cell: U+10EEEE with the row and column marks.
  private func placeholder(row: Int?, column: Int?) -> String {
    var text = "\u{10EEEE}"
    if let row { text.unicodeScalars.append(Unicode.Scalar(KittyPlaceholder.diacritics[row])!) }
    if let column { text.unicodeScalars.append(Unicode.Scalar(KittyPlaceholder.diacritics[column])!) }
    return text
  }

  @Test func placeholdersShowSlicesOfAVirtualPlacement() throws {
    let terminal = Terminal()
    // A 20-by-20-pixel image in a virtual placement of 4 by 2 cells
    // (40 by 40 pixels): it fills them at twice its size. The cursor does not move.
    terminal.feed("\(esc)_Ga=T,U=1,i=5,c=4,r=2,f=32,s=20,v=20;\(pixels(20, 20))\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=5;OK\(esc)\\")
    #expect(terminal.images.isEmpty, "a virtual placement shows nothing by itself")
    let cursor = swiftTerminalSnapshot(terminal.core, scroll: nil, now: 0).snapshot!.cursor
    #expect(cursor.row == 0 && cursor.col == 0)

    // Row 0 written in full with marks; row 1 with marks on its first cell only.
    terminal.feed("\(esc)[38;5;5m" + (0..<4).map { placeholder(row: 0, column: $0) }.joined() + "\(esc)[0m\r\n")
    terminal.feed("\(esc)[38;5;5m" + placeholder(row: 1, column: 0) + String(repeating: placeholder(row: nil, column: nil), count: 3) + "\(esc)[0m")
    let slices = terminal.images.sorted { $0.row < $1.row }
    #expect(slices.count == 2, "one slice for each run")
    let top = try #require(slices.first), bottom = try #require(slices.last)
    #expect(top.row == 0 && top.col == 0 && top.columns == 4 && top.rows == 1)
    #expect(top.source == [0, 0, 20, 10] && top.extent == [40, 20])
    #expect(bottom.row == 1 && bottom.source == [0, 10, 20, 10], "unmarked cells continue the row to their left")
  }

  @Test func placeholderImagesAreNamedByTheirColor() throws {
    let terminal = Terminal()
    // Id 0x010203 by 24-bit color, a wide image centered in a square box.
    terminal.feed("\(esc)_Ga=T,U=1,i=66051,c=2,r=2,f=32,s=20,v=10,q=2;\(pixels(20, 10))\(esc)\\")
    terminal.feed("\(esc)[38;2;1;2;3m" + placeholder(row: 0, column: 0) + placeholder(row: 0, column: 1) + "\r\n"
      + placeholder(row: 1, column: 0) + placeholder(row: 1, column: 1) + "\(esc)[0m")
    let slices = terminal.images.sorted { $0.row < $1.row }
    // The box is 20 by 40 pixels; the image fits at 20 by 10, from y=15.
    #expect(slices.count == 2)
    let top = try #require(slices.first)
    #expect(top.offset == [0, 15] && top.extent == [20, 5] && top.source == [0, 0, 20, 5])
    // A color that names no image, and a different placement, show nothing.
    terminal.feed("\r\n\(esc)[38;5;9m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    terminal.feed("\(esc)[38;2;1;2;3;58;5;7m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    #expect(terminal.images.count == 2)
  }

  @Test func aPlacementCanHangFromAnother() throws {
    let terminal = Terminal()
    terminal.feed("\(esc)[3;5H" + transmit("i=1,p=1,q=2"))           // parent at row 2, column 4
    terminal.feed("\(esc)[1;1H" + transmit("i=2,p=1,P=1,Q=1,H=3,V=-1,q=2"))
    let cursor = swiftTerminalSnapshot(terminal.core, scroll: nil, now: 0).snapshot!.cursor
    #expect(cursor.row == 0 && cursor.col == 0, "a relative placement does not move the cursor")
    let child = try #require(terminal.images.first { $0.image == 2 })
    #expect(child.row == 1 && child.col == 7)
    // A grandchild, then the parent moves: both follow.
    terminal.feed(transmit("i=3,p=1,P=2,Q=1,H=1,V=1,q=2"))
    #expect(terminal.images.first { $0.image == 3 }.map { [$0.row, $0.col] } == [2, 8])
    terminal.feed("\(esc)[6;1H\(esc)_Ga=p,i=1,p=1,q=2\(esc)\\")
    #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [4, 3])
    #expect(terminal.images.first { $0.image == 3 }.map { [$0.row, $0.col] } == [5, 4])
    // Deleting the parent takes its children with it.
    terminal.feed("\(esc)_Ga=d,d=i,i=1,q=2\(esc)\\")
    #expect(terminal.images.isEmpty)
  }

  @Test func relativePlacementsAreChecked() {
    let terminal = Terminal()
    terminal.feed(transmit("i=1,p=1,q=2"))
    terminal.feed(transmit("i=2,p=1,P=9,Q=9"))
    #expect(terminal.replies().contains("ENOPARENT"))
    terminal.feed("\(esc)_Ga=p,i=1,p=1,P=1,Q=1\(esc)\\")
    #expect(terminal.replies().contains("ECYCLE"), "a placement cannot hang from itself")
    var parent = 1
    for id in 2...9 {
      terminal.feed(transmit("i=\(id),p=1,P=\(parent),Q=1,H=1"))
      parent = id
    }
    #expect(terminal.replies().contains("ETOODEEP"))
  }

  /// One 1-by-1 pixel of RGBA.
  private func dot(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String { Data([r, g, b, 255]).base64EncodedString() }
  private func frameColor(_ terminal: Terminal, at now: UInt64) -> [UInt8]? {
    guard let shown = swiftTerminalSnapshot(terminal.core, scroll: nil, now: now).snapshot?.images.first else { return nil }
    final class Box { var data = Data() }
    let box = Box()
    _ = helge_terminal_image_rgba(terminal.core, shown.image, shown.generation, Unmanaged.passUnretained(box).toOpaque()) {
      context, bytes, count in
      guard let context, let bytes else { return }
      Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
    }
    return Array(box.data.prefix(4))
  }

  @Test func framesPlayInTurnAndLoop() {
    let terminal = Terminal()
    // A red pixel, then a green frame shown for 100 ms and a blue one for 50 ms.
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=1,v=1,q=2;\(dot(255, 0, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=100,q=2;\(dot(0, 255, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=50;\(dot(0, 0, 255))\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=4;OK\(esc)\\")
    #expect(frameColor(terminal, at: 0) == [255, 0, 0, 255], "stopped until told to run")
    #expect(helge_terminal_next_frame_delay(terminal.core, 0) == -1)

    // Give the otherwise gapless root a 40 ms gap, then loop for ever.
    terminal.feed("\(esc)_Ga=a,i=4,r=1,z=40,s=3,q=2\(esc)\\", at: 1000)
    #expect(frameColor(terminal, at: 1000) == [255, 0, 0, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 1000) == 40)
    #expect(frameColor(terminal, at: 1040) == [0, 255, 0, 255])
    #expect(frameColor(terminal, at: 1139) == [0, 255, 0, 255])
    #expect(frameColor(terminal, at: 1140) == [0, 0, 255, 255])
    #expect(frameColor(terminal, at: 1190) == [255, 0, 0, 255], "back to the first frame")
    #expect(frameColor(terminal, at: 1000 + 190 * 1000 + 45) == [0, 255, 0, 255], "a thousand loops later")

    // Stop on a chosen frame.
    terminal.feed("\(esc)_Ga=a,i=4,s=1,c=3,q=2\(esc)\\", at: 400_000)
    #expect(frameColor(terminal, at: 500_000) == [0, 0, 255, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 500_000) == -1)
  }

  @Test func loadingWaitsOnTheLastFrameAndLoopsCanBeCounted() {
    let terminal = Terminal()
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=1,v=1,q=2;\(dot(255, 0, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=100,q=2;\(dot(0, 255, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=a,i=4,r=1,z=40,s=2,q=2\(esc)\\")
    #expect(frameColor(terminal, at: 10_000) == [0, 255, 0, 255], "waits on the last frame")
    // Two loops: red 40, green 100, red 40, green 100, then it stays green.
    terminal.feed("\(esc)_Ga=a,i=4,s=3,c=1,v=3,q=2\(esc)\\", at: 20_000)
    #expect(frameColor(terminal, at: 20_000 + 150) == [255, 0, 0, 255], "second time round")
    #expect(frameColor(terminal, at: 20_000 + 285) == [0, 255, 0, 255])
    #expect(frameColor(terminal, at: 20_000 + 400) == [0, 255, 0, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 20_400) == -1)
  }

  @Test func framesAreBuiltOnABaseAndComposed() throws {
    let terminal = Terminal()
    // A 2-by-1 image: red, red.
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=2,v=1,q=2;\(Data([255, 0, 0, 255, 255, 0, 0, 255]).base64EncodedString())\(esc)\\")
    // Frame 2: frame 1 with a blue pixel at x=1.
    terminal.feed("\(esc)_Ga=f,i=4,c=1,x=1,f=32,s=1,v=1,q=2;\(dot(0, 0, 255))\(esc)\\")
    // Frame 3: transparent, half-transparent green at x=0.
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,q=2;\(Data([0, 255, 0, 128]).base64EncodedString())\(esc)\\")
    // Compose frame 2's blue pixel onto frame 3 at x=0, blending.
    terminal.feed("\(esc)_Ga=c,i=4,r=2,c=3,X=1,Y=0,x=0,y=0,w=1,h=1,q=2\(esc)\\")
    func frame(_ number: Int) -> [UInt8] {
      terminal.feed("\(esc)_Ga=a,i=4,s=1,c=\(number),q=2\(esc)\\")
      final class Box { var data = Data() }
      let box = Box()
      let shown = swiftTerminalSnapshot(terminal.core, scroll: nil, now: 0).snapshot!.images[0]
      _ = helge_terminal_image_rgba(terminal.core, shown.image, shown.generation, Unmanaged.passUnretained(box).toOpaque()) {
        context, bytes, count in
        guard let context, let bytes else { return }
        Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
      }
      return Array(box.data)
    }
    #expect(frame(2) == [255, 0, 0, 255, 0, 0, 255, 255])
    #expect(frame(3) == [0, 0, 255, 255, 0, 0, 0, 0], "an opaque pixel covers what is below")
    #expect(frame(1) == [255, 0, 0, 255, 255, 0, 0, 255], "the base frame is unchanged")
    terminal.feed("\(esc)_Gi=4,a=f,r=9,f=32,s=1,v=1;\(dot(0, 0, 0))\(esc)\\")
    #expect(terminal.replies().contains("ENOENT"), "a frame that does not exist")
  }

  @Test func compositionRejectsOverlapAndMissingFramesAtomically() throws {
    let terminal = Terminal()
    let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255]
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=2,v=2,q=2;\(Data(red + red + red + blue).base64EncodedString())\(esc)\\")
    let original = try #require(terminal.images.first)
    for fields in ["r=1,c=1,w=2,h=2", "r=1,c=1,X=1,Y=1,x=1,y=1,w=1,h=1"] {
      terminal.feed("\(esc)_Ga=c,i=4,\(fields)\(esc)\\")
      #expect(terminal.replies() == "\(esc)_Gi=4;EINVAL:invalid graphics command or image data\(esc)\\")
      #expect(terminal.images.first?.generation == original.generation)
      #expect(frameColor(terminal, at: 0) == red)
    }
    terminal.feed("\(esc)_Ga=c,i=4,r=2,c=1\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=4;ENOENT:image not found\(esc)\\")
    #expect(terminal.images.first?.generation == original.generation)
    // Missing dimensions mean the full image, not the remainder after X/Y.
    terminal.feed("\(esc)_Ga=c,i=4,r=1,c=1,X=1\(esc)\\")
    #expect(terminal.replies().contains("EINVAL"))
    #expect(terminal.images.first?.generation == original.generation)
    // Disjoint rectangles in the same frame are legal. Exercise both axes.
    terminal.feed("\(esc)_Ga=c,i=4,r=1,c=1,X=1,Y=1,x=0,y=0,w=1,h=1,C=1\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=4;OK\(esc)\\")
    #expect(terminal.images.first?.generation != original.generation)
    #expect(frameColor(terminal, at: 0) == blue)
  }

  @Test func theTerminalSaysWhatItSupports() {
    let terminal = Terminal()
    terminal.feed("\(esc)_Gi=31,a=q,e=t,t=f,U=1;\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=31,e=t,t=f;OK\(esc)\\")
  }

  @Test func featureQueriesAreActionSpecificAndIgnoreDefaults() {
    let terminal = Terminal()
    func query(_ action: String, _ fields: String, _ expected: String) {
      terminal.feed("\(esc)_Ga=q,i=31,e=\(action),\(fields);ignored payload\(esc)\\")
      #expect(terminal.replies() == "\(esc)_Gi=31\(expected);OK\(esc)\\")
    }
    query("T", "C=1,U=1,c=0,t=d,f=32,m=1", ",e=T,C=1,U=1")
    query("f", "r=1,X=1,U=1,C=1,z=-1", ",e=f,X=1,r=1,z=-1")
    query("a", "s=3,v=1,c=2,r=1,z=0,U=1", ",e=a,c=2,r=1,s=3")
    query("c", "C=1,r=2,c=3,U=1,t=f", ",e=c,C=1,c=3,r=2")
    query("d", "d=f,r=2,t=f,U=1", ",e=d,d=f,r=2")
    query("p", "f=24,s=10,P=1,Q=2,H=-3,z=5", ",e=p,H=-3,P=1,Q=2,z=5")
    query("q", "f=24,t=s,s=1,v=1,U=1", ",e=q,f=24,s=1,t=s,v=1")
    query("t", "f=8,t=invalid,s=4294967295,U=1", ",e=t")
    query("a", "s=4,v=0,c=-1", ",e=a")
    query("j", "U=1,p=7", "")
    #expect(terminal.images.isEmpty)
  }

  @Test func featureQueriesPreservePendingUploads() {
    let terminal = Terminal()
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=1,v=1,m=1;\(dot(255, 0, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=q,i=31,e=T,U=1,m=1;not base64\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=31,e=T,U=1;OK\(esc)\\")
    terminal.feed("\(esc)_Ga=q,i=31,I=7,e=T\(esc)\\")
    #expect(terminal.replies().contains("EINVAL"))
    terminal.feed("\(esc)_Gm=0\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=4;OK\(esc)\\")
    #expect(frameColor(terminal, at: 0) == [255, 0, 0, 255])
  }

  @Test func rootFrameIsGaplessAndZeroGapEditsAreIgnored() {
    let terminal = Terminal()
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=1,v=1,q=2;\(dot(255, 0, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,q=2;\(dot(0, 255, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=60,q=2;\(dot(0, 0, 255))\(esc)\\")
    terminal.feed("\(esc)_Ga=a,i=4,s=3,q=2\(esc)\\", at: 1000)
    #expect(frameColor(terminal, at: 1000) == [0, 255, 0, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 1000) == 40)
    #expect(frameColor(terminal, at: 1040) == [0, 0, 255, 255])
    #expect(frameColor(terminal, at: 1100) == [0, 255, 0, 255])
    terminal.feed("\(esc)_Ga=a,i=4,s=1,c=1,r=1,z=25,q=2\(esc)\\", at: 1200)
    terminal.feed("\(esc)_Ga=a,i=4,r=1,z=0,s=3,q=2\(esc)\\", at: 1200)
    #expect(frameColor(terminal, at: 1200) == [255, 0, 0, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 1200) == 25)
  }

  @Test func frameDeletionPromotesRenumbersAndPreservesPixels() throws {
    let terminal = Terminal()
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=1,v=1,q=2;\(dot(255, 0, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=60,q=2;\(dot(0, 255, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=80,q=2;\(dot(0, 0, 255))\(esc)\\")
    terminal.feed("\(esc)_Ga=a,i=4,s=1,c=2,q=2\(esc)\\")
    let green = try #require(terminal.images.first).generation
    terminal.feed("\(esc)_Ga=d,d=f,i=4,r=1,q=2\(esc)\\")
    #expect(frameColor(terminal, at: 0) == [0, 255, 0, 255])
    #expect(terminal.images.first?.generation == green, "promotion preserves resource identity")
    terminal.feed("\(esc)_Ga=a,i=4,s=3,q=2\(esc)\\", at: 1000)
    #expect(helge_terminal_next_frame_delay(terminal.core, 1000) == 60)
    #expect(frameColor(terminal, at: 1060) == [0, 0, 255, 255])
    terminal.feed("\(esc)_Ga=d,d=f,i=4,r=2,q=2\(esc)\\", at: 1060)
    #expect(frameColor(terminal, at: 1060) == [0, 255, 0, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 1060) == -1)
    terminal.feed("\(esc)_Ga=a,i=4,c=2\(esc)\\")
    #expect(terminal.replies().contains("EINVAL"), "deleted frame number is gone")
    terminal.feed("\(esc)_Ga=d,d=f,i=4,q=2\(esc)\\")
    #expect(terminal.images.count == 1, "lowercase keeps the last frame")
    terminal.feed("\(esc)_Ga=d,d=F,i=4,q=2\(esc)\\")
    #expect(terminal.images.isEmpty, "uppercase deletes the last frame and its placements")
  }

  @Test func relativeChildrenFollowVirtualPlaceholderGeometry() throws {
    let terminal = Terminal()
    terminal.feed(transmit("i=1,p=1,U=1,c=1,r=1,q=2", 1, 1))
    terminal.feed(transmit("i=2,p=1,P=1,Q=1,H=2,V=1,q=2", 1, 1))
    #expect(terminal.images.isEmpty)
    terminal.feed("\(esc)[3;5H\(esc)[38;5;1m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [3, 6])
    terminal.feed("\(esc)[5;3H\(esc)[38;5;1m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [3, 4], "independent minimum x and y")
    terminal.feed("\(esc)[3;1H\(esc)[2K")
    #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [5, 4])
    // No snapshot between text movement and deletion: command geometry must be current.
    terminal.feed("\(esc)[5;1H\(esc)[2K\(esc)[7;8H\(esc)[38;5;1m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    terminal.feed("\(esc)_Ga=d,d=p,x=10,y=8,q=2\(esc)\\")
    #expect(!terminal.images.contains { $0.image == 2 })
    #expect(terminal.images.contains { $0.image == 1 }, "virtual parent survives positional deletion")
  }

  @Test func positionalDeletionUsesResolvedRelativeOrigins() {
    for deletion in ["d=p,x=8,y=2", "d=q,x=8,y=2,z=7", "d=x,x=8", "d=y,y=2", "d=c"] {
      let terminal = Terminal()
      terminal.feed("\(esc)[3;5H" + transmit("i=1,p=1,q=2", 1, 1))
      terminal.feed("\(esc)[1;1H" + transmit("i=2,p=1,P=1,Q=1,H=3,V=-1,z=7,q=2", 1, 1))
      terminal.feed("\(esc)[2;8H\(esc)_Ga=d,\(deletion),q=2\(esc)\\")
      #expect(terminal.images.map(\.image) == [1], "\(deletion) deletes the child at its resolved position")
    }
  }

  @Test func animationEditsPreserveElapsedTimeAndCompletedLoops() {
    let terminal = Terminal()
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=1,v=1,q=2;\(dot(255, 0, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=60,q=2;\(dot(0, 255, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,z=80,q=2;\(dot(0, 0, 255))\(esc)\\")
    terminal.feed("\(esc)_Ga=a,i=4,r=1,z=40,s=3,v=3,q=2\(esc)\\", at: 1000)
    terminal.feed("\(esc)_Ga=d,d=f,i=4,r=3,q=2\(esc)\\", at: 1010)
    #expect(helge_terminal_next_frame_delay(terminal.core, 1010) == 30, "deleting a different frame preserves elapsed time")
    terminal.feed("\(esc)_Ga=a,i=4,r=1,z=0,q=2\(esc)\\", at: 1150)
    #expect(frameColor(terminal, at: 1150) == [0, 255, 0, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 1150) == -1, "an edit does not restart completed loops")
    #expect(frameColor(terminal, at: 1300) == [0, 255, 0, 255])
    terminal.feed("\(esc)_Ga=a,i=4,s=1,c=1,q=2\(esc)\\", at: 1400)
    terminal.feed("\(esc)_Ga=a,i=4,s=3,q=2\(esc)\\", at: 1500)
    #expect(frameColor(terminal, at: 1600) == [255, 0, 0, 255], "stopping resets the loop counter")
  }

  @Test func rootFrameDataEditsCanSetItsGap() {
    let terminal = Terminal()
    terminal.feed("\(esc)_Ga=T,i=4,f=32,s=1,v=1,q=2;\(dot(255, 0, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,f=32,s=1,v=1,q=2;\(dot(0, 255, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=f,i=4,r=1,z=25,f=32,s=1,v=1,q=2;\(dot(0, 0, 255))\(esc)\\")
    terminal.feed("\(esc)_Ga=a,i=4,s=3,q=2\(esc)\\", at: 1000)
    #expect(frameColor(terminal, at: 1000) == [0, 0, 255, 255])
    #expect(helge_terminal_next_frame_delay(terminal.core, 1000) == 25)
  }

  @Test func framePromotionDoesNotChangeImageNumberOrder() throws {
    let terminal = Terminal()
    terminal.feed(transmit("I=7,q=2", 1, 1))
    let old = try #require(terminal.images.first).image
    terminal.feed(transmit("I=7,q=2", 1, 1))
    terminal.feed("\(esc)_Ga=f,i=\(old),f=32,s=1,v=1,q=2;\(dot(0, 255, 0))\(esc)\\")
    terminal.feed("\(esc)_Ga=d,d=f,i=\(old),r=1,q=2\(esc)\\")
    terminal.feed("\(esc)_Ga=d,d=F,I=7,q=2\(esc)\\")
    #expect(terminal.images.map(\.image) == [old], "I names the newest image, not the most recently edited frame")
  }

  @Test func frameDeletionReleasesStorageAndAbortsPartialUpload() {
    let store = KittyGraphicsStore()
    let context = KittyGraphicsContext(alternate: false, row: 1, column: 0, cellWidth: 10, cellHeight: 20)
    func send(_ header: String, _ body: String = "") {
      _ = store.consume(Data("G\(header);\(body)".utf8), context: context, now: 0)
    }
    send("a=T,i=4,f=32,s=1,v=1", dot(255, 0, 0))
    send("a=f,i=4,f=32,s=1,v=1", dot(0, 255, 0))
    #expect(store.accountedBytes == 8)
    send("a=f,i=4,f=32,s=1,v=1,m=1", dot(0, 0, 255))
    #expect(store.accountedBytes == 12)
    send("a=d,d=f,i=4,r=1")
    #expect(store.accountedBytes == 4)
    send("a=d,d=f,i=4,r=99")
    #expect(store.accountedBytes == 4)
    send("a=d,d=F,i=4")
    #expect(store.accountedBytes == 0)
  }

  @Test func virtualParentFollowsActiveScreenAndScrollback() {
    let terminal = Terminal()
    terminal.feed(transmit("i=1,p=1,U=1,c=1,r=1,q=2", 1, 1))
    terminal.feed(transmit("i=2,p=1,P=1,Q=1,H=2,V=3,q=2", 1, 1))
    terminal.feed("\(esc)[1;1H\(esc)[38;5;1m" + placeholder(row: 0, column: 0) + "\(esc)[0m\(esc)[10;1H\n")
    #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [2, 2], "parent above viewport can anchor visible child")
    helge_terminal_set_history_limit(terminal.core, 0)
    #expect(!terminal.images.contains { $0.image == 2 }, "history eviction invalidates cached parent geometry")
    terminal.feed("\(esc)[?1049h\(esc)[2;5H\(esc)[38;5;1m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [4, 6], "virtual parent belongs to the text's screen")
    terminal.feed("\(esc)[?1049l\(esc)_Ga=d,d=i,i=1,q=2\(esc)\\")
    terminal.feed("\(esc)_Ga=p,i=2,p=3\(esc)\\")
    #expect(terminal.replies().contains("ENOENT"), "orphaned relative image is freed with its last placement")
  }

  @Test func virtualParentsWithLargeHistory() {
    let terminal = Terminal()
    helge_terminal_set_history_limit(terminal.core, 50_000)
    terminal.feed(String(repeating: "ordinary history\r\n", count: 20_000))
    terminal.feed(transmit("i=1,p=1,U=1,c=1,r=1,q=2", 1, 1))
    terminal.feed(transmit("i=2,p=1,P=1,Q=1,H=2,V=1,q=2", 1, 1))
    terminal.feed("\(esc)[3;5H\(esc)[38;5;1m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [3, 6])
    let start = DispatchTime.now().uptimeNanoseconds
    for tick in 0..<100 {
      let images = swiftTerminalSnapshot(terminal.core, scroll: nil, now: UInt64(tick)).snapshot?.images ?? []
      #expect(images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [3, 6])
    }
    print("Kitty virtual-parent snapshots, 20k history rows, 100 ticks: \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) ms")
    let outputStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<100 {
      terminal.feed("\(esc)[1;1Hordinary output")
      #expect(terminal.images.first { $0.image == 2 }.map { [$0.row, $0.col] } == [3, 6])
    }
    print("Kitty virtual-parent snapshots with live edits, 20k history rows, 100 updates: \(Double(DispatchTime.now().uptimeNanoseconds - outputStart) / 1_000_000) ms")
    terminal.feed("\(esc)[3;1H\(esc)[2K")
    #expect(!terminal.images.contains { $0.image == 2 }, "text mutation invalidates the cached geometry")
  }

  @Test func frameDeletionRejectsBothIdentityKeysWithoutMutation() {
    for selectors in ["i=0,I=7", "I=7,i=0", "i=4,I=0"] {
      let terminal = Terminal()
      terminal.feed(transmit("I=7,q=2", 1, 1))
      terminal.feed("\(esc)_Ga=d,d=F,\(selectors)\(esc)\\")
      #expect(terminal.replies().contains("EINVAL"))
      #expect(terminal.images.count == 1)
    }
  }

  @Test func virtualParentCacheFollowsNewHistoryRows() {
    let terminal = Terminal()
    terminal.feed(transmit("i=1,p=1,U=1,c=1,r=1,q=2", 1, 1))
    terminal.feed(transmit("i=2,p=1,P=1,Q=1,H=2,V=4,q=2", 1, 1))
    terminal.feed("\(esc)[3;5H\(esc)[38;5;1m" + placeholder(row: 0, column: 0) + "\(esc)[0m")
    #expect(terminal.images.first { $0.image == 2 }?.row == 6)
    for scroll in 1...5 {
      terminal.feed("\(esc)[10;1H\r\n")
      #expect(terminal.images.first { $0.image == 2 }?.row == 6 - scroll)
    }
    helge_terminal_set_history_limit(terminal.core, 0)
    #expect(!terminal.images.contains { $0.image == 2 })
  }

  @Test func placementRejectsBothIdentityKeys() {
    let terminal = Terminal()
    terminal.feed(transmit("I=7,q=2", 1, 1))
    terminal.feed("\(esc)_Ga=p,i=0,I=7\(esc)\\")
    #expect(terminal.replies().contains("EINVAL"))
    #expect(terminal.images.count == 1)
  }

  @Test func currentKittenLargeChunksAndUnpaddedBase64() {
    let terminal = Terminal()
    let payload = pixels(256, 128).replacingOccurrences(of: "=", with: "")
    let split = payload.index(payload.startIndex, offsetBy: 128 * 1024)
    terminal.feed("\(esc)_Ga=T,i=8,f=32,s=256,v=128,m=1;\(payload[..<split])\(esc)\\")
    #expect(terminal.images.isEmpty)
    terminal.feed("\(esc)_Ga=T,m=0;\(payload[split...])\(esc)\\")
    #expect(terminal.replies().contains("OK"))
    #expect(terminal.images.first?.image == 8)
  }

  @Test func largeChunkCompatibilityRemainsBoundedAndCanonical() {
    for payload in [String(repeating: "A", count: 128 * 1024 + 4), "AAAAAB", "AAAAAA="] {
      let terminal = Terminal()
      terminal.feed("\(esc)_Ga=T,i=8,f=32,s=1,v=1;\(payload)\(esc)\\")
      #expect(terminal.images.isEmpty)
      #expect(terminal.replies().contains("EINVAL"))
    }
  }
}

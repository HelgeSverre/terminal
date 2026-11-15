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
    func feed(_ text: String) {
      let bytes = Array(text.utf8)
      bytes.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < buffer.count || helge_terminal_has_work(core) {
          let count = helge_terminal_feed(core, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
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

  @Test func theTerminalSaysWhatItSupports() {
    let terminal = Terminal()
    terminal.feed("\(esc)_Gi=31,a=q,e=t,t=f,U=1,I=2;\(esc)\\")
    #expect(terminal.replies() == "\(esc)_Gi=31,e=t,I=2,U=1,t=f;OK\(esc)\\")
  }
}

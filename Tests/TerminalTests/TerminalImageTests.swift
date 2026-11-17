import CoreGraphics
import Foundation
import ImageIO
import Testing
import TerminalEngine
import UniformTypeIdentifiers

/// Sixel pictures and iTerm2 inline images, through the public emulator.
@Suite struct TerminalImageTests {
  private let esc = "\u{1b}"

  /// A PNG of `width` by `height` pixels, each `rgba`.
  private func png(width: Int, height: Int, rgba: [UInt8] = [255, 0, 0, 255]) throws -> Data {
    var pixels = [UInt8]()
    for _ in 0..<(width * height) { pixels.append(contentsOf: rgba) }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
  private func inline(_ file: Data, _ arguments: String, terminator: String = "\u{07}") -> String {
    "\(esc)]1337;File=\(arguments):\(file.base64EncodedString())\(terminator)"
  }
  private func pixel(_ data: Data, _ index: Int) -> [UInt8] { Array(data[(index * 4)..<(index * 4 + 4)]) }

  @Test func aSixelPictureIsDecodedAndTheCursorMovesBelowIt() throws {
    let terminal = try #require(HeadlessTerminal(columns: 40, rows: 10))
    // Two colors, each two pixels wide and one band of six pixels tall;
    // then a second band where only the top pixel of the first column is set.
    terminal.feed("ab\(esc)P0;1q\"1;1;4;12#0;2;100;0;0#1;2;0;100;0#0!2~#1!2~-#1@\(esc)\\c")
    let screen = try #require(terminal.screen())
    let image = try #require(screen.images.first)
    #expect(screen.images.count == 1)
    #expect(image.pixelWidth == 4 && image.pixelHeight == 12)
    #expect(image.row == 0 && image.column == 2 && image.columns == 1 && image.rows == 1)
    let pixels = try #require(terminal.pixels(of: image))
    #expect(pixels.count == 4 * 12 * 4)
    #expect(pixel(pixels, 0) == [255, 0, 0, 255] && pixel(pixels, 1) == [255, 0, 0, 255])
    #expect(pixel(pixels, 2) == [0, 255, 0, 255] && pixel(pixels, 5 * 4 + 3) == [0, 255, 0, 255])
    #expect(pixel(pixels, 6 * 4) == [0, 255, 0, 255], "the second band's one pixel")
    #expect(pixel(pixels, 6 * 4 + 1) == [0, 0, 0, 0] && pixel(pixels, 7 * 4) == [0, 0, 0, 0], "untouched pixels are transparent")
    // Text continues on the line below, in the column the picture began in.
    #expect(screen.cursorRow == 1 && screen.cursorColumn == 3)
    #expect(screen.rows[0] == "ab" && screen.rows[1] == "  c")
  }

  @Test func sixelRepeatsColorsAndLimitsHold() throws {
    let terminal = try #require(HeadlessTerminal(columns: 40, rows: 10))
    // HLS red, a repeat of 20, and a carriage return that overdraws.
    terminal.feed("\(esc)P7;1;0q#5;1;120;50;100#5!20~$#0;2;0;0;100#0!3~\(esc)\\")
    let image = try #require(terminal.screen()?.images.first)
    #expect(image.pixelWidth == 20 && image.pixelHeight == 6 && image.columns == 3)
    let pixels = try #require(terminal.pixels(of: image))
    #expect(pixel(pixels, 0) == [0, 0, 255, 255], "overdrawn in blue")
    #expect(pixel(pixels, 3) == [255, 0, 0, 255], "hue 120 is red on the VT340's wheel")

    // A picture far larger than the limits is cut off, not grown without bound.
    let huge = try #require(HeadlessTerminal(columns: 40, rows: 10))
    huge.feed("\(esc)Pq\"1;1;999999;999999#0!999999~" + String(repeating: "-!999999~", count: 50) + "\(esc)\\")
    let cut = try #require(huge.screen()?.images.first)
    #expect(cut.pixelWidth <= 4096 && cut.pixelHeight <= 4096)
    #expect(cut.pixelWidth * cut.pixelHeight * 4 <= 16 * 1024 * 1024)

    // An empty picture, and a control string that is not Sixel, show nothing.
    let quiet = try #require(HeadlessTerminal(columns: 40, rows: 10))
    quiet.feed("\(esc)Pq\(esc)\\\(esc)P1$r0m\(esc)\\\(esc)P+q544e\(esc)\\ok")
    let screen = try #require(quiet.screen())
    #expect(screen.images.isEmpty && screen.rows[0] == "ok")
  }

  @Test func sixelParametersStayWithinTheirCommand() throws {
    // Digits outside a command are ignored. They must not turn !2 into !92.
    // An oversized color parameter list must also leave the next command usable.
    let payload = "9;9!2~$#1" + String(repeating: ";", count: 100_000) + "#2;2;100;0;0#2@"
    for fragmented in [false, true] {
      let terminal = try #require(HeadlessTerminal(columns: 40, rows: 10))
      let sequence = esc + "P7;1q" + payload + esc + "\\"
      if fragmented {
        for byte in sequence.utf8 { terminal.feed(Data([byte])) }
      } else {
        terminal.feed(sequence)
      }
      let image = try #require(terminal.screen()?.images.first)
      #expect(image.pixelWidth == 2 && image.pixelHeight == 6)
      #expect(pixel(try #require(terminal.pixels(of: image)), 0) == [255, 0, 0, 255])
    }
  }

  @Test func aPictureTallerThanTheScreenScrollsItIntoView() throws {
    let terminal = try #require(HeadlessTerminal(columns: 20, rows: 4))
    terminal.feed("top\r\n")
    // 96 pixels tall: six rows of 16 pixels on a four-row screen.
    terminal.feed("\(esc)P7;1q#0;2;0;0;100" + String(repeating: "#0!8~-", count: 16) + "\(esc)\\end")
    let screen = try #require(terminal.screen())
    let image = try #require(screen.images.first)
    #expect(image.rows == 6 && image.row == -3, "its top has scrolled off with the text")
    #expect(screen.cursorRow == 3 && screen.rows[3] == "end")
    #expect(screen.historyRows == 4)
  }

  @Test func anInlineImageTakesTheCellsAskedFor() throws {
    let terminal = try #require(HeadlessTerminal(columns: 40, rows: 10))
    let file = try png(width: 2, height: 1, rgba: [10, 200, 30, 255])
    terminal.feed("x" + inline(file, "name=YS5wbmc=;size=\(file.count);width=4;height=2;preserveAspectRatio=0;inline=1") + "y")
    let screen = try #require(terminal.screen())
    let image = try #require(screen.images.first)
    #expect(image.pixelWidth == 2 && image.pixelHeight == 1)
    #expect(image.row == 0 && image.column == 1 && image.columns == 4 && image.rows == 2)
    #expect(pixel(try #require(terminal.pixels(of: image)), 1) == [10, 200, 30, 255])
    // The cursor ends on the picture's last row, to its right.
    #expect(screen.cursorRow == 1 && screen.cursorColumn == 6 && screen.rows[1] == "     y")
  }

  @Test func inlineImageSizesFollowTheProtocol() throws {
    func placed(_ arguments: String, width: Int, height: Int, columns: Int = 40) throws -> HeadlessTerminal.Image? {
      let terminal = try #require(HeadlessTerminal(columns: columns, rows: 20))
      #expect(terminal.setCellSize(width: 10, height: 20))
      terminal.feed(inline(try png(width: width, height: height), arguments, terminator: "\(esc)\\"))
      return try #require(terminal.screen()).images.first
    }
    func cells(_ image: HeadlessTerminal.Image?) -> [Int] { image.map { [$0.columns, $0.rows] } ?? [] }
    #expect(cells(try placed("inline=1", width: 100, height: 40)) == [10, 2], "natural size")
    #expect(cells(try placed("inline=1", width: 1000, height: 100)) == [40, 2], "scaled to the screen's width")
    #expect(cells(try placed("inline=1;width=20", width: 100, height: 100)) == [20, 10], "height follows the shape")
    #expect(cells(try placed("inline=1;height=5", width: 100, height: 100)) == [10, 5])
    #expect(cells(try placed("inline=1;width=100px;height=100px", width: 200, height: 100)) == [10, 3], "fitted inside the box")
    #expect(cells(try placed("inline=1;width=50%", width: 100, height: 100)) == [20, 10])
    #expect(cells(try placed("inline=1;width=10;height=10;preserveAspectRatio=0", width: 200, height: 100)) == [10, 10])
    #expect(try placed("width=4", width: 10, height: 10) == nil, "without inline=1 it is a download, which is not shown")
    #expect(try placed("inline=0", width: 10, height: 10) == nil)
  }

  @Test func aLargePictureIsScaledDownAndRubbishIsIgnored() throws {
    let terminal = try #require(HeadlessTerminal(columns: 40, rows: 10))
    terminal.feed(inline(try png(width: 5000, height: 3000), "inline=1"))
    let image = try #require(terminal.screen()?.images.first)
    #expect(image.pixelWidth * image.pixelHeight * 4 <= 16 * 1024 * 1024)
    #expect(image.pixelWidth <= 4096 && abs(image.pixelWidth * 3 - image.pixelHeight * 5) <= 5, "the shape is kept")

    let quiet = try #require(HeadlessTerminal(columns: 40, rows: 10))
    quiet.feed("\(esc)]1337;File=inline=1:bm90IGFuIGltYWdl\u{07}")          // not an image
    quiet.feed("\(esc)]1337;File=inline=1:!!!!\u{07}")                      // not base64
    quiet.feed("\(esc)]1337;File=inline=1\u{07}")                           // no data
    quiet.feed("\(esc)]1337;File=inline=1:iVBOR\u{18}after")                // cancelled
    let screen = try #require(quiet.screen())
    #expect(screen.images.isEmpty && screen.rows[0] == "after")
  }

  @Test func theTerminalSaysItHasSixel() throws {
    let terminal = try #require(HeadlessTerminal(columns: 40, rows: 10))
    terminal.feed("\(esc)[c")
    #expect(String(decoding: terminal.takeReplies(), as: UTF8.self) == "\(esc)[?62;4;22c")
  }
}

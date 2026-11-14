import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

@Suite enum TerminalPaletteTests {
  @Test static func indexedColorsQueryAndReset() {
    var palette = TerminalPalette()
    let original1 = palette.snapshotPalette[1]
    let original2 = palette.snapshotPalette[2]
    let original3 = palette.snapshotPalette[3]

    let replies = palette.applyOSC(command: "4", value: "+1;#0102ff;+2;rgb:f/80/0000;3;?;4;#+f00ff;5;rgb:+f/80/0000;256;#ffffff;6")
    #expect(palette.snapshotPalette[1] == [1, 2, 255])
    #expect(palette.snapshotPalette[2] == [255, 128, 0])
    // Integer fields accept an optional leading plus. The rgb scaling
    // deliberately uses the full field length, including that plus sign.
    #expect(palette.snapshotPalette[4] == [15, 0, 255])
    #expect(palette.snapshotPalette[5] == [15, 128, 0])
    #expect(replies == ["\u{1b}]4;3;rgb:fafa/cccc/1515\u{1b}\\"])

    _ = palette.applyOSC(command: "4", value: "3;#ffffff")
    _ = palette.applyOSC(command: "104", value: "+1;garbage;256;+2")
    #expect(palette.snapshotPalette[1] == original1)
    #expect(palette.snapshotPalette[2] == original2)
    #expect(palette.snapshotPalette[3] == [255, 255, 255])
    _ = palette.applyOSC(command: "104", value: "")
    #expect(palette.snapshotPalette[3] == original3)
  }

  @Test static func defaultColorsQueriesAndReset() {
    var palette = TerminalPalette()
    _ = palette.applyOSC(command: "10", value: "rgb:f/80/ffff")
    _ = palette.applyOSC(command: "11", value: "#123456")
    #expect(palette.snapshotDefaultForeground == [255, 128, 255])
    #expect(palette.snapshotDefaultBackground == [18, 52, 86])
    #expect(palette.applyOSC(command: "10", value: "?") == ["\u{1b}]10;rgb:ffff/8080/ffff\u{1b}\\"])
    #expect(palette.applyOSC(command: "11", value: "?") == ["\u{1b}]11;rgb:1212/3434/5656\u{1b}\\"])

    _ = palette.applyOSC(command: "10", value: "#12é456")
    _ = palette.applyOSC(command: "11", value: "rgb:/1/2")
    _ = palette.applyOSC(command: "110", value: "#000000")
    _ = palette.applyOSC(command: "111", value: "#000000")
    #expect(palette.snapshotDefaultForeground == [255, 128, 255])
    #expect(palette.snapshotDefaultBackground == [18, 52, 86])
  }

  @Test static func resetRestoresEveryColor() {
    var palette = TerminalPalette()
    _ = palette.applyOSC(command: "4", value: "0;#ffffff")
    _ = palette.applyOSC(command: "10", value: "#000001")
    _ = palette.applyOSC(command: "11", value: "#000002")
    palette.reset()
    #expect(palette.snapshotPalette[0] == [27, 28, 31])
    #expect(palette.snapshotDefaultForeground == [230, 230, 230])
    #expect(palette.snapshotDefaultBackground == [10, 10, 11])
  }
}

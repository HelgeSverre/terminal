import Foundation
import Testing
@testable import TerminalEngine
import TerminalInterop

@Suite struct TerminalProtocolDiscoveryTests {
  private func terminal(_ identity: TerminalIdentity = .helgeTerminal) throws -> HeadlessTerminal {
    try #require(HeadlessTerminal(columns: 12, rows: 5, identity: identity))
  }
  private func ask(_ terminal: HeadlessTerminal, _ query: String) -> String {
    terminal.feed(query)
    return String(decoding: terminal.takeReplies(), as: UTF8.self)
  }
  private func dcs(_ payload: String) -> String { "\u{1b}P\(payload)\u{1b}\\" }
  private func osc(_ payload: String) -> String { "\u{1b}]\(payload)\u{1b}\\" }

  @Test func versionIsTruthfulAndHostSupplied() throws {
    let core = try terminal()
    #expect(ask(core, "\u{1b}[>q") == dcs(">|HelgeTerminal"))
    let host = try terminal(TerminalIdentity(name: "ExampleHost", version: "2.3.4"))
    for query in ["\u{1b}[>q", "\u{1b}[>0q", "\u{1b}[>00q"] {
      #expect(ask(host, query) == dcs(">|ExampleHost 2.3.4"))
    }
    for query in ["\u{1b}[>1q", "\u{1b}[>0;0q", "\u{1b}[>0 q", "\u{1b}[q"] {
      #expect(ask(host, query).isEmpty)
    }
    host.feed("\u{1b}c")
    #expect(ask(host, "\u{1b}[>q") == dcs(">|ExampleHost 2.3.4"), "RIS does not change implementation identity")
    let unsafe = TerminalIdentity(name: "Host\u{1b}\\\nName", version: String(repeating: "v", count: 200))
    #expect(unsafe.name == "Host\\Name" && unsafe.version?.utf8.count == 128)
  }

  @Test func absentHardwareStatusReportsAreTruthful() throws {
    let core = try terminal()
    let reports = [("15", "\u{1b}[?13n"), ("25", "\u{1b}[?21n"), ("26", "\u{1b}[?27;1n"), ("55", "\u{1b}[?50n"),
      ("56", "\u{1b}[?57;0n"), ("62", "\u{1b}[0*{"), ("63;123", dcs("123!~0000")), ("75", "\u{1b}[?70n"), ("85", "\u{1b}[?83n")]
    for (request, reply) in reports { #expect(ask(core, "\u{1b}[?\(request)n") == reply, "DECDSR \(request)") }
    #expect(ask(core, "\u{1b}[15n").isEmpty, "the ANSI form of a DEC report is not answered")
    #expect(ask(core, "\u{1b}[?6n") == "\u{1b}[?1;1R" && ask(core, "\u{1b}[5n") == "\u{1b}[0n")
    #expect(ask(core, "\u{1b}Z") == ask(core, "\u{1b}[c"), "DECID answers as primary device attributes")
    #expect(ask(core, dcs("$q$}")) == dcs("1$r0$}") && ask(core, dcs("$q$~")) == dcs("1$r0$~"))
  }

  @Test func modesThatCanNeverBeSetReportPermanentlyReset() throws {
    let core = try terminal()
    for mode in [1, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19] {
      #expect(ask(core, "\u{1b}[\(mode)$p") == "\u{1b}[\(mode);4$y")
      #expect(ask(core, "\u{1b}[\(mode)h\u{1b}[\(mode)$p") == "\u{1b}[\(mode);4$y", "setting it changes nothing")
    }
    #expect(ask(core, "\u{1b}[?60$p") == "\u{1b}[?60;4$y")
    #expect(ask(core, "\u{1b}[?60h\u{1b}[?60$p") == "\u{1b}[?60;4$y")
    #expect(ask(core, "\u{1b}[2$p\u{1b}[12$p\u{1b}[3$p") == "\u{1b}[2;0$y\u{1b}[12;0$y\u{1b}[3;0$y", "modes xterm can toggle stay unrecognized")
    #expect(ask(core, "\u{1b}[4$p\u{1b}[?7$p") == "\u{1b}[4;2$y\u{1b}[?7;1$y")
  }

  @Test func numericKeypadModeIsTheKeypadApplicationMode() throws {
    let core = try terminal()
    #expect(ask(core, "\u{1b}[?66$p") == "\u{1b}[?66;2$y")
    #expect(ask(core, "\u{1b}[?66h\u{1b}[?66$p") == "\u{1b}[?66;1$y")
    #expect(ask(core, "\u{1b}>\u{1b}[?66$p") == "\u{1b}[?66;2$y", "DECKPNM resets the same mode")
    #expect(ask(core, "\u{1b}=\u{1b}[?66$p") == "\u{1b}[?66;1$y")
    #expect(ask(core, "\u{1b}[?41$p\u{1b}[?45$p\u{1b}[?1045$p\u{1b}[?80$p\u{1b}[?8452$p")
      == "\u{1b}[?41;2$y\u{1b}[?45;2$y\u{1b}[?1045;2$y\u{1b}[?80;2$y\u{1b}[?8452;2$y")
    #expect(ask(core, "\u{1b}[?41;45;1045;80;8452h\u{1b}[?41$p\u{1b}[?45$p\u{1b}[?1045$p\u{1b}[?80$p\u{1b}[?8452$p")
      == "\u{1b}[?41;1$y\u{1b}[?45;1$y\u{1b}[?1045;1$y\u{1b}[?80;1$y\u{1b}[?8452;1$y")
  }

  @Test func capabilitiesAreBoundedAndDoNotOverclaim() throws {
    let core = try terminal()
    func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
    #expect(ask(core, dcs("+q\(hex("TN"));\(hex("Co"))")) == dcs("1+r544e=\(hex("helge-terminal"));436f=323536"))
    #expect(ask(core, dcs("+q\(hex("kcuu1"))")) == dcs("1+r\(hex("kcuu1"))=1b5b41"))
    core.feed("\u{1b}[?1h")
    #expect(ask(core, dcs("+q\(hex("kcuu1"))")) == dcs("1+r\(hex("kcuu1"))=1b4f41"))
    #expect(ask(core, dcs("+q436f;626f677573;544e")) == dcs("1+r436f=323536") + dcs("0+r"))
    for request in ["+q", "+q1", "+qzz", "+q3b", "+q" + Array(repeating: "436f", count: 33).joined(separator: ";")] {
      #expect(ask(core, dcs(request)) == dcs("0+r"))
    }
    // Overflow is discarded through ST, and its body cannot become output.
    #expect(ask(core, dcs("+q" + String(repeating: "a", count: 5000))).isEmpty)
    core.feed("safe")
    #expect(core.screen()?.rows.first == "safe")
  }

  @Test func cHostsCanSupplyAnIdentityWithoutChangingTheABIVersion() throws {
    let core = try #require(helge_terminal_create(12, 5))
    defer { helge_terminal_destroy(core) }
    #expect(helge_terminal_abi_version() == 1)
    "EmbeddedHost".withCString { name in
      "9.8.7".withCString { version in helge_terminal_set_identity(core, name, version) }
    }
    let query = Data("\u{1b}[>q".utf8)
    query.withUnsafeBytes { bytes in
      #expect(helge_terminal_feed(core, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, 0) == bytes.count)
    }
    final class Capture { var bytes = Data() }
    let result = Capture()
    helge_terminal_replies(core, Unmanaged.passUnretained(result).toOpaque()) { context, bytes, count in
      guard let context, let bytes else { return }
      Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().bytes.append(bytes, count: count)
    }
    #expect(String(decoding: result.bytes, as: UTF8.self) == dcs(">|EmbeddedHost 9.8.7"))
  }

  @Test func statusQueriesRoundTripThePenAndSettings() throws {
    let core = try terminal()
    core.feed("\u{1b}[2;4r\u{1b}[?69h\u{1b}[3;10s\u{1b}[5 q\u{1b}[1\"q")
    #expect(ask(core, dcs("$qr")) == dcs("1$r2;4r"))
    #expect(ask(core, dcs("$qs")) == dcs("1$r3;10s"))
    #expect(ask(core, dcs("$q q")) == dcs("1$r5 q"))
    #expect(ask(core, dcs("$q\"q")) == dcs("1$r1\"q"))
    #expect(ask(core, dcs("$qunknown")) == dcs("0$r"))
    core.feed("\u{1b}c\u{1b}[0;1;2;3;4:3;5;7;8;9;53;38;2;10;20;30;48;5;123;58;2;5;6;7m")
    let reply = ask(core, dcs("$qm"))
    #expect(reply.hasPrefix(dcs("1$r").dropLast(2)))
    let restored = try terminal()
    restored.feed("\u{1b}[" + String(reply.dropFirst(5).dropLast(2)) + "X")
    core.feed("X")
    let source = try #require(core.screen()).cells[0][0]
    let target = try #require(restored.screen()).cells[0][0]
    #expect(source.foreground == target.foreground && source.background == target.background)
    #expect(source.bold == target.bold && source.italic == target.italic && source.underlined == target.underlined)
    #expect(source.concealed == target.concealed && source.struckThrough == target.struckThrough)
  }

  @Test func queriesSurviveEverySplitAndCancellation() throws {
    let query = Data(("\u{1b}[>q" + dcs("+q436f") + dcs("$qm")).utf8)
    let expected = dcs(">|HelgeTerminal") + dcs("1+r436f=323536") + dcs("1$r0m")
    for split in 0...query.count {
      let core = try terminal()
      core.feed(query.prefix(split)); core.feed(query.dropFirst(split))
      #expect(String(decoding: core.takeReplies(), as: UTF8.self) == expected)
    }
    let core = try terminal()
    core.feed("\u{1b}P+q436f\u{18}A\u{1b}P$qm\u{1a}B")
    #expect(core.takeReplies().isEmpty)
    #expect(core.screen()?.rows.first == "AB")
  }

  @Test func cursorAndDynamicColorsResetToTheLatestHostScheme() throws {
    let core = try terminal()
    core.setColors(TerminalColorScheme(foreground: 0x112233, background: 0x445566, cursor: 0x778899))
    core.feed(osc("10;#abcdef;rgb:1/2/3;red"))
    #expect(ask(core, osc("10;?;?;?")) == osc("10;rgb:abab/cdcd/efef") + osc("11;rgb:1111/2222/3333") + osc("12;rgb:ffff/0000/0000"))
    #expect(core.screen()?.cursorColor == 0xff0000)
    core.setColors(TerminalColorScheme(foreground: 0x010203, background: 0xfafafa, cursor: 0x040506))
    #expect(core.screen()?.cursorColor == 0xff0000, "a child override survives host theme switching")
    core.feed(osc("110") + osc("111;") + osc("112"))
    #expect(ask(core, osc("10;?;?;?")) == osc("10;rgb:0101/0202/0303") + osc("11;rgb:fafa/fafa/fafa") + osc("12;rgb:0404/0505/0606"))
    #expect(core.screen()?.cursorColor == 0x040506)
    core.feed(osc("12;blue") + "\u{1b}c")
    #expect(core.screen()?.cursorColor == 0x040506)
  }

  @Test func attributeColorsAreLiveAndOptIn() throws {
    let core = try terminal()
    core.feed("\u{1b}[1mX\u{1b}[31mY" + osc("5;0;#123456"))
    #expect(core.screen()?.cells[0][0].foreground == TerminalColorScheme.standard.foreground)
    core.feed(osc("106;0;1"))
    #expect(core.screen()?.cells[0][0].foreground == 0x123456)
    #expect(core.screen()?.cells[0][1].foreground == 0xef4444, "explicit ANSI color wins until colorAttrMode is enabled")
    core.feed(osc("6;5;1"))
    #expect(core.screen()?.cells[0][1].foreground == 0x123456)
    #expect(ask(core, osc("4;256;?")) == osc("4;256;rgb:1212/3434/5656"))
    core.feed(osc("105;0"))
    #expect(core.screen()?.cells[0][0].foreground == TerminalColorScheme.standard.foreground)
  }

  @Test func configuredThemeReportsIgnoreChildColorOverrides() throws {
    let core = try terminal()
    #expect(ask(core, "\u{1b}[?996n") == "\u{1b}[?997;1n")
    #expect(ask(core, "\u{1b}[?2031$p") == "\u{1b}[?2031;2$y")
    core.feed("\u{1b}[?2031h")
    core.setColors(TerminalColorScheme(background: 0xffffff))
    #expect(String(decoding: core.takeReplies(), as: UTF8.self) == "\u{1b}[?997;2n")
    core.feed(osc("11;black"))
    #expect(core.takeReplies().isEmpty)
    #expect(ask(core, "\u{1b}[?996n") == "\u{1b}[?997;2n")
    core.feed("\u{1b}[?2031l")
    core.setColors(.standard)
    #expect(core.takeReplies().isEmpty)
  }

  @Test func titlesAreBoundedFilteredAndRestorable() throws {
    let core = try terminal()
    core.feed(osc("0;original") + "\u{1b}[22;0t" + osc("1;icon") + osc("2;window"))
    #expect(core.screen()?.title == "window")
    #expect(ask(core, "\u{1b}[20t\u{1b}[21t").isEmpty, "titles set by output are never reported back as input")
    core.feed("\u{1b}[23;0t")
    #expect(core.screen()?.title == "original")
    let bidi = "\u{061c}\u{200e}\u{200f}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2066}\u{2067}\u{2068}\u{2069}"
    core.feed(osc("2;host" + bidi + "/path\u{200d}\u{2060}"))
    #expect(core.screen()?.title == "host/path\u{200d}\u{2060}")
    core.feed(osc("2;" + String(repeating: "猫", count: 2000)))
    #expect(core.screen()?.title.utf8.count == 4095)
    // Child window move/resize commands still have no effect on geometry.
    core.feed("\u{1b}[3;10;10t\u{1b}[8;100;200t")
    #expect(core.columns == 12 && core.rows == 5)
  }

  @Test func titleStackRetainsTheNewestSixteenAndHandlesEmptyPops() throws {
    let core = try terminal()
    for index in 0..<20 { core.feed(osc("2;title-\(index)") + "\u{1b}[22;2t") }
    core.feed(osc("2;temporary"))
    for index in (4..<20).reversed() {
      core.feed("\u{1b}[23;2t")
      #expect(core.screen()?.title == "title-\(index)")
    }
    core.feed("\u{1b}[23;0t")
    #expect(core.screen()?.title == "title-4")
    core.feed("\u{1b}[22;2t\u{1b}c" + osc("2;after-reset") + "\u{1b}[23;2t")
    #expect(core.screen()?.title == "after-reset")
  }

  @Test func partialTitleStackFramesInheritMissingTitlesWhenPopped() throws {
    let core = try terminal()
    // Push the icon and window separately, then restore both in one pop.
    core.feed(osc("1;original-icon") + osc("2;original-window") + "\u{1b}[22;1t\u{1b}[22;2t")
    core.feed(osc("1;changed-icon") + osc("2;changed-window") + "\u{1b}[23;0t")
    #expect(core.screen()?.title == "original-window")
  }
}

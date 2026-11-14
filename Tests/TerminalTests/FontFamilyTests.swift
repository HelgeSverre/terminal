import AppKit
import CoreText
import Testing
@testable import TerminalHost
@testable import TerminalUI

/// A host names an installed font family for a view.
@Suite @MainActor struct FontFamilyTests {
  private func family(_ font: CTFont) -> String { CTFontCopyFamilyName(font) as String }

  @Test func anInstalledFamilyIsUsedWithItsFaces() {
    #expect(family(TerminalFont.core(size: 14)) == TerminalFont.family)
    let regular = TerminalFont.core(size: 14, family: "Menlo")
    #expect(family(regular) == "Menlo")
    let bold = TerminalFont.core(size: 14, bold: true, family: "Menlo")
    #expect(CTFontGetSymbolicTraits(bold).contains(.traitBold))
    let italic = TerminalFont.core(size: 14, italic: true, family: "menlo")
    #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic), "the name is matched without regard to case")
    #expect(family(TerminalFont.core(size: 14, family: "No Such Family 4f1c")) == TerminalFont.family)
  }

  @Test func theFamilyDrawsTheGlyphsAndKeepsTheIcons() {
    let font = TerminalFont.core(size: 28, family: "Menlo")
    #expect(TerminalFont.rasterize("A", font: font, width: 20, height: 40).fonts == ["Menlo-Regular"])
    // A Nerd Font icon Menlo does not have comes from the bundled symbols.
    let icon = TerminalFont.rasterize("\u{e0b0}", font: font, width: 20, height: 40)
    #expect(!icon.missing)
    #expect(icon.fonts.allSatisfy { !$0.hasPrefix("Menlo") }, "\(icon.fonts)")
  }

  @Test func onlyPunctuationJoinsLigatures() {
    for text in ["-", ">", "=", "!", "|", ":", ".", "/", "*", "&", "~", "\\"] {
      #expect(TerminalFont.joinsLigatures(text), "\(text)")
    }
    for text in ["f", "i", "0", " ", "", "->", "é", "猫", "(", "{", "\"", ","] {
      #expect(!TerminalFont.joinsLigatures(text), "\(text)")
    }
  }

  /// A run shaped as one line lets a font with ligatures substitute its
  /// glyphs; the same characters shaped one by one stay as they are.
  @Test func aRunIsShapedAsOneLine() throws {
    let name = "JetBrains Mono"
    let font = TerminalFont.core(size: 28, family: name)
    // The font is not part of macOS; without it there is nothing to shape.
    guard (CTFontCopyFamilyName(font) as String) == name else { return }
    func glyphs(_ text: String) -> [CGGlyph] {
      TerminalFont.rasterize(text, font: font, width: 17 * text.count, height: 40, ligatures: true).glyphIDs
    }
    #expect(glyphs("->") != glyphs("-") + glyphs(">"), "the arrow has glyphs of its own")
    #expect(glyphs("!=") != glyphs("!") + glyphs("="))
    #expect(glyphs("-(") == glyphs("-") + glyphs("("), "no ligature, no change")
    let arrow = TerminalFont.rasterize("->", font: font, width: 34, height: 40, ligatures: true)
    #expect(!arrow.missing && !arrow.clipped)
  }

  @Test func aViewMeasuresItsGridInTheChosenFamily() {
    final class Idle: TerminalTransport {
      func start(_ connection: TerminalConnection, columns: Int, rows: Int) {}
      func send(_ bytes: Data) {}
    }
    func size(_ family: String?) -> NSSize {
      let session = TerminalSession(transport: Idle())
      defer { session.close() }
      let view = TerminalCanvasView(
        frame: .zero, session: session, rendering: nil, clipboard: nil,
        configuration: TerminalViewConfiguration(fontSize: 20, fontFamily: family))
      return view.contentSize(columns: 100, rows: 10)
    }
    #expect(size("Menlo") != size(nil), "Menlo's line is not as tall as Obel Mono's")
    #expect(size("No Such Family 4f1c") == size(nil))
  }
}

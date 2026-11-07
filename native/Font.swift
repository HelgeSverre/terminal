import AppKit
import CoreText

// Use the same PostScript faces for layout and rasterization. Fonts remain
// user-installed assets; the application does not redistribute font files.
enum TerminalFont {
  static let family = "Obel Mono"
  static func appKit(size: CGFloat) -> NSFont {
    NSFont(name: "ObelMono-Regular", size: size) ?? NSFont(name: "Menlo", size: size)
      ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  }
  static func core(size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
    let name =
      "ObelMono-" + (bold ? (italic ? "BoldItalic" : "Bold") : (italic ? "Italic" : "Regular"))
    let selected = CTFontCreateWithName(name as CFString, size, nil)
    if CTFontCopyFamilyName(selected) as String == family { return selected }
    let fallback = CTFontCreateWithName("Menlo" as CFString, size, nil)
    let traits: CTFontSymbolicTraits =
      bold ? (italic ? [.boldTrait, .italicTrait] : .boldTrait) : (italic ? .italicTrait : [])
    return CTFontCreateCopyWithSymbolicTraits(fallback, 0, nil, traits, traits) ?? fallback
  }
}

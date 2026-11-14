import AppKit
import CoreText

// Owns font files, face selection and the icon cascade. Both layout and drawing
// resolve from bundled descriptors, independently of fonts installed on the Mac.
package enum TerminalFont {
  package static let family = "Obel Mono"
  private static let resources: [String: CTFontDescriptor] = {
    guard let root = TerminalResources.bundle.resourceURL?.appendingPathComponent("Fonts") else { return [:] }
    var result: [String: CTFontDescriptor] = [:]
    for name in ["Regular", "Bold", "Italic", "BoldItalic", "Symbols"] {
      let path = name == "Symbols"
        ? "nerd-symbols/SymbolsNerdFontMono-Regular.ttf" : "obel-mono/ObelMono-\(name).ttf"
      let url = root.appendingPathComponent(path)
      if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
        let descriptor = descriptors.first {
        result[name] = descriptor
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
    return result
  }()
  package static func appKit(size: CGFloat, family: String? = nil) -> NSFont {
    core(size: size, family: family) as NSFont
  }
  /// The face of an installed family, or nil when the Mac has no such
  /// family. A family without the bold or italic face gives its regular one.
  private static func installed(_ name: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont? {
    let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
    let regular = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    guard (CTFontCopyFamilyName(regular) as String).caseInsensitiveCompare(name) == .orderedSame else { return nil }
    var traits: CTFontSymbolicTraits = []
    if bold { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    guard !traits.isEmpty else { return regular }
    return CTFontCreateCopyWithSymbolicTraits(regular, size, nil, traits, [.traitBold, .traitItalic]) ?? regular
  }
  /// `family` names an installed fixed-pitch family; nil, or a name the Mac
  /// does not have, gives the bundled Obel Mono.
  package static func core(size: CGFloat, bold: Bool = false, italic: Bool = false, family: String? = nil) -> CTFont {
    let face = bold ? (italic ? "BoldItalic" : "Bold") : (italic ? "Italic" : "Regular")
    let base: CTFont
    if let family, family != Self.family, let chosen = installed(family, size: size, bold: bold, italic: italic) {
      base = chosen
    } else if let descriptor = resources[face] {
      base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    } else {
      let selected = CTFontCreateWithName(("ObelMono-" + face) as CFString, size, nil)
      base = CTFontCopyFamilyName(selected) as String == family
        ? selected : CTFontCreateWithName("Menlo" as CFString, size, nil)
    }
    guard let symbols = resources["Symbols"] else { return base }
    let cascade = CTFontDescriptorCreateCopyWithAttributes(
      CTFontCopyFontDescriptor(base), [kCTFontCascadeListAttribute: [symbols]] as CFDictionary)
    return CTFontCreateWithFontDescriptor(cascade, size, nil)
  }
  private static let icons = Set(iconCodepoints)
  /// The characters programming fonts join into ligatures: `->`, `!=`,
  /// `===`, `|>` and the like. Letters and digits are left alone, so `fi`
  /// in a word is never joined.
  private static let ligatureCharacters = Set("!#$%&*+-./:;<=>?@\\^_|~".utf8)
  /// Whether `text` is one character that can be part of a ligature.
  package static func joinsLigatures(_ text: String) -> Bool {
    var bytes = text.utf8.makeIterator()
    guard let first = bytes.next(), bytes.next() == nil else { return false }
    return ligatureCharacters.contains(first)
  }
  package struct Bitmap {
    package var pixels: [UInt8]
    package let missing: Bool
    package let fonts: [String]
    package let glyphIDs: [CGGlyph]
    package let clipped: Bool
  }
  package static func rasterize(_ text: String, font: CTFont, width: Int, height: Int,
                                ligatures: Bool = false) -> Bitmap {
    var selected = font
    var icon = false
    if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
      icons.contains(scalar.value), let descriptor = resources["Symbols"],
      !CFCharacterSetIsLongCharacterMember(CTFontCopyCharacterSet(font), scalar.value) {
      selected = CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(font), nil)
      icon = true
    }
    func line(_ value: CTFont) -> CTLine {
      CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: value, .foregroundColor: NSColor.white, .ligature: ligatures ? 1 : 0]))
    }
    var shaped = line(selected)
    var bounds = CTLineGetBoundsWithOptions(shaped, .useGlyphPathBounds)
    if icon, !bounds.isEmpty {
      // Symbols Mono uses a one-em advance; Obel's grid cell is 0.6 em.
      let ratio = min(1, CGFloat(width) / max(1, bounds.width), CGFloat(height - 2) / max(1, bounds.height))
      selected = CTFontCreateCopyWithAttributes(selected, CTFontGetSize(selected) * ratio, nil, nil)
      shaped = line(selected)
      bounds = CTLineGetBoundsWithOptions(shaped, .useGlyphPathBounds)
    }
    let position = icon && !bounds.isEmpty
      ? CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
      : CGPoint(x: 0, y: CGFloat(height) - CTFontGetAscent(font) - 2)
    var missing = false
    var fonts: [String] = []
    var glyphIDs: [CGGlyph] = []
    for run in CTLineGetGlyphRuns(shaped) as! [CTRun] {
      var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
      CTRunGetGlyphs(run, CFRange(location: 0, length: glyphs.count), &glyphs)
      glyphIDs.append(contentsOf: glyphs)
      missing = missing || glyphs.contains(0)
      let attributes = CTRunGetAttributes(run) as NSDictionary
      if let value = attributes[kCTFontAttributeName] {
        fonts.append(CTFontCopyPostScriptName(value as! CTFont) as String)
      }
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
      guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      context.textPosition = position
      CTLineDraw(shaped, context)
    }
    let ink = bounds.offsetBy(dx: position.x, dy: position.y)
    let clipped = !bounds.isEmpty && (ink.minX < -0.5 || ink.maxX > CGFloat(width) + 0.5
      || ink.minY < -0.5 || ink.maxY > CGFloat(height) + 0.5)
    return Bitmap(pixels: pixels, missing: missing, fonts: fonts, glyphIDs: glyphIDs, clipped: clipped)
  }
  // Enumerate the actual shipped cmap, including supplementary-plane icons.
  package static let iconCodepoints: [UInt32] = {
    guard let descriptor = resources["Symbols"] else { return [] }
    let set = CTFontCopyCharacterSet(CTFontCreateWithFontDescriptor(descriptor, 14, nil))
    return (0...0x10ffff).compactMap {
      CFCharacterSetIsLongCharacterMember(set, UInt32($0)) ? UInt32($0) : nil
    }
  }()
}

import AppKit
import CoreText

// A catalog of the actual bundled cmap, used by both the printable specimen
// and the native paged rendering smoke. Never guesses coverage from ranges.
enum FontCatalog {
  static let codepoints = TerminalFont.iconCodepoints.filter {
    $0 >= 32 && !($0 >= 127 && $0 <= 159) && Unicode.Scalar($0) != nil
  }
  static func text(_ points: ArraySlice<UInt32>) -> String {
    points.map { String(format: "%06X", $0) + " " + String(Unicode.Scalar($0)!) + "  " }.joined()
  }
  static func write(to path: String) throws {
    var text = "Obel Mono + Symbols Nerd Font Mono 3.5.1\r\n\(codepoints.count) encoded printable characters; hexadecimal Unicode labels.\r\n"
    for offset in stride(from: 0, to: codepoints.count, by: 8) {
      text += Self.text(codepoints[offset..<min(offset + 8, codepoints.count)]) + "\r\n"
    }
    try text.write(toFile: path, atomically: true, encoding: .utf8)
  }
  static func inspect() -> [String: Any] {
    var missing: [String] = []
    var blank: [String] = []
    var clipped: [String] = []
    var resolved: Set<String> = []
    var faces: [String] = []
    var sources: [String] = []

    let normal = TerminalFont.appKit(size: 14)
    let width = Int(ceil(("M" as NSString).size(withAttributes: [.font: normal]).width * 2))
    let height = Int(ceil((normal.ascender - normal.descender + 3) * 2))

    for (name, bold, italic) in [("regular", false, false), ("bold", true, false),
                                ("italic", false, true), ("bold-italic", true, true)] {
      let font = TerminalFont.core(size: 28, bold: bold, italic: italic)
      faces.append(CTFontCopyPostScriptName(font) as String)
      sources.append((CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path ?? "missing")

      for point in codepoints {
        let scalar = Unicode.Scalar(point)!
        let label = name + ":" + String(format: "U+%04X", point)
        let bitmap = TerminalFont.rasterize(String(scalar), font: font, width: width, height: height)
        let pixels = bitmap.pixels
        if bitmap.missing { missing.append(label) }
        resolved.formUnion(bitmap.fonts)
        if bitmap.clipped { clipped.append(label) }
        if point != 0xec03 && !CharacterSet.whitespacesAndNewlines.contains(scalar)
          && !stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] != 0 }) {
          blank.append(label)
        }
      }
    }
    let bundled = sources.allSatisfy { $0.hasPrefix((Bundle.main.resourceURL?.path ?? "") + "/Fonts/") }
    return ["codepoints": codepoints.count, "faces": faces, "resolved_fonts": resolved.sorted(),
      "font_sources": sources, "bundled_text_faces": bundled,
      "cell_pixels": [width, height], "missing_glyphs": missing, "unexpected_blank_glyphs": blank,
      "clipped_bounds": clipped, "passed": bundled && codepoints.count > 10_000 && missing.isEmpty && blank.isEmpty && clipped.isEmpty,
      "intentional_blank": "U+EC03 cod-blank",
      "note": "Every mapped printable Nerd Font character shaped and rasterized in all four text styles. Bounds outside the cell are reported separately."]
  }
}

@MainActor final class GlyphSmokeTest {
  private static var active: GlyphSmokeTest?
  private let window: TerminalWindow
  private let path: String
  private var page = -1
  private var pending = false
  private var points: ArraySlice<UInt32> = []
  private var verified = 0
  private var renderedPages = 0
  private var previousSubmissions: UInt64 = 0
  private var failures: [String] = []
  private let budgetPressure = CommandLine.arguments.contains("--atlas-fallback-budget-smoke")
  private let pressure: Bool
  private let pages: Int
  private let styles: Int
  private let pageSize: Int
  init(window: TerminalWindow, path: String) {
    self.window = window
    self.path = path
    pressure = CommandLine.arguments.contains("--atlas-pressure-smoke") || budgetPressure
    pages = pressure ? 1 : (FontCatalog.codepoints.count + 1023) / 1024
    styles = pressure ? 1 : 4
    pageSize = budgetPressure ? 128 : 1024
  }
  static func start(window: TerminalWindow, path: String) {
    let test = GlyphSmokeTest(window: window, path: path)
    active = test
    window.panes.first?.onObservedSnapshot = { [weak test] in test?.observe($0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 50) {
      if active === test { test.failures.append("timeout"); test.finish() }
    }
  }
  private func observe(_ snapshot: TerminalSnapshot) {
    guard !pending else { return }
    let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
    if page == -1 {
      guard text.contains("GLYPH_READY") else { return }
      pending = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in next() }
    } else if text.contains("GLYPH_END_\(page)_DONE") {
      pending = true
      let seen = Set(text.unicodeScalars.map { $0.value })
      if !points.allSatisfy({ seen.contains($0) }) { failures.append("page \(page) lost grid characters") }
      verified += points.count
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
        let submissions = RendererMetrics.submissions()
        if submissions > previousSubmissions { renderedPages += 1 }
        else { failures.append("page \(page) had no Metal submission") }
        previousSubmissions = submissions
        next()
      }
    }
  }
  private func next() {
    page += 1
    guard page < pages * styles else { finish(); return }
    let offset = (page % pages) * pageSize
    points = FontCatalog.codepoints[offset..<min(offset + pageSize, FontCatalog.codepoints.count)]
    let style = ["0", "1", "3", "1;3"][page / pages]
    if pressure, let pane = window.panes.first {
      // Twenty cells exceed the pressure atlas width, exercising the direct
      // fallback on the IME/preedit path as well as ordinary grid glyphs.
      pane.setMarkedText(
        String(repeating: "W", count: 20), selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    var output = "\u{1b}[2J\u{1b}[H\u{1b}[0mObel Mono + Nerd Font: page \(page + 1)/\(pages * styles)\r\n\u{1b}[\(style)m"
    for index in stride(from: points.startIndex, to: points.endIndex, by: 32) {
      output += points[index..<min(index + 32, points.endIndex)].map {
        String(Unicode.Scalar($0)!) + " "
      }.joined() + "\r\n"
    }
    output += "\u{1b}[0mGLYPH_END_\(page)_DONE"
    pending = false
    previousSubmissions = RendererMetrics.submissions()
    if window.panes.first?.session.shortcut(output) != true {
      failures.append("PTY input rejected"); finish()
    }
  }
  private func finish() {
    guard Self.active === self else { return }
    Self.active = nil
    window.panes.first?.onObservedSnapshot = nil
    let metrics = RendererMetrics.report()
    let expected = pressure ? min(pageSize, FontCatalog.codepoints.count) : FontCatalog.codepoints.count * 4
    let visibleDrops = metrics["visible_glyph_drops"] as? UInt64 ?? 0
    let exactFallbacks = metrics["exact_glyph_fallbacks"] as? UInt64 ?? 0
    let substitutions = metrics["substitute_glyph_fallbacks"] as? UInt64 ?? 0
    let oversized = metrics["oversized_glyph_fallbacks"] as? UInt64 ?? 0
    let droppedBuffers = metrics["dropped_quad_buffers"] as? UInt64 ?? 0
    let peakBytes = metrics["peak_glyph_fallback_bytes"] as? UInt64 ?? 0
    let peakCount = metrics["peak_glyph_fallback_count"] as? UInt64 ?? 0
    let pressurePassed = !pressure || (budgetPressure
      ? substitutions > 0 && oversized > 0
      : exactFallbacks > 0 && substitutions == 0 && oversized > 0
        && peakBytes <= UInt64(8 * 1024 * 1024) && peakCount <= 1024)
    let result: [String: Any] = ["passed": failures.isEmpty && verified == expected
      && metrics["command_errors"] as? Int == 0
      && visibleDrops == 0 && droppedBuffers == 0 && pressurePassed, "failures": failures,
      "unique_codepoints": FontCatalog.codepoints.count, "style_codepoints_verified": verified,
      "rendered_pages": renderedPages, "atlas_pressure": pressure, "metal": metrics,
      "note": pressure
        ? "A bounded symbol fixture and oversized preedit exercised the raw cat PTY, native grid, and Metal fallback paths. Counters verify admission and draw preparation; pixel coverage is checked separately by the shared rasterizer catalog."
        : "Every mapped printable symbol passed through a raw cat PTY and the native grid in all four styles, with a Metal submission per page. Pixel coverage is checked separately by the shared rasterizer catalog."]
    do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path), options: .atomic) }
    catch { NSLog("Glyph report failed: %@", String(describing: error)) }
    if !CommandLine.arguments.contains("--keep-open") { NSApp.terminate(nil) }
  }
}

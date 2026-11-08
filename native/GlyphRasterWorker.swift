import AppKit
import CoreText

// Immutable input for raster work. The resolved face is part of the key: a
// font-size/style change creates a different resident glyph instead of
// resetting glyphs used by other terminal panes.
struct GlyphRasterRecipe: Hashable {
  let text: String
  let width: Int
  let height: Int
  let pointSize: Int
  let bold: Bool
  let italic: Bool
  let fontIdentity: String
  // The request is deliberately self-contained.  A later font preference
  // cannot mutate this work item into a glyph for a different face.
  let backingScale: Int
}

enum GlyphRasterKind { case mask, color }

struct GlyphRasterResult {
  let recipe: GlyphRasterRecipe
  let pixels: [UInt8]
  let kind: GlyphRasterKind
  let resolvedFonts: [String]
  let glyphIDs: [CGGlyph]
}

// One bounded worker keeps CoreText/CG allocations out of the render owner.
// Results are immutable and the caller decides whether the recipe is still
// current before admitting it to GPU residency.
final class GlyphRasterWorker: @unchecked Sendable {
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "no.helgesverre.terminal.glyph-raster"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  private let lock = NSLock()
  private var pending: Set<GlyphRasterRecipe> = []
  private var queuedBytes = 0
  private let maxJobs = 256
  private let maxQueuedBytes = 8 * 1024 * 1024

  @discardableResult
  func request(
    _ recipe: GlyphRasterRecipe,
    completion: @escaping @Sendable (GlyphRasterResult?, @escaping @Sendable () -> Void) -> Void
  ) -> Bool {
    let bytes = recipe.width * recipe.height * 4
    guard recipe.width > 0, recipe.height > 0, bytes > 0 else { return false }
    lock.lock()
    guard pending.count < maxJobs, queuedBytes + bytes <= maxQueuedBytes,
      pending.insert(recipe).inserted
    else {
      lock.unlock()
      return false
    }
    queuedBytes += bytes
    lock.unlock()
    queue.addOperation { [weak self] in
      autoreleasepool {
        let result = Self.rasterize(recipe)
        completion(result) { [weak self] in self?.complete(recipe, bytes: bytes) }
      }
    }
    return true
  }
  private func complete(_ recipe: GlyphRasterRecipe, bytes: Int) {
    lock.lock()
    pending.remove(recipe)
    queuedBytes -= bytes
    lock.unlock()
  }
  private static func rasterize(_ recipe: GlyphRasterRecipe) -> GlyphRasterResult? {
    // TerminalFont.core rebuilds the immutable configured face *and* its
    // cascade. The identity remains in the recipe key; reconstructing a bare
    // PostScript face here would drop the Symbols/fallback cascade.
    let font = TerminalFont.core(
      size: CGFloat(recipe.pointSize), bold: recipe.bold, italic: recipe.italic)
    let bitmap = TerminalFont.rasterize(recipe.text, font: font, width: recipe.width, height: recipe.height)
    // CoreText's resolved runs are authoritative. Preserve RGBA whenever the
    // result is not plainly white coverage; uncertain data stays color.
    var mask = true
    for offset in stride(from: 0, to: bitmap.pixels.count, by: 4) {
      let a = bitmap.pixels[offset + 3]
      guard a > 0 else { continue }
      if bitmap.pixels[offset] != a || bitmap.pixels[offset + 1] != a || bitmap.pixels[offset + 2] != a {
        mask = false
        break
      }
    }
    return GlyphRasterResult(
      recipe: recipe, pixels: bitmap.pixels, kind: mask ? .mask : .color,
      resolvedFonts: bitmap.fonts, glyphIDs: bitmap.glyphIDs)
  }
}

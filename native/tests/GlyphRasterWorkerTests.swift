import Foundation

private final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: GlyphRasterResult?
  func set(_ result: GlyphRasterResult?) { lock.lock(); value = result; lock.unlock() }
  func get() -> GlyphRasterResult? { lock.lock(); defer { lock.unlock() }; return value }
}

@main enum GlyphRasterWorkerTests {
  static func main() {
    let worker = GlyphRasterWorker()
    let recipe = GlyphRasterRecipe(
      text: "A", width: 24, height: 32, pointSize: 14, bold: false, italic: false,
      fontIdentity: "Menlo-Regular", backingScale: 1)
    let result = DispatchSemaphore(value: 0)
    let completed = ResultBox()
    precondition(worker.request(recipe) { value, release in completed.set(value); release(); result.signal() })
    // Pending raster work is deduplicated rather than spending staging budget
    // twice for the same immutable recipe.
    precondition(!worker.request(recipe) { _, _ in })
    precondition(result.wait(timeout: .now() + 5) == .success)
    precondition(completed.get()?.recipe == recipe)
    precondition(completed.get()?.pixels.count == recipe.width * recipe.height * 4)
    precondition(!(completed.get()?.glyphIDs.isEmpty ?? true))
    precondition(!worker.request(GlyphRasterRecipe(
      text: "", width: 0, height: 32, pointSize: 14, bold: false, italic: false,
      fontIdentity: "Menlo-Regular", backingScale: 1)) { _, _ in })
    print("PASS glyph raster worker: dedupe, completion, immutable recipe")
  }
}

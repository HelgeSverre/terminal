import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

@Suite enum GlyphRasterWorkerTests {
  private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GlyphRasterResult?
    func set(_ result: GlyphRasterResult?) { lock.lock(); value = result; lock.unlock() }
    func get() -> GlyphRasterResult? { lock.lock(); defer { lock.unlock() }; return value }
  }

  /// Dedupe, completion and the immutable recipe.
  @Test static func dedupeCompletionAndRecipe() {
    let worker = GlyphRasterWorker()
    let recipe = GlyphRasterRecipe(
      text: "A", width: 24, height: 32, pointSize: 14, bold: false, italic: false,
      fontIdentity: "Menlo-Regular", backingScale: 1)
    let result = DispatchSemaphore(value: 0)
    let completed = ResultBox()
    #expect(worker.request(recipe) { value, release in completed.set(value); release(); result.signal() })
    // Pending raster work is deduplicated rather than spending staging budget
    // twice for the same immutable recipe.
    #expect(!worker.request(recipe) { _, _ in })
    #expect(result.wait(timeout: .now() + 5) == .success)
    #expect(completed.get()?.recipe == recipe)
    #expect(completed.get()?.pixels.count == recipe.width * recipe.height * 4)
    #expect(!(completed.get()?.glyphIDs.isEmpty ?? true))
    #expect(!worker.request(GlyphRasterRecipe(
      text: "", width: 0, height: 32, pointSize: 14, bold: false, italic: false,
      fontIdentity: "Menlo-Regular", backingScale: 1)) { _, _ in })
  }
}

import AppKit
import Metal
import Testing
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI
import TerminalInterop

@Suite enum PresentationTests {
  /// Rasterize the same device-pixel rectangles consumed by Metal. The test
  /// compares pixels, including gaps, rather than merely counting primitives.
  fileprivate static func pixels(kind: Int, width: Int = 12, height: Int = 20,
    scale: Int = 1, origin: Int = 0) -> [[Bool]] {
    var result = Array(repeating: Array(repeating: false, count: width), count: height)
    for rect in UnderlineGeometry.rectangles(kind: kind, x: origin, width: width, height: height, scale: scale) {
      for y in rect.y..<(rect.y + rect.height) {
        for x in rect.x..<(rect.x + rect.width) { result[y][x] = true }
      }
    }
    return result
  }

  @Test static func underlineStylePixels() {
    #expect(pixels(kind: 1)[17] == Array(repeating: true, count: 12))
    #expect(pixels(kind: 2)[16] == Array(repeating: true, count: 12))
    #expect(pixels(kind: 2)[17] == Array(repeating: false, count: 12))
    #expect(pixels(kind: 2)[18] == Array(repeating: true, count: 12))
    #expect(pixels(kind: 4)[17] == [true, false, true, false, true, false, true, false, true, false, true, false])
    #expect(pixels(kind: 5)[17] == [true, true, true, false, false, true, true, true, false, false, true, true])
    #expect(pixels(kind: 3)[16] == [true, false, false, false, true, false, false, false, true, false, false, false])
    #expect(Set((1...5).map { pixels(kind: $0).flatMap { $0 }.map { $0 ? "1" : "0" }.joined() }).count == 5)
  }

  @Test static func wideAndRetinaUnderlinePixels() {
    for kind in 1...5 {
      let wide = pixels(kind: kind, width: 38, height: 40, scale: 2)
      let left = pixels(kind: kind, width: 19, height: 40, scale: 2)
      let right = pixels(kind: kind, width: 19, height: 40, scale: 2, origin: 19)
      #expect(zip(wide, zip(left, right)).allSatisfy { full, halves in full == halves.0 + halves.1 },
        "a wide-cell decoration has no seam or restarted pattern")
      #expect(wide.contains { $0.contains(true) })
      #expect(wide.prefix(28).allSatisfy { !$0.contains(true) })
    }
  }

  @Test static func blinkOnlySchedulesRelevantRequests() {
    for shape in [0, 2, 4, 6] {
      let state = TerminalBlinkPresentation(now: 0.75, cursorShape: shape, cursor: true, text: false)
      #expect(state.cursorVisible && state.nextDeadline == nil)
    }
    for shape in [1, 3, 5] {
      let state = TerminalBlinkPresentation(now: 0.75, cursorShape: shape, cursor: true, text: false)
      #expect(!state.cursorVisible && state.textVisible && state.nextDeadline == 1)
    }
    let text = TerminalBlinkPresentation(now: 1.25, cursorShape: 0, cursor: false, text: true)
    #expect(text.textVisible && text.nextDeadline == 1.5)
    let idle = TerminalBlinkPresentation(now: 1.75, cursorShape: 1, cursor: false, text: false)
    #expect(idle.nextDeadline == nil)
    // A cursor that moved at 1.7 is drawn at 1.75 and next changes at 2.2;
    // blinking text beside it stays on the shared clock and is hidden.
    let moved = TerminalBlinkPresentation(now: 1.75, cursorEpoch: 1.7, cursorShape: 1, cursor: true, text: true)
    #expect(moved.cursorVisible && !moved.textVisible && moved.nextDeadline == 2)
    let later = TerminalBlinkPresentation(now: 2.25, cursorEpoch: 1.7, cursorShape: 1, cursor: true, text: false)
    #expect(!later.cursorVisible && later.nextDeadline == 2.7)
  }

  @Test static func oneBlinkWakeIsPendingAndFiresOnce() async {
    let wake = BlinkWake()
    var fired = 0
    wake.schedule(10, now: 9.99) { fired += 1 }
    wake.schedule(10, now: 9.995) { fired += 100 }
    await TestEnvironment.wait { fired != 0 }
    #expect(fired == 1, "asking again for the scheduled deadline keeps the first timer")
    wake.schedule(20, now: 19.99) { fired += 1 }
    wake.cancel()
    wake.schedule(30, now: 29.999) { fired += 10 }
    await TestEnvironment.wait { fired >= 11 }
    #expect(fired == 11, "a cancelled wake never fires")
  }

  @Test static func scrollRequestsSurviveOutputUnderAPinnedViewport() {
    var viewport = ViewportPresentation()
    viewport.reset(offset: 10)
    #expect(viewport.scroll(delta: 30, lineHeight: 20, maximum: 100) == 2)
    viewport.awaitScroll(now: 0)
    #expect(viewport.pending == 12)
    // Output arrives before the scroll is applied: the pinned offset grows.
    viewport.publish(offset: 11, pinnedGrowth: 1, now: 0.01)
    #expect(viewport.pending == 13 && viewport.anchor == 13 && viewport.fraction == -0.5)
    viewport.publish(offset: 13, pinnedGrowth: 0, now: 0.02)
    #expect(viewport.pending == nil && viewport.anchor == 13 && viewport.fraction == -0.5)
    // Scroll and output in the same publication.
    #expect(viewport.scroll(delta: 20, lineHeight: 20, maximum: 100) == 1)
    viewport.awaitScroll(now: 1)
    viewport.publish(offset: 16, pinnedGrowth: 2, now: 1.01)
    #expect(viewport.pending == nil && viewport.anchor == 16)
    // Full history hides the growth; the wait ends by time instead of never.
    #expect(viewport.scroll(delta: 20, lineHeight: 20, maximum: 100) == 1)
    viewport.awaitScroll(now: 2)
    viewport.publish(offset: 19, pinnedGrowth: 0, now: 2.1)
    #expect(viewport.pending == 17, "an unexpected offset does not overwrite a fresh request")
    viewport.publish(offset: 19, pinnedGrowth: 0, now: 2.3)
    #expect(viewport.pending == nil && viewport.anchor == 19)
    // A request for the tail is not moved by growth.
    viewport.reset(offset: 1)
    #expect(viewport.scroll(delta: -20, lineHeight: 20, maximum: 100) == -1)
    viewport.awaitScroll(now: 3)
    viewport.publish(offset: 0, pinnedGrowth: 1, now: 3.01)
    #expect(viewport.pending == nil && viewport.anchor == 0)
  }

  @Test static func fractionalScrollAndGeometryAreInverse() {
    var viewport = ViewportPresentation()
    #expect(viewport.scroll(delta: 5, lineHeight: 20, maximum: 10) == 1)
    #expect(viewport.anchor == 1 && viewport.fraction == -0.75)
    #expect(viewport.scroll(delta: 10, lineHeight: 20, maximum: 10) == 0)
    #expect(viewport.fraction == -0.25)
    let geometry = ViewportGeometry(inset: 8, cellWidth: 10, cellHeight: 20, offset: -5)
    for row in 0..<5 {
      let rect = geometry.rect(row: row, column: 3, cells: 2)
      #expect(geometry.row(at: rect.midY) == row)
      #expect(geometry.column(at: rect.minX + 1) == 3)
      #expect(rect.width == 20)
    }
    #expect(geometry.row(at: 25) == 1, "selection/link hits follow the translated row boundary")
    #expect(viewport.scroll(delta: -15, lineHeight: 20, maximum: 10) == -1)
    #expect(viewport.position == 0 && viewport.fraction == 0)
    #expect(viewport.scroll(delta: 1_000_000, lineHeight: 20, maximum: 10) == 10)
    #expect(viewport.fraction == 0)
    viewport.reset(offset: 3)
    _ = viewport.scroll(delta: -5, lineHeight: 20, maximum: 10)
    viewport.reconcile(offset: 4)
    #expect(viewport.position == 3.75 && viewport.anchor == 4)
  }

  @Test static func failedSubmissionQuiescesUntilNewDemand() {
    var gate = RendererFailureGate()
    gate.failed(submittedGeneration: 1, currentGeneration: 1)
    #expect(gate.blocked)
    gate.requested()
    #expect(!gate.blocked)
    gate.failed(submittedGeneration: 1, currentGeneration: 2)
    #expect(!gate.blocked, "an older failed frame cannot suppress a new view request")
    gate.finished(.staleDrawable, submittedGeneration: 2, currentGeneration: 2)
    #expect(!gate.blocked, "a drawable of the old size is replaced, not treated as a GPU failure")
    gate.finished(.failed, submittedGeneration: 2, currentGeneration: 2)
    #expect(gate.blocked)
  }

  @Test static func overscanPreservesViewportAndActionProofs() throws {
    let core = try #require(helge_terminal_create(8, 2))
    defer { helge_terminal_destroy(core) }
    SnapshotBridgeTests.feed(core, "first\r\nsecond\r\nthird\r\nfourth")
    let base = try #require(SnapshotBridge.read(core, scroll: 1, now: 0).snapshot)
    let expanded = base.includingPresentationOverscan()
    #expect(base.rows.count == 2 && expanded.rows.count == 3)
    #expect(expanded.rows.prefix(2).elementsEqual(base.rows))
    #expect(expanded.selectionPresentation?.rows.count == 3)
    let hit = try #require(expanded.selectionHit(row: 2, boundary: 1))
    #expect(hit.rowID == expanded.rows[2].id && hit.rowRevision == expanded.rows[2].revision)
    #expect(expanded.rows[2].cells.prefix(6).map(\.text).joined() == "fourth")
    #expect(expanded.includingPresentationOverscan().rows.count == 3, "guard expansion is idempotent")
    let tail = try #require(SnapshotBridge.read(core, scroll: 0, now: 0).snapshot)
    #expect(tail.presentationOverscan == nil)
  }

}

#if GLYPH_RESIDENCY_TESTING
/// Offscreen Metal tests share the explicit driver-probe gate with residency
/// tests. CPU presentation geometry remains in PresentationTests.
@Suite(.serialized) enum PresentationMetalTests {
  private static func render(_ request: RenderRequest, using rendering: TerminalRendering) async -> [UInt8]? {
    await withCheckedContinuation { continuation in
      rendering.renderPixelsForTesting(request) { continuation.resume(returning: $0) }
    }
  }

  @Test static func metalUnderlinesMatchColoredWideAndRetinaPixels() async throws {
    try #require(MTLCreateSystemDefaultDevice() != nil, "the local Metal gate requires a real GPU")
    let rendering = try TerminalRendering()
    let core = try #require(helge_terminal_create(2, 1))
    defer { helge_terminal_destroy(core) }
    for scale in [1, 2] {
      let width = 12 * scale
      let height = 20 * scale
      for kind in 1...5 {
        SnapshotBridgeTests.feed(core,
          "\u{1b}[2J\u{1b}[H\u{1b}]11;#000000\u{7}\u{1b}[0;38;2;0;0;0;48;2;0;0;0;58;2;255;0;0;4:\(kind)m猫")
        let snapshot = try #require(SnapshotBridge.read(core, scroll: 0, now: 0).snapshot)
        let request = RenderRequest(snapshot: snapshot, width: width * 2, height: height,
          inset: 0, cellWidth: width, cellHeight: height, fontSize: CGFloat(14 * scale),
          focused: true, marked: "", linkUnderline: [], backingScale: scale, cursorVisible: false)
        let result = try #require(await render(request, using: rendering))
        let expected = PresentationTests.pixels(kind: kind, width: width * 2, height: height, scale: scale)
        for y in 0..<height {
          for x in 0..<(width * 2) {
            let offset = (y * width * 2 + x) * 4
            #expect(result[offset] == 0 && result[offset + 1] == 0)
            #expect(result[offset + 2] == (expected[y][x] ? 255 : 0),
              "style \(kind), scale \(scale), pixel \(x),\(y)")
          }
        }
      }
    }
  }

  @Test static func metalFractionalViewportClipsGuardRowAndBlinkHidesInk() async throws {
    try #require(MTLCreateSystemDefaultDevice() != nil, "the local Metal gate requires a real GPU")
    let rendering = try TerminalRendering()
    let core = try #require(helge_terminal_create(2, 2))
    defer { helge_terminal_destroy(core) }
    SnapshotBridgeTests.feed(core,
      "\u{1b}]11;#000000\u{7}\u{1b}[48;2;255;0;0m  \r\n\u{1b}[48;2;0;255;0m  \r\n\u{1b}[48;2;0;0;255m  ")
    let snapshot = try #require(SnapshotBridge.read(core, scroll: 1, now: 0).snapshot)
    let request = RenderRequest(snapshot: snapshot.includingPresentationOverscan(), width: 20, height: 40,
      inset: 0, cellWidth: 10, cellHeight: 20, fontSize: 14, focused: true,
      marked: "", linkUnderline: [], cursorVisible: false, scrollOffsetPixels: -5, viewportRows: 2)
    let result = try #require(await render(request, using: rendering))
    func pixel(_ y: Int) -> [UInt8] { Array(result[(y * 20 * 4)..<(y * 20 * 4 + 3)]) }
    #expect(pixel(0) == [0, 0, 255] && pixel(14) == [0, 0, 255])
    #expect(pixel(15) == [0, 255, 0] && pixel(34) == [0, 255, 0])
    #expect(pixel(35) == [255, 0, 0] && pixel(39) == [255, 0, 0])
    SnapshotBridgeTests.feed(core, "\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[5;38;2;255;0;0m█")
    let blinking = try #require(SnapshotBridge.read(core, scroll: 0, now: 0).snapshot)
    let hidden = RenderRequest(snapshot: blinking, width: 20, height: 40, inset: 0,
      cellWidth: 10, cellHeight: 20, fontSize: 14, focused: true, marked: "", linkUnderline: [],
      cursorVisible: false, textVisible: false)
    let hiddenPixels = try #require(await render(hidden, using: rendering))
    #expect(stride(from: 0, to: hiddenPixels.count, by: 4).allSatisfy {
      hiddenPixels[$0] == 0 && hiddenPixels[$0 + 1] == 0 && hiddenPixels[$0 + 2] == 0
    })
  }
}
#endif

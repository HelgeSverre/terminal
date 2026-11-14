import Foundation
import Metal
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

// Synthetic bitmaps give deterministic dimensions/materials, while exercising
// the production bounded worker, callback, owner queue and upload boundaries.
private final class ResidencyScenario: @unchecked Sendable {
  let owner = DispatchQueue(label: "glyph-residency-scenario")
  let residency: GlyphResidency
  let ready = DispatchSemaphore(value: 0)
  let rasterGate = DispatchSemaphore(value: 0)
  private var wakeups = 0 // owner queue only
  let budget: Int

  init(device: MTLDevice, budget: Int, holdRaster: String? = nil) {
    self.budget = budget
    let gate = rasterGate
    let worker = GlyphRasterWorker(rasterizer: { recipe in
      if recipe.text == holdRaster {
        #expect(gate.wait(timeout: .now() + 5) == .success, "controlled raster was never released")
      }
      return GlyphRasterResult(recipe: recipe,
        pixels: [UInt8](repeating: 255, count: recipe.width * recipe.height * 4),
        kind: recipe.text.hasPrefix("color") ? .color : .mask,
        resolvedFonts: ["fixture"], glyphIDs: [1])
    })
    residency = GlyphResidency(device: device, owner: owner, worker: worker, budget: budget) {}
    residency.setOnReady { [weak self] in
      guard let self else { return }
      self.wakeups += 1
      self.ready.signal()
    }
  }

  @discardableResult
  func frame(_ surface: UUID, _ recipes: [GlyphRasterRecipe], submit: Bool = false) -> [Bool] {
    owner.sync {
      residency.beginFrame(surface: surface)
      let resident = recipes.map { residency.resolve($0) != nil }
      residency.finishFrameDemand()
      if submit { residency.submitted() } else { residency.abandonedPreparedFrame() }
      #expect(residency.diagnostics().residentBytes <= budget, "GPU capacity exceeded budget")
      return resident
    }
  }

  func complete() { owner.sync { residency.completedSubmission() } }
  func wakeCount() -> Int { owner.sync { wakeups } }
  func detach(_ surface: UUID) { owner.sync { residency.detachSurface(surface) } }
  func has(_ recipe: GlyphRasterRecipe) -> Bool {
    owner.sync { residency.testingHasResident(recipe) }
  }
  func waitForUpload() {
    for _ in 0..<20 {
      if owner.sync(execute: { residency.testingUploadCount() > 0 }) { return }
      guard ready.wait(timeout: .now() + 5) == .success else {
        Issue.record("worker did not deliver bitmap")
        return
      }
    }
    Issue.record("upload was never queued")
  }

  func settle(_ scenes: [(UUID, [GlyphRasterRecipe])]) {
    for _ in 0..<40 {
      let wakesBeforeFrame = owner.sync { wakeups }
      for (surface, recipes) in scenes { frame(surface, recipes) }
      if owner.sync(execute: { residency.testingWorkIsIdle() }) {
        // A demand transition can request one more frame without a CPU job
        // yet: that next frame is what re-requests a suppressed glyph.
        if owner.sync(execute: { wakeups == wakesBeforeFrame }) { return }
        continue
      }
      guard ready.wait(timeout: .now() + 5) == .success else {
        Issue.record("recovery stopped making progress")
        return
      }
    }
    Issue.record("residency never settled")
  }

  func assertQuiescent(_ scenes: [(UUID, [GlyphRasterRecipe])]) {
    let before = owner.sync { (wakeups, residency.diagnostics().residentBytes) }
    for _ in 0..<8 {
      for (surface, recipes) in scenes { frame(surface, recipes, submit: true); complete() }
    }
    owner.sync {
      #expect(residency.testingWorkIsIdle(), "stable scene queued more raster work")
      #expect(wakeups == before.0, "stable scene kept requesting redraws")
      #expect(residency.diagnostics().residentBytes == before.1, "stable scene kept allocating")
    }
  }
}

@Suite enum GlyphResidencyScenarioTests {
  static func recipe(_ text: String, _ width: Int = 600, _ height: Int = 600) -> GlyphRasterRecipe {
    GlyphRasterRecipe(text: text, width: width, height: height, pointSize: 12,
      bold: false, italic: false, fontIdentity: "fixture", backingScale: 1)
  }
  static func capacity(device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int) -> Int {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let heapDescriptor = MTLHeapDescriptor()
    heapDescriptor.storageMode = .shared
    heapDescriptor.size = device.heapTextureSizeAndAlign(descriptor: descriptor).size
    guard let heap = device.makeHeap(descriptor: heapDescriptor) else {
      Issue.record("fixture heap unavailable")
      return 0
    }
    // Admission charges actual heap capacity, which can exceed the queried
    // resource size. Give a two-allocation fixture exactly two real heaps.
    return Int(heap.size)
  }

  static let a = recipe("A"), b = recipe("B")
  static let directA = recipe("direct-A", 1024, 1024)
  static let directB = recipe("direct-B", 1024, 1024)

  /// The device and the page capacity every scenario budgets from. Without a
  /// Metal device the scenario fails, as the old executable did.
  static func fixture() -> (device: MTLDevice, maskPage: Int)? {
    guard let device = MTLCreateSystemDefaultDevice() else {
      Issue.record("GLYPH_RESIDENCY_DEVICE=unavailable")
      return nil
    }
    return (device, capacity(device: device, .r8Unorm, 1024, 1024))
  }

  // One-page A+B stays resident+outline; B-only must recover without another
  // user event, then stop issuing raster work and redraws.
  @Test static func oversubscribedSceneRecoversAfterBOnly() {
    guard let (device, maskPage) = fixture() else { return }
    let one = maskPage + 4096
    let first = UUID()
    let test = ResidencyScenario(device: device, budget: one)
    test.settle([(first, [a])])
    #expect(test.has(a))
    test.settle([(first, [a, b])])
    #expect(test.has(a) && !test.has(b), "oversubscribed scene evicted a visible glyph")
    test.assertQuiescent([(first, [a, b])])
    test.settle([(first, [b])])
    #expect(!test.has(a) && test.has(b), "B-only did not recover")
    test.assertQuiescent([(first, [b])])
  }

  // Upload while A is pinned must remain staged, not become a permanent
  // failure. Completion must wake it; no second CPU raster may be necessary.
  @Test static func pinnedUploadStaysStagedUntilCompletion() {
    guard let (device, maskPage) = fixture() else { return }
    let one = maskPage + 4096
    let first = UUID()
    let test = ResidencyScenario(device: device, budget: one)
    test.settle([(first, [directA])])
    #expect(test.frame(first, [directA], submit: true) == [true])
    test.frame(first, [directB])
    test.waitForUpload()
    test.frame(first, [directB])
    #expect(test.has(directA) && !test.has(directB), "submitted A was reclaimed")
    #expect(test.owner.sync { test.residency.testingUploadCount() == 1 },
      "pinned upload was discarded instead of retained")
    let wakesBeforeCompletion = test.wakeCount()
    test.complete()
    #expect(test.wakeCount() == wakesBeforeCompletion + 1, "pin completion did not request recovery frame")
    test.settle([(first, [directB])])
    #expect(!test.has(directA) && test.has(directB), "direct B did not recover after pin drain")
    test.assertQuiescent([(first, [directB])])
  }

  // Distinct surfaces contribute to a union. B must not evict still-visible
  // A; detaching A's surface must clear capacity suppression and recover B.
  @Test static func surfaceUnionAndDetach() {
    guard let (device, maskPage) = fixture() else { return }
    let one = maskPage + 4096
    let first = UUID(), second = UUID()
    let test = ResidencyScenario(device: device, budget: one)
    test.settle([(first, [directA])])
    test.settle([(first, [directA]), (second, [directB])])
    #expect(test.has(directA) && !test.has(directB), "second surface replaced visible first")
    test.assertQuiescent([(first, [directA]), (second, [directB])])
    test.detach(first)
    test.settle([(second, [directB])])
    #expect(!test.has(directA) && test.has(directB), "detach did not recover direct B")
    test.assertQuiescent([(second, [directB])])
  }

  // The original red test now uses real worker acceptance, so B's CPU
  // reservation is released before its GPU allocation is attempted.
  @Test static func mixedMaterialRecoveryAcrossSurfaces() {
    guard let (device, maskPage) = fixture() else { return }
    let first = UUID(), second = UUID()
    let color = recipe("color-C", 512, 512)
    let test = ResidencyScenario(device: device,
      budget: maskPage + capacity(device: device, .rgba8Unorm, 512, 512) + 4096)
    test.settle([(first, [directA])])
    test.settle([(first, [directA]), (second, [color])])
    let summary = test.owner.sync { test.residency.testingSummary() }
    #expect(test.has(directA) && test.has(color), "\(summary)")
    test.settle([(first, [directB]), (second, [color])])
    #expect(!test.has(directA) && test.has(directB) && test.has(color),
      "two-surface mixed-material recovery lost a visible resident")
    test.assertQuiescent([(first, [directB]), (second, [color])])
    test.detach(second)
    test.assertQuiescent([(first, [directB])])
  }

  // One scene change may reclaim multiple pages, regardless of result order.
  @Test static func multiPageDemandChange() {
    guard let (device, maskPage) = fixture() else { return }
    let first = UUID()
    let a2 = recipe("A2"), b2 = recipe("B2")
    let test = ResidencyScenario(device: device, budget: 2 * maskPage + 4096)
    test.settle([(first, [a])])
    test.settle([(first, [a, a2])])
    #expect(test.has(a) && test.has(a2))
    test.settle([(first, [b, b2])])
    #expect(test.has(b) && test.has(b2) && !test.has(a) && !test.has(a2),
      "multi-page demand change did not fully recover")
    test.assertQuiescent([(first, [b, b2])])
  }

  // A larger exact texture can require retiring several obsolete direct
  // allocations; stopping after one victim would strand a fitting result.
  @Test static func largerTextureReclaimsSeveralAllocations() {
    guard let (device, _) = fixture() else { return }
    let first = UUID()
    let smallA = recipe("small-A", 1024, 400), smallB = recipe("small-B", 1024, 400)
    let large = recipe("large", 1024, 800)
    let test = ResidencyScenario(device: device,
      budget: max(2 * capacity(device: device, .r8Unorm, 1024, 400), capacity(device: device, .r8Unorm, 1024, 800)) + 4096)
    test.settle([(first, [smallA])])
    test.settle([(first, [smallA, smallB])])
    #expect(test.has(smallA) && test.has(smallB))
    test.settle([(first, [large])])
    #expect(test.has(large) && !test.has(smallA) && !test.has(smallB),
      "larger exact texture did not reclaim both obsolete allocations")
    test.assertQuiescent([(first, [large])])
  }

  // Other CPU jobs temporarily reserve more than their eventual R8 GPU
  // capacity. An early result must not be permanently suppressed by them.
  @Test static func cpuReservationPressureDoesNotDiscardUpload() {
    guard let (device, maskPage) = fixture() else { return }
    let first = UUID()
    let directC = recipe("direct-C", 1024, 1024)
    let test = ResidencyScenario(device: device, budget: 2 * maskPage + 4096, holdRaster: directC.text)
    test.settle([(first, [directA])])
    test.frame(first, [directB, directC])
    test.waitForUpload() // B has returned, C is still gated inside the worker.
    test.frame(first, [directB, directC])
    #expect(test.owner.sync { test.residency.testingUploadCount() == 1 },
      "CPU reservation pressure discarded a recoverable upload")
    #expect(test.has(directA), "CPU reservation pressure prematurely reclaimed cached A")
    test.rasterGate.signal()
    test.settle([(first, [directB, directC])])
    #expect(!test.has(directA) && test.has(directB) && test.has(directC),
      "CPU reservation release did not recover GPU capacity")
    test.assertQuiescent([(first, [directB, directC])])
  }
}

import Foundation
import Metal
import simd

// This is the only owner of font-raster results and glyph GPU allocations.
// TerminalRendering intentionally sees leases only; it cannot reset a page or
// account an allocation independently of the process-wide budget.
struct GlyphLease {
  enum Kind { case mask, color }
  let uv: SIMD4<Float>
  let width: Int
  let texture: MTLTexture
  let kind: Kind
  fileprivate let allocation: UUID?
  fileprivate let allocationGeneration: UInt64?
}

final class GlyphResidency: @unchecked Sendable {
  struct LegacyTexture {
    let id: UUID
    let heap: MTLHeap
    let texture: MTLTexture
    let capacity: Int
  }
  struct Diagnostics {
    let residentBytes: Int
    let retiredBytes: Int
    let reservations: Int
    let directFallbackBytes: Int
    let transientReplacementBytes: Int
    let deniedAllocations: UInt64
  }
  private enum PageKind { case mask, color
    var format: MTLPixelFormat { self == .mask ? .r8Unorm : .rgba8Unorm }
    var side: Int { self == .mask ? 1024 : 512 }
  }
  private struct Page {
    let id: UUID
    let kind: PageKind
    let heap: MTLHeap
    let texture: MTLTexture
    let capacity: Int
    var x: Int = 1
    var y: Int = 0
    var shelf: Int = 0
    var generation: UInt64 = 0
    var pins = 0
  }
  private struct Entry {
    let lease: GlyphLease
    let page: UUID?
    let bytes: Int
  }

  private let device: MTLDevice
  private let worker: GlyphRasterWorker
  private let owner: DispatchQueue
  private let byteBudget: Int
  private var onReady: @Sendable () -> Void
  private var pages: [UUID: Page] = [:]
  private var entries: [GlyphRasterRecipe: Entry] = [:]
  private var pending: Set<GlyphRasterRecipe> = []
  // Results wait until the next safe frame boundary: an async CPU replace
  // must never overwrite a page sampled by the sole submitted command buffer.
  private struct QueuedUpload {
    let result: GlyphRasterResult
    let release: @Sendable () -> Void
  }
  private var uploadQueue: [QueuedUpload] = []
  private var preparedPins: Set<UUID> = []
  private var submittedPins: Set<UUID> = []
  private var residentBytes = 0
  private var reservations = 0
  private var directFallbackBytes = 0
  private var transientReplacementBytes = 0
  private var legacyBridgeBytes = 0
  private var activeLegacy: [UUID: Int] = [:]
  private var deniedAllocations: UInt64 = 0
  private var fallback: GlyphLease?

  init(device: MTLDevice, owner: DispatchQueue, worker: GlyphRasterWorker = GlyphRasterWorker(), budget: Int = 64 * 1024 * 1024,
       onReady: @escaping @Sendable () -> Void) {
    self.device = device
    self.owner = owner
    self.worker = worker
    byteBudget = budget
    self.onReady = onReady
  }

  func beginFrame() {
    preparedPins.removeAll(keepingCapacity: true)
    let uploads = uploadQueue
    uploadQueue.removeAll(keepingCapacity: true)
    for upload in uploads { install(upload.result); upload.release() }
  }

  func setOnReady(_ callback: @escaping @Sendable () -> Void) { onReady = callback }

  func resolve(_ recipe: GlyphRasterRecipe) -> GlyphLease? {
    if let entry = entries[recipe] {
      if let page = entry.page {
        guard let current = pages[page], current.generation == entry.lease.allocationGeneration else {
          entries.removeValue(forKey: recipe)
          return resolve(recipe)
        }
        preparedPins.insert(page)
      }
      return entry.lease
    }
    if pending.insert(recipe).inserted {
      reservations += recipe.width * recipe.height * 4
      let accepted = worker.request(recipe) { [weak self] result, release in
        guard let self else { release(); return }
        // Raster completion crosses the actor boundary before touching cache
        // state or Metal. Stale/cancelled results become harmless misses.
        self.owner.async { [weak self] in self?.accept(recipe, result: result, release: release) }
      }
      if !accepted {
        pending.remove(recipe)
        reservations -= recipe.width * recipe.height * 4
      }
    }
    return nil
  }

  // Must run on TerminalRendering's serial executor.
  private func accept(_ recipe: GlyphRasterRecipe, result: GlyphRasterResult?, release: @escaping @Sendable () -> Void) {
    guard pending.remove(recipe) != nil else { release(); return }
    reservations -= recipe.width * recipe.height * 4
    // A raster failure remains a miss: the visible fallback is retained and a
    // future request may retry instead of caching a blank texture.
    guard let result, !result.pixels.isEmpty, !result.glyphIDs.contains(0) else {
      release()
      onReady()
      return
    }
    uploadQueue.append(QueuedUpload(result: result, release: release))
    onReady()
  }

  // Called only by beginFrame, after the preceding one-in-flight submission
  // has completed and released its pins.
  private func install(_ result: GlyphRasterResult) {
    let recipe = result.recipe
    let kind: PageKind = result.kind == .mask ? .mask : .color
    guard let placement = reserve(kind: kind, width: recipe.width, height: recipe.height) else {
      onReady()
      return
    }
    var pixels = result.pixels
    if kind == .mask {
      pixels = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0 + 3] }
    } else {
      convertPremultipliedSRGBToLinear(&pixels)
    }
    let bytesPerRow = recipe.width * (kind == .mask ? 1 : 4)
    pixels.withUnsafeBytes {
      placement.page.texture.replace(
        region: MTLRegionMake2D(placement.x, placement.y, recipe.width, recipe.height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: bytesPerRow)
    }
    let side = Float(kind.side)
    let lease = GlyphLease(
      uv: SIMD4(Float(placement.x) / side, Float(placement.y) / side,
                Float(recipe.width) / side, Float(recipe.height) / side),
      width: recipe.width, texture: placement.page.texture,
      kind: kind == .mask ? .mask : .color, allocation: placement.page.id,
      allocationGeneration: placement.page.generation)
    entries[recipe] = Entry(lease: lease, page: placement.page.id, bytes: recipe.width * recipe.height)
  }

  func fallbackGlyph(width: Int, height: Int) -> GlyphLease? {
    if let fallback { return fallback }
    // A one-pixel R8 coverage texel is a visible, bounded substitute while
    // async raster work is pending.  It is not an invisible glyph drop.
    guard let page = createPage(.mask) else { return nil }
    var byte: UInt8 = 255
    withUnsafeBytes(of: &byte) {
      page.texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 1)
    }
    let value = GlyphLease(uv: SIMD4(0, 0, 1 / 1024.0, 1 / 1024.0), width: width,
                           texture: page.texture, kind: .mask, allocation: page.id,
                           allocationGeneration: page.generation)
    fallback = value
    preparedPins.insert(page.id)
    return value
  }

  func submitted() {
    submittedPins.formUnion(preparedPins)
    preparedPins.removeAll(keepingCapacity: true)
    for id in submittedPins { pages[id]?.pins += 1 }
  }

  func abandonedPreparedFrame() { preparedPins.removeAll(keepingCapacity: true) }

  func completedSubmission() {
    for id in submittedPins {
      guard var page = pages[id] else { continue }
      page.pins = max(0, page.pins - 1)
      pages[id] = page
    }
    submittedPins.removeAll(keepingCapacity: true)
  }

  func diagnostics() -> Diagnostics {
    Diagnostics(residentBytes: residentBytes, retiredBytes: 0, reservations: reservations,
                directFallbackBytes: directFallbackBytes, transientReplacementBytes: transientReplacementBytes,
                deniedAllocations: deniedAllocations)
  }

  // The legacy bridge uses the same heap admission path as native pages. The
  // actual heap capacity is charged before its texture exists.
  func makeLegacyTexture(_ descriptor: MTLTextureDescriptor) -> LegacyTexture? {
    let requirement = device.heapTextureSizeAndAlign(descriptor: descriptor)
    let estimate = Int(requirement.size)
    guard estimate > 0, residentBytes + reservations + estimate <= byteBudget else {
      deniedAllocations &+= 1
      return nil
    }
    let heapDescriptor = MTLHeapDescriptor()
    heapDescriptor.storageMode = descriptor.storageMode
    heapDescriptor.size = requirement.size
    guard let heap = device.makeHeap(descriptor: heapDescriptor) else { return nil }
    let actual = Int(heap.size)
    guard residentBytes + reservations + actual <= byteBudget,
      let texture = heap.makeTexture(descriptor: descriptor)
    else { deniedAllocations &+= 1; return nil }
    residentBytes += actual
    legacyBridgeBytes += actual
    let id = UUID()
    activeLegacy[id] = actual
    return LegacyTexture(id: id, heap: heap, texture: texture, capacity: actual)
  }

  // Idempotent by design: a replacement glyph can appear in several quads in
  // one command buffer, but its heap capacity is retired exactly once.
  func releaseLegacyTexture(_ id: UUID) {
    guard let bytes = activeLegacy.removeValue(forKey: id), bytes > 0 else { return }
    residentBytes = max(0, residentBytes - bytes)
    legacyBridgeBytes = max(0, legacyBridgeBytes - bytes)
  }

  private func reserve(kind: PageKind, width: Int, height: Int) -> (page: Page, x: Int, y: Int)? {
    guard width > 0, height > 0, width + 1 < kind.side, height + 1 < kind.side else { return nil }
    for page in pages.values where page.kind == kind {
      if let result = reserve(on: page, width: width, height: height) { return result }
    }
    guard let page = createPage(kind), let result = reserve(on: page, width: width, height: height) else {
      // All charged pages are full. Reclaim only a page no submitted frame can
      // still sample; its generation invalidates every old lease/UV.
      guard let victim = pages.values.first(where: { $0.kind == kind && $0.pins == 0 }) else {
        return nil
      }
      evict(victim.id)
      guard let recycled = pages[victim.id] else { return nil }
      return reserve(on: recycled, width: width, height: height)
    }
    return result
  }

  private func reserve(on source: Page, width: Int, height: Int) -> (page: Page, x: Int, y: Int)? {
    guard var page = pages[source.id] else { return nil }
    var x = page.x
    var y = page.y
    var shelf = page.shelf
    if x + width + 1 > page.kind.side { x = 0; y += shelf + 1; shelf = 0 }
    guard y + height + 1 < page.kind.side else { return nil }
    let point = (x, y)
    page.x = x + width + 1
    page.y = y
    page.shelf = max(shelf, height)
    pages[page.id] = page
    return (page, point.0, point.1)
  }

  private func createPage(_ kind: PageKind) -> Page? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: kind.format, width: kind.side,
                                                                height: kind.side, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
    let capacity = Int(sizeAndAlign.size)
    // Account capacity before heap allocation.  A failed allocation never
    // leaves an optimistic budget charge behind.
    guard capacity > 0, residentBytes + reservations + capacity <= byteBudget else {
      deniedAllocations &+= 1
      return nil
    }
    let heapDescriptor = MTLHeapDescriptor()
    heapDescriptor.storageMode = .shared
    heapDescriptor.size = sizeAndAlign.size
    guard let heap = device.makeHeap(descriptor: heapDescriptor) else { return nil }
    let actualCapacity = Int(heap.size)
    guard residentBytes + reservations + actualCapacity <= byteBudget,
          let texture = heap.makeTexture(descriptor: descriptor) else {
      deniedAllocations &+= 1
      return nil
    }
    residentBytes += actualCapacity
    let page = Page(id: UUID(), kind: kind, heap: heap, texture: texture, capacity: actualCapacity)
    pages[page.id] = page
    RendererMetrics.recordAtlasPages(pages.count)
    return page
  }

  private func evict(_ id: UUID) {
    guard var page = pages[id], page.pins == 0 else { return }
    entries = entries.filter { $0.value.page != id }
    page.x = 1
    page.y = 0
    page.shelf = 0
    page.generation &+= 1
    // Keep the allocation-free visible fallback valid when its page is the
    // chosen victim: it always samples the rewritten opaque texel.
    if page.kind == .mask {
      var opaque: UInt8 = 255
      withUnsafeBytes(of: &opaque) {
        page.texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                             withBytes: $0.baseAddress!, bytesPerRow: 1)
      }
    }
    pages[id] = page
  }

  private func convertPremultipliedSRGBToLinear(_ pixels: inout [UInt8]) {
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Float(pixels[offset + 3]) / 255
      guard alpha > 0 else { pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0; continue }
      for channel in 0..<3 {
        let straight = min(1, Float(pixels[offset + channel]) / 255 / alpha)
        let linear = straight <= 0.04045 ? straight / 12.92 : pow((straight + 0.055) / 1.055, 2.4)
        pixels[offset + channel] = UInt8(clamping: Int((linear * alpha * 255).rounded()))
      }
    }
  }
}

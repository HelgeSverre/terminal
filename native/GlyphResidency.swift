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
}

final class GlyphResidency: @unchecked Sendable {
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
    var lastUse: UInt64
  }
  private struct Retired {
    let page: Page
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
  private var preparedPins: Set<UUID> = []
  private var submittedPins: Set<UUID> = []
  private var retired: [Retired] = []
  private var residentBytes = 0
  private var retiredBytes = 0
  private var reservations = 0
  private var directFallbackBytes = 0
  private var transientReplacementBytes = 0
  private var legacyBridgeBytes = 0
  private var deniedAllocations: UInt64 = 0
  private var useSerial: UInt64 = 0
  private var fallback: GlyphLease?

  init(device: MTLDevice, owner: DispatchQueue, worker: GlyphRasterWorker = GlyphRasterWorker(), budget: Int = 64 * 1024 * 1024,
       onReady: @escaping @Sendable () -> Void) {
    self.device = device
    self.owner = owner
    self.worker = worker
    byteBudget = budget
    self.onReady = onReady
  }

  func beginFrame() { preparedPins.removeAll(keepingCapacity: true) }

  func setOnReady(_ callback: @escaping @Sendable () -> Void) { onReady = callback }

  func resolve(_ recipe: GlyphRasterRecipe) -> GlyphLease? {
    useSerial &+= 1
    if var entry = entries[recipe] {
      entry.lastUse = useSerial
      entries[recipe] = entry
      if let page = entry.page { preparedPins.insert(page) }
      return entry.lease
    }
    if pending.insert(recipe).inserted {
      reservations += recipe.width * recipe.height * 4
      let accepted = worker.request(recipe) { [weak self] result in
        guard let self else { return }
        // Raster completion crosses the actor boundary before touching cache
        // state or Metal. Stale/cancelled results become harmless misses.
        self.owner.async { [weak self] in self?.accept(recipe, result: result) }
      }
      if !accepted {
        pending.remove(recipe)
        reservations -= recipe.width * recipe.height * 4
      }
    }
    return nil
  }

  // Must run on TerminalRendering's serial executor.
  private func accept(_ recipe: GlyphRasterRecipe, result: GlyphRasterResult?) {
    guard pending.remove(recipe) != nil else { return }
    reservations -= recipe.width * recipe.height * 4
    // A raster failure remains a miss: the visible fallback is retained and a
    // future request may retry instead of caching a blank texture.
    guard let result, !result.pixels.isEmpty, !result.glyphIDs.contains(0) else {
      onReady()
      return
    }
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
      kind: kind == .mask ? .mask : .color, allocation: placement.page.id)
    entries[recipe] = Entry(lease: lease, page: placement.page.id, bytes: recipe.width * recipe.height,
                            lastUse: useSerial)
    onReady()
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
                           texture: page.texture, kind: .mask, allocation: page.id)
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
    collectRetired()
  }

  func diagnostics() -> Diagnostics {
    Diagnostics(residentBytes: residentBytes, retiredBytes: retiredBytes, reservations: reservations,
                directFallbackBytes: directFallbackBytes, transientReplacementBytes: transientReplacementBytes,
                deniedAllocations: deniedAllocations)
  }

  // Transitional renderer textures still enter through the residency owner.
  // This closes the common migration bug where a new atlas obeys a process
  // budget while the old atlas silently remains outside it.
  func reserveLegacyTexture(_ descriptor: MTLTextureDescriptor) -> Int? {
    let capacity = Int(device.heapTextureSizeAndAlign(descriptor: descriptor).size)
    guard capacity > 0,
          residentBytes + retiredBytes + reservations + capacity <= byteBudget else {
      deniedAllocations &+= 1
      return nil
    }
    residentBytes += capacity
    legacyBridgeBytes += capacity
    return capacity
  }

  func cancelLegacyReservation(_ bytes: Int) {
    guard bytes > 0 else { return }
    residentBytes = max(0, residentBytes - bytes)
    legacyBridgeBytes = max(0, legacyBridgeBytes - bytes)
  }

  private func reserve(kind: PageKind, width: Int, height: Int) -> (page: Page, x: Int, y: Int)? {
    guard width > 0, height > 0, width + 1 < kind.side, height + 1 < kind.side else { return nil }
    for page in pages.values where page.kind == kind {
      if let result = reserve(on: page, width: width, height: height) { return result }
    }
    guard let page = createPage(kind), let result = reserve(on: page, width: width, height: height) else {
      return nil
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
    guard capacity > 0, residentBytes + retiredBytes + reservations + capacity <= byteBudget else {
      deniedAllocations &+= 1
      return nil
    }
    let heapDescriptor = MTLHeapDescriptor()
    heapDescriptor.storageMode = .shared
    heapDescriptor.size = sizeAndAlign.size
    guard let heap = device.makeHeap(descriptor: heapDescriptor) else { return nil }
    let actualCapacity = Int(heap.size)
    guard residentBytes + retiredBytes + reservations + actualCapacity <= byteBudget,
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

  private func collectRetired() {
    // There is one GPU submission in flight.  Pages are only retired after
    // their submitted pins drain, so releasing the heap is safe here.
    let releasable = retired.filter { $0.page.pins == 0 }
    retired.removeAll { $0.page.pins == 0 }
    for value in releasable { retiredBytes -= value.bytes }
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

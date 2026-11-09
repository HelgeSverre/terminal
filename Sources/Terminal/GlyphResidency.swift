import Foundation
import Metal
import simd
import Darwin

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
    let pendingJobs: Int
    let queuedUploads: Int
    let capacityWaiting: Bool
    var quiescent: Bool { pendingJobs == 0 && queuedUploads == 0 && !capacityWaiting }
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
  private var visibleDemand: Set<GlyphRasterRecipe> = []
  private var currentDemand: Set<GlyphRasterRecipe> = []
  private var surfaceDemand: [UUID: Set<GlyphRasterRecipe>] = [:]
  private var activeSurface: UUID?
  private var suppressedForDemand: Set<GlyphRasterRecipe> = []
  private var failed: Set<GlyphRasterRecipe> = []
  private var failedOrder: [GlyphRasterRecipe] = []
  private let failedLimit = 1024
  private var capacityWait = false
  // Results wait until the next safe frame boundary: an async CPU replace
  // must never overwrite a page sampled by the sole submitted command buffer.
  private struct QueuedUpload {
    let result: GlyphRasterResult
    let release: @Sendable () -> Void
  }
  private var uploadQueue: [QueuedUpload] = []
  private var preparedPins: Set<UUID> = []
  private var submittedPins: Set<UUID> = []
  private var preparedDirect: Set<UUID> = []
  private var submittedDirect: Set<UUID> = []
  private var residentBytes = 0
  private var reservations = 0
  private var directFallbackBytes = 0
  private var transientReplacementBytes = 0
  private var legacyBridgeBytes = 0
  private var activeLegacy: [UUID: Int] = [:]
  private struct DirectResident { let allocation: LegacyTexture; let recipe: GlyphRasterRecipe; var pins: Int }
  private var directResident: [UUID: DirectResident] = [:]
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

  // Metal reports a texture's placement requirement, not necessarily the
  // allocation granularity of the heap that will contain it. Heaps are also
  // rounded to a VM page on this target, so charge the maximum granularity
  // before creating one. This value matches MTLHeap.size for our descriptors.
  static func heapCapacity(device: MTLDevice, descriptor: MTLTextureDescriptor) -> Int {
    let requirement = device.heapTextureSizeAndAlign(descriptor: descriptor)
    guard requirement.size > 0, requirement.align > 0 else { return 0 }
    let granularity = max(requirement.align, Int(getpagesize()))
    let remainder = requirement.size % granularity
    let capacity = remainder == 0
      ? requirement.size
      : requirement.size + (granularity - remainder)
    return capacity
  }

  func beginFrame(surface: UUID? = nil) {
    activeSurface = surface
    currentDemand.removeAll(keepingCapacity: true)
    preparedPins.removeAll(keepingCapacity: true)
    preparedDirect.removeAll(keepingCapacity: true)
    let uploads = uploadQueue
    uploadQueue.removeAll(keepingCapacity: true)
    for upload in uploads {
      switch install(upload.result) {
      case .installed, .impossible: upload.release()
      case .waitingForCapacity: uploadQueue.append(upload)
      }
    }
  }

  func setOnReady(_ callback: @escaping @Sendable () -> Void) { onReady = callback }

  func resolve(_ recipe: GlyphRasterRecipe) -> GlyphLease? {
    currentDemand.insert(recipe)
    if let entry = entries[recipe] {
      if let page = entry.page {
        guard let current = pages[page], current.generation == entry.lease.allocationGeneration else {
          entries.removeValue(forKey: recipe)
          return resolve(recipe)
        }
        preparedPins.insert(page)
      } else if let id = entry.lease.allocation, directResident[id] != nil {
        preparedDirect.insert(id)
      }
      return entry.lease
    }
    guard !failed.contains(recipe), !suppressedForDemand.contains(recipe) else { return nil }
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

  // Called after a renderer has resolved every glyph for one complete scene.
  // Internal raster repaint does not change this set; pane/font/close changes
  // do, which makes previously suppressed capacity misses eligible again.
  func finishFrameDemand() {
    let previousDemand = visibleDemand
    if let activeSurface { surfaceDemand[activeSurface] = currentDemand }
    let nextDemand = activeSurface == nil
      ? currentDemand
      : surfaceDemand.values.reduce(into: Set<GlyphRasterRecipe>()) { $0.formUnion($1) }
    guard nextDemand != previousDemand else { return }
    let hadEstablishedDemand = !previousDemand.isEmpty
    visibleDemand = nextDemand
    // Initial discovery of an oversubscribed scene settles resident+outline;
    // later admission consults the visible-demand union directly rather than
    // a one-install global permit.
    if hadEstablishedDemand && !suppressedForDemand.isEmpty {
      suppressedForDemand.removeAll(keepingCapacity: true)
      onReady()
    }
  }

  func detachSurface(_ id: UUID) {
    guard surfaceDemand.removeValue(forKey: id) != nil else { return }
    let nextDemand = surfaceDemand.values.reduce(into: Set<GlyphRasterRecipe>()) { $0.formUnion($1) }
    guard nextDemand != visibleDemand else { return }
    visibleDemand = nextDemand
    if !suppressedForDemand.isEmpty {
      suppressedForDemand.removeAll(keepingCapacity: true)
      onReady()
    }
  }

  // Must run on TerminalRendering's serial executor.
  private func accept(_ recipe: GlyphRasterRecipe, result: GlyphRasterResult?, release: @escaping @Sendable () -> Void) {
    guard pending.remove(recipe) != nil else { release(); return }
    reservations -= recipe.width * recipe.height * 4
    // A raster failure remains a miss: the visible fallback is retained and a
    // future request may retry instead of caching a blank texture.
    guard let result, !result.pixels.isEmpty, !result.glyphIDs.contains(0) else {
      rememberFailure(recipe)
      release()
      onReady()
      return
    }
    uploadQueue.append(QueuedUpload(result: result, release: release))
    onReady()
  }

  // Called only by beginFrame, after the preceding one-in-flight submission
  // has completed and released its pins.
  private enum InstallOutcome { case installed, waitingForCapacity, impossible }
  private func install(_ result: GlyphRasterResult) -> InstallOutcome {
    let recipe = result.recipe
    let kind: PageKind = result.kind == .mask ? .mask : .color
    guard recipe.width > 0, recipe.height > 0 else { rememberFailure(recipe); return .impossible }
    if recipe.width + 1 >= kind.side || recipe.height + 1 >= kind.side {
      return installOversize(result, kind: kind)
    }
    // A staged batch represents one unchanged visible demand. Do not evict a
    // peer admitted earlier in that batch: two individually-fitting glyphs
    // must settle on resident+outline, not alternate eviction every frame.
    guard let placement = reserve(kind: kind, width: recipe.width, height: recipe.height,
      allowEviction: true) else {
      // Other bounded CPU jobs still reserve worst-case RGBA capacity. Their
      // acceptance releases those reservations and requests another frame.
      if reservations > 0 { return .waitingForCapacity }
      guard pages.values.contains(where: { $0.kind == kind && $0.pins > 0 }) else {
        suppressedForDemand.insert(recipe)
        return .impossible
      }
      capacityWait = true
      return .waitingForCapacity
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
    return .installed
  }

  private func installOversize(_ result: GlyphRasterResult, kind: PageKind) -> InstallOutcome {
    let recipe = result.recipe
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: kind.format,
      width: recipe.width, height: recipe.height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let available = makeLegacyTexture(descriptor)
    // Do not retire cached GPU allocations when another CPU reservation
    // would prevent their replacement anyway. Its callback will wake us.
    if available == nil && reservations > 0 { return .waitingForCapacity }
    guard let allocation = available ?? reclaimDirectAndAllocate(descriptor) else {
      // Pin pressure is temporary: preserve the bitmap until completion,
      // rather than putting a successfully rasterized glyph in failed.
      if directResident.values.contains(where: { $0.pins > 0 && !visibleDemand.contains($0.recipe) }) {
        capacityWait = true
        return .waitingForCapacity
      }
      // An unchanged oversized working set settles on resident+outline.
      // A later scene change/detach clears this capacity suppression.
      suppressedForDemand.insert(recipe)
      return .impossible
    }
    var pixels = result.pixels
    if kind == .mask { pixels = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0 + 3] } }
    else { convertPremultipliedSRGBToLinear(&pixels) }
    let row = recipe.width * (kind == .mask ? 1 : 4)
    pixels.withUnsafeBytes {
      allocation.texture.replace(region: MTLRegionMake2D(0, 0, recipe.width, recipe.height),
        mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: row)
    }
    directResident[allocation.id] = DirectResident(allocation: allocation, recipe: recipe, pins: 0)
    directFallbackBytes += allocation.capacity
    let lease = GlyphLease(uv: SIMD4(0, 0, 1, 1), width: recipe.width,
      texture: allocation.texture, kind: kind == .mask ? .mask : .color,
      allocation: allocation.id, allocationGeneration: nil)
    entries[recipe] = Entry(lease: lease, page: nil, bytes: allocation.capacity)
    return .installed
  }

  private func reclaimDirectAndAllocate(_ descriptor: MTLTextureDescriptor) -> LegacyTexture? {
    while reclaimUnusedDirect() {
      if let allocation = makeLegacyTexture(descriptor) { return allocation }
    }
    return nil
  }

  private func reclaimUnusedDirect() -> Bool {
    guard let victim = directResident.values.first(where: {
      $0.pins == 0 && !visibleDemand.contains($0.recipe)
    }) else { return false }
    directResident.removeValue(forKey: victim.allocation.id)
    entries.removeValue(forKey: victim.recipe)
    directFallbackBytes -= victim.allocation.capacity
    releaseLegacyTexture(victim.allocation.id)
    // The local heap/texture reference dies when this helper returns, before
    // its caller allocates the replacement capacity.
    return true
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
    submittedDirect.formUnion(preparedDirect)
    preparedDirect.removeAll(keepingCapacity: true)
    for id in submittedDirect { directResident[id]?.pins += 1 }
  }

  func abandonedPreparedFrame() {
    preparedPins.removeAll(keepingCapacity: true)
    preparedDirect.removeAll(keepingCapacity: true)
  }

  func completedSubmission() {
    let releasedPins = !submittedPins.isEmpty || !submittedDirect.isEmpty
    for id in submittedPins {
      guard var page = pages[id] else { continue }
      page.pins = max(0, page.pins - 1)
      pages[id] = page
    }
    submittedPins.removeAll(keepingCapacity: true)
    for id in submittedDirect {
      guard var direct = directResident[id] else { continue }
      direct.pins = max(0, direct.pins - 1)
      directResident[id] = direct
    }
    submittedDirect.removeAll(keepingCapacity: true)
    if releasedPins && capacityWait {
      capacityWait = false
      onReady()
    }
  }

  func diagnostics() -> Diagnostics {
    Diagnostics(residentBytes: residentBytes, retiredBytes: 0, reservations: reservations,
                directFallbackBytes: directFallbackBytes, transientReplacementBytes: transientReplacementBytes,
                deniedAllocations: deniedAllocations, pendingJobs: pending.count,
                queuedUploads: uploadQueue.count, capacityWaiting: capacityWait)
  }

  // The legacy bridge uses the same heap admission path as native pages. The
  // actual heap capacity is charged before its texture exists.
  func makeLegacyTexture(_ descriptor: MTLTextureDescriptor) -> LegacyTexture? {
    let capacity = Self.heapCapacity(device: device, descriptor: descriptor)
    guard capacity > 0, residentBytes + reservations + capacity <= byteBudget else {
      deniedAllocations &+= 1
      return nil
    }
    let heapDescriptor = MTLHeapDescriptor()
    heapDescriptor.storageMode = descriptor.storageMode
    heapDescriptor.size = capacity
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

  private func reserve(kind: PageKind, width: Int, height: Int,
                       allowEviction: Bool = true) -> (page: Page, x: Int, y: Int)? {
    guard width > 0, height > 0, width + 1 < kind.side, height + 1 < kind.side else { return nil }
    for page in pages.values where page.kind == kind {
      if let result = reserve(on: page, width: width, height: height) { return result }
    }
    guard let page = createPage(kind), let result = reserve(on: page, width: width, height: height) else {
      // All charged pages are full. Reclaim only a page no submitted frame can
      // still sample; its generation invalidates every old lease/UV.
      guard allowEviction,
        let victim = pages.values.first(where: {
          $0.kind == kind && $0.pins == 0 && pageIsEvictable($0.id)
        }) else {
        return nil
      }
      evict(victim.id)
      guard let recycled = pages[victim.id] else { return nil }
      return reserve(on: recycled, width: width, height: height)
    }
    return result
  }

  private func pageIsEvictable(_ id: UUID) -> Bool {
    // With no completed scene yet, preserve the first resident page rather
    // than churn through a staged batch before demand is known.
    guard !visibleDemand.isEmpty else { return false }
    for (recipe, entry) in entries where entry.page == id {
      if visibleDemand.contains(recipe) { return false }
    }
    return true
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
    let capacity = Self.heapCapacity(device: device, descriptor: descriptor)
    // Account capacity before heap allocation.  A failed allocation never
    // leaves an optimistic budget charge behind.
    guard capacity > 0, residentBytes + reservations + capacity <= byteBudget else {
      deniedAllocations &+= 1
      return nil
    }
    let heapDescriptor = MTLHeapDescriptor()
    heapDescriptor.storageMode = .shared
    heapDescriptor.size = capacity
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

  private func rememberFailure(_ recipe: GlyphRasterRecipe) {
    guard failed.insert(recipe).inserted else { return }
    failedOrder.append(recipe)
    if failedOrder.count > failedLimit {
      failed.remove(failedOrder.removeFirst())
    }
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

  #if GLYPH_RESIDENCY_TESTING
  func testingWorkIsIdle() -> Bool { pending.isEmpty && uploadQueue.isEmpty }
  func testingUploadCount() -> Int { uploadQueue.count }
  func testingSummary() -> String {
    "resident=\(entries.keys.map(\.text).sorted()) visible=\(visibleDemand.map(\.text).sorted()) suppressed=\(suppressedForDemand.map(\.text).sorted()) failed=\(failed.map(\.text).sorted()) bytes=\(residentBytes)/\(byteBudget) reserved=\(reservations)"
  }
  // Narrow headless probes keep the production API free of allocator knobs
  // while exercising real MTLHeap admission/reclaim behavior.
  func testingRecycleAndGeneration() -> Bool {
    guard let first = createPage(.mask), var page = pages[first.id] else { return false }
    let recipe = GlyphRasterRecipe(text: "x", width: 8, height: 8, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    let stale = GlyphLease(uv: SIMD4(0, 0, 1, 1), width: 8, texture: page.texture,
      kind: .mask, allocation: page.id, allocationGeneration: page.generation)
    entries[recipe] = Entry(lease: stale, page: page.id, bytes: 64)
    visibleDemand = [GlyphRasterRecipe(text: "other", width: 8, height: 8, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)]
    page.x = page.kind.side - 1
    page.y = page.kind.side - 1
    pages[page.id] = page
    guard let recycled = reserve(kind: .mask, width: 8, height: 8),
      recycled.page.id == page.id, recycled.page.generation == page.generation + 1
    else { return false }
    return resolve(recipe) == nil
  }

  func testingPinnedPageBlocksReclaim() -> Bool {
    guard let first = createPage(.color), var page = pages[first.id] else { return false }
    visibleDemand = [GlyphRasterRecipe(text: "other", width: 8, height: 8, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)]
    page.x = page.kind.side - 1; page.y = page.kind.side - 1
    pages[page.id] = page
    preparedPins.insert(page.id); submitted()
    let blocked = reserve(kind: .color, width: 8, height: 8) == nil
    completedSubmission()
    let recovered = reserve(kind: .color, width: 8, height: 8) != nil
    return blocked && recovered
  }

  func testingLegacyReleaseExactlyOnce() -> Bool {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
      width: 8, height: 8, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let allocation = makeLegacyTexture(descriptor) else { return false }
    let charged = diagnostics().residentBytes
    releaseLegacyTexture(allocation.id)
    let released = diagnostics().residentBytes
    releaseLegacyTexture(allocation.id)
    return charged > released && diagnostics().residentBytes == released
  }

  func testingLegacyHeapDropsWithLease() -> Bool {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
      width: 8, height: 8, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    weak var weakHeap: MTLHeap?
    var id: UUID?
    autoreleasepool {
      var allocation: LegacyTexture? = makeLegacyTexture(descriptor)
      weakHeap = allocation?.heap
      id = allocation?.id
      allocation = nil
    }
    guard let id else { return false }
    // The residency retains only the scalar charge keyed by id, never a GPU
    // object. The heap must die before releasing that charge.
    guard weakHeap == nil else { return false }
    releaseLegacyTexture(id)
    return diagnostics().residentBytes == 0
  }

  func testingOversizeWorkingSetStabilizes() -> Bool {
    guard let first = createPage(.mask), var page = pages[first.id] else { return false }
    visibleDemand = [GlyphRasterRecipe(text: "other", width: 8, height: 8, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)]
    let charged = diagnostics().residentBytes
    let startGeneration = page.generation
    // Simulate a working set repeatedly exceeding a one-page budget. Every
    // cycle must recycle the one charged page, never add another heap.
    for _ in 0..<32 {
      page.x = page.kind.side - 1; page.y = page.kind.side - 1
      pages[page.id] = page
      guard let next = reserve(kind: .mask, width: 8, height: 8), next.page.id == page.id else {
        return false
      }
      page = next.page
    }
    return pages.count == 1 && page.generation == startGeneration + 32
      && diagnostics().residentBytes == charged
  }

  func testingNegativeCacheIsBoundedAndRecipeScoped() -> Bool {
    for index in 0...failedLimit {
      rememberFailure(GlyphRasterRecipe(text: "bad\(index)", width: 8, height: 8,
        pointSize: 12, bold: false, italic: false, fontIdentity: "bad", backingScale: 1))
    }
    let changedFont = GlyphRasterRecipe(text: "bad0", width: 8, height: 8,
      pointSize: 12, bold: false, italic: false, fontIdentity: "new-font", backingScale: 1)
    return failed.count == failedLimit && !failed.contains(changedFont)
  }

  func testingTwoGlyphWorkingSetSettles() -> Bool {
    let a = GlyphRasterRecipe(text: "A", width: 600, height: 600, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    let b = GlyphRasterRecipe(text: "B", width: 600, height: 600, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    let bitmap = [UInt8](repeating: 255, count: 600 * 600 * 4)
    let resultA = GlyphRasterResult(recipe: a, pixels: bitmap, kind: .mask,
      resolvedFonts: ["Menlo-Regular"], glyphIDs: [1])
    let resultB = GlyphRasterResult(recipe: b, pixels: bitmap, kind: .mask,
      resolvedFonts: ["Menlo-Regular"], glyphIDs: [2])
    guard install(resultA) == .installed, install(resultB) == .impossible,
      entries[a] != nil, entries[b] == nil, suppressedForDemand.contains(b)
    else { return false }
    // First completed scene establishes unchanged visible A+B demand. B is
    // suppressed (outline), not permanently failed, and A stays resident.
    let residentA = resolve(a) != nil
    let stillMissingB = resolve(b) == nil
    finishFrameDemand()
    guard residentA && stillMissingB && pages.count == 1 else { return false }
    // A close/demand change to B alone clears suppression; a returned B raster
    // can now evict invisible A and become resident.
    currentDemand = [b]; finishFrameDemand()
    // No upload is ready in the first B-only frame. The eviction permit must
    // survive this empty beginFrame until the worker's delayed B result is
    // installed on the following preparation boundary.
    beginFrame()
    guard install(resultB) == .installed, entries[b] != nil, entries[a] == nil else { return false }
    return true
  }

  func testingPrepareDelayedBRecovery() -> GlyphRasterRecipe? {
    let a = GlyphRasterRecipe(text: "A", width: 600, height: 600, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    let b = GlyphRasterRecipe(text: "B", width: 600, height: 600, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    let bitmap = [UInt8](repeating: 255, count: 600 * 600 * 4)
    guard install(GlyphRasterResult(recipe: a, pixels: bitmap, kind: .mask,
      resolvedFonts: ["Menlo-Regular"], glyphIDs: [1])) == .installed,
      install(GlyphRasterResult(recipe: b, pixels: bitmap, kind: .mask,
      resolvedFonts: ["Menlo-Regular"], glyphIDs: [2])) == .impossible
    else { return nil }
    _ = resolve(a); _ = resolve(b); finishFrameDemand() // establish A+B
    currentDemand = [b]; finishFrameDemand() // A detached, B eligible
    return b
  }

  func testingOversizeExactResident() -> Bool {
    let recipe = GlyphRasterRecipe(text: "W", width: 1024, height: 8, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    let pixels = [UInt8](repeating: 255, count: recipe.width * recipe.height * 4)
    guard install(GlyphRasterResult(recipe: recipe, pixels: pixels, kind: .mask,
      resolvedFonts: ["Menlo-Regular"], glyphIDs: [1])) == .installed,
      let lease = resolve(recipe)
    else { return false }
    return lease.width == recipe.width && lease.uv == SIMD4(0, 0, 1, 1)
      && directFallbackBytes > 0
  }

  func testingHasResident(_ recipe: GlyphRasterRecipe) -> Bool { entries[recipe] != nil }
  #endif
}

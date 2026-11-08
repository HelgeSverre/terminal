import AppKit
import CoreText
import Metal
import QuartzCore
import simd

struct GridSelection: Equatable {
  var start: Int
  var end: Int
  var lower: Int { min(start, end) }
  var upper: Int { max(start, end) }
}
struct RenderRequest {
  let snapshot: TerminalSnapshot
  let width: Int
  let height: Int
  let inset: Int
  let cellWidth: Int
  let cellHeight: Int
  let fontSize: CGFloat
  let focused: Bool
  let scrolled: Bool
  let selection: GridSelection?
  let marked: String
}
private struct Quad {
  var rect: SIMD4<Float>
  var uv: SIMD4<Float>
  var color: SIMD4<Float>
  // x == 0 denotes R8 coverage, x == 1 denotes premultiplied linear RGBA.
  var material: SIMD4<Float> = SIMD4(1, 0, 0, 0)
}
// Transitional drawing record. Residency owns admission and texture lifetime;
// frame assembly retains only this resolved lease shape.
private struct GlyphKey: Hashable {
  let text: String
  let cells: Int
  let bold: Bool
  let italic: Bool
  let width: Int
  let height: Int
  let pointSize: Int
  let fontIdentity: String
}
private struct Glyph {
  let uv: SIMD4<Float>
  let width: Int
  let atlasPage: Int?
  let texture: MTLTexture?
  let kind: GlyphLease.Kind
  let heap: MTLHeap?
  let legacyID: UUID?
}
private struct SurfaceImageKey: Hashable {
  let surface: UUID
  let image: ImageKey
}

// The application owns rendering, rather than every terminal pane owning a
// command queue and glyph cache. A pane receives only an opaque surface lease.
// Rendering state, GPU submissions, and (eventually) glyph residency therefore
// have one place to enforce lifetime and process-wide resource rules.
final class TerminalRendering: @unchecked Sendable {
  final class SurfaceLease: @unchecked Sendable {
    fileprivate let id = UUID()
    private let completionLock = NSLock()
    private var completedSnapshotRevision: UInt64 = 0
    fileprivate func recordCompletedRevision(_ revision: UInt64) {
      completionLock.lock()
      completedSnapshotRevision = max(completedSnapshotRevision, revision)
      completionLock.unlock()
    }
    fileprivate func completedRevision() -> UInt64 {
      completionLock.lock()
      defer { completionLock.unlock() }
      return completedSnapshotRevision
    }
  }
  struct SurfaceStatus {
    let attached: Bool
    let completedSnapshotRevision: UInt64
    let lastTargetTimestamp: CFTimeInterval
    let lastPresentationTargetTimestamp: CFTimeInterval
  }
  private struct SurfaceState {
    let lease: SurfaceLease
    let layer: CAMetalLayer
    let displayLink: SurfaceDisplayLink
    var latest: RenderRequest?
    var lastRendered: RenderRequest?
    var generation: UInt64 = 0
    var awaitingDrawable = false
    var pendingDrawable: CAMetalDrawable?
    var rendering = false
    var targetTimestamp: CFTimeInterval = 0
    var targetPresentationTimestamp: CFTimeInterval = 0
  }
  private struct Submission {
    let request: RenderRequest
    let drawable: CAMetalDrawable
    let surface: SurfaceLease
    let generation: UInt64
  }
  // CAMetalDisplayLink supplies a drawable in its update callback, avoiding a
  // blocking nextDrawable call. This object lives on the main run loop; it
  // never encodes Metal work itself.
  private final class SurfaceDisplayLink: NSObject, CAMetalDisplayLinkDelegate {
    private weak var rendering: TerminalRendering?
    private let lease: SurfaceLease
    private let link: CAMetalDisplayLink
    private var invalidated = false
    init(rendering: TerminalRendering, lease: SurfaceLease, layer: CAMetalLayer) {
      self.rendering = rendering
      self.lease = lease
      link = CAMetalDisplayLink(metalLayer: layer)
      super.init()
      link.delegate = self
      link.add(to: .main, forMode: .common)
      link.isPaused = true
    }
    func requestFrame() {
      let resume = { [weak self] in
        guard let self, !self.invalidated else { return }
        self.link.isPaused = false
      }
      if Thread.isMainThread { resume() }
      else { DispatchQueue.main.async(execute: resume) }
    }
    func invalidate() {
      let stop = { [self] in
        guard !invalidated else { return }
        self.invalidated = true
        self.link.isPaused = true
        self.link.invalidate()
      }
      if Thread.isMainThread { stop() }
      else { DispatchQueue.main.async(execute: stop) }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
      guard link === self.link, !invalidated else { return }
      // Demand-paused: each accepted update hands one drawable to the owner.
      // A newer request can re-arm the link after this callback returns.
      link.isPaused = true
      rendering?.received(
        drawable: update.drawable, target: update.targetTimestamp,
        presentationTarget: update.targetPresentationTimestamp, surface: lease)
    }
  }
  private let device: MTLDevice
  private let commands: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let imagePipeline: MTLRenderPipelineState
  private var imageTextures: [SurfaceImageKey: MTLTexture] = [:]
  // All Metal encoding and all shared residency mutation happen here. A
  // demand-paused CAMetalDisplayLink provides already-available drawables.
  private let executor = DispatchQueue(label: "no.helgesverre.terminal.render", qos: .userInteractive)
  private let surfacesLock = NSLock()
  private var surfaces: [UUID: SurfaceState] = [:]
  // Ready drawables are admitted FIFO. A nonresponsive/off-display surface has
  // no queue entry and therefore cannot gate a healthy surface.
  private var readySurfaces: [UUID] = []
  private var readySet: Set<UUID> = []
  private var drainScheduled = false
  private var gpuBusy = false
  private let glyphResidency: GlyphResidency
  private var atlases: [MTLTexture] = []
  private var atlasHeaps: [MTLHeap] = []
  private var glyphs: [GlyphKey: Glyph] = [:]
  private var atlasX: [Int] = []
  private var atlasY: [Int] = []
  private var shelves: [Int] = []
  private var frameAtlasPages: Set<Int> = []
  private var directGlyphBytes = 0
  private var directGlyphCount = 0
  private var directGlyphExhausted = false
  private var replacementGlyph: Glyph?
  private let atlasSize: Int
  private let atlasPages: Int
  private let directGlyphBudget: Int
  private let directGlyphLimit: Int
  private var metrics = SIMD2<Int>(0, 0)
  private var fontSize: CGFloat = 0
  private var font: CTFont
  private var boldFont: CTFont
  private var italicFont: CTFont
  private var boldItalicFont: CTFont
  private var submissions: UInt64 = 0
  init() throws {
    guard let gpu = MTLCreateSystemDefaultDevice(), let commands = gpu.makeCommandQueue() else {
      throw RendererError.noDevice
    }
    device = gpu
    self.commands = commands
    let pressureSmoke = CommandLine.arguments.contains("--atlas-pressure-smoke")
    let fallbackBudgetSmoke = CommandLine.arguments.contains("--atlas-fallback-budget-smoke")
    atlasSize = pressureSmoke ? 128 : 2048
    atlasPages = pressureSmoke ? 4 : 2
    directGlyphBudget = fallbackBudgetSmoke ? 0 : 8 * 1024 * 1024
    directGlyphLimit = fallbackBudgetSmoke ? 0 : 1024
    guard let libraryURL = Bundle.main.url(forResource: "Terminal", withExtension: "metallib")
    else { throw RendererError.noShaders }
    let library = try gpu.makeLibrary(URL: libraryURL)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "terminal_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "terminal_fragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
    descriptor.fragmentFunction = library.makeFunction(name: "terminal_image_fragment")
    imagePipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
    let legacyDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
    legacyDescriptor.storageMode = .shared; legacyDescriptor.usage = .shaderRead
    // The denial smoke leaves room for exactly the legacy solid texel atlas
    // that keeps allocation-free outlines visible.  It deliberately leaves
    // no native mask/direct heap capacity, so its result is a real global
    // budget denial rather than a legacy-atlas initialization failure.
    let sharedBudget = fallbackBudgetSmoke
      ? GlyphResidency.heapCapacity(device: gpu, descriptor: legacyDescriptor)
      : 64 * 1024 * 1024
    glyphResidency = GlyphResidency(device: gpu, owner: executor, budget: sharedBudget) {}
    font = TerminalFont.core(size: 14)
    boldFont = font
    italicFont = font
    boldItalicFont = font
    guard appendAtlasPage() != nil else { throw RendererError.noMemory }
    resetAtlas()
    glyphResidency.setOnReady { [weak self] in self?.redisplayAfterGlyphReady() }
  }
  enum RendererError: Error { case noDevice, noShaders, noMemory }
  func attach(_ layer: CAMetalLayer) -> SurfaceLease {
    precondition(Thread.isMainThread)
    layer.device = device
    layer.pixelFormat = .bgra8Unorm_srgb
    layer.framebufferOnly = true
    layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    layer.isOpaque = true
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
    let lease = SurfaceLease()
    let displayLink = SurfaceDisplayLink(rendering: self, lease: lease, layer: layer)
    surfacesLock.lock()
    surfaces[lease.id] = SurfaceState(lease: lease, layer: layer, displayLink: displayLink)
    surfacesLock.unlock()
    return lease
  }
  func detach(_ lease: SurfaceLease) {
    precondition(Thread.isMainThread)
    surfacesLock.lock()
    let surface = surfaces.removeValue(forKey: lease.id)
    readySet.remove(lease.id)
    readySurfaces.removeAll { $0 == lease.id }
    surfacesLock.unlock()
    surface?.displayLink.invalidate()
    executor.async { [weak self] in
      self?.imageTextures = self?.imageTextures.filter { $0.key.surface != lease.id } ?? [:]
      self?.glyphResidency.detachSurface(lease.id)
    }
  }
  func surfaceStatus(_ lease: SurfaceLease?, layer: CAMetalLayer?) -> SurfaceStatus {
    guard let layer, let lease else {
      return SurfaceStatus(
        attached: false, completedSnapshotRevision: 0, lastTargetTimestamp: 0,
        lastPresentationTargetTimestamp: 0)
    }
    surfacesLock.lock()
    defer { surfacesLock.unlock() }
    let surface = surfaces[lease.id]
    let attached = surface?.layer === layer
    return SurfaceStatus(
      attached: attached, completedSnapshotRevision: attached ? lease.completedRevision() : 0,
      lastTargetTimestamp: attached ? surface?.targetTimestamp ?? 0 : 0,
      lastPresentationTargetTimestamp: attached ? surface?.targetPresentationTimestamp ?? 0 : 0)
  }
  func request(_ lease: SurfaceLease, latest value: RenderRequest) {
    var displayLinks: [SurfaceDisplayLink] = []
    surfacesLock.lock()
    if var surface = surfaces[lease.id] {
      surface.latest = value
      surface.generation &+= 1
      surfaces[lease.id] = surface
      if surface.pendingDrawable != nil { enqueueReadyLocked(lease.id) }
      displayLinks = armEligibleSurfacesLocked()
    }
    surfacesLock.unlock()
    displayLinks.forEach { $0.requestFrame() }
    scheduleDrain()
  }
  private func beginDisplayLinkLocked(_ surface: SurfaceState) -> SurfaceDisplayLink? {
    guard !surface.awaitingDrawable, surface.pendingDrawable == nil, !surface.rendering,
      surface.latest != nil
    else {
      return nil
    }
    var updated = surface
    updated.awaitingDrawable = true
    surfaces[surface.lease.id] = updated
    return surface.displayLink
  }
  private func armEligibleSurfacesLocked() -> [SurfaceDisplayLink] {
    Array(surfaces.values).compactMap { beginDisplayLinkLocked($0) }
  }
  private func enqueueReadyLocked(_ id: UUID) {
    guard readySet.insert(id).inserted else { return }
    readySurfaces.append(id)
  }
  private func nextSubmissionLocked() -> Submission? {
    guard !gpuBusy else { return nil }
    while !readySurfaces.isEmpty {
      let id = readySurfaces.removeFirst()
      readySet.remove(id)
      guard var surface = surfaces[id], !surface.rendering,
        let request = surface.latest, let drawable = surface.pendingDrawable
      else { continue }
      surface.pendingDrawable = nil
      surface.rendering = true
      surface.lastRendered = request
      let generation = surface.generation
      surfaces[id] = surface
      gpuBusy = true
      return Submission(request: request, drawable: drawable, surface: surface.lease, generation: generation)
    }
    return nil
  }
  private func submit(_ submission: Submission?) {
    guard let submission else { return }
    if !draw(
      submission.request, drawable: submission.drawable, surface: submission.surface,
      generation: submission.generation)
    {
      finishedWithoutSubmission(surface: submission.surface, generation: submission.generation)
    }
  }
  private func drainReady() {
    var displayLinks: [SurfaceDisplayLink] = []
    surfacesLock.lock()
    drainScheduled = false
    displayLinks = armEligibleSurfacesLocked()
    let submission = nextSubmissionLocked()
    surfacesLock.unlock()
    displayLinks.forEach { $0.requestFrame() }
    submit(submission)
  }
  private func scheduleDrain() {
    surfacesLock.lock()
    guard !drainScheduled else {
      surfacesLock.unlock()
      return
    }
    drainScheduled = true
    surfacesLock.unlock()
    executor.async { [weak self] in self?.drainReady() }
  }
  // Raster completion has no surface-local ownership.  It wakes the same
  // fair scheduler that accepts display-link drawables; a newer snapshot will
  // therefore present the resident glyph without a worker-side UI call.
  private func redisplayAfterGlyphReady() {
    var displayLinks: [SurfaceDisplayLink] = []
    surfacesLock.lock()
    for id in surfaces.keys {
      guard var surface = surfaces[id],
        let previous = surface.lastRendered
      else { continue }
      // A result can arrive while this surface's fallback frame is in flight.
      // Bump the demand generation even when latest is already nonnil, so that
      // completion cannot clear the replacement request as if it were old.
      if surface.latest == nil { surface.latest = previous }
      surface.generation &+= 1
      surfaces[id] = surface
    }
    displayLinks = armEligibleSurfacesLocked()
    surfacesLock.unlock()
    displayLinks.forEach { $0.requestFrame() }
    scheduleDrain()
  }
  // The display-link callback can arrive on the main run loop. Keep it tiny:
  // ownership validation and Metal encoding remain serialized on executor.
  fileprivate func received(
    drawable: CAMetalDrawable, target: CFTimeInterval, presentationTarget: CFTimeInterval,
    surface lease: SurfaceLease
  ) {
    executor.async { [weak self, lease] in
      self?.accept(
        drawable: drawable, target: target, presentationTarget: presentationTarget, surface: lease)
    }
  }
  private func accept(
    drawable: CAMetalDrawable, target: CFTimeInterval, presentationTarget: CFTimeInterval,
    surface lease: SurfaceLease
  ) {
    var displayLinks: [SurfaceDisplayLink] = []
    var submission: Submission?
    surfacesLock.lock()
    guard var surface = surfaces[lease.id] else {
      surfacesLock.unlock()
      return
    }
    // Pausing a display link does not cancel a callback already enqueued by
    // Core Animation. Only the callback matching our outstanding demand may
    // retain a drawable; all late/duplicate updates are released immediately.
    guard surface.awaitingDrawable, !surface.rendering, surface.pendingDrawable == nil,
      surface.latest != nil
    else {
      surfacesLock.unlock()
      return
    }
    surface.awaitingDrawable = false
    surface.targetTimestamp = target
    surface.targetPresentationTimestamp = presentationTarget
    // Keep at most one supplied drawable for a surface. It may wait behind a
    // different GPU submission, but no off-display surface can block another.
    surface.pendingDrawable = drawable
    enqueueReadyLocked(lease.id)
    surfaces[lease.id] = surface
    displayLinks = armEligibleSurfacesLocked()
    submission = nextSubmissionLocked()
    surfacesLock.unlock()
    displayLinks.forEach { $0.requestFrame() }
    submit(submission)
  }
  private func finishedWithoutSubmission(surface lease: SurfaceLease, generation: UInt64) {
    surfacesLock.lock()
    if var surface = surfaces[lease.id] {
      surface.rendering = false
      surfaces[lease.id] = surface
    }
    gpuBusy = false
    let displayLinks = armEligibleSurfacesLocked()
    let submission = nextSubmissionLocked()
    surfacesLock.unlock()
    displayLinks.forEach { $0.requestFrame() }
    submit(submission)
  }
  private func completed(
    surface lease: SurfaceLease, generation: UInt64, revision: UInt64, command: MTLCommandBuffer
  ) {
    RendererMetrics.completed(
      gpuMs: (command.gpuEndTime - command.gpuStartTime) * 1000, error: command.error != nil)
    surfacesLock.lock()
    if var surface = surfaces[lease.id] {
      surface.rendering = false
      if command.error == nil {
        lease.recordCompletedRevision(revision)
        if surface.generation == generation {
          surface.latest = nil
          // Defensive release if a duplicate callback raced an older build.
          surface.pendingDrawable = nil
        }
      }
      surfaces[lease.id] = surface
    }
    gpuBusy = false
    let displayLinks = armEligibleSurfacesLocked()
    let submission = nextSubmissionLocked()
    surfacesLock.unlock()
    displayLinks.forEach { $0.requestFrame() }
    submit(submission)
  }
  private func resetAtlas() {
    glyphs.removeAll(keepingCapacity: true)
    atlasX = Array(repeating: 4, count: atlases.count)
    atlasY = Array(repeating: 0, count: atlases.count)
    shelves = Array(repeating: 0, count: atlases.count)
    replacementGlyph = nil
    var white: [UInt8] = [255, 255, 255, 255]
    for atlas in atlases { white.withUnsafeMutableBytes {
      atlas.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4)
    }}
  }
  private func appendAtlasPage() -> Int? {
    guard atlases.count < atlasPages else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let allocation = glyphResidency.makeLegacyTexture(descriptor) else { return nil }
    let atlas = allocation.texture
    atlases.append(atlas); atlasX.append(4); atlasY.append(0); shelves.append(0)
    atlasHeaps.append(allocation.heap)
    var white: [UInt8] = [255, 255, 255, 255]
    white.withUnsafeMutableBytes { atlas.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
    RendererMetrics.recordAtlasPages(atlases.count)
    return atlases.count - 1
  }
  private func resetAtlasPage(_ page: Int) {
    glyphs = glyphs.filter { $0.value.atlasPage != page }
    atlasX[page] = 4; atlasY[page] = 0; shelves[page] = 0
    var white: [UInt8] = [255, 255, 255, 255]
    white.withUnsafeMutableBytes {
      atlases[page].replace(
        region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 4)
    }
  }
  private func reserve(_ width: Int, _ height: Int, in page: Int) -> (x: Int, y: Int)? {
    guard width > 0, height > 0, width + 1 < atlasSize, height + 1 < atlasSize else { return nil }
    if atlasX[page] + width + 1 > atlasSize { atlasX[page] = 0; atlasY[page] += shelves[page] + 1; shelves[page] = 0 }
    guard atlasY[page] + height + 1 < atlasSize else { return nil }
    let result = (x: atlasX[page], y: atlasY[page]); atlasX[page] += width + 1; shelves[page] = max(shelves[page], height)
    return result
  }
  private func placement(_ width: Int, _ height: Int) -> (page: Int, x: Int, y: Int)? {
    guard width > 0, height > 0, width + 1 < atlasSize, height + 1 < atlasSize else { return nil }
    for page in atlases.indices { if let point = reserve(width, height, in: page) { return (page, point.x, point.y) } }
    if let page = appendAtlasPage(), let point = reserve(width, height, in: page) { return (page, point.x, point.y) }
    for page in atlases.indices where !frameAtlasPages.contains(page) { resetAtlasPage(page); if let point = reserve(width, height, in: page) { return (page, point.x, point.y) } }
    return nil
  }
  private func glyphPixels(_ key: GlyphKey, width: Int, height: Int) -> [UInt8] {
    let selected = key.bold ? (key.italic ? boldItalicFont : boldFont) : (key.italic ? italicFont : font)
    var pixels = TerminalFont.rasterize(key.text, font: selected, width: width, height: height).pixels
    for pixel in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Float(pixels[pixel + 3]) / 255
      if alpha > 0 {
        for component in 0..<3 {
          let straight = min(1, Float(pixels[pixel + component]) / 255 / alpha)
          pixels[pixel + component] = UInt8(
            clamping: Int((CellPalette.linear(straight) * alpha * 255).rounded()))
        }
      } else {
        pixels[pixel] = 0
        pixels[pixel + 1] = 0
        pixels[pixel + 2] = 0
      }
    }
    return pixels
  }
  private func glyphKind(_ pixels: [UInt8]) -> GlyphLease.Kind {
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = pixels[offset + 3]
      guard alpha > 0 else { continue }
      if pixels[offset] != alpha || pixels[offset + 1] != alpha || pixels[offset + 2] != alpha {
        return .color
      }
    }
    return .mask
  }
  private func directGlyph(_ key: GlyphKey, width: Int, height: Int, limited: Bool = true) -> Glyph? {
    guard !limited || (!directGlyphExhausted && directGlyphCount < directGlyphLimit) else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let allocation = glyphResidency.makeLegacyTexture(descriptor) else {
      if limited { directGlyphExhausted = true }
      return nil
    }
    let texture = allocation.texture
    let allocatedBytes = Int(texture.allocatedSize)
    guard !limited || directGlyphBytes + allocatedBytes <= directGlyphBudget else {
      glyphResidency.releaseLegacyTexture(allocation.id)
      directGlyphExhausted = true
      return nil
    }
    let pixels = glyphPixels(key, width: width, height: height)
    let kind = glyphKind(pixels)
    pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
    if limited { directGlyphBytes += allocatedBytes; directGlyphCount += 1; RendererMetrics.recordExactGlyphFallback() }
    return Glyph(uv: SIMD4(0, 0, 1, 1), width: width, atlasPage: nil, texture: texture, kind: kind,
                 heap: allocation.heap, legacyID: allocation.id)
  }
  private func glyph(_ key: GlyphKey, cells: Int, request: RenderRequest) -> Glyph? {
    let recipe = GlyphRasterRecipe(text: key.text, width: request.cellWidth * cells,
      height: request.cellHeight, pointSize: key.pointSize, bold: key.bold, italic: key.italic,
      fontIdentity: key.fontIdentity, backingScale: 1)
    if let resident = glyphResidency.resolve(recipe) {
      return Glyph(uv: resident.uv, width: resident.width, atlasPage: nil, texture: resident.texture, kind: resident.kind,
                   heap: nil, legacyID: nil)
    }
    // Raster misses never synchronously call CoreText/CoreGraphics on the
    // render owner. The caller draws the exact-span outline until the bounded
    // worker result reaches residency, including oversize/pressure cases.
    return nil
  }
  private func draw(
    _ request: RenderRequest, drawable: CAMetalDrawable, surface: SurfaceLease, generation: UInt64
  ) -> Bool {
    guard request.width > 0, request.height > 0 else { return false }
    glyphResidency.beginFrame(surface: surface.id)
    var residencySubmitted = false
    var frameLegacyIDs: Set<UUID> = []
    defer {
      if !residencySubmitted {
        glyphResidency.abandonedPreparedFrame()
        frameLegacyIDs.forEach { glyphResidency.releaseLegacyTexture($0) }
      }
    }
    if metrics != SIMD2(request.cellWidth, request.cellHeight) || fontSize != request.fontSize {
      metrics = SIMD2(request.cellWidth, request.cellHeight)
      fontSize = request.fontSize
      font = TerminalFont.core(size: fontSize)
      boldFont = TerminalFont.core(size: fontSize, bold: true)
      italicFont = TerminalFont.core(size: fontSize, italic: true)
      boldItalicFont = TerminalFont.core(size: fontSize, bold: true, italic: true)
      // Glyph keys include metrics and font identity, so a pane changing font
      // no longer invalidates resident glyphs used by other panes.
    }
    let preparationStart = DispatchTime.now().uptimeNanoseconds
    RendererMetrics.beginGlyphFrame(revision: request.snapshot.revision)
    var quads: [Quad] = []
    var backgrounds: [Quad] = []
    var glyphQuads = Array(repeating: [Quad](), count: atlases.count)
    var directGlyphQuads: [(quad: Quad, texture: MTLTexture, heap: MTLHeap?, legacyID: UUID?)] = []
    let snap = request.snapshot
    let searchRows = Dictionary(snap.search.map { ($0.row, $0) }, uniquingKeysWith: { first, _ in first })
    let palette = CellPalette(snapshot: snap)
    let baseBackground = palette.background
    let whiteUV = SIMD4<Float>(0.5 / Float(atlasSize), 0.5 / Float(atlasSize), 0, 0)
    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: SIMD4<Float>) {
      quads.append(
        Quad(rect: SIMD4(Float(x), Float(y), Float(w), Float(h)), uv: whiteUV, color: color))
    }
    func appendGlyph(_ quad: Quad, _ glyph: Glyph) {
      var quad = quad
      quad.material = SIMD4(glyph.kind == .mask ? 0 : 1, 0, 0, 0)
      if let page = glyph.atlasPage {
        while glyphQuads.count <= page { glyphQuads.append([]) }
        glyphQuads[page].append(quad)
      } else if let texture = glyph.texture {
        directGlyphQuads.append((quad, texture, glyph.heap, glyph.legacyID))
        if let id = glyph.legacyID { frameLegacyIDs.insert(id) }
      }
    }
    var needsReset = false
    for pass in 0..<2 {
      quads.removeAll(keepingCapacity: true)
      backgrounds.removeAll(keepingCapacity: true)
      glyphQuads = Array(repeating: [], count: atlases.count)
      directGlyphQuads.removeAll(keepingCapacity: true)
      frameAtlasPages = [0]
      directGlyphBytes = 0
      directGlyphCount = 0
      directGlyphExhausted = false
      replacementGlyph = nil
      needsReset = false
      for (r, row) in snap.rows.enumerated() {
        let search = searchRows[r]
        for (c, cell) in row.cells.enumerated() {
          let x = request.inset + c * request.cellWidth
          let y = request.inset + r * request.cellHeight
          let colors = palette.resolve(cell.style)
          var fg = colors.foreground
          var bg = colors.background
          if let search, search.start <= c && c < search.end {
            bg = TerminalTheme.linear(TerminalTheme.accent)
            fg = TerminalTheme.linear(TerminalTheme.background)
          }
          if let selection = request.selection, selection.lower <= r * snap.cols + c,
            r * snap.cols + c < selection.upper
          {
            bg = TerminalTheme.linear(TerminalTheme.selection)
            fg = TerminalTheme.linear(TerminalTheme.text)
          }
          if bg != baseBackground {
            backgrounds.append(
              Quad(
                rect: SIMD4(
                  Float(x), Float(y), Float(request.cellWidth), Float(request.cellHeight)),
                uv: whiteUV, color: bg))
          }
          if !cell.text.isEmpty && !cell.style.conceal && cell.kind != "Continuation" {
            let cells = cell.kind == "Lead2" ? 2 : 1
            if cell.text == "▀" {
              rect(x, y, request.cellWidth, request.cellHeight / 2, fg)
            } else if cell.text == "▄" {
              rect(
                x, y + request.cellHeight / 2, request.cellWidth,
                request.cellHeight - request.cellHeight / 2, fg)
            } else if cell.text == "█" {
              rect(x, y, request.cellWidth, request.cellHeight, fg)
            } else if let shapes = GeometricGlyph.rectangles(
              text: cell.text, width: request.cellWidth * cells, height: request.cellHeight)
            {
              for shape in shapes {
                var tint = fg
                tint.w *= shape.coverage
                rect(x + shape.x, y + shape.y, shape.width, shape.height, tint)
              }
            } else {
              let displayText =
                cell.text.unicodeScalars.first.map { CharacterSet.nonBaseCharacters.contains($0) }
                  == true ? "◌" + cell.text : cell.text
              let key = GlyphKey(
                text: displayText, cells: cells, bold: cell.style.bold, italic: cell.style.italic,
                width: request.cellWidth * cells, height: request.cellHeight,
                pointSize: Int(request.fontSize.rounded()),
                fontIdentity: CTFontCopyPostScriptName(
                  cell.style.bold ? (cell.style.italic ? boldItalicFont : boldFont)
                    : (cell.style.italic ? italicFont : font)) as String)
              if let glyph = glyph(key, cells: cells, request: request) {
                appendGlyph(
                  Quad(
                    rect: SIMD4(Float(x), Float(y), Float(glyph.width), Float(request.cellHeight)),
                    uv: glyph.uv, color: glyph.kind == .color ? SIMD4(1, 1, 1, 1) : fg), glyph)
              } else {
                // Budget exhaustion must not turn terminal text into a blank
                // cell. This outline uses the already-bound solid texel and
                // allocates nothing, while preserving the cell span.
                let span = request.cellWidth * cells
                rect(x, y, span, 1, fg)
                rect(x, y + request.cellHeight - 1, span, 1, fg)
                rect(x, y, 1, request.cellHeight, fg)
                rect(x + span - 1, y, 1, request.cellHeight, fg)
                RendererMetrics.recordSubstituteGlyphFallback()
              }
            }
            if cell.style.underline > 0 {
              rect(x, y + request.cellHeight - 3, request.cellWidth * cells, 1, colors.underline(matching: fg))
            }
            if cell.style.strike {
              rect(x, y + request.cellHeight / 2, request.cellWidth * cells, 1, fg)
            }
            if cell.style.overline { rect(x, y, request.cellWidth * cells, 1, fg) }
          }
        }
      }
      if !needsReset || pass == 1 { break }
      resetAtlas()
    }
    let textQuads = quads
    let textGlyphQuads = glyphQuads
    let textDirectGlyphQuads = directGlyphQuads
    quads.removeAll(keepingCapacity: true)
    glyphQuads = Array(repeating: [], count: atlases.count)
    directGlyphQuads.removeAll(keepingCapacity: true)
    if snap.cursor.visible && !request.scrolled {
      let x = request.inset + snap.cursor.col * request.cellWidth
      let y = request.inset + snap.cursor.row * request.cellHeight
      let tint =
        request.focused
        ? TerminalTheme.linear(TerminalTheme.accent, alpha: 0.65)
        : TerminalTheme.linear(TerminalTheme.muted, alpha: 0.25)
      switch snap.cursor.shape {
      case 3, 4: rect(x, y + request.cellHeight - 2, request.cellWidth, 2, tint)
      case 5, 6: rect(x, y, 2, request.cellHeight, tint)
      default: rect(x, y, request.cellWidth, request.cellHeight, tint)
      }
    }
    if !request.marked.isEmpty {
      let smokeMarkedLimit = CommandLine.arguments.contains("--atlas-pressure-smoke")
        || CommandLine.arguments.contains("--atlas-fallback-budget-smoke")
      let cells = min(smokeMarkedLimit ? 160 : 20, max(1, request.marked.count))
      let key = GlyphKey(
        text: request.marked, cells: cells, bold: false, italic: false,
        width: request.cellWidth * cells, height: request.cellHeight,
        pointSize: Int(request.fontSize.rounded()),
        fontIdentity: CTFontCopyPostScriptName(font) as String)
      if let g = glyph(key, cells: cells, request: request) {
        let x = request.inset + snap.cursor.col * request.cellWidth
        let y = request.inset + snap.cursor.row * request.cellHeight
        rect(
          x, y, cells * request.cellWidth, request.cellHeight,
          TerminalTheme.linear(TerminalTheme.raised))
        appendGlyph(
          Quad(
            rect: SIMD4(Float(x), Float(y), Float(g.width), Float(request.cellHeight)), uv: g.uv,
            color: SIMD4(1, 1, 1, 1)), g)
        rect(
          x, y + request.cellHeight - 2, cells * request.cellWidth, 1,
          TerminalTheme.linear(TerminalTheme.accent))
      } else {
        let x = request.inset + snap.cursor.col * request.cellWidth
        let y = request.inset + snap.cursor.row * request.cellHeight
        let span = cells * request.cellWidth
        let tint = TerminalTheme.linear(TerminalTheme.text)
        rect(x, y, span, 1, tint)
        rect(x, y + request.cellHeight - 1, span, 1, tint)
        rect(x, y, 1, request.cellHeight, tint)
        rect(x + span - 1, y, 1, request.cellHeight, tint)
        RendererMetrics.recordSubstituteGlyphFallback()
      }
    }
    let overlayQuads = quads
    let overlayGlyphQuads = glyphQuads
    let overlayDirectGlyphQuads = directGlyphQuads
    RendererMetrics.recordGlyphFallbackFrame(bytes: directGlyphBytes, count: directGlyphCount)
    let imageKeys = Set(snap.images.map { $0.key })
    imageTextures = imageTextures.filter {
      $0.key.surface != surface.id || imageKeys.contains($0.key.image)
    }
    for placement in snap.images where imageTextures[
      SurfaceImageKey(surface: surface.id, image: placement.key)
    ] == nil {
      guard let pixels = snap.imagePixels[placement.key],
        pixels.data.count == placement.width * placement.height * 4
      else { continue }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm_srgb, width: placement.width, height: placement.height,
        mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = .shaderRead
      if let texture = device.makeTexture(descriptor: descriptor) {
        pixels.data.withUnsafeBytes {
          texture.replace(
            region: MTLRegionMake2D(0, 0, placement.width, placement.height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: placement.width * 4)
        }
        imageTextures[SurfaceImageKey(surface: surface.id, image: placement.key)] = texture
      }
    }
    let preparationMs = Double(DispatchTime.now().uptimeNanoseconds - preparationStart) / 1_000_000
    guard let command = commands.makeCommandBuffer() else { return false }
    let drawableWidth = drawable.texture.width
    let drawableHeight = drawable.texture.height
    let matchesRequest = RendererMetrics.recordDrawable(
      requestWidth: request.width, requestHeight: request.height,
      drawableWidth: drawableWidth, drawableHeight: drawableHeight)
    // The drawable belongs to a different viewport size than this request.
    // Drop obsolete work; the geometry change queued a replacement request.
    // This does not synchronize layer geometry with drawable presentation.
    guard matchesRequest else {
      RendererMetrics.recordStaleFrameDrop()
      return false
    }
    command.label = "Terminal frame \(submissions) revision \(snap.revision)"
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = drawable.texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(baseBackground.x), green: Double(baseBackground.y),
      blue: Double(baseBackground.z), alpha: 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
      return false
    }
    encoder.setRenderPipelineState(pipeline)
    var extent = SIMD2<Float>(Float(drawableWidth), Float(drawableHeight))
    encoder.setVertexBytes(&extent, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    func drawQuads(_ items: [Quad], texture: MTLTexture, state: MTLRenderPipelineState) {
      guard !items.isEmpty else { return }
      guard let buffer = device.makeBuffer(
        bytes: items, length: MemoryLayout<Quad>.stride * items.count, options: .storageModeShared
      ) else {
        RendererMetrics.recordQuadBufferDrop(items.count)
        return
      }
      encoder.setRenderPipelineState(state)
      encoder.setVertexBuffer(buffer, offset: 0, index: 0)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: items.count)
    }
    func drawImages(_ accepts: (Int) -> Bool) {
      let clipWidth = min(drawableWidth - request.inset, snap.cols * request.cellWidth)
      let clipHeight = min(drawableHeight - request.inset, snap.rows.count * request.cellHeight)
      guard clipWidth > 0, clipHeight > 0 else { return }
      encoder.setScissorRect(
        MTLScissorRect(x: request.inset, y: request.inset, width: clipWidth, height: clipHeight))
      for p in snap.images where accepts(p.z) {
        guard let texture = imageTextures[SurfaceImageKey(surface: surface.id, image: p.key)] else {
          continue
        }
        let sourceW = Float(p.source[2])
        let sourceH = Float(p.source[3])
        let boxW = p.natural ? sourceW : Float(p.columns * request.cellWidth - p.offset[0])
        let boxH = p.natural ? sourceH : Float(p.rows * request.cellHeight - p.offset[1])
        let factor = min(boxW / sourceW, boxH / sourceH)
        let width = sourceW * factor
        let height = sourceH * factor
        let x = Float(request.inset + p.col * request.cellWidth + p.offset[0]) + (boxW - width) / 2
        let y =
          Float(request.inset + p.row * request.cellHeight + p.offset[1]) + (boxH - height) / 2
        let quad = Quad(
          rect: SIMD4(x, y, width, height),
          uv: SIMD4(
            Float(p.source[0]) / Float(p.width), Float(p.source[1]) / Float(p.height),
            sourceW / Float(p.width), sourceH / Float(p.height)), color: SIMD4(1, 1, 1, 1))
        drawQuads([quad], texture: texture, state: imagePipeline)
      }
      encoder.setScissorRect(
        MTLScissorRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight))
    }
    drawImages { $0 < -1_073_741_824 }
    drawQuads(backgrounds, texture: atlases[0], state: pipeline)
    drawImages { $0 < 0 && $0 >= -1_073_741_824 }
    drawQuads(textQuads, texture: atlases[0], state: pipeline)
    for (page, quads) in textGlyphQuads.enumerated() {
      drawQuads(quads, texture: atlases[page], state: pipeline)
    }
    for item in textDirectGlyphQuads { drawQuads([item.quad], texture: item.texture, state: pipeline) }
    drawImages { $0 >= 0 }
    drawQuads(overlayQuads, texture: atlases[0], state: pipeline)
    for (page, quads) in overlayGlyphQuads.enumerated() {
      drawQuads(quads, texture: atlases[page], state: pipeline)
    }
    for item in overlayDirectGlyphQuads { drawQuads([item.quad], texture: item.texture, state: pipeline) }
    encoder.endEncoding()
    RendererMetrics.recordPresentation(
      requestWidth: request.width, requestHeight: request.height,
      drawableWidth: drawableWidth, drawableHeight: drawableHeight)
    command.present(drawable)
    let retiredFallbackIDs = frameLegacyIDs
    let completedRevision = snap.revision
    glyphResidency.finishFrameDemand()
    glyphResidency.submitted()
    RendererMetrics.recordResidency(glyphResidency.diagnostics())
    residencySubmitted = true
    command.addCompletedHandler { [weak self, retiredFallbackIDs, surface] command in
      self?.executor.async {
        RendererMetrics.completeGlyphFrame(revision: completedRevision)
        retiredFallbackIDs.forEach { self?.glyphResidency.releaseLegacyTexture($0) }
        self?.glyphResidency.completedSubmission()
        self?.completed(
          surface: surface, generation: generation, revision: completedRevision, command: command)
      }
    }
    command.commit()
    submissions += 1
    RendererMetrics.record(preparationMs: preparationMs)
    return true
  }
}

final class RendererMetrics: @unchecked Sendable {
  private static let lock = NSLock()
  private static var count: UInt64 = 0
  private static var mismatchedDrawables: UInt64 = 0
  private static var mismatchedPresents: UInt64 = 0
  private static var droppedStaleFrames: UInt64 = 0
  private static var visibleGlyphDrops: UInt64 = 0
  private static var exactGlyphFallbacks: UInt64 = 0
  private static var substituteGlyphFallbacks: UInt64 = 0
  private static var oversizedGlyphFallbacks: UInt64 = 0
  private static var peakGlyphFallbackBytes: UInt64 = 0
  private static var peakGlyphFallbackCount: UInt64 = 0
  private static var droppedQuadBuffers: UInt64 = 0
  private static var peakAtlasPages: UInt64 = 0
  // A submission is recorded before command.commit().  Native diagnostics that
  // install a marked overlay need the complementary completion sequence to
  // distinguish that overlay's render from the preceding PTY snapshot.
  private static var completedCount: UInt64 = 0
  private static var preparation: [Double] = []
  private static var gpu: [Double] = []
  private static var errors = 0
  private static var residency: [String: Any] = [:]
  private static var currentGlyphRevision: UInt64 = 0
  private static var currentGlyphSubstitutes: UInt64 = 0
  private static var completedGlyphRevision: UInt64 = 0
  private static var completedGlyphSubstitutes: UInt64 = 0
  static func beginGlyphFrame(revision: UInt64) {
    lock.lock()
    currentGlyphRevision = revision
    currentGlyphSubstitutes = 0
    lock.unlock()
  }
  static func completeGlyphFrame(revision: UInt64) {
    lock.lock()
    guard currentGlyphRevision == revision else { lock.unlock(); return }
    completedGlyphRevision = revision
    completedGlyphSubstitutes = currentGlyphSubstitutes
    lock.unlock()
  }
  static func recordResidency(_ value: GlyphResidency.Diagnostics) {
    lock.lock()
    residency = ["resident_bytes": value.residentBytes, "reservations": value.reservations,
      "direct_bytes": value.directFallbackBytes, "denied_allocations": value.deniedAllocations,
      "pending_jobs": value.pendingJobs, "queued_uploads": value.queuedUploads,
      "capacity_waiting": value.capacityWaiting, "quiescent": value.quiescent]
    lock.unlock()
  }
  static func record(preparationMs: Double) {
    lock.lock()
    count += 1
    if preparation.count == 128 { preparation.removeFirst() }
    preparation.append(preparationMs)
    lock.unlock()
  }
  static func completed(gpuMs: Double, error: Bool) {
    lock.lock()
    completedCount &+= 1
    if gpuMs > 0 {
      if gpu.count == 128 { gpu.removeFirst() }
      gpu.append(gpuMs)
    }
    if error { errors += 1 }
    lock.unlock()
  }
  static func recordDrawable(
    requestWidth: Int, requestHeight: Int, drawableWidth: Int, drawableHeight: Int
  ) -> Bool {
    let matches = requestWidth == drawableWidth && requestHeight == drawableHeight
    guard !matches else { return true }
    lock.lock()
    mismatchedDrawables += 1
    lock.unlock()
    return false
  }
  static func recordStaleFrameDrop() {
    lock.lock()
    droppedStaleFrames += 1
    lock.unlock()
  }
  static func recordPresentation(
    requestWidth: Int, requestHeight: Int, drawableWidth: Int, drawableHeight: Int
  ) {
    guard requestWidth != drawableWidth || requestHeight != drawableHeight else { return }
    lock.lock()
    mismatchedPresents += 1
    lock.unlock()
  }
  static func mismatchedPresentations() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return mismatchedPresents
  }
  static func staleFrameDropCount() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return droppedStaleFrames
  }
  static func recordVisibleGlyphDrop() {
    lock.lock()
    visibleGlyphDrops += 1
    lock.unlock()
  }
  static func recordExactGlyphFallback() {
    lock.lock()
    exactGlyphFallbacks += 1
    lock.unlock()
  }
  static func recordSubstituteGlyphFallback() {
    lock.lock()
    substituteGlyphFallbacks += 1
    currentGlyphSubstitutes += 1
    lock.unlock()
  }
  static func recordOversizedGlyphFallback() {
    lock.lock()
    oversizedGlyphFallbacks += 1
    lock.unlock()
  }
  static func recordGlyphFallbackFrame(bytes: Int, count: Int) {
    lock.lock()
    peakGlyphFallbackBytes = max(peakGlyphFallbackBytes, UInt64(bytes))
    peakGlyphFallbackCount = max(peakGlyphFallbackCount, UInt64(count))
    lock.unlock()
  }
  static func recordQuadBufferDrop(_ count: Int) {
    lock.lock()
    droppedQuadBuffers += UInt64(count)
    lock.unlock()
  }
  static func recordAtlasPages(_ count: Int) {
    lock.lock()
    peakAtlasPages = max(peakAtlasPages, UInt64(count))
    lock.unlock()
  }
  static func submissions() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  static func report() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "submissions": count, "preparation_ms": preparation, "gpu_command_ms": gpu,
      "completed_submissions": completedCount,
      "command_errors": errors, "font": TerminalFont.family, "attachment": "BGRA8Unorm_sRGB",
      "glyph_atlas": "premultiplied linear RGBA8Unorm",
      "mismatched_drawables": mismatchedDrawables,
      "mismatched_presents": mismatchedPresents,
      "dropped_stale_frames": droppedStaleFrames,
      "visible_glyph_drops": visibleGlyphDrops,
      "exact_glyph_fallbacks": exactGlyphFallbacks,
      "substitute_glyph_fallbacks": substituteGlyphFallbacks,
      "oversized_glyph_fallbacks": oversizedGlyphFallbacks,
      "peak_glyph_fallback_bytes": peakGlyphFallbackBytes,
      "peak_glyph_fallback_count": peakGlyphFallbackCount,
      "dropped_quad_buffers": droppedQuadBuffers,
      "peak_atlas_pages": peakAtlasPages,
      "last_completed_glyph_revision": completedGlyphRevision,
      "last_completed_substitutes": completedGlyphSubstitutes,
      "glyph_residency": residency,
    ]
  }
}

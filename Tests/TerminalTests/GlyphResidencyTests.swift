import Darwin
import Foundation
import Metal
import Testing
import simd
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

private struct ShaderQuad {
  var rect: SIMD4<Float>
  var uv: SIMD4<Float>
  var color: SIMD4<Float>
  var material: SIMD4<Float>
}

/// The glyph atlas residency and its production shader fixtures. They need a
/// Metal device; without one each test fails, as the old executable did.
@Suite enum GlyphResidencyTests {
  /// The device, plus a budget that permits exactly one page plus alignment
  /// slack, forcing reclaim rather than second-page growth.
  static func fixture() -> (device: MTLDevice, budget: Int)? {
    guard let device = MTLCreateSystemDefaultDevice() else {
      Issue.record("GLYPH_RESIDENCY_DEVICE=unavailable")
      return nil
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
      width: 1024, height: 1024, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let onePage = Int(device.heapTextureSizeAndAlign(descriptor: descriptor).size)
    let capabilityHeap = MTLHeapDescriptor()
    capabilityHeap.storageMode = .shared
    capabilityHeap.size = onePage
    guard let heap = device.makeHeap(descriptor: capabilityHeap) else { Issue.record("probe heap unavailable"); return nil }
    guard heap.makeTexture(descriptor: descriptor) != nil else { Issue.record("probe heap texture unavailable"); return nil }
    return (device, onePage + max(4096, onePage / 16))
  }

  /// The production shader library: the app bundle's metallib when a build left
  /// one in `dist/`, otherwise the same shader compiled from its source.
  static func productionLibrary(device: MTLDevice) -> MTLLibrary? {
    let built = TestEnvironment.repository.appendingPathComponent("dist/Terminal.app/Contents/Resources/Terminal.metallib")
    if let library = try? device.makeLibrary(URL: built) { return library }
    let source = TestEnvironment.repository.appendingPathComponent("Sources/TerminalView/Resources/Terminal.metal")
    guard let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }
    return try? device.makeLibrary(source: text, options: nil)
  }

  @Test static func syncResidencyScenarios() {
    guard let (device, budget) = fixture() else { return }
    func makeResidency() -> GlyphResidency {
      GlyphResidency(device: device, owner: DispatchQueue(label: "glyph-residency-test"), budget: budget) {}
    }
    #expect(makeResidency().testingRecycleAndGeneration())
    #expect(makeResidency().testingPinnedPageBlocksReclaim())
    #expect(makeResidency().testingLegacyReleaseExactlyOnce())
    #expect(makeResidency().testingLegacyHeapDropsWithLease())
    #expect(makeResidency().testingOversizeWorkingSetStabilizes())
    #expect(makeResidency().testingNegativeCacheIsBoundedAndRecipeScoped())
    #expect(makeResidency().testingTwoGlyphWorkingSetSettles())
    #expect(makeResidency().testingOversizeExactResident())
  }

  @Test static func delayedBRecoversThroughRealWorker() {
    guard let (device, budget) = fixture() else { return }
    // Real raster-worker → owner-queue delivery, with an empty frame boundary
    // before B completes. This catches the old permit-reset race.
    let callbackOwner = DispatchQueue(label: "glyph-residency-async-test")
    let callbackResidency = GlyphResidency(device: device, owner: callbackOwner, budget: budget) {}
    let callbackReady = DispatchSemaphore(value: 0)
    let delayedB = callbackOwner.sync { callbackResidency.testingPrepareDelayedBRecovery() }
    guard let delayedB else { Issue.record("async recovery setup"); return }
    callbackResidency.setOnReady { callbackReady.signal() }
    callbackOwner.sync {
      #expect(callbackResidency.resolve(delayedB) == nil)
      callbackResidency.beginFrame() // empty upload boundary before worker completion
    }
    #expect(callbackReady.wait(timeout: .now() + 5) == .success, "worker callback")
    callbackOwner.sync {
      callbackResidency.beginFrame()
      #expect(callbackResidency.testingHasResident(delayedB), "delayed B recovers")
    }
  }

  @Test static func prewarmReportsInFlightUntilUpload() {
    guard let (device, budget) = fixture() else { return }
    // Prewarm queues raster work without frame demand. Until upload the miss
    // reports in flight, so the renderer leaves the cell blank, not outlined.
    let prewarmOwner = DispatchQueue(label: "glyph-residency-prewarm-test")
    let prewarmGate = DispatchSemaphore(value: 0)
    let prewarmWorker = GlyphRasterWorker(rasterizer: { recipe in
      #expect(prewarmGate.wait(timeout: .now() + 5) == .success, "prewarm raster never released")
      return GlyphRasterResult(recipe: recipe,
        pixels: [UInt8](repeating: 255, count: recipe.width * recipe.height * 4),
        kind: .mask, resolvedFonts: ["fixture"], glyphIDs: [1])
    })
    let prewarmReady = DispatchSemaphore(value: 0)
    let prewarmResidency = GlyphResidency(device: device, owner: prewarmOwner,
      worker: prewarmWorker, budget: budget) { prewarmReady.signal() }
    let warm = GlyphRasterRecipe(text: "a", width: 8, height: 16, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    let cold = GlyphRasterRecipe(text: "b", width: 8, height: 16, pointSize: 12,
      bold: false, italic: false, fontIdentity: "Menlo-Regular", backingScale: 1)
    prewarmOwner.sync {
      #expect(!prewarmResidency.isInFlight(warm), "nothing in flight before prewarm")
      prewarmResidency.prewarm([warm])
      #expect(prewarmResidency.isInFlight(warm), "prewarm queues raster work")
      #expect(!prewarmResidency.isInFlight(cold), "unrequested glyph is not in flight")
    }
    prewarmGate.signal()
    #expect(prewarmReady.wait(timeout: .now() + 5) == .success, "prewarm callback")
    prewarmOwner.sync {
      #expect(prewarmResidency.isInFlight(warm), "awaiting upload is still in flight")
      prewarmResidency.beginFrame()
      #expect(!prewarmResidency.isInFlight(warm), "installed glyph leaves flight")
      #expect(prewarmResidency.resolve(warm) != nil, "prewarmed glyph resident on first demand")
    }
  }

  @Test static func textureReadback() {
    guard let (device, _) = fixture() else { return }
    let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
      width: 3, height: 1, mipmapped: false)
    maskDescriptor.storageMode = .shared
    guard let mask = device.makeTexture(descriptor: maskDescriptor) else { Issue.record("mask texture"); return }
    let coverage: [UInt8] = [0, 128, 255]
    coverage.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 3) }
    var readCoverage = [UInt8](repeating: 0, count: 3)
    mask.getBytes(&readCoverage, bytesPerRow: 3, from: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0)
    #expect(readCoverage == coverage)
    let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
      width: 1, height: 1, mipmapped: false)
    colorDescriptor.storageMode = .shared
    guard let color = device.makeTexture(descriptor: colorDescriptor) else { Issue.record("color texture"); return }
    let rgba: [UInt8] = [64, 32, 16, 128]
    rgba.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 4) }
    var readRGBA = [UInt8](repeating: 0, count: 4)
    color.getBytes(&readRGBA, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
    #expect(readRGBA == rgba)
  }

  /// Production R8/RGBA shader fixtures.
  @Test static func productionShaderFixtures() {
    guard let (device, _) = fixture() else { return }
    let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
      width: 3, height: 1, mipmapped: false)
    maskDescriptor.storageMode = .shared
    guard let mask = device.makeTexture(descriptor: maskDescriptor) else { Issue.record("mask texture"); return }
    let coverage: [UInt8] = [0, 128, 255]
    coverage.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 3) }
    var readCoverage = [UInt8](repeating: 0, count: 3)
    mask.getBytes(&readCoverage, bytesPerRow: 3, from: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0)
    #expect(readCoverage == coverage)
    let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
      width: 1, height: 1, mipmapped: false)
    colorDescriptor.storageMode = .shared
    guard let color = device.makeTexture(descriptor: colorDescriptor) else { Issue.record("color texture"); return }
    let rgba: [UInt8] = [64, 32, 16, 128]
    rgba.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 4) }
    var readRGBA = [UInt8](repeating: 0, count: 4)
    color.getBytes(&readRGBA, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
    #expect(readRGBA == rgba)
    // Execute the production terminal vertex/fragment pair into an sRGB
    // attachment. The R8 texture deliberately covers 0, .5 and 1 coverage.
    guard let library = productionLibrary(device: device),
      let vertex = library.makeFunction(name: "terminal_vertex"),
      let fragment = library.makeFunction(name: "terminal_fragment")
    else { Issue.record("production metallib unavailable"); return }
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
      width: 3, height: 1, mipmapped: false)
    targetDescriptor.storageMode = .shared; targetDescriptor.usage = [.renderTarget, .shaderRead]
    guard let target = device.makeTexture(descriptor: targetDescriptor),
      let queue = device.makeCommandQueue()
    else { Issue.record("offscreen target"); return }
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = vertex; pipelineDescriptor.fragmentFunction = fragment
    pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
    pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor),
      let command = queue.makeCommandBuffer()
    else { Issue.record("offscreen pipeline"); return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { Issue.record("offscreen encoder"); return }
    let quads = (0..<3).map { index in ShaderQuad(
      rect: SIMD4(Float(index), 0, 1, 1),
      uv: SIMD4(Float(index) / 3, 0, 1.0 / 3, 1), color: SIMD4(1, 1, 1, 1),
      material: SIMD4(0, 0, 0, 0)) }
    var extent = SIMD2<Float>(3, 1)
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(quads, length: MemoryLayout<ShaderQuad>.stride * quads.count, index: 0)
    encoder.setVertexBytes(&extent, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.setFragmentTexture(mask, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 3)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    var rendered = [UInt8](repeating: 0, count: 12)
    target.getBytes(&rendered, bytesPerRow: 12, from: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0)
    // Attachment bytes are BGRA sRGB.  Linear 0/.5/1 coverage becomes
    // encoded approximately 0/188/255; allow one LSB driver rounding.
    for (index, expected) in [0, 188, 255].enumerated() {
      let value = Int(rendered[index * 4])
      #expect(abs(value - expected) <= 1, "R8 shader coverage \(index): \(value)")
    }
    func renderColor(background: Double, tintAlpha: Float) -> [UInt8]? {
      let oneDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
        width: 1, height: 1, mipmapped: false)
      oneDescriptor.storageMode = .shared; oneDescriptor.usage = [.renderTarget, .shaderRead]
      guard let output = device.makeTexture(descriptor: oneDescriptor),
        let colorCommand = queue.makeCommandBuffer()
      else { Issue.record("color output"); return nil }
      let colorPass = MTLRenderPassDescriptor()
      colorPass.colorAttachments[0].texture = output
      colorPass.colorAttachments[0].loadAction = .clear; colorPass.colorAttachments[0].storeAction = .store
      colorPass.colorAttachments[0].clearColor = MTLClearColorMake(background, background, background, 1)
      guard let colorEncoder = colorCommand.makeRenderCommandEncoder(descriptor: colorPass) else {
        Issue.record("color encoder")
        return nil
      }
      let quad = ShaderQuad(rect: SIMD4(0, 0, 1, 1), uv: SIMD4(0, 0, 1, 1),
        color: SIMD4(1, 1, 1, tintAlpha), material: SIMD4(1, 0, 0, 0))
      var oneExtent = SIMD2<Float>(1, 1)
      colorEncoder.setRenderPipelineState(pipeline)
      colorEncoder.setVertexBytes([quad], length: MemoryLayout<ShaderQuad>.stride, index: 0)
      colorEncoder.setVertexBytes(&oneExtent, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
      colorEncoder.setFragmentTexture(color, index: 0)
      colorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
      colorEncoder.endEncoding(); colorCommand.commit(); colorCommand.waitUntilCompleted()
      var bytes = [UInt8](repeating: 0, count: 4)
      output.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
      return bytes
    }
    func expect(_ actual: [UInt8]?, _ expectedBGRA: [Int], _ name: String) {
      guard let actual else { return }
      for index in 0..<4 {
        #expect(abs(Int(actual[index]) - expectedBGRA[index]) <= 1,
          "\(name) channel \(index): \(actual) != \(expectedBGRA)")
      }
    }
    // `rgba` is premultiplied *linear* color. These cases catch both treating
    // it as coverage and accidental double sRGB conversion.
    expect(renderColor(background: 0, tintAlpha: 1), [71, 99, 137, 255], "RGBA dark")
    expect(renderColor(background: 1, tintAlpha: 1), [197, 207, 225, 255], "RGBA light")
    expect(renderColor(background: 0, tintAlpha: 0.5), [50, 71, 99, 255], "RGBA tint alpha")
  }
}

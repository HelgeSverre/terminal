import Foundation
import Metal
import simd

private struct ShaderQuad {
  var rect: SIMD4<Float>
  var uv: SIMD4<Float>
  var color: SIMD4<Float>
  var material: SIMD4<Float>
}

// GlyphResidency's production metric sink is deliberately tiny; the isolated
// Metal executable supplies it without linking the window renderer.
final class RendererMetrics {
  static func recordAtlasPages(_ count: Int) {}
}

@main enum GlyphResidencyTests {
  static func main() {
    guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
      width: 1024, height: 1024, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let onePage = Int(device.heapTextureSizeAndAlign(descriptor: descriptor).size)
    // Permit exactly one page plus alignment slack, forcing reclaim rather
    // than second-page growth.
    let budget = onePage + max(4096, onePage / 16)
    func makeResidency() -> GlyphResidency {
      GlyphResidency(device: device, owner: DispatchQueue(label: "glyph-residency-test"), budget: budget) {}
    }
    precondition(makeResidency().testingRecycleAndGeneration())
    precondition(makeResidency().testingPinnedPageBlocksReclaim())
    precondition(makeResidency().testingLegacyReleaseExactlyOnce())
    let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
      width: 3, height: 1, mipmapped: false)
    maskDescriptor.storageMode = .shared
    guard let mask = device.makeTexture(descriptor: maskDescriptor) else { fatalError("mask texture") }
    let coverage: [UInt8] = [0, 128, 255]
    coverage.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 3) }
    var readCoverage = [UInt8](repeating: 0, count: 3)
    mask.getBytes(&readCoverage, bytesPerRow: 3, from: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0)
    precondition(readCoverage == coverage)
    let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
      width: 1, height: 1, mipmapped: false)
    colorDescriptor.storageMode = .shared
    guard let color = device.makeTexture(descriptor: colorDescriptor) else { fatalError("color texture") }
    let rgba: [UInt8] = [64, 32, 16, 128]
    rgba.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 4) }
    var readRGBA = [UInt8](repeating: 0, count: 4)
    color.getBytes(&readRGBA, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
    precondition(readRGBA == rgba)
    // Execute the production terminal vertex/fragment pair into an sRGB
    // attachment. The R8 texture deliberately covers 0, .5 and 1 coverage.
    let libraryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("dist/Terminal.app/Contents/Resources/Terminal.metallib")
    guard let library = try? device.makeLibrary(URL: libraryURL),
      let vertex = library.makeFunction(name: "terminal_vertex"),
      let fragment = library.makeFunction(name: "terminal_fragment")
    else { fatalError("production metallib unavailable") }
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
      width: 3, height: 1, mipmapped: false)
    targetDescriptor.storageMode = .shared; targetDescriptor.usage = [.renderTarget, .shaderRead]
    guard let target = device.makeTexture(descriptor: targetDescriptor),
      let queue = device.makeCommandQueue()
    else { fatalError("offscreen target") }
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
    else { fatalError("offscreen pipeline") }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { fatalError("offscreen encoder") }
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
      precondition(abs(value - expected) <= 1, "R8 shader coverage \(index): \(value)")
    }
    print("PASS glyph residency: tiny-budget reclaim, pins, stale generation, exactly-once release, R8/RGBA fixtures")
  }
}

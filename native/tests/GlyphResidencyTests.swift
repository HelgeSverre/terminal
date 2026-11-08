import Foundation
import Metal

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
    print("PASS glyph residency: tiny-budget reclaim, pins, stale generation, exactly-once release, R8/RGBA fixtures")
  }
}

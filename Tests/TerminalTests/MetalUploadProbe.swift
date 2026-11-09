import Darwin
import Metal

@main enum MetalUploadProbe {
  static func mark(_ value: String) { fputs("METAL_UPLOAD_PROBE=\(value)\n", stderr); fflush(stderr) }
  static func main() {
    mark("before_device")
    guard let device = MTLCreateSystemDefaultDevice() else { exit(2) }
    fputs("METAL_UPLOAD_DEVICE=name=\(device.name) registry=\(device.registryID) apple2=\(device.supportsFamily(.apple2)) mac2=\(device.supportsFamily(.mac2))\n", stderr); fflush(stderr)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    mark("before_shared_texture")
    guard let texture = device.makeTexture(descriptor: descriptor) else { exit(3) }
    var pixel: UInt8 = 0x7f
    texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 1)
    mark("after_shared_texture_replace")
    let heapDescriptor = MTLHeapDescriptor(); heapDescriptor.storageMode = .shared
    heapDescriptor.size = device.heapTextureSizeAndAlign(descriptor: descriptor).size
    mark("before_shared_heap")
    guard let heap = device.makeHeap(descriptor: heapDescriptor), let heapTexture = heap.makeTexture(descriptor: descriptor) else { exit(4) }
    mark("before_shared_heap_texture_replace")
    heapTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 1)
    mark("after_shared_heap_texture_replace")
  }
}

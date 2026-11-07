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
}
private struct GlyphKey: Hashable {
  let text: String
  let cells: Int
  let bold: Bool
  let italic: Bool
}
private struct Glyph {
  let uv: SIMD4<Float>
  let width: Int
}

final class MetalRenderer: @unchecked Sendable {
  let layer: CAMetalLayer
  private let device: MTLDevice
  private let commands: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let imagePipeline: MTLRenderPipelineState
  private var imageTextures: [ImageKey: MTLTexture] = [:]
  private let queue = DispatchQueue(label: "no.helgesverre.terminal.render", qos: .userInteractive)
  private let lock = NSLock()
  private var latest: RenderRequest?
  private var scheduled = false
  private let inFlight = DispatchSemaphore(value: 2)
  private var atlas: MTLTexture
  private var glyphs: [GlyphKey: Glyph] = [:]
  private var atlasX = 4
  private var atlasY = 0
  private var shelf = 0
  private let atlasSize = 2048
  private var metrics = SIMD2<Int>(0, 0)
  private var fontSize: CGFloat = 0
  private var font: CTFont
  private var boldFont: CTFont
  private var italicFont: CTFont
  private var boldItalicFont: CTFont
  private var submissions: UInt64 = 0
  init(layer: CAMetalLayer) throws {
    guard let gpu = MTLCreateSystemDefaultDevice(), let commands = gpu.makeCommandQueue() else {
      throw RendererError.noDevice
    }
    self.layer = layer
    device = gpu
    self.commands = commands
    layer.device = gpu
    layer.pixelFormat = .bgra8Unorm_srgb
    layer.framebufferOnly = true
    layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    layer.isOpaque = true
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
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
    let texture = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 2048, height: 2048, mipmapped: false)
    texture.storageMode = .shared
    texture.usage = .shaderRead
    guard let atlas = gpu.makeTexture(descriptor: texture) else { throw RendererError.noMemory }
    self.atlas = atlas
    font = TerminalFont.core(size: 14)
    boldFont = font
    italicFont = font
    boldItalicFont = font
    resetAtlas()
  }
  enum RendererError: Error { case noDevice, noShaders, noMemory }
  func request(_ value: RenderRequest) {
    lock.lock()
    latest = value
    if scheduled {
      lock.unlock()
      return
    }
    scheduled = true
    lock.unlock()
    queue.async { [self] in drain() }
  }
  private func drain() {
    lock.lock()
    let value = latest
    latest = nil
    lock.unlock()
    if let value { draw(value) }
    lock.lock()
    if latest != nil {
      lock.unlock()
      queue.async { [self] in drain() }
    } else {
      scheduled = false
      lock.unlock()
    }
  }
  private func resetAtlas() {
    glyphs.removeAll(keepingCapacity: true)
    atlasX = 4
    atlasY = 0
    shelf = 0
    var white: [UInt8] = [255, 255, 255, 255]
    white.withUnsafeMutableBytes {
      atlas.replace(
        region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 4)
    }
  }
  private static func linear(_ s: Float) -> Float {
    s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
  }
  private func color(_ spec: TerminalColor, fallback: [Int], palette: [[Int]]) -> SIMD4<Float> {
    let rgb =
      spec.rgb ?? spec.index.flatMap { palette.indices.contains($0) ? palette[$0] : nil }
      ?? fallback
    return SIMD4(
      Self.linear(Float(rgb[0]) / 255), Self.linear(Float(rgb[1]) / 255),
      Self.linear(Float(rgb[2]) / 255), 1)
  }
  private func glyph(_ key: GlyphKey, cells: Int, request: RenderRequest) -> Glyph? {
    if let value = glyphs[key] { return value }
    let width = request.cellWidth * cells
    let height = request.cellHeight
    if atlasX + width + 1 > atlasSize {
      atlasX = 0
      atlasY += shelf + 1
      shelf = 0
    }
    guard atlasY + height + 1 < atlasSize else { return nil }
    let selected =
      key.bold ? (key.italic ? boldItalicFont : boldFont) : (key.italic ? italicFont : font)
    var pixels = TerminalFont.rasterize(key.text, font: selected, width: width, height: height).pixels
    // Convert premultiplied sRGB raster output to premultiplied linear RGBA.
    // White mask glyphs retain coverage; emoji keep their source colors.
    for pixel in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Float(pixels[pixel + 3]) / 255
      if alpha > 0 {
        for component in 0..<3 {
          let straight = min(1, Float(pixels[pixel + component]) / 255 / alpha)
          pixels[pixel + component] = UInt8(
            clamping: Int((Self.linear(straight) * alpha * 255).rounded()))
        }
      } else {
        pixels[pixel] = 0
        pixels[pixel + 1] = 0
        pixels[pixel + 2] = 0
      }
    }
    pixels.withUnsafeBytes {
      atlas.replace(
        region: MTLRegionMake2D(atlasX, atlasY, width, height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: width * 4)
    }
    let value = Glyph(
      uv: SIMD4(
        Float(atlasX) / 2048, Float(atlasY) / 2048, Float(width) / 2048, Float(height) / 2048),
      width: width)
    atlasX += width + 1
    shelf = max(shelf, height)
    glyphs[key] = value
    return value
  }
  private func draw(_ request: RenderRequest) {
    guard request.width > 0, request.height > 0 else { return }
    inFlight.wait()
    // Atlas writes cannot race sampling in an older command buffer. At most two
    // frames are in flight, but glyph uploads currently drain both before mutation.
    inFlight.wait()
    inFlight.signal()
    if metrics != SIMD2(request.cellWidth, request.cellHeight) || fontSize != request.fontSize {
      metrics = SIMD2(request.cellWidth, request.cellHeight)
      fontSize = request.fontSize
      font = TerminalFont.core(size: fontSize)
      boldFont = TerminalFont.core(size: fontSize, bold: true)
      italicFont = TerminalFont.core(size: fontSize, italic: true)
      boldItalicFont = TerminalFont.core(size: fontSize, bold: true, italic: true)
      resetAtlas()
    }
    let preparationStart = DispatchTime.now().uptimeNanoseconds
    var quads: [Quad] = []
    var backgrounds: [Quad] = []
    let snap = request.snapshot
    let searchRows = Dictionary(snap.search.map { ($0.row, $0) }, uniquingKeysWith: { first, _ in first })
    let baseBackground = SIMD4<Float>(
      Self.linear(Float(snap.default_bg[0]) / 255), Self.linear(Float(snap.default_bg[1]) / 255),
      Self.linear(Float(snap.default_bg[2]) / 255), 1)
    let whiteUV = SIMD4<Float>(0.5 / 2048, 0.5 / 2048, 0, 0)
    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: SIMD4<Float>) {
      quads.append(
        Quad(rect: SIMD4(Float(x), Float(y), Float(w), Float(h)), uv: whiteUV, color: color))
    }
    var needsReset = false
    for pass in 0..<2 {
      quads.removeAll(keepingCapacity: true)
      backgrounds.removeAll(keepingCapacity: true)
      needsReset = false
      for (r, row) in snap.rows.enumerated() {
        let search = searchRows[r]
        for (c, cell) in row.cells.enumerated() {
          let x = request.inset + c * request.cellWidth
          let y = request.inset + r * request.cellHeight
          var fg = color(cell.style.foreground, fallback: snap.default_fg, palette: snap.palette)
          var bg = color(cell.style.background, fallback: snap.default_bg, palette: snap.palette)
          if cell.style.inverse != snap.modes.reverse_video { swap(&fg, &bg) }
          if cell.style.faint { fg *= SIMD4(0.65, 0.65, 0.65, 1) }
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
                text: displayText, cells: cells, bold: cell.style.bold, italic: cell.style.italic)
              if let glyph = glyph(key, cells: cells, request: request) {
                let emoji = cell.text.unicodeScalars.contains { (0x1f000...0x1faff).contains($0.value) }
                quads.append(
                  Quad(
                    rect: SIMD4(Float(x), Float(y), Float(glyph.width), Float(request.cellHeight)),
                    uv: glyph.uv, color: emoji ? SIMD4(1, 1, 1, 1) : fg))
              } else {
                needsReset = true
              }
            }
            if cell.style.underline > 0 {
              rect(x, y + request.cellHeight - 3, request.cellWidth * cells, 1, fg)
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
    quads.removeAll(keepingCapacity: true)
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
      let cells = min(20, max(1, request.marked.count))
      let key = GlyphKey(text: request.marked, cells: cells, bold: false, italic: false)
      if let g = glyph(key, cells: cells, request: request) {
        let x = request.inset + snap.cursor.col * request.cellWidth
        let y = request.inset + snap.cursor.row * request.cellHeight
        rect(
          x, y, cells * request.cellWidth, request.cellHeight,
          TerminalTheme.linear(TerminalTheme.raised))
        quads.append(
          Quad(
            rect: SIMD4(Float(x), Float(y), Float(g.width), Float(request.cellHeight)), uv: g.uv,
            color: SIMD4(1, 1, 1, 1)))
        rect(
          x, y + request.cellHeight - 2, cells * request.cellWidth, 1,
          TerminalTheme.linear(TerminalTheme.accent))
      }
    }
    let overlayQuads = quads
    let imageKeys = Set(snap.images.map { $0.key })
    imageTextures = imageTextures.filter { imageKeys.contains($0.key) }
    for placement in snap.images where imageTextures[placement.key] == nil {
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
        imageTextures[placement.key] = texture
      }
    }
    let preparationMs = Double(DispatchTime.now().uptimeNanoseconds - preparationStart) / 1_000_000
    guard let drawable = layer.nextDrawable(), let command = commands.makeCommandBuffer() else {
      inFlight.signal()
      return
    }
    let drawableWidth = drawable.texture.width
    let drawableHeight = drawable.texture.height
    let matchesRequest = RendererMetrics.recordDrawable(
      requestWidth: request.width, requestHeight: request.height,
      drawableWidth: drawableWidth, drawableHeight: drawableHeight)
    // `CAMetalLayer` can hand us a drawable for a resize that happened after this
    // request was queued. Its pixel coordinates describe the old grid, so a
    // present would temporarily distort or clip the terminal. The geometry change
    // also queued a replacement request; let it render the current drawable.
    guard matchesRequest else {
      RendererMetrics.recordStaleFrameDrop()
      inFlight.signal()
      return
    }
    command.label = "Terminal frame \(submissions) revision \(snap.revision)"
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = drawable.texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(Self.linear(Float(snap.default_bg[0]) / 255)),
      green: Double(Self.linear(Float(snap.default_bg[1]) / 255)),
      blue: Double(Self.linear(Float(snap.default_bg[2]) / 255)), alpha: 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
      inFlight.signal()
      return
    }
    encoder.setRenderPipelineState(pipeline)
    var extent = SIMD2<Float>(Float(drawableWidth), Float(drawableHeight))
    encoder.setVertexBytes(&extent, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    func drawQuads(_ items: [Quad], texture: MTLTexture, state: MTLRenderPipelineState) {
      guard !items.isEmpty,
        let buffer = device.makeBuffer(
          bytes: items, length: MemoryLayout<Quad>.stride * items.count, options: .storageModeShared
        )
      else { return }
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
        guard let texture = imageTextures[p.key] else { continue }
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
    drawQuads(backgrounds, texture: atlas, state: pipeline)
    drawImages { $0 < 0 && $0 >= -1_073_741_824 }
    drawQuads(textQuads, texture: atlas, state: pipeline)
    drawImages { $0 >= 0 }
    drawQuads(overlayQuads, texture: atlas, state: pipeline)
    encoder.endEncoding()
    RendererMetrics.recordPresentation(
      requestWidth: request.width, requestHeight: request.height,
      drawableWidth: drawableWidth, drawableHeight: drawableHeight)
    command.present(drawable)
    let semaphore = inFlight
    command.addCompletedHandler { command in
      RendererMetrics.completed(
        gpuMs: (command.gpuEndTime - command.gpuStartTime) * 1000, error: command.error != nil)
      semaphore.signal()
    }
    command.commit()
    submissions += 1
    RendererMetrics.record(preparationMs: preparationMs)
  }
}

final class RendererMetrics: @unchecked Sendable {
  private static let lock = NSLock()
  private static var count: UInt64 = 0
  private static var mismatchedDrawables: UInt64 = 0
  private static var mismatchedPresents: UInt64 = 0
  private static var droppedStaleFrames: UInt64 = 0
  private static var preparation: [Double] = []
  private static var gpu: [Double] = []
  private static var errors = 0
  static func record(preparationMs: Double) {
    lock.lock()
    count += 1
    if preparation.count == 128 { preparation.removeFirst() }
    preparation.append(preparationMs)
    lock.unlock()
  }
  static func completed(gpuMs: Double, error: Bool) {
    lock.lock()
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
      "command_errors": errors, "font": TerminalFont.family, "attachment": "BGRA8Unorm_sRGB",
      "glyph_atlas": "premultiplied linear RGBA8Unorm",
      "mismatched_drawables": mismatchedDrawables,
      "mismatched_presents": mismatchedPresents,
      "dropped_stale_frames": droppedStaleFrames,
    ]
  }
}

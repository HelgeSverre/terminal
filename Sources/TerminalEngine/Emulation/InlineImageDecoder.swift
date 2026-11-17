import Foundation
import CoreGraphics
import ImageIO

/// Collects an iTerm2 inline image as its bytes arrive: what follows
/// `OSC 1337 ; File=` up to the string terminator, which is
/// `name=…;width=…;inline=1:` and then the file in base64.
final class InlineImageDecoder {
  /// The largest file accepted, before decoding.
  static let maximumFileBytes = 32 * 1024 * 1024
  /// The most pixels kept; a larger picture is scaled down while decoding.
  static let maximumPixels = KittyGraphicsStore.maximumImageBytes / 4

  /// One of the protocol's sizes: `auto`, cells, pixels or percent.
  enum Size: Equatable { case automatic, cells(Int), pixels(Int), percent(Int) }
  struct Request {
    var width = Size.automatic
    var height = Size.automatic
    var preservesAspectRatio = true
    var inline = false
  }
  struct Frame {
    let rgba: Data
    let milliseconds: Int
  }
  var waitsForFileEnd = false
  private var partBytes = 0

  convenience init(multipartHeader: String) {
    self.init()
    for byte in (multipartHeader + ":").utf8 { push(byte) }
    waitsForFileEnd = true
  }
  func beginPart() { partBytes = 0 }

  private var header: [UInt8] = []
  private var inHeader = true
  private var encoded = Data()
  private var failed = false

  func push(_ byte: UInt8) {
    guard !failed else { return }
    if waitsForFileEnd {
      partBytes += 1
      guard partBytes <= 1_048_576 else { failed = true; return }
    }
    if inHeader {
      if byte == UInt8(ascii: ":") { inHeader = false }
      else if header.count < 4096 { header.append(byte) }
      else { failed = true }
      return
    }
    // Base64 of the largest file, with room for line breaks some tools add.
    guard encoded.count < Self.maximumFileBytes / 3 * 4 + 4 else { failed = true; return }
    if byte > 0x20 { encoded.append(byte) }
  }

  private static func size(_ text: Substring) -> Size? {
    if text == "auto" { return .automatic }
    if text.hasSuffix("px"), let value = Int(text.dropLast(2)), value > 0 { return .pixels(min(value, 1_000_000)) }
    if text.hasSuffix("%"), let value = Int(text.dropLast(1)), value > 0 { return .percent(min(value, 1000)) }
    if let value = Int(text), value > 0 { return .cells(min(value, 4096)) }
    return nil
  }

  /// The request and the decoded picture, or nil when the sequence is not
  /// an inline image this terminal can show.
  func finish() -> (request: Request, width: Int, height: Int, rgba: Data, frames: [Frame])? {
    guard !failed, !inHeader, let fields = String(bytes: header, encoding: .utf8) else { return nil }
    var request = Request()
    for field in fields.split(separator: ";") {
      guard let equals = field.firstIndex(of: "=") else { continue }
      let value = field[field.index(after: equals)...]
      switch field[..<equals] {
      case "width": if let size = Self.size(value) { request.width = size }
      case "height": if let size = Self.size(value) { request.height = size }
      case "preserveAspectRatio": request.preservesAspectRatio = value != "0"
      case "inline": request.inline = value == "1"
      default: break
      }
    }
    // Without `inline=1` the file is a download, which is not offered.
    guard request.inline, let file = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
      !file.isEmpty, file.count <= Self.maximumFileBytes,
      let picture = Self.decode(file),
      let source = CGImageSourceCreateWithData(file as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count <= 1000, count <= KittyGraphicsStore.maximumImageBytes / picture.rgba.count else { return nil }
    var frames: [Frame] = []
    if count > 1 {
      for index in 0..<count {
        guard let frame = Self.decode(file, frame: index), frame.width == picture.width, frame.height == picture.height else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        frames.append(Frame(rgba: frame.rgba, milliseconds: Int(min(60, max(0.01, delay)) * 1000)))
      }
    }
    return (request, picture.width, picture.height, picture.rgba, frames)
  }

  /// Decodes any format ImageIO reads (PNG, JPEG, GIF's first frame, …) to
  /// straight RGBA, scaled down when it has more pixels than are kept.
  static func decode(_ file: Data, frame: Int = 0) -> (width: Int, height: Int, rgba: Data)? {
    guard let source = CGImageSourceCreateWithData(file as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
      let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
      let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
      sourceWidth > 0, sourceHeight > 0, sourceWidth <= 65_536, sourceHeight <= 65_536
    else { return nil }
    // The longest side that keeps the picture within both limits.
    var longest = min(4096, max(sourceWidth, sourceHeight))
    let pixels = Double(sourceWidth) * Double(sourceHeight)
    let scale = Double(longest) / Double(max(sourceWidth, sourceHeight))
    if pixels * scale * scale > Double(maximumPixels) {
      longest = Int((Double(maximumPixels) / pixels).squareRoot() * Double(max(sourceWidth, sourceHeight)))
    }
    guard longest > 0 else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: longest, kCGImageSourceShouldCache: false,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary) else { return nil }
    let width = image.width, height = image.height
    guard width > 0, height > 0, width * height <= maximumPixels else { return nil }
    var rgba = Data(count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      // The store keeps straight alpha; undo the premultiplication.
      let bytes = raw.bindMemory(to: UInt8.self)
      for index in stride(from: 0, to: width * height * 4, by: 4) {
        let alpha = Int(bytes[index + 3])
        guard alpha != 0, alpha != 255 else { continue }
        for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, Int(bytes[index + channel]) * 255 / alpha)) }
      }
      return true
    }
    return drawn ? (width, height, rgba) : nil
  }
}

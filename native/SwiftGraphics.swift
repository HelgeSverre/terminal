import Foundation
import CoreGraphics
import ImageIO
import Compression

// KittyGraphicsStore is the sole owner of Kitty image protocol state.  Callers
// supply a complete APC body (the bytes after ESC _) and a grid context; they
// receive an optional reply plus an optional cursor advance.  The store keeps
// upload atomicity, resource limits, placement uniqueness and image lifetime
// private, so the terminal parser never needs to reason about chunks or pixels.

struct KittyGraphicsContext {
  let alternate: Bool
  let row: UInt64
  let column: Int
  let cellWidth: Int
  let cellHeight: Int
}

struct KittyImagePlacement: Equatable {
  let image: UInt32
  let generation: UInt64
  let width: Int
  let height: Int
  let source: [Int]
  let row: Int
  let column: Int
  let columns: Int
  let rows: Int
  let offset: [Int]
  let natural: Bool
  let z: Int
  let placement: UInt64
}

struct KittyGraphicsOutcome {
  var reply: Data?
  var advance: (Int, Int)?
}

enum KittyGraphicsError: Error, Equatable {
  case invalid, unsupported, tooLarge, noSpace, notFound
  var wire: String {
    switch self {
    case .invalid: return "EINVAL:invalid graphics command or image data"
    case .unsupported: return "ENOTSUP:unsupported graphics feature or transport"
    case .tooLarge: return "E2BIG:image exceeds configured limits"
    case .noSpace: return "ENOSPC:image storage budget exhausted"
    case .notFound: return "ENOENT:image not found"
    }
  }
}

final class KittyGraphicsStore {
  static let maximumImageBytes = 16 * 1024 * 1024
  static let maximumStorageBytes = 64 * 1024 * 1024
  private static let maximumImages = 64
  private static let maximumPlacements = 256
  private static let pngCRCTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
    return crc
  }

  private struct Image {
    let id: UInt32
    let generation: UInt64
    let alternate: Bool
    let width: Int
    let height: Int
    let rgba: Data
  }
  private struct Placement {
    let image: UInt32
    let id: UInt32
    let serial: UInt64
    let alternate: Bool
    let row: UInt64
    let column: Int
    let source: [Int]
    let cells: [Int]
    let offset: [Int]
    let natural: Bool
    let z: Int
  }
  private struct Upload {
    var fields: [Character: String]
    var bytes: Data
    let started: UInt64
    var lastChunk: UInt64
  }

  private var images: [UInt32: Image] = [:]
  private var placements: [Placement] = []
  private var pending: Upload?
  private var serial: UInt64 = 0
  private var bytes = 0

  var accountedBytes: Int { bytes + (pending?.bytes.count ?? 0) }
  var hasPlacements: Bool { !placements.isEmpty }
  func imageRGBA(id: UInt32, generation: UInt64) -> Data? {
    guard let image = images[id], image.generation == generation else { return nil }
    return image.rgba
  }
  func abort() { pending = nil }
  func tick(now: UInt64) {
    guard let upload = pending else { return }
    if now > upload.lastChunk && now - upload.lastChunk > 10_000 || now > upload.started && now - upload.started > 60_000 { pending = nil }
  }
  func clear() { images.removeAll(); placements.removeAll(); pending = nil; bytes = 0 }
  func clear(alternate: Bool, removeResources: Bool = false) {
    placements.removeAll { $0.alternate == alternate }
    if removeResources {
      let live = Set(placements.map(\.image))
      images = images.filter { $0.value.alternate != alternate || live.contains($0.key) }
      bytes = images.values.reduce(0) { $0 + $1.rgba.count }
      pending = nil
    }
  }
  func pruneAnchors(retaining rows: Set<UInt64>) { placements.removeAll { !rows.contains($0.row) } }
  func visible(alternate: Bool, positions: [UInt64: Int], height: Int) -> [KittyImagePlacement] {
    placements.compactMap { placement in
      guard placement.alternate == alternate, let image = images[placement.image],
            let row = positions[placement.row], row < height, row + placement.cells[1] > 0 else { return nil }
      return KittyImagePlacement(image: placement.image, generation: image.generation, width: image.width,
        height: image.height, source: placement.source, row: row, column: placement.column,
        columns: placement.cells[0], rows: placement.cells[1], offset: placement.offset,
        natural: placement.natural, z: placement.z, placement: placement.serial)
    }.sorted { ($0.z, $0.image, $0.placement) < ($1.z, $1.image, $1.placement) }
  }

  // `packet` is G<header>;<base64>, without the APC delimiters.
  func consume(_ packet: Data, context: KittyGraphicsContext, now: UInt64) -> KittyGraphicsOutcome {
    guard packet.first == Character("G").asciiValue else { return KittyGraphicsOutcome() }
    let body = packet.dropFirst()
    let split = body.firstIndex(of: UInt8(ascii: ";"))
    let header = split.map { Data(body[..<$0]) } ?? Data(body)
    let payload = split.map { Data(body[body.index(after: $0)...]) } ?? Data()
    guard let incoming = fields(header) else { abort(); return KittyGraphicsOutcome() }
    let action = incoming["a"] ?? "t"
    if action == "q", incoming["e"] != nil { return KittyGraphicsOutcome(reply: featureReply(incoming), advance: nil) }
    let continuation = pending != nil && incoming.keys.allSatisfy { $0 == "m" || $0 == "q" }
    var upload: Upload
    if continuation, var old = pending {
      pending = nil
      if let quiet = incoming["q"] { old.fields["q"] = quiet }
      if let more = incoming["m"] { old.fields["m"] = more }
      upload = old
    } else {
      pending = nil
      if action == "d" { return outcome(fields: incoming, result: delete(incoming, context: context)) }
      if action == "p" {
        let id = UInt32((try? number(incoming, "i", default: 0)) ?? 0)
        guard let image = images[id] else { return outcome(fields: incoming, result: .failure(.notFound)) }
        return outcome(fields: incoming, result: place(incoming, image: image, context: context))
      }
      guard action == "t" || action == "T" || action == "q" else { return outcome(fields: incoming, result: .failure(.unsupported)) }
      upload = Upload(fields: incoming, bytes: Data(), started: now, lastChunk: now)
    }
    let more: Bool
    do {
      let continuation = try number(incoming, "m", default: 0)
      guard continuation <= 1 else { throw KittyGraphicsError.invalid }
      more = continuation == 1
      try validateTransport(upload.fields)
      if payload.count > 4096 || (more && payload.contains(UInt8(ascii: "="))) { throw KittyGraphicsError.invalid }
      guard let decoded = Data(base64Encoded: payload, options: []), decoded.base64EncodedData() == payload else { throw KittyGraphicsError.invalid }
      guard upload.bytes.count + decoded.count <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
      upload.bytes.append(decoded)
      upload.lastChunk = now
    } catch let error as KittyGraphicsError { return outcome(fields: upload.fields, result: .failure(error)) }
      catch { return outcome(fields: upload.fields, result: .failure(.invalid)) }
    if more { pending = upload; return KittyGraphicsOutcome() }
    return outcome(fields: upload.fields, result: finish(upload, context: context))
  }

  private func fields(_ header: Data) -> [Character: String]? {
    guard header.count <= 1024, let string = String(data: header, encoding: .utf8) else { return nil }
    var result: [Character: String] = [:]
    for field in string.split(separator: ",", omittingEmptySubsequences: true) {
      guard field.count >= 3, field[field.index(after: field.startIndex)] == "=",
        let key = field.first, key.isASCII && key.isLetter, field.count <= 16, result[key] == nil,
        result.count < 32 else { return nil }
      result[key] = String(field.dropFirst(2))
    }
    return result
  }
  private func number(_ values: [Character: String], _ key: Character, default fallback: Int) throws -> Int {
    guard let string = values[key] else { return fallback }
    guard let value = UInt32(string), !string.hasPrefix("-") else { throw KittyGraphicsError.invalid }
    return Int(value)
  }
  private func validateTransport(_ values: [Character: String]) throws {
    let type = values["t"] ?? "d"
    guard type == "d" else { throw KittyGraphicsError.unsupported }
    if let compression = values["o"], compression != "z" { throw KittyGraphicsError.unsupported }
    let format = try number(values, "f", default: 32)
    guard format == 24 || format == 32 || format == 100 else { throw KittyGraphicsError.unsupported }
    if format != 100 {
      let width = try number(values, "s", default: 0), height = try number(values, "v", default: 0)
      guard width > 0, height > 0, width <= 65_535, height <= 65_535 else { throw KittyGraphicsError.tooLarge }
      guard width * height * 4 <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
    }
  }
  private func finish(_ upload: Upload, context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    do {
      let decoded = try decode(upload.fields, bytes: upload.bytes)
      if upload.fields["a"] == "q" { return .success(nil) }
      var id = (try? number(upload.fields, "i", default: 0)) ?? 0
      if id == 0 {
        guard let available = (1...Int(UInt32.max)).reversed().first(where: { images[UInt32($0)] == nil }) else { throw KittyGraphicsError.noSpace }
        id = available
      }
      guard serial < UInt64.max else { throw KittyGraphicsError.noSpace }
      let generation = serial + 1
      let image = Image(id: UInt32(id), generation: generation, alternate: context.alternate, width: decoded.width,
        height: decoded.height, rgba: decoded.rgba)
      if upload.fields["a"] == "T" { _ = try layout(upload.fields, image: image, context: context, serial: generation) }
      try makeRoom(replacing: UInt32(id), size: image.rgba.count)
      serial = generation
      if let old = images[UInt32(id)] { bytes -= old.rgba.count }
      images[UInt32(id)] = image; bytes += image.rgba.count
      placements.removeAll { $0.image == UInt32(id) }
      return upload.fields["a"] == "T" ? place(upload.fields, image: image, context: context) : .success(nil)
    } catch let error as KittyGraphicsError { return .failure(error) }
      catch { return .failure(.invalid) }
  }
  private func decode(_ values: [Character: String], bytes: Data) throws -> (width: Int, height: Int, rgba: Data) {
    let format = try number(values, "f", default: 32)
    if format == 100 {
      let payload = values["o"] == "z" ? try inflate(bytes, limit: Self.maximumImageBytes) : bytes
      return try png(payload)
    }
    let width = try number(values, "s", default: 0), height = try number(values, "v", default: 0)
    let expected = width * height * (format == 24 ? 3 : 4)
    guard expected > 0, expected <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
    let payload = values["o"] == "z" ? try inflate(bytes, limit: expected) : bytes
    guard expected == payload.count else { throw KittyGraphicsError.invalid }
    if format == 32 { return (width, height, payload) }
    var rgba = Data(capacity: width * height * 4)
    for pixel in payload.withUnsafeBytes({ Array($0.bindMemory(to: UInt8.self)) }).chunks(ofCount: 3) { rgba.append(contentsOf: [pixel[0], pixel[1], pixel[2], 255]) }
    return (width, height, rgba)
  }
  // The declared dimensions bound output before allocating. `compression` only
  // returns success when one complete zlib stream fits that fixed buffer, so a
  // decompression bomb cannot grow memory beyond the image protocol limit.
  private func inflate(_ input: Data, limit: Int) throws -> Data {
    guard !input.isEmpty, limit > 0, limit <= Self.maximumImageBytes else { throw KittyGraphicsError.invalid }
    // Compression.framework's ZLIB decoder consumes a raw DEFLATE stream on
    // current macOS. Kitty (and Rust's `ZlibEncoder`) supplies RFC1950 framing,
    // so validate and strip the two-byte header/four-byte Adler trailer first.
    guard input.count >= 6, input[0] & 0x0f == 8, input[0] >> 4 <= 7,
          input[1] & 0x20 == 0,
          ((UInt16(input[0]) << 8) | UInt16(input[1])) % 31 == 0 else { throw KittyGraphicsError.invalid }
    let source = input.subdata(in: 2..<(input.count - 4))
    guard !source.isEmpty else { throw KittyGraphicsError.invalid }
    // Reserve one sentinel byte so the decoder can prove stream completion
    // even when the legal payload exactly fills its declared image extent.
    var output = Data(count: limit + 1)
    let count = output.withUnsafeMutableBytes { destination in
      source.withUnsafeBytes { compressed in
        compression_decode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, limit + 1,
          compressed.bindMemory(to: UInt8.self).baseAddress!, source.count,
          nil, COMPRESSION_ZLIB)
      }
    }
    guard count > 0, count <= limit else { throw KittyGraphicsError.invalid }
    output.removeSubrange(count..<output.count)
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in output { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
    let checksum = input.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard (b << 16 | a) == checksum else { throw KittyGraphicsError.invalid }
    return output
  }
  private func png(_ bytes: Data) throws -> (width: Int, height: Int, rgba: Data) {
    guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), bytes.count >= 33 else { throw KittyGraphicsError.invalid }
    // ImageIO erases RGB behind a tRNS color key. Remove only that chunk from
    // its input, then apply the original key/palette alpha to decoded samples.
    var decodedInput = Data(bytes.prefix(8))
    var transparency: [UInt8]?
    var offset = 8
    while offset < bytes.count {
      guard bytes.count - offset >= 12 else { throw KittyGraphicsError.invalid }
      let size = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
      guard size <= bytes.count - offset - 12 else { throw KittyGraphicsError.invalid }
      let end = offset + size + 12
      var crc = UInt32.max
      for byte in bytes[(offset + 4)..<(end - 4)] { crc = Self.pngCRCTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
      let expectedCRC = bytes[(end - 4)..<end].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard crc ^ UInt32.max == expectedCRC else { throw KittyGraphicsError.invalid }
      if bytes[(offset + 4)..<(offset + 8)].elementsEqual([116, 82, 78, 83]) {
        guard transparency == nil else { throw KittyGraphicsError.invalid }
        transparency = Array(bytes[(offset + 8)..<(end - 4)])
      } else { decodedInput.append(bytes[offset..<end]) }
      offset = end
    }
    guard let source = CGImageSourceCreateWithData(decodedInput as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
          let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { throw KittyGraphicsError.invalid }
    guard width > 0, height > 0, width <= 65_535, height <= 65_535,
          width * height * 4 <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
          let color = image.colorSpace, let provider = image.dataProvider?.data else { throw KittyGraphicsError.invalid }
    // Copy decoded samples. CGContext rendering premultiplies alpha and
    // color-converts, destroying the protocol's exact RGBA values.
    let pixels = provider as Data
    let bits = image.bitsPerComponent
    guard [1, 2, 4, 8, 16].contains(bits), image.bytesPerRow * height <= pixels.count else { throw KittyGraphicsError.invalid }
    let components = image.bitsPerPixel / bits
    let table = color.colorTable ?? []
    func rawSample(_ row: Int, _ column: Int, _ component: Int) -> Int {
      let bit = (column * components + component) * bits
      let offset = row * image.bytesPerRow + bit / 8
      if bits == 16 {
        let little = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder16Little.rawValue
        return Int(pixels[offset + (little ? 1 : 0)]) << 8 | Int(pixels[offset + (little ? 0 : 1)])
      }
      if bits == 8 { return Int(pixels[offset]) }
      let mask = (1 << bits) - 1
      return (Int(pixels[offset]) >> (8 - bits - bit % 8)) & mask
    }
    func sample(_ row: Int, _ column: Int, _ component: Int) -> UInt8 {
      let value = rawSample(row, column, component)
      if bits == 16 { return UInt8(value >> 8) }
      return bits == 8 || color.model == .indexed ? UInt8(value) : UInt8(value * 255 / ((1 << bits) - 1))
    }
    var rgba = Data(capacity: width * height * 4)
    for row in 0..<height { for column in 0..<width {
      let alphaFirst = image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
      let start = alphaFirst ? 1 : 0
      var alpha: UInt8 = image.alphaInfo == .first ? sample(row, column, 0)
        : image.alphaInfo == .last ? sample(row, column, components - 1) : 255
      if let transparency {
        switch bytes[25] {
        case 0:
          guard transparency.count == 2 else { throw KittyGraphicsError.invalid }
          let key = Int(transparency[0]) << 8 | Int(transparency[1])
          if rawSample(row, column, start) == key { alpha = 0 }
        case 2:
          guard transparency.count == 6 else { throw KittyGraphicsError.invalid }
          if (0..<3).allSatisfy({ rawSample(row, column, start + $0) == Int(transparency[$0 * 2]) << 8 | Int(transparency[$0 * 2 + 1]) }) { alpha = 0 }
        case 3:
          let index = rawSample(row, column, 0)
          alpha = index < transparency.count ? transparency[index] : 255
        default: throw KittyGraphicsError.invalid
        }
      }
      switch color.model {
      case .rgb:
        guard components >= start + 3 else { throw KittyGraphicsError.invalid }
        rgba.append(contentsOf: [sample(row, column, start), sample(row, column, start + 1), sample(row, column, start + 2), alpha])
      case .monochrome:
        let gray = sample(row, column, start); rgba.append(contentsOf: [gray, gray, gray, alpha])
      case .indexed:
        let stride = color.baseColorSpace?.numberOfComponents ?? 3
        let index = Int(sample(row, column, 0)) * stride
        guard index + stride <= table.count, stride == 1 || stride == 3 else { throw KittyGraphicsError.invalid }
        rgba.append(contentsOf: stride == 1 ? [table[index], table[index], table[index], alpha] : [table[index], table[index + 1], table[index + 2], alpha])
      default: throw KittyGraphicsError.invalid
      }
    }}
    return (width, height, rgba)
  }
  private func layout(_ values: [Character: String], image: Image, context: KittyGraphicsContext, serial: UInt64) throws -> (Placement, (Int, Int)?) {
    let x = min(try number(values, "x", default: 0), image.width)
    let y = min(try number(values, "y", default: 0), image.height)
    let requestedWidth = try number(values, "w", default: 0), requestedHeight = try number(values, "h", default: 0)
    let width = requestedWidth == 0 ? image.width - x : min(requestedWidth, image.width - x)
    let height = requestedHeight == 0 ? image.height - y : min(requestedHeight, image.height - y)
    let cw = max(1, context.cellWidth), ch = max(1, context.cellHeight)
    let ox = try number(values, "X", default: 0), oy = try number(values, "Y", default: 0)
    guard width > 0, height > 0, ox < cw, oy < ch else { throw KittyGraphicsError.invalid }
    var c = try number(values, "c", default: 0), r = try number(values, "r", default: 0)
    let natural = c == 0 && r == 0
    // Reject before multiplication; all accepted placement extents are <=4096.
    guard c <= 4096, r <= 4096 else { throw KittyGraphicsError.tooLarge }
    if natural { c = (width + ox + cw - 1) / cw; r = (height + oy + ch - 1) / ch }
    else if c == 0 { c = (r * ch * width + height * cw - 1) / (height * cw) }
    else if r == 0 { r = (c * cw * height + width * ch - 1) / (width * ch) }
    guard c > 0, r > 0, c <= 4096, r <= 4096 else { throw KittyGraphicsError.tooLarge }
    let id = try number(values, "p", default: 0)
    guard let z = Int32(values["z"] ?? "0") else { throw KittyGraphicsError.invalid }
    let movement = try number(values, "C", default: 0)
    guard movement <= 1 else { throw KittyGraphicsError.invalid }
    let placement = Placement(image: image.id, id: UInt32(id), serial: serial, alternate: context.alternate,
      row: context.row, column: context.column, source: [x, y, width, height], cells: [c, r], offset: [ox, oy], natural: natural, z: Int(z))
    return (placement, movement == 0 ? (c, r) : nil)
  }
  private func place(_ values: [Character: String], image: Image, context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    do {
      guard serial < UInt64.max else { throw KittyGraphicsError.noSpace }
      let nextSerial = serial + 1
      let (placement, advance) = try layout(values, image: image, context: context, serial: nextSerial)
      if placement.id != 0 { placements.removeAll { $0.image == placement.image && $0.id == placement.id } }
      guard placements.count < Self.maximumPlacements else { throw KittyGraphicsError.noSpace }
      serial = nextSerial; placements.append(placement); return .success(advance)
    } catch let error as KittyGraphicsError { return .failure(error) }
      catch { return .failure(.invalid) }
  }
  private func delete(_ values: [Character: String], context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    guard let kind = (values["d"] ?? "a").first, (values["d"] ?? "a").count == 1, "aAiIzZ".contains(kind) else { return .failure(.unsupported) }
    let image = UInt32((try? number(values, "i", default: 0)) ?? 0)
    guard let rawPlacement = try? number(values, "p", default: 0), let z = Int32(values["z"] ?? "0") else { return .failure(.invalid) }
    let placement = UInt32(rawPlacement)
    var removeResources = Set<UInt32>()
    if kind == "I" && placement == 0 { removeResources.insert(image) }
    placements.removeAll { old in
      let matches: Bool
      switch kind { case "i", "I": matches = old.image == image && (placement == 0 || old.id == placement); case "z", "Z": matches = old.alternate == context.alternate && old.z == z; default: matches = old.alternate == context.alternate }
      if matches { removeResources.insert(old.image) }; return matches
    }
    if kind.isUppercase { for id in removeResources where !placements.contains(where: { $0.image == id }) { if let removed = images.removeValue(forKey: id) { bytes -= removed.rgba.count } } }
    return .success(nil)
  }
  private func makeRoom(replacing id: UInt32, size: Int) throws {
    let replaced = images[id]?.rgba.count ?? 0
    while bytes - replaced + size > Self.maximumStorageBytes || (images[id] == nil && images.count >= Self.maximumImages) {
      guard let victim = images.values.filter({ candidate in
        candidate.id != id && !placements.contains(where: { $0.image == candidate.id })
      }).min(by: { $0.generation < $1.generation }) else { throw KittyGraphicsError.noSpace }
      bytes -= victim.rgba.count; images.removeValue(forKey: victim.id)
    }
  }
  private func outcome(fields: [Character: String], result: Result<(Int, Int)?, KittyGraphicsError>) -> KittyGraphicsOutcome {
    let id = (try? number(fields, "i", default: 0)) ?? 0, quiet = (try? number(fields, "q", default: 0)) ?? 2
    let reply: Data?
    if id == 0 || quiet == 2 || (quiet == 1 && result.isSuccess) { reply = nil }
    else {
      let placement = (try? number(fields, "p", default: 0)) ?? 0
      let suffix = placement == 0 ? "" : ",p=\(placement)"
      let value: String
      switch result { case .success: value = "OK"; case .failure(let error): value = error.wire }
      reply = Data("\u{1b}_Gi=\(id)\(suffix);\(value)\u{1b}\\".utf8)
    }
    return KittyGraphicsOutcome(reply: reply, advance: (try? result.get()) ?? nil)
  }
  private func featureReply(_ fields: [Character: String]) -> Data? {
    guard let id = try? number(fields, "i", default: 0), id != 0,
          (try? number(fields, "q", default: 0)) == 0,
          let feature = fields["e"], feature.utf8.count == 1 else { return nil }
    guard ["t", "T", "p", "d"].contains(feature) else { return outcome(fields: fields, result: .success(nil)).reply }
    let supported = fields.keys.sorted().compactMap { key -> String? in
      let value = fields[key]!
      switch key {
      case "f": guard ["24", "32", "100"].contains(value) else { return nil }
      case "t": guard value == "d" else { return nil }
      case "o": guard value == "z" else { return nil }
      case "C": guard value == "1" else { return nil }
      case "s", "v", "c", "r", "x", "y", "w", "h", "X", "Y", "z": break
      default: return nil
      }
      return ",\(key)=\(value)"
    }.joined()
    return Data("\u{1b}_Gi=\(id),e=\(feature)\(supported);OK\u{1b}\\".utf8)
  }
}

private extension Result where Success == (Int, Int)?, Failure == KittyGraphicsError { var isSuccess: Bool { if case .success = self { return true }; return false } }
private extension Array { func chunks(ofCount size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min(count, $0 + size)]) } } }

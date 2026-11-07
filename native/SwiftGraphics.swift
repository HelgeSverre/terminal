import Foundation
import CoreGraphics
import ImageIO

// KittyGraphicsStore is the sole owner of Kitty image protocol state.  Callers
// supply a complete APC body (the bytes after ESC _) and a grid context; they
// receive an optional reply plus an optional cursor advance.  The store keeps
// upload atomicity, resource limits, placement uniqueness and image lifetime
// private, so the terminal parser never needs to reason about chunks or pixels.

struct KittyGraphicsContext {
  let alternate: Bool
  let row: Int
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
    case .invalid: return "EINVAL"
    case .unsupported: return "ENOTSUP"
    case .tooLarge: return "E2BIG"
    case .noSpace: return "ENOSPC"
    case .notFound: return "ENOENT"
    }
  }
}

final class KittyGraphicsStore {
  static let maximumImageBytes = 16 * 1024 * 1024
  static let maximumStorageBytes = 64 * 1024 * 1024
  private static let maximumImages = 64
  private static let maximumPlacements = 256

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
    let row: Int
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
  func imageRGBA(id: UInt32, generation: UInt64) -> Data? {
    guard let image = images[id], image.generation == generation else { return nil }
    return image.rgba
  }
  func abort() { pending = nil }
  func tick(now: UInt64) {
    guard let upload = pending else { return }
    if now &- upload.lastChunk > 10_000 || now &- upload.started > 60_000 { pending = nil }
  }
  func clear() { images.removeAll(); placements.removeAll(); pending = nil; bytes = 0 }
  func clear(alternate: Bool, removeResources: Bool = false) {
    placements.removeAll { $0.alternate == alternate }
    if removeResources { pruneImages() }
    pending = nil
  }
  func visible(alternate: Bool) -> [KittyImagePlacement] {
    placements.compactMap { placement in
      guard placement.alternate == alternate, let image = images[placement.image] else { return nil }
      return KittyImagePlacement(image: placement.image, generation: image.generation, width: image.width,
        height: image.height, source: placement.source, row: placement.row, column: placement.column,
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
    let action = incoming["a"]?.first ?? "t"
    if action == "q", incoming["e"] != nil { return KittyGraphicsOutcome(reply: featureReply(incoming), advance: nil) }
    let continuation = pending != nil && incoming.keys.allSatisfy { $0 == "m" || $0 == "q" }
    var upload: Upload
    if continuation, var old = pending {
      if let quiet = incoming["q"] { old.fields["q"] = quiet }
      if let more = incoming["m"] { old.fields["m"] = more }
      upload = old
    } else {
      pending = nil
      if action == "d" { return outcome(fields: incoming, result: delete(incoming, context: context)) }
      if action == "p" { return outcome(fields: incoming, result: place(incoming, context: context)) }
      guard action == "t" || action == "T" || action == "q" else { return outcome(fields: incoming, result: .failure(.unsupported)) }
      upload = Upload(fields: incoming, bytes: Data(), started: now, lastChunk: now)
    }
    let more: Bool
    do {
      let continuation = try number(upload.fields, "m", default: 0)
      guard continuation <= 1 else { throw KittyGraphicsError.invalid }
      more = continuation == 1
      try validateTransport(upload.fields)
      if payload.count > 4096 || (more && payload.contains(UInt8(ascii: "="))) { throw KittyGraphicsError.invalid }
      guard let decoded = Data(base64Encoded: payload, options: []) else { throw KittyGraphicsError.invalid }
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
    guard let value = Int(string), value >= 0 else { throw KittyGraphicsError.invalid }
    return value
  }
  private func validateTransport(_ values: [Character: String]) throws {
    let type = values["t"] ?? "d"
    guard type == "d" else { throw KittyGraphicsError.unsupported }
    let format = try number(values, "f", default: 32)
    guard format == 24 || format == 32 || format == 100 else { throw KittyGraphicsError.unsupported }
    if format != 100 {
      let width = try number(values, "s", default: 0), height = try number(values, "v", default: 0)
      guard width > 0, height > 0, width <= 65_535, height <= 65_535 else { throw KittyGraphicsError.tooLarge }
    }
  }
  private func finish(_ upload: Upload, context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    do {
      let decoded = try decode(upload.fields, bytes: upload.bytes)
      if upload.fields["a"] == "q" { return .success(nil) }
      var id = try number(upload.fields, "i", default: 0)
      if id == 0 {
        guard let available = (1...Int(UInt32.max)).reversed().first(where: { images[UInt32($0)] == nil }) else { throw KittyGraphicsError.noSpace }
        id = available
      }
      let generation = try nextSerial()
      let image = Image(id: UInt32(id), generation: generation, alternate: context.alternate, width: decoded.width,
        height: decoded.height, rgba: decoded.rgba)
      if upload.fields["a"] == "T" { _ = try layout(upload.fields, image: image, context: context, serial: generation) }
      try makeRoom(replacing: UInt32(id), size: image.rgba.count)
      if let old = images[UInt32(id)] { bytes -= old.rgba.count }
      images[UInt32(id)] = image; bytes += image.rgba.count
      placements.removeAll { $0.image == UInt32(id) }
      return upload.fields["a"] == "T" ? place(upload.fields, context: context) : .success(nil)
    } catch let error as KittyGraphicsError { return .failure(error) }
      catch { return .failure(.invalid) }
  }
  private func decode(_ values: [Character: String], bytes: Data) throws -> (width: Int, height: Int, rgba: Data) {
    let format = try number(values, "f", default: 32)
    if format == 100 { return try png(bytes) }
    let width = try number(values, "s", default: 0), height = try number(values, "v", default: 0)
    let expected = width * height * (format == 24 ? 3 : 4)
    guard expected == bytes.count else { throw KittyGraphicsError.invalid }
    if format == 32 { return (width, height, bytes) }
    var rgba = Data(capacity: width * height * 4)
    for pixel in bytes.withUnsafeBytes({ Array($0.bindMemory(to: UInt8.self)) }).chunks(ofCount: 3) { rgba.append(contentsOf: [pixel[0], pixel[1], pixel[2], 255]) }
    return (width, height, rgba)
  }
  private func png(_ bytes: Data) throws -> (width: Int, height: Int, rgba: Data) {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw KittyGraphicsError.invalid }
    let width = image.width, height = image.height
    guard width > 0, height > 0, width * height * 4 <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
    var rgba = Data(count: width * height * 4)
    let color = CGColorSpaceCreateDeviceRGB()
    let context = rgba.withUnsafeMutableBytes { raw in
      CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    guard let context else { throw KittyGraphicsError.invalid }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (width, height, rgba)
  }
  private func layout(_ values: [Character: String], image: Image, context: KittyGraphicsContext, serial: UInt64) throws -> (Placement, (Int, Int)?) {
    let columns = try number(values, "c", default: 0), rows = try number(values, "r", default: 0)
    let natural = columns == 0 && rows == 0
    let c = natural ? max(1, (image.width + max(1, context.cellWidth) - 1) / max(1, context.cellWidth)) : columns
    let r = natural ? max(1, (image.height + max(1, context.cellHeight) - 1) / max(1, context.cellHeight)) : rows
    guard c > 0, r > 0, c <= 65_535, r <= 65_535 else { throw KittyGraphicsError.invalid }
    let id = try number(values, "p", default: 0)
    let placement = Placement(image: image.id, id: UInt32(id), serial: serial, alternate: context.alternate,
      row: context.row, column: context.column, source: [try number(values, "x", default: 0), try number(values, "y", default: 0), try number(values, "w", default: 0), try number(values, "h", default: 0)], cells: [c, r], offset: [try number(values, "X", default: 0), try number(values, "Y", default: 0)], natural: natural, z: Int(values["z"] ?? "0") ?? 0)
    return (placement, values["C"] == "1" ? (c, r) : nil)
  }
  private func place(_ values: [Character: String], context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    do {
      let id = UInt32(try number(values, "i", default: 0)); guard let image = images[id] else { throw KittyGraphicsError.notFound }
      let serial = try nextSerial(); let (placement, advance) = try layout(values, image: image, context: context, serial: serial)
      if placement.id != 0 { placements.removeAll { $0.image == placement.image && $0.id == placement.id } }
      guard placements.count < Self.maximumPlacements else { throw KittyGraphicsError.noSpace }
      placements.append(placement); return .success(advance)
    } catch let error as KittyGraphicsError { return .failure(error) }
      catch { return .failure(.invalid) }
  }
  private func delete(_ values: [Character: String], context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    guard let kind = (values["d"] ?? "a").first, "aAiIzZ".contains(kind) else { return .failure(.unsupported) }
    let image = UInt32(Int(values["i"] ?? "0") ?? 0), placement = UInt32(Int(values["p"] ?? "0") ?? 0), z = Int(values["z"] ?? "0") ?? 0
    var removeResources = Set<UInt32>()
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
  private func pruneImages() { let live = Set(placements.map(\ .image)); images = images.filter { live.contains($0.key) }; bytes = images.values.reduce(0) { $0 + $1.rgba.count } }
  private func nextSerial() throws -> UInt64 { guard serial < UInt64.max else { throw KittyGraphicsError.noSpace }; serial += 1; return serial }
  private func outcome(fields: [Character: String], result: Result<(Int, Int)?, KittyGraphicsError>) -> KittyGraphicsOutcome {
    let id = Int(fields["i"] ?? "0") ?? 0, quiet = Int(fields["q"] ?? "0") ?? 0
    let reply: Data?
    if id == 0 || quiet == 2 || (quiet == 1 && result.isSuccess) { reply = nil }
    else {
      let suffix = fields["p"].map { ",p=\($0)" } ?? ""
      let value: String
      switch result { case .success: value = "OK"; case .failure(let error): value = error.wire }
      reply = Data("\u{1b}_Gi=\(id)\(suffix);\(value)\u{1b}\\".utf8)
    }
    return KittyGraphicsOutcome(reply: reply, advance: (try? result.get()) ?? nil)
  }
  private func featureReply(_ fields: [Character: String]) -> Data? { guard let id = fields["i"], fields["q"] == nil || fields["q"] == "0", let feature = fields["e"] else { return nil }; return Data("\u{1b}_Gi=\(id),e=\(feature);OK\u{1b}\\".utf8) }
}

private extension Result where Success == (Int, Int)?, Failure == KittyGraphicsError { var isSuccess: Bool { if case .success = self { return true }; return false } }
private extension Array { func chunks(ofCount size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min(count, $0 + size)]) } } }

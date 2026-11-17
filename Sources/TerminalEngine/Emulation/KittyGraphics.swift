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
  /// The ids of the rows on screen, top to bottom, for commands that name
  /// a cell.
  var screenRows: [UInt64] = []
  var rowPositions: [UInt64: Int] = [:]
  var virtualOrigins: [UInt64: KittyPlacementOrigin] = [:]
}

struct KittyPlacementOrigin {
  var row: Int
  var column: Int
}

struct GraphicsReflowAnchor {
  let serial: UInt64
  let row: UInt64
  let column: Int
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
  /// The size the picture is drawn at, in pixels, when it is not to be
  /// fitted to its cells: a slice of an image behind Unicode placeholders.
  var extent: [Int]? = nil
}

struct KittyGraphicsOutcome {
  var reply: Data?
  var advance: (Int, Int)?
}

enum KittyGraphicsError: Error, Equatable {
  case invalid, unsupported, tooLarge, noSpace, notFound, noParent, tooDeep, cycle
  var wire: String {
    switch self {
    case .noParent: return "ENOPARENT:parent placement not found"
    case .tooDeep: return "ETOODEEP:too many levels of relative placement"
    case .cycle: return "ECYCLE:relative placement would form a cycle"
    case .invalid: return "EINVAL:invalid graphics command or image data"
    case .unsupported: return "ENOTSUP:unsupported graphics feature or transport"
    case .tooLarge: return "E2BIG:image exceeds configured limits"
    case .noSpace: return "ENOSPC:image storage budget exhausted"
    case .notFound: return "ENOENT:image not found"
    }
  }
}

final class KittyGraphicsStore {
  // Current kitten uses 128 KiB chunks; older clients use 4 KiB. Keep both
  // the parser envelope and decoded upload bounded independently.
  static let maximumChunkBytes = 128 * 1024
  static let maximumPacketBytes = maximumChunkBytes + 4096
  static let maximumImageBytes = 16 * 1024 * 1024
  static let maximumStorageBytes = 64 * 1024 * 1024
  private static let maximumImageDimension = 4096
  private static let maximumImages = 64
  private static let maximumPlacements = 256
  private static let pngCRCTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
    return crc
  }

  private struct Image {
    let id: UInt32
    var generation: UInt64
    let created: UInt64
    let alternate: Bool
    let width: Int
    let height: Int
    var rgba: Data
    var indexed: Data? = nil
    var indexedAlpha = false
    /// The number a program gave it with `I`, or 0.
    var number: UInt32 = 0
    /// Frames after the first, which is `rgba`.
    var frames: [Frame] = []
    var animation = Animation()
    var totalBytes: Int { rgba.count + (indexed?.count ?? 0) + frames.reduce(0) { $0 + $1.rgba.count } }
    var frameCount: Int { 1 + frames.count }
    func pixels(ofFrame index: Int) -> Data { index == 0 ? rgba : frames[index - 1].rgba }
    func generation(ofFrame index: Int) -> UInt64 { index == 0 ? generation : frames[index - 1].generation }
    /// How long a frame is shown, in milliseconds; zero for one skipped.
    func gap(ofFrame index: Int) -> UInt64 {
      let value = index == 0 ? animation.firstGap : frames[index - 1].gap
      return value < 0 ? 0 : value == 0 ? (index == 0 ? 0 : 40) : UInt64(value)
    }
  }
  private struct Frame {
    var rgba: Data
    let generation: UInt64
    var gap: Int
  }
  /// How an image's frames play. `state` is 1 stopped, 2 running until the
  /// last frame and waiting there for more, 3 running in loops.
  private struct Animation {
    var state = 1
    var current = 0
    /// When `current` began to show, in the emulator's milliseconds.
    var since: UInt64 = 0
    var firstGap = 0
    /// 0 loops for ever; otherwise how many times the frames play.
    var loops = 0
    var loopsDone = 0
  }
  private struct Placement {
    let image: UInt32
    let id: UInt32
    let serial: UInt64
    var alternate: Bool
    var row: UInt64
    var column: Int
    var source: [Int]
    var cells: [Int]
    let offset: [Int]
    let natural: Bool
    let z: Int
    /// Shown only where the screen holds Unicode placeholders for it.
    var virtual = false
    /// For a placement relative to another (P and Q): that placement's
    /// image and id, and the offset from its top left corner in cells.
    var parentImage: UInt32 = 0
    var parentID: UInt32 = 0
    var parentOffset = [0, 0]
    var isRelative: Bool { parentImage != 0 }
  }
  private struct Upload {
    var fields: [Character: String]
    var bytes: Data
    let started: UInt64
    var lastChunk: UInt64
  }

  private var images: [UInt32: Image] = [:]
  /// The emulator's clock, in milliseconds, as of the last tick.
  private var now: UInt64 = 0
  private static let maximumFrames = 1000
  private var placements: [Placement] = []
  private var pending: Upload?
  var asynchronousTransport = false
  private var external: (upload: Upload, context: KittyGraphicsContext, read: KittyTransport.Read)?
  private let transportReader: ([Character: String], Data, Int) throws -> Data
  init(transportReader: @escaping ([Character: String], Data, Int) throws -> Data = { try KittyTransport.read($0, payload: $1, limit: $2) }) {
    self.transportReader = transportReader
  }
  var transportPending: Bool { external != nil }
  func whenTransportReady(_ callback: @escaping () -> Void) { external?.read.whenReady(callback) }
  func completeTransport() -> KittyGraphicsOutcome? {
    guard let operation = external, let result = operation.read.take() else { return nil }
    external = nil
    switch result {
    case .failure(let error): return outcome(fields: operation.upload.fields, result: .failure(error))
    case .success(let data):
      resolvedID = 0
      let finished = finish(operation.upload, context: operation.context, transported: data)
      var fields = operation.upload.fields
      if fields["I"] != nil, resolvedID != 0 { fields["i"] = String(resolvedID) }
      return outcome(fields: fields, result: finished)
    }
  }
  private var serial: UInt64 = 0
  private var bytes = 0
  private var indexedColors = [[Int]](repeating: [0, 0, 0], count: 256)

  /// Palette-linked images own their samples as well as the current RGBA.
  /// A new generation retires cached textures without changing placement IDs.
  func setPalette(_ colors: [[Int]]) {
    guard colors.count == 256, colors.allSatisfy({ $0.count == 3 && $0.allSatisfy({ (0...255).contains($0) }) }),
      colors != indexedColors else { return }
    indexedColors = colors
    for id in Array(images.keys) {
      guard var image = images[id], let samples = image.indexed, serial < UInt64.max else { continue }
      serial += 1
      image.rgba = indexedRGBA(samples, alpha: image.indexedAlpha)
      image.generation = serial
      images[id] = image
    }
  }

  private func indexedRGBA(_ samples: Data, alpha: Bool) -> Data {
    var rgba = Data(capacity: samples.count / (alpha ? 2 : 1) * 4)
    let data = [UInt8](samples)
    for offset in stride(from: 0, to: data.count, by: alpha ? 2 : 1) {
      let color = indexedColors[Int(data[offset])]
      rgba.append(contentsOf: [UInt8(color[0]), UInt8(color[1]), UInt8(color[2]), alpha ? data[offset + 1] : 255])
    }
    return rgba
  }

  var accountedBytes: Int { bytes + (pending?.bytes.count ?? 0) + (external?.upload.bytes.count ?? 0) }
  var hasPlacements: Bool { !placements.isEmpty }
  var hasVirtualPlacements: Bool { placements.contains { $0.virtual } }
  var hasRelativePlacements: Bool { placements.contains { $0.isRelative } }
  var hasVirtualParents: Bool { placements.contains { $0.isRelative && parent(of: $0)?.virtual == true } }
  var anchorRows: Set<UInt64> { Set(placements.filter { !$0.virtual && !$0.isRelative }.map(\.row)) }
  var virtualPlacementIdentities: [UInt64] { placements.filter(\.virtual).map(\.serial) }
  var reflowAnchors: [GraphicsReflowAnchor] {
    placements.filter { !$0.alternate && !$0.virtual && !$0.isRelative }
      .map { GraphicsReflowAnchor(serial: $0.serial, row: $0.row, column: $0.column) }
  }
  func applyReflow(_ anchors: [UInt64: GraphicsReflowAnchor]) {
    for index in placements.indices {
      guard let anchor = anchors[placements[index].serial] else { continue }
      placements[index].row = anchor.row; placements[index].column = anchor.column
    }
  }
  /// Rectangle scrolling moves only placements wholly inside the page. Text
  /// rows retain identity here, so image anchors must move explicitly. Clip
  /// the source and destination together when an edge leaves the page.
  func scrollRectangle(alternate: Bool, rows: [UInt64], top: Int, bottom: Int,
                       left: Int, right: Int, amount: Int, up: Bool) {
    let positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element, $0.offset) })
    var removed = Set<UInt64>()
    for index in placements.indices {
      let p = placements[index]
      guard !p.virtual, !p.isRelative, p.alternate == alternate, let row = positions[p.row],
        row >= top, row + p.cells[1] <= bottom + 1,
        p.column >= left, p.column + p.cells[0] <= right + 1 else { continue }
      let target = row + (up ? -amount : amount)
      let start = max(top, target), end = min(bottom + 1, target + p.cells[1])
      guard end > start else { removed.insert(p.serial); continue }
      let sourceStart = p.source[1] + (start - target) * p.source[3] / p.cells[1]
      let sourceEnd = p.source[1] + (end - target) * p.source[3] / p.cells[1]
      placements[index].row = rows[start]
      placements[index].cells[1] = end - start
      placements[index].source[1] = sourceStart
      placements[index].source[3] = max(1, sourceEnd - sourceStart)
    }
    placements.removeAll { removed.contains($0.serial) }
    pruneOrphans()
  }
  func imageRGBA(id: UInt32, generation: UInt64) -> Data? {
    guard let image = images[id] else { return nil }
    if image.generation == generation { return image.rgba }
    return image.frames.first { $0.generation == generation }?.rgba
  }
  func abort() { pending = nil; external?.read.cancel(); external = nil }
  func tick(now: UInt64) {
    self.now = now
    guard let upload = pending else { return }
    if now > upload.lastChunk && now - upload.lastChunk > 10_000 || now > upload.started && now - upload.started > 60_000 { pending = nil }
  }
  func clear() { abort(); images.removeAll(); placements.removeAll(); bytes = 0 }
  func clear(alternate: Bool, removeResources: Bool = false) {
    placements.removeAll { $0.alternate == alternate }
    if removeResources {
      let live = Set(placements.map(\.image))
      images = images.filter { $0.value.alternate != alternate || live.contains($0.key) }
      bytes = images.values.reduce(0) { $0 + $1.totalBytes }
      pending = nil
    }
  }
  func pruneAnchors(retaining rows: Set<UInt64>) {
    pruneAnchors(isRetained: { rows.contains($0) })
  }
  func pruneAnchors(isRetained: (UInt64) -> Bool) {
    // A relative placement goes with its parent, not with a row of its own.
    placements.removeAll { !$0.virtual && !$0.isRelative && !isRetained($0.row) }
    pruneOrphans()
  }
  /// The placement a relative one hangs from.
  private func parent(of placement: Placement) -> Placement? {
    placements.first { $0.image == placement.parentImage && $0.id == placement.parentID }
  }
  /// A placement's top left cell: its own anchor, or its parent's plus its
  /// offset. Nil when it hangs from nothing on this screen.
  private func origin(of placement: Placement, positions: [UInt64: Int],
                      virtualOrigins: [UInt64: KittyPlacementOrigin], alternate: Bool, depth: Int = 0) -> KittyPlacementOrigin? {
    guard placement.isRelative else {
      if placement.virtual { return virtualOrigins[placement.serial] }
      guard placement.alternate == alternate, let row = positions[placement.row] else { return nil }
      return KittyPlacementOrigin(row: row, column: placement.column)
    }
    guard depth < Self.maximumRelativeDepth, let parent = parent(of: placement),
      let base = origin(of: parent, positions: positions, virtualOrigins: virtualOrigins, alternate: alternate, depth: depth + 1) else { return nil }
    return KittyPlacementOrigin(row: base.row + placement.parentOffset[1], column: base.column + placement.parentOffset[0])
  }
  private static let maximumRelativeDepth = 8
  /// Removes relative placements whose parent is gone, and theirs in turn.
  private func pruneOrphans() {
    while let index = placements.firstIndex(where: { $0.isRelative && parent(of: $0) == nil }) {
      let orphan = placements.remove(at: index)
      if !placements.contains(where: { $0.image == orphan.image }), let image = images.removeValue(forKey: orphan.image) {
        bytes -= image.totalBytes
      }
    }
  }

  func visible(alternate: Bool, positions: [UInt64: Int], height: Int,
               virtualOrigins: [UInt64: KittyPlacementOrigin] = [:]) -> [KittyImagePlacement] {
    placements.compactMap { placement in
      guard !placement.virtual, let image = images[placement.image],
            let anchor = origin(of: placement, positions: positions, virtualOrigins: virtualOrigins, alternate: alternate),
            anchor.row < height, anchor.row + placement.cells[1] > 0 else { return nil }
      return KittyImagePlacement(image: placement.image, generation: image.generation(ofFrame: shownFrame(image.id)), width: image.width,
        height: image.height, source: placement.source, row: anchor.row, column: anchor.column,
        columns: placement.cells[0], rows: placement.cells[1], offset: placement.offset,
        natural: placement.natural, z: placement.z, placement: placement.serial)
    }.sorted { ($0.z, $0.image, $0.placement) < ($1.z, $1.image, $1.placement) }
  }

  /// Resolve a placeholder to its virtual placement, independently of whether
  /// its image pixels intersect this cell (transparent/letterboxed cells still anchor children).
  func placeholderOrigin(_ cell: KittyPlaceholder.Cell, screenRow: Int, screenColumn: Int)
    -> (serial: UInt64, origin: KittyPlacementOrigin)? {
    guard let placement = placements.last(where: {
      $0.virtual && $0.image == cell.image && (cell.placement == 0 || $0.id == cell.placement)
    }), let row = cell.row, let column = cell.column,
      row < placement.cells[1], column < placement.cells[0] else { return nil }
    return (placement.serial, KittyPlacementOrigin(row: screenRow - row, column: screenColumn - column))
  }

  /// Shows a picture another protocol decoded (Sixel, an iTerm2 inline
  /// image) at the cursor, over `columns` by `rows` cells; zero for both
  /// means its natural size. It becomes an image like any other here, so
  /// the storage budget, scrolling and erasing treat it the same. Returns
  /// the cells it covers, or nil when there is no room for it.
  func show(width: Int, height: Int, rgba: Data, columns: Int, rows: Int,
            context: KittyGraphicsContext, animation: [InlineImageDecoder.Frame] = []) -> (columns: Int, rows: Int)? {
    guard width > 0, height > 0, width <= Self.maximumImageDimension, height <= Self.maximumImageDimension,
      rgba.count == width * height * 4, rgba.count <= Self.maximumImageBytes, serial < UInt64.max - UInt64(max(2, animation.count + 1)),
      let id = (1...Int(UInt32.max)).reversed().first(where: { images[UInt32($0)] == nil })
    else { return nil }
    let generation = serial + 1
    var image = Image(id: UInt32(id), generation: generation, created: generation, alternate: context.alternate,
      width: width, height: height, rgba: rgba)
    if animation.count > 1 {
      guard animation.count <= Self.maximumFrames,
        animation.count <= Self.maximumImageBytes / rgba.count,
        animation.allSatisfy({ $0.rgba.count == rgba.count }) else { return nil }
      image.animation = Animation(state: 3, current: 0, since: now, firstGap: animation[0].milliseconds)
      image.frames = animation.dropFirst().enumerated().map { offset, frame in
        Frame(rgba: frame.rgba, generation: generation + UInt64(offset + 1), gap: frame.milliseconds)
      }
    }
    var fields: [Character: String] = [:]
    if columns > 0 { fields["c"] = String(columns) }
    if rows > 0 { fields["r"] = String(rows) }
    guard (try? makeRoom(replacing: image.id, size: image.totalBytes)) != nil,
      let (placement, _) = try? layout(fields, image: image, context: context, serial: generation + 1),
      placements.count < Self.maximumPlacements
    else { return nil }
    serial = generation + UInt64(max(1, animation.count))
    images[image.id] = image; bytes += image.totalBytes
    placements.append(placement)
    return (placement.cells[0], placement.cells[1])
  }

  /// The slice of an image that a run of placeholder cells shows: cells
  /// `column`..<`column + count` of the placement's row `row`, drawn at
  /// screen row `screenRow` from screen column `screenColumn`. The image is
  /// fitted into the placement's cells, keeping its shape, and centered.
  func placeholderSlice(_ cell: KittyPlaceholder.Cell, row: Int, column: Int, count: Int,
                        screenRow: Int, screenColumn: Int, alternate: Bool,
                        cellWidth: Int, cellHeight: Int) -> KittyImagePlacement? {
    guard let image = images[cell.image], let placement = placements.last(where: {
      $0.virtual && $0.image == cell.image && (cell.placement == 0 || $0.id == cell.placement)
    }) else { return nil }
    let cw = Double(max(1, cellWidth)), ch = Double(max(1, cellHeight))
    let source = placement.source
    let boxWidth = Double(placement.cells[0]) * cw, boxHeight = Double(placement.cells[1]) * ch
    let scale = min(boxWidth / Double(source[2]), boxHeight / Double(source[3]))
    let drawnX = (boxWidth - Double(source[2]) * scale) / 2, drawnY = (boxHeight - Double(source[3]) * scale) / 2
    // The part of the drawn image inside these cells, in box pixels.
    let left = max(Double(column) * cw, drawnX), right = min(Double(column + count) * cw, drawnX + Double(source[2]) * scale)
    let top = max(Double(row) * ch, drawnY), bottom = min(Double(row + 1) * ch, drawnY + Double(source[3]) * scale)
    guard right > left, bottom > top else { return nil }
    // Whole image pixels, so neighbouring slices meet without a seam: each
    // takes every pixel it touches, and they overlap by less than one.
    let x0 = max(0, Int(((left - drawnX) / scale).rounded(.down)))
    let x1 = min(source[2], Int(((right - drawnX) / scale).rounded(.up)))
    let y0 = max(0, Int(((top - drawnY) / scale).rounded(.down)))
    let y1 = min(source[3], Int(((bottom - drawnY) / scale).rounded(.up)))
    guard x1 > x0, y1 > y0 else { return nil }
    let destinationX = drawnX + Double(x0) * scale, destinationY = drawnY + Double(y0) * scale
    let width = Int((Double(x1 - x0) * scale).rounded()), height = Int((Double(y1 - y0) * scale).rounded())
    guard width > 0, height > 0 else { return nil }
    return KittyImagePlacement(
      image: image.id, generation: image.generation(ofFrame: shownFrame(image.id)), width: image.width, height: image.height,
      source: [source[0] + x0, source[1] + y0, x1 - x0, y1 - y0],
      row: screenRow, column: screenColumn, columns: count, rows: 1,
      offset: [Int((destinationX - Double(column) * cw).rounded()), Int((destinationY - Double(row) * ch).rounded())],
      natural: false, z: placement.z, placement: placement.serial, extent: [width, height])
  }

  /// The newest image a program numbered `number`.
  private func image(numbered number: UInt32) -> Image? {
    images.values.filter { $0.number == number }.max { $0.created < $1.created }
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
    let featureQuery = action == "q" && incoming["e"] != nil
    if incoming["i"] != nil && incoming["I"] != nil {
      if !featureQuery { abort() }
      return outcome(fields: incoming, result: .failure(.invalid))
    }
    if featureQuery { return KittyGraphicsOutcome(reply: featureReply(incoming), advance: nil) }
    let continuation = pending.map { upload in
      incoming.keys.allSatisfy { $0 == "m" || $0 == "q" || ($0 == "a" && action == (upload.fields["a"] ?? "t")) }
    } ?? false
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
        let numbered = UInt32((try? number(incoming, "I", default: 0)) ?? 0)
        guard let image = numbered != 0 ? self.image(numbered: numbered) : images[id] else {
          return outcome(fields: incoming, result: .failure(.notFound))
        }
        var fields = incoming
        if numbered != 0 { fields["i"] = String(image.id) }
        return outcome(fields: fields, result: place(fields, image: image, context: context))
      }
      if action == "a" || action == "c" {
        var fields = incoming
        let result = target(&fields).flatMap { id in action == "a" ? control(id, incoming) : compose(id, incoming) }
        return outcome(fields: fields, result: result)
      }
      guard ["t", "T", "q", "f"].contains(action) else { return outcome(fields: incoming, result: .failure(.unsupported)) }
      upload = Upload(fields: incoming, bytes: Data(), started: now, lastChunk: now)
    }
    let more: Bool
    do {
      let continuation = try number(incoming, "m", default: 0)
      guard continuation <= 1 else { throw KittyGraphicsError.invalid }
      more = continuation == 1
      try validateTransport(upload.fields)
      // Each chunk is decoded on its own, as kitty does, so a padded chunk
      // may be followed by more: chafa pads its last data chunk and closes
      // the transmission with an empty m=0 chunk.
      if payload.count > Self.maximumChunkBytes { throw KittyGraphicsError.invalid }
      var encoded = payload
      // RawStdEncoding omits trailing padding. Still reject partial padding,
      // non-zero unused bits and non-alphabet bytes using canonical re-encode.
      if encoded.count % 4 != 0 && !encoded.contains(UInt8(ascii: "=")) {
        encoded.append(contentsOf: repeatElement(UInt8(ascii: "="), count: 4 - encoded.count % 4))
      }
      guard let decoded = Data(base64Encoded: encoded, options: []), decoded.base64EncodedData() == encoded else { throw KittyGraphicsError.invalid }
      guard upload.bytes.count + decoded.count <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
      upload.bytes.append(decoded)
      upload.lastChunk = now
    } catch let error as KittyGraphicsError { return outcome(fields: upload.fields, result: .failure(error)) }
      catch { return outcome(fields: upload.fields, result: .failure(.invalid)) }
    if more { pending = upload; return KittyGraphicsOutcome() }
    resolvedID = 0
    if asynchronousTransport, (upload.fields["t"] ?? "d") != "d" {
      let fields = upload.fields, payload = upload.bytes
      let reader = transportReader
      external = (upload, context, KittyTransport.Read(fields: fields, payload: payload, limit: Self.maximumImageBytes) {
        try reader(fields, payload, Self.maximumImageBytes)
      })
      return KittyGraphicsOutcome()
    }
    let result = finish(upload, context: context)
    var fields = upload.fields
    if fields["I"] != nil, resolvedID != 0 { fields["i"] = String(resolvedID) }
    return outcome(fields: fields, result: result)
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
    if values["I"] != nil && values["i"] != nil { throw KittyGraphicsError.invalid }
    guard try number(values, "U", default: 0) <= 1 else { throw KittyGraphicsError.invalid }
    let type = values["t"] ?? "d"
    guard ["d", "f", "t", "s"].contains(type) else { throw KittyGraphicsError.unsupported }
    // A file, a temporary file or shared memory is named in one chunk.
    if type != "d", try number(values, "m", default: 0) != 0 { throw KittyGraphicsError.invalid }
    if let compression = values["o"], compression != "z" { throw KittyGraphicsError.unsupported }
    let format = try number(values, "f", default: 32)
    guard [8, 16, 24, 32, 100].contains(format) else { throw KittyGraphicsError.unsupported }
    if [8, 16].contains(format), values["a"] == "f" { throw KittyGraphicsError.unsupported }
    guard try number(values, "q", default: 0) <= 2 else { throw KittyGraphicsError.invalid }
    if format != 100 {
      let width = try number(values, "s", default: 0), height = try number(values, "v", default: 0)
      guard width > 0, height > 0, width <= Self.maximumImageDimension, height <= Self.maximumImageDimension else { throw KittyGraphicsError.tooLarge }
      guard width * height * 4 <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
    }
  }
  /// The id `finish` gave an image the program numbered, for the reply.
  private var resolvedID: UInt32 = 0
  private func finish(_ upload: Upload, context: KittyGraphicsContext, transported: Data? = nil) -> Result<(Int, Int)?, KittyGraphicsError> {
    do {
      let data = try transported ?? transportReader(upload.fields, upload.bytes, Self.maximumImageBytes)
      let decoded = try decode(upload.fields, bytes: data)
      if upload.fields["a"] == "q" { return .success(nil) }
      if upload.fields["a"] == "f" {
        var fields = upload.fields
        let result = target(&fields).flatMap { addFrame($0, fields: upload.fields, decoded: decoded) }
        if let id = fields["i"].flatMap(UInt32.init) { resolvedID = id }
        return result
      }
      var id = (try? number(upload.fields, "i", default: 0)) ?? 0
      let numbered = UInt32((try? number(upload.fields, "I", default: 0)) ?? 0)
      if id == 0 {
        guard let available = (1...Int(UInt32.max)).reversed().first(where: { images[UInt32($0)] == nil }) else { throw KittyGraphicsError.noSpace }
        id = available
      }
      guard serial < UInt64.max else { throw KittyGraphicsError.noSpace }
      let generation = serial + 1
      var image = Image(id: UInt32(id), generation: generation, created: generation, alternate: context.alternate, width: decoded.width,
        height: decoded.height, rgba: decoded.rgba, number: numbered)
      if let format = upload.fields["f"], format == "8" || format == "16" {
        image.indexedAlpha = format == "16"
        image.indexed = upload.fields["o"] == "z" ? try inflate(data, limit: decoded.width * decoded.height * (image.indexedAlpha ? 2 : 1)) : data
      }
      resolvedID = UInt32(id)
      if upload.fields["a"] == "T" { _ = try layout(upload.fields, image: image, context: context, serial: generation) }
      try makeRoom(replacing: UInt32(id), size: image.totalBytes)
      serial = generation
      if let old = images[UInt32(id)] { bytes -= old.totalBytes }
      images[UInt32(id)] = image; bytes += image.totalBytes
      placements.removeAll { $0.image == UInt32(id) }
      pruneOrphans()
      return upload.fields["a"] == "T" ? place(upload.fields, image: image, context: context) : .success(nil)
    } catch let error as KittyGraphicsError { return .failure(error) }
      catch { return .failure(.invalid) }
  }
  /// The image a frame or animation command is about, by `i` or `I`. A
  /// number is turned into its id in `fields`, for the reply.
  private func target(_ fields: inout [Character: String]) -> Result<UInt32, KittyGraphicsError> {
    let id = UInt32((try? number(fields, "i", default: 0)) ?? 0)
    let numbered = UInt32((try? number(fields, "I", default: 0)) ?? 0)
    if numbered != 0 {
      guard let image = image(numbered: numbered) else { return .failure(.notFound) }
      fields["i"] = String(image.id)
      return .success(image.id)
    }
    return images[id] == nil ? .failure(.notFound) : .success(id)
  }

  /// RGBA pixel helpers on a frame of the image's size.
  private static func blend(_ canvas: inout Data, width: Int, height: Int, pixels: Data, pixelWidth: Int,
                            pixelHeight: Int, at x: Int, _ y: Int, replace: Bool) {
    canvas.withUnsafeMutableBytes { target in
      pixels.withUnsafeBytes { source in
        let out = target.bindMemory(to: UInt8.self), input = source.bindMemory(to: UInt8.self)
        for row in 0..<pixelHeight where y + row >= 0 && y + row < height {
          for column in 0..<pixelWidth where x + column >= 0 && x + column < width {
            let from = (row * pixelWidth + column) * 4
            let to = ((y + row) * width + x + column) * 4
            guard from + 3 < input.count else { continue }
            let alpha = Int(input[from + 3])
            if replace || alpha == 255 {
              for channel in 0..<4 { out[to + channel] = input[from + channel] }
            } else if alpha > 0 {
              // Straight alpha over straight alpha.
              let below = Int(out[to + 3]), outAlpha = alpha + below * (255 - alpha) / 255
              for channel in 0..<3 {
                let value = (Int(input[from + channel]) * alpha + Int(out[to + channel]) * below * (255 - alpha) / 255)
                out[to + channel] = UInt8(outAlpha == 0 ? 0 : min(255, value / outAlpha))
              }
              out[to + 3] = UInt8(min(255, outAlpha))
            }
          }
        }
      }
    }
  }

  /// `a=f`: a new frame (or, with `r`, an existing one edited) made from a
  /// base frame `c` (or the background color `Y`) with the data put at
  /// `x`,`y`, blended unless `X=1`. `z` is how long it shows.
  private func addFrame(_ id: UInt32, fields: [Character: String], decoded: (width: Int, height: Int, rgba: Data))
    -> Result<(Int, Int)?, KittyGraphicsError> {
    guard var image = images[id] else { return .failure(.notFound) }
    guard image.indexed == nil else { return .failure(.unsupported) }
    guard let edit = try? number(fields, "r", default: 0), let base = try? number(fields, "c", default: 0),
      let x = try? number(fields, "x", default: 0), let y = try? number(fields, "y", default: 0),
      let replace = try? number(fields, "X", default: 0), let background = UInt32(fields["Y"] ?? "0"),
      let gap = Int32(fields["z"] ?? "0") else { return .failure(.invalid) }
    guard edit <= image.frameCount, base <= image.frameCount else { return .failure(.notFound) }
    image.animation = playback(image).animation
    var canvas: Data
    if edit > 0 { canvas = image.pixels(ofFrame: edit - 1) }
    else if base > 0 { canvas = image.pixels(ofFrame: base - 1) }
    else {
      let color: [UInt8] = [UInt8(background >> 24), UInt8(background >> 16 & 255), UInt8(background >> 8 & 255), UInt8(background & 255)]
      canvas = Data((0..<(image.width * image.height)).flatMap { _ in color })
    }
    Self.blend(&canvas, width: image.width, height: image.height, pixels: decoded.rgba, pixelWidth: decoded.width,
               pixelHeight: decoded.height, at: x, y, replace: replace == 1)
    guard serial < UInt64.max else { return .failure(.noSpace) }
    if edit > 0 {
      if edit == 1 {
        let old = image.rgba.count
        if gap != 0 { image.animation.firstGap = Int(gap) }
        image = Image(id: image.id, generation: serial + 1, created: image.created, alternate: image.alternate, width: image.width,
          height: image.height, rgba: canvas, number: image.number, frames: image.frames, animation: image.animation)
        bytes += canvas.count - old
      } else {
        image.frames[edit - 2] = Frame(rgba: canvas, generation: serial + 1, gap: gap == 0 ? image.frames[edit - 2].gap : Int(gap))
      }
      serial += 1
    } else {
      guard image.frameCount < Self.maximumFrames else { return .failure(.noSpace) }
      // Room for one more frame; the image itself is never evicted for it.
      do { try makeRoom(replacing: id, size: image.totalBytes + canvas.count) } catch { return .failure(.noSpace) }
      serial += 1
      image.frames.append(Frame(rgba: canvas, generation: serial, gap: Int(gap)))
      bytes += canvas.count
    }
    images[id] = image
    return .success(nil)
  }

  /// `a=a`: `s` sets the state, `c` the frame shown, `r` with `z` one
  /// frame's gap, and `v` the number of loops.
  private func control(_ id: UInt32, _ fields: [Character: String]) -> Result<(Int, Int)?, KittyGraphicsError> {
    guard var image = images[id] else { return .failure(.notFound) }
    guard image.indexed == nil else { return .failure(.unsupported) }
    guard let state = try? number(fields, "s", default: 0), state <= 3,
      let current = try? number(fields, "c", default: 0), current <= image.frameCount,
      let frame = try? number(fields, "r", default: 0), frame <= image.frameCount,
      let loops = try? number(fields, "v", default: 0), let gap = Int32(fields["z"] ?? "0")
    else { return .failure(.invalid) }
    // The frame playing now becomes the starting point for what follows.
    image.animation = playback(image).animation
    if frame > 0, gap != 0 {
      if frame == 1 { image.animation.firstGap = Int(gap) } else { image.frames[frame - 2].gap = Int(gap) }
    }
    if current > 0, image.animation.current != current - 1 {
      image.animation.current = current - 1
      image.animation.since = now
    }
    if loops > 0 { image.animation.loops = loops == 1 ? 0 : loops - 1; image.animation.loopsDone = 0 }
    if state > 0 {
      if image.animation.state == 1, state != 1 { image.animation.since = now }
      image.animation.state = state
      if state == 1 { image.animation.loopsDone = 0 }
    }
    images[id] = image
    return .success(nil)
  }

  /// `a=c`: copies a `w` by `h` rectangle at `X`,`Y` of frame `r` to `x`,`y`
  /// of frame `c`, blended unless `C=1`.
  private func compose(_ id: UInt32, _ fields: [Character: String]) -> Result<(Int, Int)?, KittyGraphicsError> {
    guard var image = images[id] else { return .failure(.notFound) }
    guard image.indexed == nil else { return .failure(.unsupported) }
    guard let from = try? number(fields, "r", default: 1), let to = try? number(fields, "c", default: 1),
      let x = try? number(fields, "X", default: 0), let y = try? number(fields, "Y", default: 0),
      let targetX = try? number(fields, "x", default: 0), let targetY = try? number(fields, "y", default: 0),
      let width = try? number(fields, "w", default: 0), let height = try? number(fields, "h", default: 0),
      let replace = try? number(fields, "C", default: 0), replace <= 1 else { return .failure(.invalid) }
    guard (1...image.frameCount).contains(from), (1...image.frameCount).contains(to) else { return .failure(.notFound) }
    let w = width == 0 ? image.width : width, h = height == 0 ? image.height : height
    guard x + w <= image.width, y + h <= image.height, targetX + w <= image.width, targetY + h <= image.height,
      w > 0, h > 0, serial < UInt64.max else { return .failure(.invalid) }
    guard from != to || x + w <= targetX || targetX + w <= x || y + h <= targetY || targetY + h <= y
    else { return .failure(.invalid) }
    var canvas = image.pixels(ofFrame: to - 1)
    let source = image.pixels(ofFrame: from - 1)
    // Only the rectangle: rows of the source frame starting at x, y.
    var rectangle = Data(capacity: w * h * 4)
    for row in 0..<h {
      let start = ((y + row) * image.width + x) * 4
      rectangle.append(source[start..<(start + w * 4)])
    }
    Self.blend(&canvas, width: image.width, height: image.height, pixels: rectangle, pixelWidth: w, pixelHeight: h,
               at: targetX, targetY, replace: replace == 1)
    serial += 1
    if to == 1 {
      image = Image(id: image.id, generation: serial, created: image.created, alternate: image.alternate, width: image.width, height: image.height,
        rgba: canvas, number: image.number, frames: image.frames, animation: image.animation)
    } else { image.frames[to - 2] = Frame(rgba: canvas, generation: serial, gap: image.frames[to - 2].gap) }
    images[id] = image
    return .success(nil)
  }

  /// The frame an image shows now, advancing a running animation by the
  /// time since its frame began.
  private func shownFrame(_ id: UInt32) -> Int {
    guard let image = images[id], image.frameCount > 1 else { return 0 }
    return playback(image).animation.current
  }
  /// The frame shown at `now`, and when the next one is due (nil when none is).
  private func playback(_ image: Image) -> (animation: Animation, next: UInt64?) {
    var animation = image.animation
    let count = image.frameCount
    animation.current = min(animation.current, count - 1)
    guard animation.state != 1, count > 1 else { return (animation, nil) }
    let total = (0..<count).reduce(UInt64(0)) { $0 + image.gap(ofFrame: $1) }
    guard total > 0 else { return (animation, nil) }
    // `loops` plays through that many times, so one fewer wrap to the start.
    var loopsLeft = animation.state == 3 && animation.loops > 0 ? max(0, animation.loops - 1 - animation.loopsDone) : -1
    // Whole loops at once, so a long-running animation costs no more to place.
    if animation.state == 3, now >= animation.since {
      let elapsedLoops = (now - animation.since) / total
      let skipped = loopsLeft < 0 ? elapsedLoops : min(elapsedLoops, UInt64(loopsLeft))
      animation.since += skipped * total
      if loopsLeft >= 0 {
        loopsLeft -= Int(skipped)
        animation.loopsDone += Int(skipped)
      }
    }
    // After skipping whole cycles, at most one cycle remains. Gapless frames
    // advance at the same timestamp without producing a zero-delay timer loop.
    for _ in 0...count {
      let gap = image.gap(ofFrame: animation.current)
      if animation.current == count - 1 {
        if animation.state == 2 || loopsLeft == 0 { return (animation, nil) }
      }
      let (due, overflow) = animation.since.addingReportingOverflow(gap)
      guard !overflow else { return (animation, nil) }
      if due > now { return (animation, due) }
      animation.since = due
      if animation.current == count - 1 {
        animation.current = 0
        if loopsLeft > 0 { loopsLeft -= 1; animation.loopsDone += 1 }
      } else { animation.current += 1 }
    }
    return (animation, nil)
  }
  /// The earliest time an animation on screen changes frame.
  func nextFrameTime(alternate: Bool) -> UInt64? {
    let shown = Set(placements.filter { $0.virtual || $0.alternate == alternate }.map(\.image))
    return shown.compactMap { id in images[id].flatMap { $0.frameCount > 1 ? playback($0).next : nil } }.min()
  }

  private func decode(_ values: [Character: String], bytes: Data) throws -> (width: Int, height: Int, rgba: Data) {
    let format = try number(values, "f", default: 32)
    if format == 100 {
      let payload = values["o"] == "z" ? try inflate(bytes, limit: Self.maximumImageBytes) : bytes
      return try png(payload)
    }
    let width = try number(values, "s", default: 0), height = try number(values, "v", default: 0)
    let expected = width * height * (format == 8 ? 1 : format == 16 ? 2 : format == 24 ? 3 : 4)
    guard expected > 0, expected <= Self.maximumImageBytes else { throw KittyGraphicsError.tooLarge }
    let payload = values["o"] == "z" ? try inflate(bytes, limit: expected) : bytes
    guard expected == payload.count else { throw KittyGraphicsError.invalid }
    if format == 8 || format == 16 { return (width, height, indexedRGBA(payload, alpha: format == 16)) }
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
    // current macOS. Kitty supplies RFC1950 (zlib) framing,
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
      let kind = bytes[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      if kind == 0x74524e53 { // tRNS
        guard transparency == nil else { throw KittyGraphicsError.invalid }
        transparency = Array(bytes[(offset + 8)..<(end - 4)])
      } else if ![0x69434350, 0x74455874, 0x7a545874, 0x69545874].contains(kind) {
        // Match the oracle's ignored iCCP/text metadata. In particular, never
        // ask ImageIO to inflate a profile or compressed text outside the
        // bounded pixel decoding operation.
        decodedInput.append(bytes[offset..<end])
      }
      offset = end
    }
    guard let source = CGImageSourceCreateWithData(decodedInput as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
          let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { throw KittyGraphicsError.invalid }
    guard width > 0, height > 0, width <= Self.maximumImageDimension, height <= Self.maximumImageDimension,
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
    let virtual = try number(values, "U", default: 0) == 1
    var placement = Placement(image: image.id, id: UInt32(id), serial: serial, alternate: context.alternate,
      row: context.row, column: context.column, source: [x, y, width, height], cells: [c, r], offset: [ox, oy], natural: natural, z: Int(z),
      virtual: virtual)
    let parentImage = try number(values, "P", default: 0), parentID = try number(values, "Q", default: 0)
    if parentImage != 0 || parentID != 0 {
      // Relative to another placement, H and V cells from its top left.
      guard parentImage != 0, parentID != 0, !virtual,
        let h = Int32(values["H"] ?? "0"), let v = Int32(values["V"] ?? "0"),
        abs(Int(h)) <= 4096, abs(Int(v)) <= 4096 else { throw KittyGraphicsError.invalid }
      guard let found = placements.first(where: { $0.image == UInt32(parentImage) && $0.id == UInt32(parentID) }) else {
        throw KittyGraphicsError.noParent
      }
      if parentImage == Int(image.id) && parentID == id { throw KittyGraphicsError.cycle }
      var ancestor: Placement? = found, depth = 1
      while let current = ancestor, current.isRelative {
        if current.parentImage == image.id && current.parentID == UInt32(id) { throw KittyGraphicsError.cycle }
        depth += 1
        guard depth < Self.maximumRelativeDepth else { throw KittyGraphicsError.tooDeep }
        ancestor = parent(of: current)
      }
      placement.parentImage = UInt32(parentImage); placement.parentID = UInt32(parentID)
      placement.parentOffset = [Int(h), Int(v)]
      placement.alternate = found.alternate
      return (placement, nil)
    }
    return (placement, movement == 0 && !virtual ? (c, r) : nil)
  }
  private func place(_ values: [Character: String], image: Image, context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    do {
      guard serial < UInt64.max else { throw KittyGraphicsError.noSpace }
      let nextSerial = serial + 1
      let (placement, advance) = try layout(values, image: image, context: context, serial: nextSerial)
      if placement.id != 0 { placements.removeAll { $0.image == placement.image && $0.id == placement.id } }
      guard placements.count < Self.maximumPlacements else { throw KittyGraphicsError.noSpace }
      serial = nextSerial; placements.append(placement); pruneOrphans(); return .success(advance)
    } catch let error as KittyGraphicsError { return .failure(error) }
      catch { return .failure(.invalid) }
  }
  private func delete(_ values: [Character: String], context: KittyGraphicsContext) -> Result<(Int, Int)?, KittyGraphicsError> {
    let selector = values["d"] ?? "a"
    guard selector.count == 1, let kind = selector.first, "aAiInNcCpPqQrRxXyYzZfF".contains(kind) else { return .failure(.unsupported) }
    if kind == "f" || kind == "F" { return deleteFrame(values, freeLast: kind == "F") }
    guard let rawImage = try? number(values, "i", default: 0), let rawPlacement = try? number(values, "p", default: 0),
      let x = try? number(values, "x", default: 0), let y = try? number(values, "y", default: 0),
      let rawNumber = try? number(values, "I", default: 0), let z = Int32(values["z"] ?? "0")
    else { return .failure(.invalid) }
    let placement = UInt32(rawPlacement)
    var image = UInt32(rawImage)
    if kind == "n" || kind == "N" {
      guard let numbered = self.image(numbered: UInt32(rawNumber)) else { return .success(nil) }
      image = numbered.id
    }
    let positions = context.rowPositions.isEmpty
      ? Dictionary(uniqueKeysWithValues: context.screenRows.enumerated().map { ($0.element, $0.offset) })
      : context.rowPositions
    func covers(_ old: Placement, column: Int?, row: Int?) -> Bool {
      guard !old.virtual,
        let anchor = origin(of: old, positions: positions, virtualOrigins: context.virtualOrigins, alternate: context.alternate),
        anchor.row < context.screenRows.count, anchor.row + old.cells[1] > 0 else { return false }
      if let column, !(anchor.column..<(anchor.column + old.cells[0])).contains(column) { return false }
      if let row, !(anchor.row..<(anchor.row + old.cells[1])).contains(row) { return false }
      return true
    }
    let cursorRow = context.screenRows.firstIndex(of: context.row)
    var touched = Set<UInt32>()
    // Resolve every origin before mutating the parent graph.
    let removed = Set(placements.filter { old in
      let matches: Bool
      switch kind {
      case "i", "I", "n", "N": matches = old.image == image && (placement == 0 || old.id == placement)
      case "r", "R": matches = x <= Int(old.image) && Int(old.image) <= y
      case "c", "C": matches = cursorRow != nil && covers(old, column: context.column, row: cursorRow)
      case "p", "P": matches = x > 0 && y > 0 && covers(old, column: x - 1, row: y - 1)
      case "q", "Q": matches = x > 0 && y > 0 && old.z == Int(z) && covers(old, column: x - 1, row: y - 1)
      case "x", "X": matches = x > 0 && covers(old, column: x - 1, row: nil)
      case "y", "Y": matches = y > 0 && covers(old, column: nil, row: y - 1)
      case "z", "Z": matches = old.z == Int(z) && covers(old, column: nil, row: nil)
      default: matches = covers(old, column: nil, row: nil)
      }
      if matches { touched.insert(old.image) }
      return matches
    }.map(\.serial))
    placements.removeAll { removed.contains($0.serial) }
    pruneOrphans()
    if kind == "I" || kind == "N", placement == 0 { touched.insert(image) }
    if kind.isUppercase {
      for id in touched where !placements.contains(where: { $0.image == id }) {
        if let removed = images.removeValue(forKey: id) { bytes -= removed.totalBytes }
      }
    }
    return .success(nil)
  }

  private func deleteFrame(_ values: [Character: String], freeLast: Bool) -> Result<(Int, Int)?, KittyGraphicsError> {
    guard let id = try? number(values, "i", default: 0), let numbered = try? number(values, "I", default: 0),
      !(values["i"] != nil && values["I"] != nil), let requested = try? number(values, "r", default: 1)
    else { return .failure(.invalid) }
    guard var image = numbered != 0 ? self.image(numbered: UInt32(numbered)) : images[UInt32(id)] else { return .success(nil) }
    if image.frameCount == 1 {
      if freeLast {
        bytes -= image.totalBytes
        images.removeValue(forKey: image.id)
        placements.removeAll { $0.image == image.id }
        pruneOrphans()
      }
      return .success(nil)
    }
    let victim = min(max(1, requested), image.frameCount) - 1
    image.animation = playback(image).animation
    let current = image.animation.current
    let removedBytes = image.pixels(ofFrame: victim).count
    if victim == 0 {
      let promoted = image.frames.removeFirst()
      image.animation.firstGap = promoted.gap == 0 ? 40 : promoted.gap
      image = Image(id: image.id, generation: promoted.generation, created: image.created, alternate: image.alternate,
        width: image.width, height: image.height, rgba: promoted.rgba, number: image.number,
        frames: image.frames, animation: image.animation)
    } else { image.frames.remove(at: victim - 1) }
    image.animation.current = min(current > victim ? current - 1 : current, image.frameCount - 1)
    if current == victim { image.animation.since = now }
    bytes -= removedBytes
    images[image.id] = image
    return .success(nil)
  }
  private func makeRoom(replacing id: UInt32, size: Int) throws {
    let replaced = images[id]?.totalBytes ?? 0
    while bytes - replaced + size > Self.maximumStorageBytes || (images[id] == nil && images.count >= Self.maximumImages) {
      guard let victim = images.values.filter({ candidate in
        candidate.id != id && !placements.contains(where: { $0.image == candidate.id })
      }).min(by: { $0.generation < $1.generation }) else { throw KittyGraphicsError.noSpace }
      bytes -= victim.totalBytes; images.removeValue(forKey: victim.id)
    }
  }
  private func outcome(fields: [Character: String], result: Result<(Int, Int)?, KittyGraphicsError>) -> KittyGraphicsOutcome {
    let id = (try? number(fields, "i", default: 0)) ?? 0, quiet = (try? number(fields, "q", default: 0)) ?? 2
    let numbered = (try? number(fields, "I", default: 0)) ?? 0
    let reply: Data?
    if (id == 0 && numbered == 0) || quiet == 2 || (quiet == 1 && result.isSuccess) { reply = nil }
    else {
      let placement = (try? number(fields, "p", default: 0)) ?? 0
      let suffix = (id == 0 ? "" : "i=\(id)") + (numbered == 0 ? "" : (id == 0 ? "" : ",") + "I=\(numbered)")
        + (placement == 0 ? "" : ",p=\(placement)")
      let value: String
      switch result { case .success: value = "OK"; case .failure(let error): value = error.wire }
      reply = Data("\u{1b}_G\(suffix);\(value)\u{1b}\\".utf8)
    }
    return KittyGraphicsOutcome(reply: reply, advance: (try? result.get()) ?? nil)
  }
  private func featureReply(_ fields: [Character: String]) -> Data? {
    guard let id = try? number(fields, "i", default: 0), id != 0,
          (try? number(fields, "q", default: 0)) == 0,
          let feature = fields["e"], feature.utf8.count == 1 else { return nil }
    let actionKeys: [String: String] = [
      "t": "ftsvSOo", "q": "ftsvSOo",
      "T": "ftsvSOopxywhXYcrCUzPQHV", "p": "pxywhXYcrCUzPQHV",
      "f": "ftsvSOoxycrzXY",
      "a": "srczv", "c": "crxywhXYC", "d": "dpxyzr",
    ]
    guard let keys = actionKeys[feature] else { return Data("\u{1b}_Gi=\(id);OK\u{1b}\\".utf8) }
    let supported = fields.keys.sorted().compactMap { key -> String? in
      let value = fields[key]!
      guard keys.contains(key) else { return nil }
      switch key {
      case "f": guard ["8", "16", "24", "100"].contains(value) else { return nil } // 32 is the default.
      case "t": guard ["f", "t", "s"].contains(value) else { return nil } // d is the default.
      case "d": guard value.count == 1, value != "a", "AiInNcCpPqQrRxXyYzZfF".contains(value) else { return nil }
      case "o": guard value == "z" else { return nil }
      case "C", "U": guard value == "1" else { return nil }
      case "X" where feature == "f": guard value == "1" else { return nil }
      case "z", "H", "V":
        guard let signed = Int32(value), signed != 0 else { return nil }
        if key != "z", abs(Int(signed)) > 4096 { return nil }
      default:
        guard let number = UInt32(value), number > 0 else { return nil }
        if feature == "a", key == "s", number > 3 { return nil }
        if feature == "a", key == "v", number == 1 { return nil }
        if ["t", "T", "q", "f"].contains(feature), (key == "s" || key == "v"), number > Self.maximumImageDimension { return nil }
        if ["p", "T"].contains(feature), (key == "c" || key == "r"), number > 4096 { return nil }
      }
      return ",\(key)=\(value)"
    }.joined()
    return Data("\u{1b}_Gi=\(id),e=\(feature)\(supported);OK\u{1b}\\".utf8)
  }
}

private extension Result where Success == (Int, Int)?, Failure == KittyGraphicsError { var isSuccess: Bool { if case .success = self { return true }; return false } }
private extension Array { func chunks(ofCount size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min(count, $0 + size)]) } } }

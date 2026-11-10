import Foundation

// Owned presentation values; no grid pointers or session ownership cross this seam.
struct CellSnapshot: Decodable, Equatable {
  let text: String
  let kind: String
  let style: CellStyle
  let link: String?
  let flags: Int
}
struct TerminalColor: Decodable, Equatable {
  let index: Int?
  let rgb: [Int]?
  init(packed: UInt32) {
    index = packed >> 24 == 1 ? Int(packed & 255) : nil
    rgb =
      packed >> 24 == 2
      ? [Int((packed >> 16) & 255), Int((packed >> 8) & 255), Int(packed & 255)] : nil
  }
  init(from decoder: Decoder) throws {
    if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self),
      s == "Default"
    {
      index = nil
      rgb = nil
      return
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    index = try c.decodeIfPresent(Int.self, forKey: .Indexed)
    rgb = try c.decodeIfPresent([Int].self, forKey: .Rgb)
  }
  enum CodingKeys: String, CodingKey { case Indexed, Rgb }
}
struct CellStyle: Decodable, Equatable {
  let foreground: TerminalColor
  let background: TerminalColor
  let underline_color: TerminalColor
  let underline: Int
  let bold: Bool
  let faint: Bool
  let italic: Bool
  let inverse: Bool
  let conceal: Bool
  let strike: Bool
  let overline: Bool
  let blink: Bool
}
struct RowSnapshot: Decodable, Equatable {
  let cells: [CellSnapshot]
  let soft_wrapped: Bool
  // Zero means legacy metadata without a usable owner identity.
  var id: UInt64 = 0
  var revision: UInt64 = 0
}
extension RowSnapshot {
  enum CodingKeys: String, CodingKey { case cells, soft_wrapped, id, revision }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    cells = try values.decode([CellSnapshot].self, forKey: .cells)
    soft_wrapped = try values.decode(Bool.self, forKey: .soft_wrapped)
    id = try values.decodeIfPresent(UInt64.self, forKey: .id) ?? 0
    revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
  }
}

enum TerminalSelectionScreen: String, Codable { case primary, alternate }
enum TerminalSelectionAffinity: String, Codable { case before, after }
enum TerminalSelectionGranularity: String, Codable { case character, word, line, rectangular }
enum TerminalSelectionMode: String, Codable { case linear, rectangular }
enum TerminalSelectionFailure: String, Codable, Error {
  case staleTarget, changedContent, evicted, noSelection, busy, limitExceeded, cancelled
}

/// The bounded row identities actually presented to the user. It retains no
/// terminal cells or history pages. Range gestures carry the interior proofs
/// too, so unchanged endpoints cannot conceal an overwritten middle row.
struct TerminalSelectionPresentation: Equatable, Codable {
  struct Row: Equatable, Codable {
    let id: UInt64
    let revision: UInt64
    var softWrapped: Bool = false
  }
  let snapshotID: UInt64
  let documentGeneration: UUID
  let screen: TerminalSelectionScreen
  let geometryEpoch: UInt64
  let columns: Int
  let rows: [Row]

  func hit(row: Int, boundary: Int, affinity: TerminalSelectionAffinity = .before) -> TerminalSelectionHit? {
    guard TerminalSnapshot.geometryError(columns: columns, rows: rows.count) == nil,
      snapshotID != 0, rows.indices.contains(row), rows[row].id != 0, (0...columns).contains(boundary)
    else { return nil }
    return TerminalSelectionHit(presentation: self, row: row, boundary: boundary, affinity: affinity)
  }
}

/// Metadata proving the visible content that supplied an action. Ranges are
/// ordered, one nonempty enclosing range per contributing physical row. The
/// owner also validates every intervening presented row; no cells are retained.
struct TerminalPresentedContent: Equatable {
  struct RowRange: Equatable {
    let row: Int
    let columns: Range<Int>
  }
  let presentation: TerminalSelectionPresentation
  let rows: [RowRange]
  var retainedByteCount: Int? {
    let (proof, proofOverflow) = presentation.rows.capacity.multipliedReportingOverflow(
      by: MemoryLayout<TerminalSelectionPresentation.Row>.stride)
    let (ranges, rangeOverflow) = rows.capacity.multipliedReportingOverflow(by: MemoryLayout<RowRange>.stride)
    let (total, totalOverflow) = proof.addingReportingOverflow(ranges)
    let (retained, retainedOverflow) = total.addingReportingOverflow(MemoryLayout<Self>.stride)
    return proofOverflow || rangeOverflow || totalOverflow || retainedOverflow ? nil : retained
  }
}

struct TerminalSelectionHit: Equatable, Codable {
  let presentation: TerminalSelectionPresentation
  let row: Int
  let boundary: Int
  let affinity: TerminalSelectionAffinity
  var snapshotID: UInt64 { presentation.snapshotID }
  var documentGeneration: UUID { presentation.documentGeneration }
  var screen: TerminalSelectionScreen { presentation.screen }
  var geometryEpoch: UInt64 { presentation.geometryEpoch }
  var rowID: UInt64 { presentation.rows.indices.contains(row) ? presentation.rows[row].id : 0 }
  var rowRevision: UInt64 { presentation.rows.indices.contains(row) ? presentation.rows[row].revision : 0 }
}

extension TerminalSelectionPresentation.Row {
  enum CodingKeys: String, CodingKey { case id, revision, softWrapped }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UInt64.self, forKey: .id)
    revision = try values.decode(UInt64.self, forKey: .revision)
    softWrapped = try values.decodeIfPresent(Bool.self, forKey: .softWrapped) ?? false
  }
}

struct TerminalSelectionSnapshot: Equatable, Codable {
  enum Phase: String, Codable { case none, dragging, committed }
  struct Segment: Equatable, Codable {
    let row: Int
    let start: Int
    let end: Int
  }
  var revision: UInt64 = 0
  var phase: Phase = .none
  var mode: TerminalSelectionMode = .linear
  // Sorted by row/start and disjoint within each row; renderers can walk the
  // immutable decoration in linear time without knowing selection semantics.
  // Linear selections can include zero-width endpoint markers so projections
  // retain selected hard-row separators. These markers paint no cells.
  var segments: [Segment] = []
  var issue: TerminalSelectionFailure?
  static let none = TerminalSelectionSnapshot()
}
struct CursorSnapshot: Decodable, Equatable {
  let row: Int
  let col: Int
  let pending_wrap: Bool
  let visible: Bool
  let shape: Int
}
struct ModesSnapshot: Decodable, Equatable {
  let application_cursor: Bool
  let bracketed_paste: Bool
  let focus: Bool
  let mouse: Int
  let sgr_mouse: Bool
  let reverse_video: Bool
  let newline: Bool?
}
struct ImageKey: Hashable {
  let id: UInt32
  let generation: UInt64
}
struct ImagePlacementSnapshot: Decodable, Equatable {
  let image: UInt32
  let generation: UInt64
  let width: Int
  let height: Int
  let source: [Int]
  let row: Int
  let col: Int
  let columns: Int
  let rows: Int
  let offset: [Int]
  let natural: Bool
  let z: Int
  let placement: UInt64
  var key: ImageKey { ImageKey(id: image, generation: generation) }
}
final class ImagePixels: @unchecked Sendable {
  let data: Data
  init(_ data: Data) { self.data = data }
}
struct TerminalSnapshot: Decodable {
  // The publication contract is bounded independently of handle creation.
  // Keep this preflight usable without allocating or projecting a grid.
  static func geometryError(columns: Int, rows: Int) -> String? {
    guard (1...4096).contains(columns), (1...4096).contains(rows),
          columns <= 1_048_576 / rows else { return "Invalid snapshot dimensions or palette" }
    return nil
  }
  let at_prompt: Bool
  // Old persisted/remote snapshot metadata predates this field. Nil must not
  // be treated as shell readiness by callers.
  let input_ready: Bool?
  let search: [SearchHighlight]
  let images: [ImagePlacementSnapshot]
  var imagePixels: [ImageKey: ImagePixels] = [:]
  enum CodingKeys: String, CodingKey {
    case at_prompt, input_ready, search, images, revision, geometry_epoch, document_epoch, history_epoch, screen_epoch,
      scroll_offset, following_tail, viewport_clamp_revision, cols, rows, cursor, modes, alternate, title, cwd,
      history_rows, palette, default_fg, default_bg, selectionPresentation, selection, search_matches
  }
  let revision: UInt64
  let geometry_epoch: UInt64
  let document_epoch: UInt64
  let history_epoch: UInt64
  let screen_epoch: UInt64
  let scroll_offset: Int
  let following_tail: Bool
  let viewport_clamp_revision: UInt64
  let cols: Int
  let rows: [RowSnapshot]
  let cursor: CursorSnapshot
  let modes: ModesSnapshot
  let alternate: Bool
  let title: String
  let cwd: String?
  let history_rows: Int
  let palette: [[Int]]
  let default_fg: [Int]
  let default_bg: [Int]
  var selectionPresentation: TerminalSelectionPresentation? = nil
  var selection: TerminalSelectionSnapshot = .none
  /// Visible matches other than the navigated one, which stays in `search`.
  var search_matches: [SearchHighlight] = []

  func selectionHit(row: Int, boundary: Int, affinity: TerminalSelectionAffinity = .before) -> TerminalSelectionHit? {
    selectionPresentation?.hit(row: row, boundary: boundary, affinity: affinity)
  }
}
extension TerminalSnapshot {
  // Old diagnostic/persisted snapshots can still be read, but cannot create
  // actionable presented hits without the new owner identity metadata.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    at_prompt = try values.decode(Bool.self, forKey: .at_prompt)
    input_ready = try values.decodeIfPresent(Bool.self, forKey: .input_ready)
    search = try values.decode([SearchHighlight].self, forKey: .search)
    images = try values.decode([ImagePlacementSnapshot].self, forKey: .images)
    revision = try values.decode(UInt64.self, forKey: .revision)
    geometry_epoch = try values.decode(UInt64.self, forKey: .geometry_epoch)
    document_epoch = try values.decode(UInt64.self, forKey: .document_epoch)
    history_epoch = try values.decode(UInt64.self, forKey: .history_epoch)
    screen_epoch = try values.decode(UInt64.self, forKey: .screen_epoch)
    scroll_offset = try values.decode(Int.self, forKey: .scroll_offset)
    following_tail = try values.decode(Bool.self, forKey: .following_tail)
    viewport_clamp_revision = try values.decode(UInt64.self, forKey: .viewport_clamp_revision)
    cols = try values.decode(Int.self, forKey: .cols)
    rows = try values.decode([RowSnapshot].self, forKey: .rows)
    cursor = try values.decode(CursorSnapshot.self, forKey: .cursor)
    modes = try values.decode(ModesSnapshot.self, forKey: .modes)
    alternate = try values.decode(Bool.self, forKey: .alternate)
    title = try values.decode(String.self, forKey: .title)
    cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
    history_rows = try values.decode(Int.self, forKey: .history_rows)
    palette = try values.decode([[Int]].self, forKey: .palette)
    default_fg = try values.decode([Int].self, forKey: .default_fg)
    default_bg = try values.decode([Int].self, forKey: .default_bg)
    selectionPresentation = try values.decodeIfPresent(TerminalSelectionPresentation.self, forKey: .selectionPresentation)
    selection = try values.decodeIfPresent(TerminalSelectionSnapshot.self, forKey: .selection) ?? .none
    search_matches = try values.decodeIfPresent([SearchHighlight].self, forKey: .search_matches) ?? []
  }
}
struct SearchHighlight: Decodable, Equatable {
  let row: Int
  let start: Int
  let end: Int
}

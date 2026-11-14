import Foundation

// Owned presentation values; no grid pointers or session ownership cross this seam.
package struct CellSnapshot: Decodable, Equatable {
  package let text: String
  package let kind: String
  package let style: CellStyle
  package let link: String?
  package let flags: Int
}
package struct TerminalColor: Decodable, Equatable {
  package let index: Int?
  package let rgb: [Int]?
  package init(packed: UInt32) {
    index = packed >> 24 == 1 ? Int(packed & 255) : nil
    rgb =
      packed >> 24 == 2
      ? [Int((packed >> 16) & 255), Int((packed >> 8) & 255), Int(packed & 255)] : nil
  }
  package init(from decoder: Decoder) throws {
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
  package enum CodingKeys: String, CodingKey { case Indexed, Rgb }
}
package struct CellStyle: Decodable, Equatable {
  package let foreground: TerminalColor
  package let background: TerminalColor
  package let underline_color: TerminalColor
  package let underline: Int
  package let bold: Bool
  package let faint: Bool
  package let italic: Bool
  package let inverse: Bool
  package let conceal: Bool
  package let strike: Bool
  package let overline: Bool
  package let blink: Bool
}
package struct RowSnapshot: Decodable, Equatable {
  package let cells: [CellSnapshot]
  package let soft_wrapped: Bool
  // Zero means legacy metadata without a usable owner identity.
  package var id: UInt64 = 0
  package var revision: UInt64 = 0
}
extension RowSnapshot {
  package enum CodingKeys: String, CodingKey { case cells, soft_wrapped, id, revision }
  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    cells = try values.decode([CellSnapshot].self, forKey: .cells)
    soft_wrapped = try values.decode(Bool.self, forKey: .soft_wrapped)
    id = try values.decodeIfPresent(UInt64.self, forKey: .id) ?? 0
    revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
  }
}

package enum TerminalSelectionScreen: String, Codable { case primary, alternate }
package enum TerminalSelectionAffinity: String, Codable { case before, after }
package enum TerminalSelectionGranularity: String, Codable { case character, word, line, rectangular }
package enum TerminalSelectionMode: String, Codable { case linear, rectangular }
package enum TerminalSelectionFailure: String, Codable, Error {
  case staleTarget, changedContent, evicted, noSelection, busy, limitExceeded, cancelled
}

/// The bounded row identities actually presented to the user. It retains no
/// terminal cells or history pages. Range gestures carry the interior proofs
/// too, so unchanged endpoints cannot conceal an overwritten middle row.
package struct TerminalSelectionPresentation: Equatable, Codable {
  package struct Row: Equatable, Codable {
    package let id: UInt64
    package let revision: UInt64
    package var softWrapped: Bool = false
  }
  package let snapshotID: UInt64
  package let documentGeneration: UUID
  package let screen: TerminalSelectionScreen
  package let geometryEpoch: UInt64
  package let columns: Int
  package let rows: [Row]

  package func hit(row: Int, boundary: Int, affinity: TerminalSelectionAffinity = .before) -> TerminalSelectionHit? {
    guard TerminalSnapshot.geometryError(columns: columns, rows: rows.count) == nil,
      snapshotID != 0, rows.indices.contains(row), rows[row].id != 0, (0...columns).contains(boundary)
    else { return nil }
    return TerminalSelectionHit(presentation: self, row: row, boundary: boundary, affinity: affinity)
  }
}

/// Metadata proving the visible content that supplied an action. Ranges are
/// ordered, one nonempty enclosing range per contributing physical row. The
/// owner also validates every intervening presented row; no cells are retained.
package struct TerminalPresentedContent: Equatable {
  package struct RowRange: Equatable {
    package let row: Int
    package let columns: Range<Int>
    package init(row: Int, columns: Range<Int>) {
      self.row = row
      self.columns = columns
    }
  }
  package let presentation: TerminalSelectionPresentation
  package let rows: [RowRange]
  package init(presentation: TerminalSelectionPresentation, rows: [RowRange]) {
    self.presentation = presentation
    self.rows = rows
  }
  package var retainedByteCount: Int? {
    let (proof, proofOverflow) = presentation.rows.capacity.multipliedReportingOverflow(
      by: MemoryLayout<TerminalSelectionPresentation.Row>.stride)
    let (ranges, rangeOverflow) = rows.capacity.multipliedReportingOverflow(by: MemoryLayout<RowRange>.stride)
    let (total, totalOverflow) = proof.addingReportingOverflow(ranges)
    let (retained, retainedOverflow) = total.addingReportingOverflow(MemoryLayout<Self>.stride)
    return proofOverflow || rangeOverflow || totalOverflow || retainedOverflow ? nil : retained
  }
}

package struct TerminalSelectionHit: Equatable, Codable {
  package let presentation: TerminalSelectionPresentation
  package let row: Int
  package let boundary: Int
  package let affinity: TerminalSelectionAffinity
  package var snapshotID: UInt64 { presentation.snapshotID }
  package var documentGeneration: UUID { presentation.documentGeneration }
  package var screen: TerminalSelectionScreen { presentation.screen }
  package var geometryEpoch: UInt64 { presentation.geometryEpoch }
  package var rowID: UInt64 { presentation.rows.indices.contains(row) ? presentation.rows[row].id : 0 }
  package var rowRevision: UInt64 { presentation.rows.indices.contains(row) ? presentation.rows[row].revision : 0 }
}

extension TerminalSelectionPresentation.Row {
  package enum CodingKeys: String, CodingKey { case id, revision, softWrapped }
  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UInt64.self, forKey: .id)
    revision = try values.decode(UInt64.self, forKey: .revision)
    softWrapped = try values.decodeIfPresent(Bool.self, forKey: .softWrapped) ?? false
  }
}

package struct TerminalSelectionSnapshot: Equatable, Codable {
  package enum Phase: String, Codable { case none, dragging, committed }
  package struct Segment: Equatable, Codable {
    package let row: Int
    package let start: Int
    package let end: Int
  }
  package var revision: UInt64 = 0
  package var phase: Phase = .none
  package var mode: TerminalSelectionMode = .linear
  // Sorted by row/start and disjoint within each row; renderers can walk the
  // immutable decoration in linear time without knowing selection semantics.
  // Linear selections can include zero-width endpoint markers so projections
  // retain selected hard-row separators. These markers paint no cells.
  package var segments: [Segment] = []
  package var issue: TerminalSelectionFailure?
  package static let none = TerminalSelectionSnapshot()
}
package struct CursorSnapshot: Decodable, Equatable {
  package let row: Int
  package let col: Int
  package let pending_wrap: Bool
  package let visible: Bool
  package let shape: Int
}
package struct ModesSnapshot: Decodable, Equatable {
  package let application_cursor: Bool
  package let bracketed_paste: Bool
  package let focus: Bool
  package let mouse: Int
  package let sgr_mouse: Bool
  package let reverse_video: Bool
  package let newline: Bool?
}
package struct ImageKey: Hashable {
  package let id: UInt32
  package let generation: UInt64
}
package struct ImagePlacementSnapshot: Decodable, Equatable {
  package let image: UInt32
  package let generation: UInt64
  package let width: Int
  package let height: Int
  package let source: [Int]
  package let row: Int
  package let col: Int
  package let columns: Int
  package let rows: Int
  package let offset: [Int]
  package let natural: Bool
  package let z: Int
  package let placement: UInt64
  package var key: ImageKey { ImageKey(id: image, generation: generation) }
}
package final class ImagePixels: @unchecked Sendable {
  package let data: Data
  package init(_ data: Data) { self.data = data }
}
package struct TerminalSnapshot: Decodable {
  // The publication contract is bounded independently of handle creation.
  // Keep this preflight usable without allocating or projecting a grid.
  package static func geometryError(columns: Int, rows: Int) -> String? {
    guard (1...4096).contains(columns), (1...4096).contains(rows),
          columns <= 1_048_576 / rows else { return "Invalid snapshot dimensions or palette" }
    return nil
  }
  package let at_prompt: Bool
  // Old persisted/remote snapshot metadata predates this field. Nil must not
  // be treated as shell readiness by callers.
  package let input_ready: Bool?
  package let search: [SearchHighlight]
  package let images: [ImagePlacementSnapshot]
  package var imagePixels: [ImageKey: ImagePixels] = [:]
  package enum CodingKeys: String, CodingKey {
    case at_prompt, input_ready, search, images, revision, geometry_epoch, document_epoch, history_epoch, screen_epoch,
      scroll_offset, following_tail, viewport_clamp_revision, cols, rows, cursor, modes, alternate, title, cwd,
      history_rows, palette, default_fg, default_bg, selectionPresentation, selection, search_matches
  }
  package let revision: UInt64
  package let geometry_epoch: UInt64
  package let document_epoch: UInt64
  package let history_epoch: UInt64
  package let screen_epoch: UInt64
  package let scroll_offset: Int
  package let following_tail: Bool
  package let viewport_clamp_revision: UInt64
  package let cols: Int
  package let rows: [RowSnapshot]
  package let cursor: CursorSnapshot
  package let modes: ModesSnapshot
  package let alternate: Bool
  package let title: String
  package let cwd: String?
  package let history_rows: Int
  package let palette: [[Int]]
  package let default_fg: [Int]
  package let default_bg: [Int]
  package var selectionPresentation: TerminalSelectionPresentation? = nil
  package var selection: TerminalSelectionSnapshot = .none
  /// Visible matches other than the navigated one, which stays in `search`.
  package var search_matches: [SearchHighlight] = []

  package func selectionHit(row: Int, boundary: Int, affinity: TerminalSelectionAffinity = .before) -> TerminalSelectionHit? {
    selectionPresentation?.hit(row: row, boundary: boundary, affinity: affinity)
  }
}
extension TerminalSnapshot {
  // Old diagnostic/persisted snapshots can still be read, but cannot create
  // actionable presented hits without the new owner identity metadata.
  package init(from decoder: Decoder) throws {
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
package struct SearchHighlight: Decodable, Equatable {
  package let row: Int
  package let start: Int
  package let end: Int
}

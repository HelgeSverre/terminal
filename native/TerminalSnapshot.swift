import Foundation

// Owned presentation values shared by the emulator and its consumers.
// No grid pointers or session/queue ownership crosses this seam.
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
      scroll_offset, following_tail, viewport_clamp_revision, cols, rows, cursor, modes, alternate, title,
      history_rows, palette, default_fg, default_bg
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
  let history_rows: Int
  let palette: [[Int]]
  let default_fg: [Int]
  let default_bg: [Int]
}
struct SearchHighlight: Decodable, Equatable {
  let row: Int
  let start: Int
  let end: Int
}

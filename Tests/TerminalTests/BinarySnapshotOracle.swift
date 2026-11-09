// Independent C ABI adapter retained as a test oracle for direct Swift snapshots.
import Foundation

// Row/cell data crosses as length-delimited typed views. Only small window/image
// metadata uses JSON. All views are copied on the owner before the callback returns.
enum BinarySnapshotOracle {
  private struct Header: Decodable {
    struct RowIdentity: Decodable { let id: UInt64; let revision: UInt64 }
    let row_identities: [RowIdentity]?
    let at_prompt: Bool
    let input_ready: Bool?
    let search: [SearchHighlight]
    let images: [ImagePlacementSnapshot]
    let revision: UInt64
    let geometry_epoch: UInt64
    let document_epoch: UInt64
    let history_epoch: UInt64
    let screen_epoch: UInt64
    let scroll_offset: Int
    let following_tail: Bool
    let viewport_clamp_revision: UInt64
    let cols: Int
    let cursor: CursorSnapshot
    let modes: ModesSnapshot
    let alternate: Bool
    let title: String
    let cwd: String?
    let history_rows: Int
    let palette: [[Int]]
    let default_fg: [Int]
    let default_bg: [Int]
  }
  private final class Capture {
    var snapshot: TerminalSnapshot?
    var error: String?
  }
  struct Result {
    let snapshot: TerminalSnapshot?
    let error: String?
  }
  static func read(_ core: OpaquePointer?, scroll: Int, now: UInt64) -> Result {
    let capture = Capture()
    _ = terminal_snapshot_binary(
      core, scroll, now, Unmanaged.passUnretained(capture).toOpaque(), receive)
    return Result(snapshot: capture.snapshot, error: capture.error)
  }
  static func readView(_ core: OpaquePointer?, now: UInt64) -> Result {
    let capture = Capture()
    _ = terminal_view_snapshot_binary(
      core, now, Unmanaged.passUnretained(capture).toOpaque(), receive)
    return Result(snapshot: capture.snapshot, error: capture.error)
  }
  // Invalid shapes must fail before any grid access. A single non-nil cell
  // and wrap sentinel exercises that decoder guard without a giant terminal.
  static func malformedGeometry(metadata: Data, cellCount: Int, rowCount: Int) -> Result {
    let capture = Capture()
    var cell = TerminalCellView()
    var wrap: UInt8 = 0
    metadata.withUnsafeBytes { bytes in
      withUnsafePointer(to: &cell) { cells in
        withUnsafePointer(to: &wrap) { wraps in
          receive(Unmanaged.passUnretained(capture).toOpaque(), bytes.bindMemory(to: UInt8.self).baseAddress,
                  metadata.count, cells, cellCount, wraps, rowCount)
        }
      }
    }
    return Result(snapshot: capture.snapshot, error: capture.error)
  }
  static func emptyStringSentinels(metadata: Data) -> Result {
    let capture = Capture()
    var byte: UInt8 = 0
    withUnsafePointer(to: &byte) { sentinel in
      var cell = TerminalCellView()
      cell.text = sentinel; cell.link = sentinel
      metadata.withUnsafeBytes { bytes in
        withUnsafePointer(to: &cell) { cells in
          receive(Unmanaged.passUnretained(capture).toOpaque(), bytes.bindMemory(to: UInt8.self).baseAddress,
                  metadata.count, cells, 1, sentinel, 1)
        }
      }
    }
    return Result(snapshot: capture.snapshot, error: capture.error)
  }
  private static let receive:
    @convention(c) (
      UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
      UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int
    ) -> Void = { context, metadata, metadataCount, cells, cellCount, wraps, rowCount in
      guard let context, let metadata, let cells, let wraps else { return }
      let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
      do {
        let header = try JSONDecoder().decode(
          Header.self, from: Data(bytes: metadata, count: metadataCount))
        guard (1...4096).contains(header.cols), (1...4096).contains(rowCount),
          header.cols * rowCount == cellCount, cellCount <= 1_048_576,
          header.palette.count == 256, header.palette.allSatisfy({ $0.count == 3 }),
          header.default_fg.count == 3, header.default_bg.count == 3
        else {
          capture.error = "Invalid snapshot dimensions or palette"
          return
        }
        let kinds = ["Empty", "Lead1", "Lead2", "Continuation", "WrapSpacer"]
        guard header.row_identities == nil || header.row_identities?.count == rowCount else {
          capture.error = "Invalid snapshot row identities"
          return
        }
        var rows: [RowSnapshot] = []
        rows.reserveCapacity(rowCount)
        for row in 0..<rowCount {
          var output: [CellSnapshot] = []
          output.reserveCapacity(header.cols)
          for column in 0..<header.cols {
            let cell = cells[row * header.cols + column]
            guard Int(cell.kind) < kinds.count else {
              capture.error = "Invalid cell kind"
              return
            }
            let flags = cell.style_flags
            let style = CellStyle(
              foreground: TerminalColor(packed: cell.foreground),
              background: TerminalColor(packed: cell.background),
              underline_color: TerminalColor(packed: cell.underline_color),
              underline: Int(cell.underline), bold: flags & 1 != 0, faint: flags & 2 != 0,
              italic: flags & 4 != 0, inverse: flags & 8 != 0, conceal: flags & 16 != 0,
              strike: flags & 32 != 0, overline: flags & 64 != 0, blink: flags & 128 != 0)
            let text = String(
              decoding: UnsafeBufferPointer(start: cell.text, count: cell.text_len), as: UTF8.self)
            let link = cell.link.map {
              String(decoding: UnsafeBufferPointer(start: $0, count: cell.link_len), as: UTF8.self)
            }
            output.append(
              CellSnapshot(
                text: text, kind: kinds[Int(cell.kind)], style: style, link: link,
                flags: Int(cell.cell_flags)))
          }
          rows.append(RowSnapshot(cells: output, soft_wrapped: wraps[row] != 0,
            id: header.row_identities?[row].id ?? 0, revision: header.row_identities?[row].revision ?? 0))
        }
        capture.snapshot = TerminalSnapshot(
          at_prompt: header.at_prompt,
          input_ready: header.input_ready,
          search: header.search,
          images: header.images, revision: header.revision, geometry_epoch: header.geometry_epoch,
          document_epoch: header.document_epoch, history_epoch: header.history_epoch,
          screen_epoch: header.screen_epoch, scroll_offset: header.scroll_offset,
          following_tail: header.following_tail, viewport_clamp_revision: header.viewport_clamp_revision,
          cols: header.cols, rows: rows, cursor: header.cursor, modes: header.modes,
          alternate: header.alternate, title: header.title, cwd: header.cwd, history_rows: header.history_rows,
          palette: header.palette, default_fg: header.default_fg, default_bg: header.default_bg)
      } catch {
        capture.error = "Snapshot metadata decode failed: \(error)"
      }
    }
}

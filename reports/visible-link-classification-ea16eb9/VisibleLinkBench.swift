import Foundation
@main enum VisibleLinkBench {
  private static let plainStyle = CellStyle(
    foreground: TerminalColor(packed: 0), background: TerminalColor(packed: 0),
    underline_color: TerminalColor(packed: 0), underline: 0, bold: false, faint: false,
    italic: false, inverse: false, conceal: false, strike: false, overline: false, blink: false)

  private static func cell(_ text: String, _ kind: String = "Lead1", link: String? = nil) -> CellSnapshot {
    CellSnapshot(text: text, kind: kind, style: plainStyle, link: link, flags: 0)
  }

  private static func row(
    _ cells: [CellSnapshot], columns: Int, soft: Bool = false, id: UInt64 = 0, revision: UInt64 = 0
  ) -> RowSnapshot {
    RowSnapshot(
      cells: cells + Array(repeating: cell("", "Empty"), count: max(0, columns - cells.count)),
      soft_wrapped: soft, id: id, revision: revision)
  }

  private static func snapshot(_ rows: [RowSnapshot], columns: Int, revision: UInt64 = 1) -> TerminalSnapshot {
    TerminalSnapshot(
      at_prompt: false, input_ready: nil, search: [], images: [], revision: revision,
      geometry_epoch: 1, document_epoch: revision, history_epoch: 1, screen_epoch: revision,
      scroll_offset: 0, following_tail: true, viewport_clamp_revision: 1, cols: columns,
      rows: rows, cursor: CursorSnapshot(row: 0, col: 0, pending_wrap: false, visible: true, shape: 0),
      modes: ModesSnapshot(application_cursor: false, bracketed_paste: false, focus: false,
                           mouse: 0, sgr_mouse: false, reverse_video: false, newline: false),
      alternate: false, title: "", cwd: nil, history_rows: 0,
      palette: Array(repeating: [0, 0, 0], count: 256), default_fg: [230, 230, 230],
      default_bg: [10, 10, 11])
  }

  private static func cells(_ text: String, link: String? = nil) -> [CellSnapshot] {
    text.map { cell(String($0), link: link) }
  }

  private static func projectedSnapshot(
    _ rows: [RowSnapshot], columns: Int, revision: UInt64 = 1,
    selection: TerminalSelectionSnapshot = .none
  ) -> TerminalSnapshot {
    var value = snapshot(rows, columns: columns, revision: revision)
    value.selectionPresentation = TerminalSelectionPresentation(
      snapshotID: revision, documentGeneration: UUID(), screen: .primary,
      geometryEpoch: value.geometry_epoch, columns: columns,
      rows: rows.map { .init(id: $0.id, revision: $0.revision, softWrapped: $0.soft_wrapped) })
    value.selection = selection
    return value
  }

  static func main() {
    let fixtures = [("ascii", "hello terminal 1234567890 ", Optional<String>.none),
                    ("unicode", "Unicode: 猫 é 👩🏽‍💻 🇳🇴 ∑─▁▂▃▄▅▆▇█ ", nil),
                    ("urls", "(https://example.test/a_(b)) mailto:a@example.test ", nil),
                    ("osc8", "explicit visible text 猫 ", "https://example.test/owned")]
    var checksum = 0
    for (name, text, link) in fixtures {
      let sample = cells(text, link: link)
      let filled = (0..<100).map { sample[$0 % sample.count] }
      let rows = (0..<30).map { row(filled, columns: 100, id: UInt64($0 + 1)) }
      let value = projectedSnapshot(rows, columns: 100)
      var times: [Double] = []
      for _ in 0..<7 {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<64 {
          let result = VisibleLinkProjection(snapshot: value)
          checksum &+= result.occurrences.count
          checksum &+= result.occurrence(atGrid: 50)?.label.utf8.count ?? 0
        }
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
      }
      print("\(name) rows=30 cols=100 iterations=64 ms=\(times.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    }
    print("checksum=\(checksum)")
  }
}

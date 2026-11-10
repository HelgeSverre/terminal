import Foundation

// The same source is compiled against both frozen revisions. Budgets come
// exclusively from the baseline binary, including tests of the candidate.
enum RowStorageCompatibilityProbe {
  private final class Metadata { var value = Data() }
  private static let collectMetadata: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
    UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int
  ) -> Void = { context, metadata, count, _, _, _, _ in
    guard let context, let metadata, count > 0 else { return }
    Unmanaged<Metadata>.fromOpaque(context).takeUnretainedValue().value = Data(bytes: metadata, count: count)
  }
  static let widths: [UInt32] = [1, 2, 3, 4, 7, 17, 31, 63, 80, 127]
  static func feed(_ terminal: OpaquePointer, _ text: String) {
    let data = Data(text.utf8)
    let used = data.withUnsafeBytes {
      terminal_feed(terminal, $0.bindMemory(to: UInt8.self).baseAddress, data.count, 0)
    }
    precondition(used == data.count)
  }
  static func snapshot(_ terminal: OpaquePointer) -> [String: Any] {
    let capture = Metadata()
    precondition(terminal_view_snapshot_binary(
      terminal, 0, Unmanaged.passUnretained(capture).toOpaque(), collectMetadata))
    var owner = try! JSONSerialization.jsonObject(with: capture.value) as! [String: Any]
    let offset = owner["scroll_offset"] as! Int
    let raw = terminal_snapshot(terminal, offset, 0)!
    defer { terminal_string_free(raw) }
    let numeric = try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as! [String: Any]
    owner["rows"] = numeric["rows"]
    return owner
  }
  static func setup(_ width: UInt32, linked: Bool) -> OpaquePointer {
    let terminal = terminal_create(width, 3)!
    let text = linked
      ? "\u{1b}]8;;https://example.test/é\u{7}\u{1b}[31;44;1me\u{301}猫\u{1b}[0m\u{1b}]8;;\u{7}"
      : "abcdef"
    feed(terminal, (0..<12).map { "\($0)\(text)" }.joined(separator: "\r\n"))
    terminal_view_scroll(terminal, 1)
    precondition(terminal_resize(terminal, width + 3, 5))
    precondition(terminal_resize(terminal, max(1, width / 2), 2))
    feed(terminal, "\r\n\(text)\r\nEND")
    return terminal
  }
  static func rowValue(_ row: TerminalRow) -> [String: Any] {
    ["id": row.id, "revision": row.revision, "soft_wrapped": row.softWrapped,
     "charge": row.retainedStorageCost, "cells": row.cells.map { cell in
       ["text": cell.text, "kind": cell.kind, "flags": cell.flags,
        "protected": cell.protected, "link": cell.link as Any? ?? NSNull(),
        "style": [cell.style.foreground, cell.style.background, cell.style.underline,
                  UInt32(cell.style.flags), UInt32(cell.style.underlineKind)]] as [String: Any]
     }]
  }
  static func documentValue(_ document: TerminalDocument) -> [String: Any] {
    ["primary": document.primary.rows.map(rowValue), "history": document.history.map(rowValue),
     "cursor": [document.primary.cursorRow, document.primary.cursorColumn],
     "pending_wrap": document.primary.pendingWrap]
  }
  @inline(never) static func importedRow(_ width: Int) -> TerminalRow {
    var cells: [TerminalCell] = []
    cells.reserveCapacity(width * 3 + 7)
    for column in 0..<width {
      cells.append(TerminalCell(text: column.isMultiple(of: 2) ? "e\u{301}" : "z",
                                kind: 1, style: TerminalStyle(background: 9),
                                link: "https://example.test/\(column)", flags: 2, protected: true))
    }
    return TerminalRow(id: 1000, cells: cells)
  }
  static func main() throws {
    let basis: [String: UInt64]
    if CommandLine.arguments.count == 3 {
      basis = try JSONDecoder().decode([String: UInt64].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    } else { basis = [:] }
    var charges: [String: UInt64] = [:]
    var records: [[String: Any]] = []
    for width in widths {
      for linked in [false, true] {
        let key = "\(width)-\(linked)"
        let calibration = setup(width, linked: linked)
        charges[key] = terminal_history_bytes(calibration)
        terminal_destroy(calibration)
        guard let charge = basis[key] else { continue }
        precondition(charge > 0)
        for delta: Int64 in [-1, 0, 1] {
          let terminal = setup(width, linked: linked)
          terminal_set_history_byte_limit(terminal, UInt64(Int64(charge) + delta))
          records.append(["case": key, "delta": delta, "stage": "limit", "snapshot": snapshot(terminal),
                          "history_bytes": terminal_history_bytes(terminal)])
          feed(terminal, "\r\nAFTER")
          records.append(["case": key, "delta": delta, "stage": "after", "snapshot": snapshot(terminal),
                          "history_bytes": terminal_history_bytes(terminal)])
          precondition(terminal_resize(terminal, width + 1, 4))
          records.append(["case": key, "delta": delta, "stage": "grow", "snapshot": snapshot(terminal),
                          "history_bytes": terminal_history_bytes(terminal)])
          terminal_destroy(terminal)
        }
      }
      guard !basis.isEmpty else { continue }
      // Over-reserved cell storage and an actual retained screen force the
      // old and new implementations through their COW mutation paths.
      var cells: [TerminalCell] = []
      cells.reserveCapacity(Int(width) * 3 + 7)
      for column in 0..<Int(width) {
        cells.append(TerminalCell(text: column.isMultiple(of: 2) ? "e\u{301}" : "z",
                                  kind: 1, style: TerminalStyle(background: 9),
                                  link: "https://example.test/\(column)", flags: 2, protected: true))
      }
      var document = TerminalDocument(columns: Int(width), rows: 3)
      document.primary.rows[0] = TerminalRow(id: 1000, cells: cells)
      let retained = document.primary
      for scalar in "XYZ".unicodeScalars {
        _ = document.print(scalar, usingAlternate: false, leftRightMargins: false,
                           autoWrap: true, insertMode: false,
                           attributes: .init(style: TerminalStyle(), link: nil, protected: false))
      }
      records.append(["case": "cow-\(width)", "stage": "mutated", "document": documentValue(document),
                      "retained": retained.rows.map(rowValue)])
      let transaction = DocumentReflowTransaction(source: document,
        geometry: TerminalResizeGeometry(columns: Int(width) + 3, rows: 4, cellWidth: 8, cellHeight: 16),
        anchor: nil, promptEraseStyle: nil, historyRows: 50_000, historyBytes: 64 * 1024 * 1024)
      var replacement: DocumentReflowTransaction.Replacement?
      for _ in 0..<10_000 {
        switch transaction.advance() {
        case .pending: continue
        case .ready(let value): replacement = value
        default: preconditionFailure("small compatibility reflow must complete")
        }
        break
      }
      precondition(replacement != nil)
      document = replacement!.document
      transaction.retire()
      DocumentReflowTransaction.drainRetirementForTesting()
      records.append(["case": "cow-\(width)", "stage": "reflow", "document": documentValue(document),
                      "retained": retained.rows.map(rowValue)])
      for shared in [false, true] {
        for inserting in [false, true] {
          var shifted = TerminalDocument(columns: Int(width), rows: 3)
          shifted.primary.rows[0] = importedRow(Int(width))
          let held: TerminalScreen? = shared ? shifted.primary : nil
          _ = shifted.print("X".unicodeScalars.first!, usingAlternate: false,
                            leftRightMargins: false, autoWrap: true, insertMode: inserting,
                            attributes: .init(style: TerminalStyle(), link: nil, protected: false))
          records.append(["case": "shift-\(width)-\(shared)-\(inserting)",
                          "document": documentValue(shifted),
                          "retained": held?.rows.map(rowValue) as Any? ?? NSNull()])
        }
      }
      // A text-only cluster extension and a cap-flag-only write must follow
      // the same storage-detach accounting as physical scalar replacement.
      for capOnly in [false, true] {
        var extended = TerminalDocument(columns: Int(width), rows: 3)
        extended.primary.rows[0] = importedRow(Int(width))
        for scalar in (capOnly ? "e" + String(repeating: "\u{301}", count: 63) : "e").unicodeScalars {
          _ = extended.print(scalar, usingAlternate: false, leftRightMargins: false,
                             autoWrap: true, insertMode: false,
                             attributes: .init(style: TerminalStyle(), link: nil, protected: false))
        }
        let held = extended.primary
        _ = extended.print("\u{301}".unicodeScalars.first!, usingAlternate: false,
                           leftRightMargins: false, autoWrap: true, insertMode: false,
                           attributes: .init(style: TerminalStyle(), link: nil, protected: false))
        records.append(["case": "extend-\(width)-\(capOnly)", "document": documentValue(extended),
                        "retained": held.rows.map(rowValue)])
      }
      var resized = TerminalDocument(columns: Int(width), rows: 3)
      resized.primary.rows[0] = importedRow(Int(width))
      let originalScreen = resized.primary
      resized.primary = resized.resize(originalScreen, columns: Int(width) + 3, rows: 3)
      resized.primary.cursorRow = 2
      _ = resized.index(usingAlternate: false, reverse: false, leftRightMargins: false,
                        eraseStyle: TerminalStyle())
      records.append(["case": "resize-index-\(width)", "document": documentValue(resized),
                      "retained": originalScreen.rows.map(rowValue)])
    }
    let data = try JSONSerialization.data(withJSONObject: ["charges": charges, "records": records], options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
  }
}

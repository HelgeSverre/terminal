import Foundation

// This exercises the document's ownership seam directly.  An immutable
// screen value retained by a publisher must survive both an in-place document
// mutation and destruction of the mutable document without sharing edited
// rows/cells with the next snapshot.
@main enum TerminalDocumentOwnershipTests {
  static let styled = TerminalDocument.PrintAttributes(
    style: TerminalStyle(foreground: 0x0201_0203, background: 0x0204_0506, flags: 1),
    link: "https://example.test/owned", protected: true)
  static func place(_ scalar: Unicode.Scalar, starts: Bool, alternate: Bool = false, into document: inout TerminalDocument) {
    _ = document.print(scalar, startsCluster: starts, usingAlternate: alternate,
                       leftRightMargins: false, autoWrap: true, insertMode: false,
                       attributes: styled)
  }
  static func retainedSnapshot() -> TerminalScreen {
    var document = TerminalDocument(columns: 4, rows: 2)
    let old = document.primary
    _ = document.print("A".unicodeScalars.first!, startsCluster: true,
                       usingAlternate: false, leftRightMargins: false,
                       autoWrap: true, insertMode: false,
                       attributes: TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false))
    precondition(document.primary.rows[0].cells[0].text == "A")
    precondition(old.rows[0].cells[0].text.isEmpty)
    return old
  }

  static func populatedSnapshotsRemainImmutable() {
    var document = TerminalDocument(columns: 2, rows: 2)
    place("a".unicodeScalars.first!, starts: true, into: &document)
    let beforeCombining = document.primary
    place("\u{301}".unicodeScalars.first!, starts: false, into: &document)
    precondition(document.primary.rows[0].cells[0].text == "a\u{301}")
    precondition(beforeCombining.rows[0].cells[0].text == "a")
    precondition(beforeCombining.rows[0].cells[0].style == styled.style && beforeCombining.rows[0].cells[0].link == styled.link && beforeCombining.rows[0].cells[0].protected)

    // VS16 grows this glyph to two cells at the right edge and therefore
    // wraps; the retained one-cell screen must not be edited in place.
    var widthDocument = TerminalDocument(columns: 2, rows: 2)
    _ = widthDocument.print("x".unicodeScalars.first!, startsCluster: true, usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    _ = widthDocument.print("\u{00a9}".unicodeScalars.first!, startsCluster: true, usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    let beforeVS = widthDocument.primary
    _ = widthDocument.print("\u{fe0f}".unicodeScalars.first!, startsCluster: false, usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    precondition(SwiftUnicode.cellWidth(of: "©\u{fe0f}") == 2)
    precondition(beforeVS.rows[0].cells[1].text == "©")
    precondition(widthDocument.primary != beforeVS && widthDocument.primary.cursorRow == 1)

    var historyDocument = TerminalDocument(columns: 2, rows: 1)
    place("A".unicodeScalars.first!, starts: true, into: &historyDocument)
    place("B".unicodeScalars.first!, starts: true, into: &historyDocument)
    let beforeScroll = historyDocument.primary
    place("C".unicodeScalars.first!, starts: true, into: &historyDocument)
    precondition(historyDocument.history.count == 1 && historyDocument.history[0].cells[0].text == "A")
    precondition(beforeScroll.rows[0].cells[0].text == "A" && beforeScroll.rows[0].cells[1].text == "B")

    let beforeAlternate = historyDocument.alternate
    place("Z".unicodeScalars.first!, starts: true, alternate: true, into: &historyDocument)
    precondition(beforeAlternate.rows[0].cells[0].text.isEmpty)
    precondition(historyDocument.alternate.rows[0].cells[0].text == "Z")
  }

  static func rangeLocalWidePairRepairPreservesSnapshots() {
    let wideStyle = TerminalStyle(foreground: 0x0102_0304, background: 0x0506_0708, flags: 3)
    let wideLead = TerminalCell(text: "猫", kind: 2, style: wideStyle,
                                link: "https://example.test/wide", flags: 2, protected: true)
    let wideContinuation = TerminalCell(text: "", kind: 3, style: wideStyle,
                                        link: "https://example.test/wide", flags: 2, protected: true)
    let plain = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
    func overwrite(_ document: inout TerminalDocument, at column: Int, with scalar: Unicode.Scalar) {
      document.primary.cursorRow = 0; document.primary.cursorColumn = column
      _ = document.print(scalar, startsCluster: true, usingAlternate: false,
                         leftRightMargins: false, autoWrap: true, insertMode: false,
                         attributes: plain)
    }

    // Replacing either side of a pair clears only its surviving neighbour. The
    // retained screen must retain the original rich pair unchanged.
    for (column, text, expectedLead, expectedContinuation) in [(0, "A", 1, 0), (1, "B", 0, 1)] {
      var document = TerminalDocument(columns: 6, rows: 1)
      document.primary.rows[0].cells[0] = wideLead
      document.primary.rows[0].cells[1] = wideContinuation
      let before = document.primary
      overwrite(&document, at: column, with: text.unicodeScalars.first!)
      precondition(document.primary.rows[0].cells[0].kind == expectedLead)
      precondition(document.primary.rows[0].cells[1].kind == expectedContinuation)
      precondition(document.primary.rows[0].cells[column].text == text)
      precondition(document.hasValidInvariants(document.primary))
      precondition(before.rows[0].cells[0] == wideLead && before.rows[0].cells[1] == wideContinuation)
    }

    // An adjacent pair is outside the repaired edge and keeps its rich
    // metadata when the preceding continuation is overwritten.
    var adjacent = TerminalDocument(columns: 6, rows: 1)
    adjacent.primary.rows[0].cells[0] = wideLead
    adjacent.primary.rows[0].cells[1] = wideContinuation
    let secondStyle = TerminalStyle(foreground: 9, background: 10, flags: 4)
    let secondLead = TerminalCell(text: "界", kind: 2, style: secondStyle,
                                  link: "https://example.test/second", flags: 1, protected: false)
    let secondContinuation = TerminalCell(text: "", kind: 3, style: secondStyle,
                                          link: "https://example.test/second", flags: 1, protected: false)
    adjacent.primary.rows[0].cells[2] = secondLead
    adjacent.primary.rows[0].cells[3] = secondContinuation
    overwrite(&adjacent, at: 1, with: "X".unicodeScalars.first!)
    precondition(adjacent.primary.rows[0].cells[0].kind == 0)
    precondition(adjacent.primary.rows[0].cells[2] == secondLead && adjacent.primary.rows[0].cells[3] == secondContinuation)
    precondition(adjacent.hasValidInvariants(adjacent.primary))

    // A cluster can grow from one to two columns at an edge; replacing the
    // lead shrinks it back to one without leaving a continuation behind.
    var clusterGrowth = TerminalDocument(columns: 2, rows: 1)
    _ = clusterGrowth.print("©".unicodeScalars.first!, startsCluster: true, usingAlternate: false,
                        leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    let beforeGrowth = clusterGrowth.primary
    _ = clusterGrowth.print("\u{fe0f}".unicodeScalars.first!, startsCluster: false, usingAlternate: false,
                        leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    precondition(beforeGrowth.rows[0].cells[0].kind == 1)
    precondition(clusterGrowth.primary.rows[0].cells[0].kind == 2 && clusterGrowth.primary.rows[0].cells[1].kind == 3)
    overwrite(&clusterGrowth, at: 0, with: "S".unicodeScalars.first!)
    precondition(clusterGrowth.primary.rows[0].cells[0].kind == 1 && clusterGrowth.primary.rows[0].cells[1].kind == 0)
    precondition(clusterGrowth.hasValidInvariants(clusterGrowth.primary))

    // The right margin can drop a shifted continuation. Repair checks the
    // changed span's crossing neighbour, rather than scanning the whole row.
    var inserted = TerminalDocument(columns: 6, rows: 1)
    inserted.primary.leftMargin = 1; inserted.primary.rightMargin = 4
    inserted.primary.rows[0].cells[3] = wideLead
    inserted.primary.rows[0].cells[4] = wideContinuation
    let beforeInsert = inserted.primary
    inserted.primary.cursorRow = 0; inserted.primary.cursorColumn = 1
    _ = inserted.print("Z".unicodeScalars.first!, startsCluster: true, usingAlternate: false,
                       leftRightMargins: true, autoWrap: true, insertMode: true, attributes: plain)
    precondition(inserted.primary.rows[0].cells[1].text == "Z")
    precondition(inserted.primary.rows[0].cells[4].kind == 0)
    precondition(inserted.hasValidInvariants(inserted.primary))
    precondition(beforeInsert.rows[0].cells[3] == wideLead && beforeInsert.rows[0].cells[4] == wideContinuation)

    // The public delete seam still takes the full-row repair route. Its
    // resulting screen must remain valid when a deleted lead pulls a lone
    // continuation across a horizontal edit boundary.
    var deleted = TerminalDocument(columns: 6, rows: 1)
    deleted.primary.rows[0].cells[1] = wideLead
    deleted.primary.rows[0].cells[2] = wideContinuation
    let beforeDelete = deleted.primary
    var editedScreen = deleted.primary
    deleted.shift(&editedScreen, row: 0, column: 1, right: 4, count: 1,
                  inserting: false, eraseStyle: TerminalStyle())
    deleted.primary = editedScreen
    precondition(deleted.primary.rows[0].cells[1].kind == 0)
    precondition(deleted.hasValidInvariants(deleted.primary))
    precondition(beforeDelete.rows[0].cells[1] == wideLead && beforeDelete.rows[0].cells[2] == wideContinuation)

    var clipped = TerminalDocument(columns: 1, rows: 1)
    _ = clipped.print("猫".unicodeScalars.first!, startsCluster: true, usingAlternate: false,
                      leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    precondition(clipped.primary.rows[0].cells[0].kind == 1 && clipped.primary.rows[0].cells[0].flags & 1 != 0)
    precondition(clipped.hasValidInvariants(clipped.primary))
  }

  static func main() {
    let old = retainedSnapshot()
    populatedSnapshotsRemainImmutable()
    rangeLocalWidePairRepairPreservesSnapshots()
    // `document` has been destroyed. Retention is real value/COW retention,
    // not a borrowed mutable grid whose lifetime happens to extend this call.
    precondition(old.rows[0].cells[0].text.isEmpty)
    precondition(old.rows[0].cells[0].kind == 0)
    print("PASS TerminalDocument ownership: snapshots, local wide-pair repair, cluster width, margin insert and clipped cells")
  }
}

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

  static func main() {
    let old = retainedSnapshot()
    populatedSnapshotsRemainImmutable()
    // `document` has been destroyed. Retention is real value/COW retention,
    // not a borrowed mutable grid whose lifetime happens to extend this call.
    precondition(old.rows[0].cells[0].text.isEmpty)
    precondition(old.rows[0].cells[0].kind == 0)
    print("PASS TerminalDocument ownership: populated snapshots survive cluster, width, scroll, alternate mutation and destruction")
  }
}

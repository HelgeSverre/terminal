import Foundation

// This exercises the document's ownership seam directly.  An immutable
// screen value retained by a publisher must survive both an in-place document
// mutation and destruction of the mutable document without sharing edited
// rows/cells with the next snapshot.
@main enum TerminalDocumentOwnershipTests {
  static let styled = TerminalDocument.PrintAttributes(
    style: TerminalStyle(foreground: 0x0201_0203, background: 0x0204_0506, flags: 1),
    link: "https://example.test/owned", protected: true)
  static func place(_ scalar: Unicode.Scalar, alternate: Bool = false, into document: inout TerminalDocument) {
    _ = document.print(scalar, usingAlternate: alternate,
                       leftRightMargins: false, autoWrap: true, insertMode: false,
                       attributes: styled)
  }
  static func retainedSnapshot() -> TerminalScreen {
    var document = TerminalDocument(columns: 4, rows: 2)
    let old = document.primary
    _ = document.print("A".unicodeScalars.first!,
                       usingAlternate: false, leftRightMargins: false,
                       autoWrap: true, insertMode: false,
                       attributes: TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false))
    precondition(document.primary.rows[0].cells[0].text == "A")
    precondition(old.rows[0].cells[0].text.isEmpty)
    return old
  }

  static func populatedSnapshotsRemainImmutable() {
    var document = TerminalDocument(columns: 2, rows: 2)
    place("a".unicodeScalars.first!, into: &document)
    let beforeCombining = document.primary
    place("\u{301}".unicodeScalars.first!, into: &document)
    precondition(document.primary.rows[0].cells[0].text == "a\u{301}")
    precondition(beforeCombining.rows[0].cells[0].text == "a")
    precondition(beforeCombining.rows[0].cells[0].style == styled.style && beforeCombining.rows[0].cells[0].link == styled.link && beforeCombining.rows[0].cells[0].protected)

    // VS16 grows this glyph to two cells at the right edge and therefore
    // wraps; the retained one-cell screen must not be edited in place.
    var widthDocument = TerminalDocument(columns: 2, rows: 2)
    _ = widthDocument.print("x".unicodeScalars.first!, usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    _ = widthDocument.print("\u{00a9}".unicodeScalars.first!, usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    let beforeVS = widthDocument.primary
    _ = widthDocument.print("\u{fe0f}".unicodeScalars.first!, usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    precondition(SwiftUnicode.cellWidth(of: "©\u{fe0f}") == 2)
    precondition(beforeVS.rows[0].cells[1].text == "©")
    precondition(widthDocument.primary != beforeVS && widthDocument.primary.cursorRow == 1)

    var historyDocument = TerminalDocument(columns: 2, rows: 1)
    place("A".unicodeScalars.first!, into: &historyDocument)
    place("B".unicodeScalars.first!, into: &historyDocument)
    let beforeScroll = historyDocument.primary
    place("C".unicodeScalars.first!, into: &historyDocument)
    precondition(historyDocument.history.count == 1 && historyDocument.history[0].cells[0].text == "A")
    precondition(beforeScroll.rows[0].cells[0].text == "A" && beforeScroll.rows[0].cells[1].text == "B")

    let beforeAlternate = historyDocument.alternate
    historyDocument.resetPrintCluster()
    place("Z".unicodeScalars.first!, alternate: true, into: &historyDocument)
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
      document.resetPrintCluster()
      document.primary.cursorRow = 0; document.primary.cursorColumn = column
      _ = document.print(scalar, usingAlternate: false,
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
    _ = clusterGrowth.print("©".unicodeScalars.first!, usingAlternate: false,
                        leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    let beforeGrowth = clusterGrowth.primary
    _ = clusterGrowth.print("\u{fe0f}".unicodeScalars.first!, usingAlternate: false,
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
    inserted.resetPrintCluster()
    _ = inserted.print("Z".unicodeScalars.first!, usingAlternate: false,
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
    clipped.resetPrintCluster()
    _ = clipped.print("猫".unicodeScalars.first!, usingAlternate: false,
                      leftRightMargins: false, autoWrap: true, insertMode: false, attributes: styled)
    precondition(clipped.primary.rows[0].cells[0].kind == 1 && clipped.primary.rows[0].cells[0].flags & 1 != 0)
    precondition(clipped.hasValidInvariants(clipped.primary))
  }

  static func documentOwnsSegmentationAndOrphans() {
    var document = TerminalDocument(columns: 6, rows: 1)
    // Prepend must survive through the document-owned segmenter and join the
    // following ASCII scalar even though that scalar takes the width-one path.
    place("\u{0600}".unicodeScalars.first!, into: &document)
    place("A".unicodeScalars.first!, into: &document)
    precondition(document.primary.rows[0].cells[0].text == "\u{0600}A")

    document.resetPrintCluster()
    document.primary.cursorColumn = 2
    place("A".unicodeScalars.first!, into: &document)
    // U+0080 is filtered before segmentation and must neither mutate cells
    // nor split the following combining mark from A.
    precondition(document.print("\u{0080}".unicodeScalars.first!, usingAlternate: false,
                                leftRightMargins: false, autoWrap: true, insertMode: false,
                                attributes: styled) == nil)
    place("\u{301}".unicodeScalars.first!, into: &document)
    precondition(document.primary.rows[0].cells[2].text == "A\u{301}")

    // An orphan default-ignorable resets the retained owner; a subsequent
    // mark cannot silently edit the preceding rich cell.
    document.resetPrintCluster()
    document.primary.cursorColumn = 4
    place("B".unicodeScalars.first!, into: &document)
    document.resetPrintCluster()
    precondition(document.print("\u{fe0f}".unicodeScalars.first!, usingAlternate: false,
                                leftRightMargins: false, autoWrap: true, insertMode: false,
                                attributes: styled) == nil)
    place("\u{301}".unicodeScalars.first!, into: &document)
    precondition(document.primary.rows[0].cells[4].text == "B")
    precondition(document.hasValidInvariants(document.primary))
  }

  // The decoder drains this API in bounded pieces.  Keep an oracle that
  // compares every rich cell, row identity, history row and cursor outcome
  // against the scalar entry point; this catches a tempting but incorrect
  // implementation that treats a batch as an independent grapheme stream.
  static func batchWriterMatchesScalarTransactions() {
    let attributes = TerminalDocument.PrintAttributes(
      style: TerminalStyle(foreground: 0x0102_0304, background: 0x0506_0708, flags: 3),
      link: "https://example.test/batch", protected: true)
    func same(_ lhs: TerminalDocument, _ rhs: TerminalDocument) {
      precondition(lhs.primary == rhs.primary && lhs.alternate == rhs.alternate)
      precondition(lhs.history == rhs.history)
      precondition(lhs.hasValidInvariants(lhs.primary) && lhs.hasValidInvariants(lhs.alternate))
    }
    func scalar(_ values: [Unicode.Scalar], alternate: Bool, setup: (inout TerminalDocument) -> Void = { _ in }) -> (document: TerminalDocument, mutations: Int) {
      var document = TerminalDocument(columns: 2, rows: 1); setup(&document)
      var mutations = 0
      for value in values {
        if document.print(value, usingAlternate: alternate, leftRightMargins: true,
                          autoWrap: true, insertMode: true, attributes: attributes) != nil { mutations += 1 }
      }
      return (document, mutations)
    }
    func batch(_ values: [Unicode.Scalar], alternate: Bool, chunks: [Int] = [Int.max], setup: (inout TerminalDocument) -> Void = { _ in }) -> (document: TerminalDocument, mutations: Int) {
      var document = TerminalDocument(columns: 2, rows: 1); setup(&document)
      var offset = 0, mutations = 0
      var chunk = 0
      while offset < values.count {
        let end = min(values.count, offset + chunks[chunk % chunks.count])
        while offset < end {
          let effect = document.print(values[offset..<end], usingAlternate: alternate,
                                      leftRightMargins: true, autoWrap: true,
                                      insertMode: true, attributes: attributes)
          precondition(effect.consumedScalarCount > 0)
          offset += effect.consumedScalarCount; mutations += effect.mutationCount
        }
        chunk += 1
      }
      return (document, mutations)
    }
    func matches(_ values: [Unicode.Scalar], alternate: Bool, chunks: [Int] = [Int.max], setup: (inout TerminalDocument) -> Void = { _ in }) {
      let expected = scalar(values, alternate: alternate, setup: setup)
      let actual = batch(values, alternate: alternate, chunks: chunks, setup: setup)
      same(expected.document, actual.document)
      precondition(expected.mutations == actual.mutations)
    }

    // 1023/1024 crosses the Core scratch boundary.  Prepend joins the ASCII
    // that follows it, and the long combining run must preserve cap state.
    let boundary = Array((String(repeating: "x", count: 1023) + "\u{600}A" +
                          String(repeating: "\u{301}", count: 64) + "👩" + "क्‍ष").unicodeScalars)
    matches(boundary, alternate: false)
    matches(boundary, alternate: false, chunks: [1, 17, 2, 401, 3, 64, 7])
    // Controls and orphan ignorables are admitted (so stream offsets stay
    // exact) but have the same zero mutation count as scalar printing.
    matches(Array("\u{fe0f}A\u{301}\u{7}B".unicodeScalars), alternate: false)

    // Full-width primary and alternate scrolls must install replacement IDs
    // before the next bounded call; partial margins and a one-column wide
    // glyph cover the placement helper's non-scroll paths too.
    let scrolling = Array("abcdefghijkl".unicodeScalars)
    matches(scrolling, alternate: false)
    matches(scrolling, alternate: true)
    let marginSetup: (inout TerminalDocument) -> Void = { document in
      document.primary.leftMargin = 1; document.primary.rightMargin = 1
    }
    matches(Array("猫A".unicodeScalars), alternate: false, setup: marginSetup)

    var oneScalar = TerminalDocument(columns: 1, rows: 1)
    var oneBatch = TerminalDocument(columns: 1, rows: 1)
    for value in "猫A".unicodeScalars { _ = oneScalar.print(value, usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes) }
    var offset = 0; let oneValues = Array("猫A".unicodeScalars)
    while offset < oneValues.count {
      let effect = oneBatch.print(oneValues[offset...], usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
      precondition(effect.consumedScalarCount > 0); offset += effect.consumedScalarCount
    }
    same(oneScalar, oneBatch)

    // A retained rich snapshot must stay immutable after the batch updates a
    // joining cluster and then scrolls a replacement into the same screen.
    var retained = TerminalDocument(columns: 2, rows: 1)
    _ = retained.print(Array("A".unicodeScalars), usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    let primarySnapshot = retained.primary
    _ = retained.print(Array("\u{301}BC".unicodeScalars), usingAlternate: false, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    precondition(primarySnapshot.rows[0].cells[0].text == "A")
    retained.resetPrintCluster()
    let alternateSnapshot = retained.alternate
    _ = retained.print(Array("XYZ".unicodeScalars), usingAlternate: true, leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    precondition(alternateSnapshot.rows[0].cells[0].text.isEmpty)
  }

  static func main() {
    let old = retainedSnapshot()
    populatedSnapshotsRemainImmutable()
    rangeLocalWidePairRepairPreservesSnapshots()
    documentOwnsSegmentationAndOrphans()
    batchWriterMatchesScalarTransactions()
    // `document` has been destroyed. Retention is real value/COW retention,
    // not a borrowed mutable grid whose lifetime happens to extend this call.
    precondition(old.rows[0].cells[0].text.isEmpty)
    precondition(old.rows[0].cells[0].kind == 0)
    print("PASS TerminalDocument ownership: snapshots, document segmentation, batch transactions, local wide-pair repair, cluster width, margin insert and clipped cells")
  }
}

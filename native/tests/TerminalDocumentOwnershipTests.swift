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

  static func carriageReturnMutatesSelectedScreen() {
    var document = TerminalDocument(columns: 5, rows: 2)
    document.primary.leftMargin = 2; document.primary.rightMargin = 3
    document.primary.cursorColumn = 4; document.primary.pendingWrap = true
    let retainedPrimary = document.primary
    document.carriageReturn(usingAlternate: false, leftRightMargins: true)
    precondition(document.primary.cursorColumn == 2 && !document.primary.pendingWrap)
    precondition(retainedPrimary.cursorColumn == 4 && retainedPrimary.pendingWrap)

    document.alternate.leftMargin = 1; document.alternate.rightMargin = 3
    document.alternate.cursorColumn = 0; document.alternate.pendingWrap = true
    let retainedAlternate = document.alternate
    document.carriageReturn(usingAlternate: true, leftRightMargins: true)
    precondition(document.alternate.cursorColumn == 0 && !document.alternate.pendingWrap)
    precondition(retainedAlternate.cursorColumn == 0 && retainedAlternate.pendingWrap)

    document.primary.cursorColumn = 4; document.primary.pendingWrap = true
    document.carriageReturn(usingAlternate: false, leftRightMargins: false)
    precondition(document.primary.cursorColumn == 0 && !document.primary.pendingWrap)
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
      document.primary.rows[0].setCell(wideLead, at: 0)
      document.primary.rows[0].setCell(wideContinuation, at: 1)
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
    adjacent.primary.rows[0].setCell(wideLead, at: 0)
    adjacent.primary.rows[0].setCell(wideContinuation, at: 1)
    let secondStyle = TerminalStyle(foreground: 9, background: 10, flags: 4)
    let secondLead = TerminalCell(text: "界", kind: 2, style: secondStyle,
                                  link: "https://example.test/second", flags: 1, protected: false)
    let secondContinuation = TerminalCell(text: "", kind: 3, style: secondStyle,
                                          link: "https://example.test/second", flags: 1, protected: false)
    adjacent.primary.rows[0].setCell(secondLead, at: 2)
    adjacent.primary.rows[0].setCell(secondContinuation, at: 3)
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
    inserted.primary.rows[0].setCell(wideLead, at: 3)
    inserted.primary.rows[0].setCell(wideContinuation, at: 4)
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
    deleted.primary.rows[0].setCell(wideLead, at: 1)
    deleted.primary.rows[0].setCell(wideContinuation, at: 2)
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

  static func printedReplacementKeepsRichPairBoundaries() {
    let old = TerminalDocument.PrintAttributes(
      style: TerminalStyle(foreground: 1, background: 0x1111_1111, flags: 1),
      link: "https://example.test/old", protected: false)
    let replacement = TerminalDocument.PrintAttributes(
      style: TerminalStyle(foreground: 2, background: 0x2222_2222, flags: 4),
      link: "https://example.test/replacement", protected: true)
    func print(_ document: inout TerminalDocument, _ text: String,
               _ attributes: TerminalDocument.PrintAttributes) {
      for scalar in text.unicodeScalars {
        _ = document.print(scalar, usingAlternate: false, leftRightMargins: false,
                           autoWrap: true, insertMode: false, attributes: attributes)
      }
    }

    // Placing a wide lead on a continuation between two adjacent rich pairs
    // must clear both surviving outside halves, without touching a retained
    // snapshot or inheriting either old pair's metadata.
    var crossing = TerminalDocument(columns: 4, rows: 1)
    print(&crossing, "猫", old); crossing.resetPrintCluster()
    print(&crossing, "界", old); crossing.resetPrintCluster()
    let retained = crossing.primary
    crossing.primary.cursorColumn = 1; crossing.primary.pendingWrap = false
    let revision = crossing.primary.rows[0].revision
    print(&crossing, "犬", replacement)
    let row = crossing.primary.rows[0]
    precondition(row.revision == revision + 1)
    precondition(row.cells[0].kind == 0 && row.cells[0].style == replacement.style.erased())
    precondition(row.cells[1].text == "犬" && row.cells[1].kind == 2 &&
                 row.cells[1].style == replacement.style && row.cells[1].link == replacement.link &&
                 row.cells[1].protected && row.cells[1].flags & 2 != 0)
    precondition(row.cells[2].kind == 3 && row.cells[2].style == replacement.style &&
                 row.cells[2].link == replacement.link && row.cells[2].protected && row.cells[2].flags & 2 != 0)
    precondition(row.cells[3].kind == 0 && row.cells[3].style == replacement.style.erased())
    precondition(retained.rows[0].cells[0].text == "猫" && retained.rows[0].cells[2].text == "界")
    precondition(crossing.hasValidInvariants(crossing.primary))

    // Variation selectors exercise both physical widths at the same cursor.
    // Replacing a VS16-wide lead with VS15 text must clear the obsolete
    // continuation while retaining the new rich attributes.
    var variation = TerminalDocument(columns: 2, rows: 1)
    print(&variation, "©", replacement)
    print(&variation, "\u{fe0f}", replacement)
    precondition(variation.primary.rows[0].cells[0].kind == 2 && variation.primary.rows[0].cells[1].kind == 3)
    let shrinkRevision = variation.primary.rows[0].revision
    variation.resetPrintCluster(); variation.primary.cursorColumn = 0; variation.primary.pendingWrap = false
    print(&variation, "©\u{fe0e}", replacement)
    let shrunk = variation.primary.rows[0]
    precondition(shrunk.revision == shrinkRevision + 2)
    precondition(shrunk.cells[0].kind == 1)
    precondition(shrunk.cells[0].text == "©\u{fe0e}")
    precondition(shrunk.cells[0].style == replacement.style && shrunk.cells[0].link == replacement.link && shrunk.cells[0].protected)
    precondition(shrunk.cells[1].kind == 0 && shrunk.cells[1].style == replacement.style.erased())
    precondition(variation.hasValidInvariants(variation.primary))
  }

  static func documentOwnsIndexTransactions() {
    let attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(foreground: 7), link: nil, protected: false)
    var document = TerminalDocument(columns: 4, rows: 2)
    _ = document.print("A".unicodeScalars.first!, usingAlternate: false,
                       leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    document.primary.cursorRow = 1; document.primary.cursorColumn = 0; document.primary.pendingWrap = true
    let removedID = document.primary.rows[0].id
    let forward = document.index(usingAlternate: false, reverse: false,
                                 leftRightMargins: false, eraseStyle: TerminalStyle(background: 9))
    precondition(!document.primary.pendingWrap && forward == 1 && document.history.count == 1)
    precondition(document.history[0].id == removedID && document.history[0].cells[0].text == "A")
    precondition(document.primary.rows[1].id != removedID && document.primary.rows[1].cells.allSatisfy { $0.style.background == 9 })

    let alternateBefore = document.alternate
    document.alternate.cursorRow = 1; document.alternate.cursorColumn = 0
    let alternate = document.index(usingAlternate: true, reverse: false,
                                   leftRightMargins: false, eraseStyle: TerminalStyle())
    precondition(alternate == 0 && document.history.count == 1)
    precondition(alternateBefore.rows[0].id != document.alternate.rows[1].id)

    document.primary.cursorRow = 0; document.primary.cursorColumn = 0
    let reverse = document.index(usingAlternate: false, reverse: true,
                                 leftRightMargins: false, eraseStyle: TerminalStyle())
    precondition(reverse == 0 && document.history.count == 1)
    precondition(document.hasValidInvariants(document.primary) && document.hasValidInvariants(document.alternate))

    document.primary.leftMargin = 1; document.primary.rightMargin = 2
    document.primary.cursorRow = 1; document.primary.cursorColumn = 1
    let partial = document.index(usingAlternate: false, reverse: false,
                                 leftRightMargins: true, eraseStyle: TerminalStyle(background: 3))
    precondition(partial == 0 && document.history.count == 1)
    precondition(document.primary.rows[1].cells[1].style.background == 3 && document.primary.rows[1].cells[2].style.background == 3)
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

  static func asciiSpanMatchesScalarTransactions() {
    let attributes = TerminalDocument.PrintAttributes(
      style: TerminalStyle(foreground: 0x0102_0304, background: 0x0506_0708, flags: 1),
      link: "https://example.test/ascii-span", protected: true)
    func compare(_ values: [Unicode.Scalar], columns: Int = 4, rows: Int = 1,
                 leftRightMargins: Bool = false, autoWrap: Bool = true, insertMode: Bool = false,
                 configure: (inout TerminalDocument) -> Void = { _ in }) -> TerminalDocument.PrintBatchEffect {
      var scalar = TerminalDocument(columns: columns, rows: rows); configure(&scalar)
      var batch = TerminalDocument(columns: columns, rows: rows); configure(&batch)
      var scalarMutations = 0
      for value in values {
        if scalar.print(value, usingAlternate: false, leftRightMargins: leftRightMargins,
                        autoWrap: autoWrap, insertMode: insertMode, attributes: attributes) != nil {
          scalarMutations += 1
        }
      }
      var offset = 0, batchMutations = 0
      var last = TerminalDocument.PrintBatchEffect(
        effect: .init(appendedHistoryCount: 0, lastPrinted: nil, repeatAttributes: nil),
        consumedScalarCount: 0, mutationCount: 0)
      while offset < values.count {
        last = batch.print(values[offset...], usingAlternate: false, leftRightMargins: leftRightMargins,
                           autoWrap: autoWrap, insertMode: insertMode, attributes: attributes)
        precondition(last.consumedScalarCount > 0)
        offset += last.consumedScalarCount; batchMutations += last.mutationCount
      }
      precondition(batch.primary == scalar.primary && batch.alternate == scalar.alternate && batch.history == scalar.history)
      precondition(batchMutations == scalarMutations)
      precondition(batch.hasValidInvariants(batch.primary))
      return last
    }

    let ordinary = compare(Array("ABCD".unicodeScalars))
    precondition(ordinary.effect.lastPrinted == "D" && ordinary.effect.repeatAttributes?.link == attributes.link)
    // Prepend makes the first ASCII scalar a continuation; it must go through
    // the scalar transaction before a later fresh ASCII may be admitted.
    _ = compare(Array("\u{600}ABC".unicodeScalars))
    // The final ASCII owns a following combining mark after the span seeds
    // segmenter/open-cluster state from that final scalar.
    _ = compare(Array("ABC\u{301}".unicodeScalars))
    _ = compare(Array("ABCDEFG".unicodeScalars), autoWrap: false)
    _ = compare(Array("ABCD".unicodeScalars), insertMode: true)
    _ = compare(Array("ABC".unicodeScalars), columns: 5, leftRightMargins: true,
                configure: { document in document.primary.leftMargin = 1; document.primary.rightMargin = 3; document.primary.cursorColumn = 1 })

    // The first ordinary ASCII replacement lands on a continuation, then the
    // admitted B/C span crosses the lead of a second rich pair. Both external
    // surviving halves must clear with the replacement's metadata, while a
    // retained screen retains its original rich pairs unchanged.
    let old = TerminalDocument.PrintAttributes(
      style: TerminalStyle(foreground: 9, background: 0x1111_1111, flags: 4),
      link: "https://example.test/ascii-span-old", protected: false)
    func prepopulate(_ document: inout TerminalDocument) {
      for text in ["猫", "X", "界"] {
        for scalar in text.unicodeScalars {
          _ = document.print(scalar, usingAlternate: false, leftRightMargins: false,
                             autoWrap: true, insertMode: false, attributes: old)
        }
        document.resetPrintCluster()
      }
      document.primary.cursorColumn = 1; document.primary.pendingWrap = false
    }
    var scalarCrossing = TerminalDocument(columns: 6, rows: 1); prepopulate(&scalarCrossing)
    var spanCrossing = TerminalDocument(columns: 6, rows: 1); prepopulate(&spanCrossing)
    let retainedCrossing = spanCrossing.primary
    for scalar in "ABC".unicodeScalars {
      _ = scalarCrossing.print(scalar, usingAlternate: false, leftRightMargins: false,
                               autoWrap: true, insertMode: false, attributes: attributes)
    }
    let crossingEffect = spanCrossing.print(Array("ABC".unicodeScalars), usingAlternate: false,
                                             leftRightMargins: false, autoWrap: true,
                                             insertMode: false, attributes: attributes)
    precondition(crossingEffect.consumedScalarCount == 3 && crossingEffect.mutationCount == 3)
    precondition(spanCrossing.primary == scalarCrossing.primary)
    let crossing = spanCrossing.primary.rows[0]
    precondition(crossing.cells[0].kind == 0 && crossing.cells[0].style == attributes.style.erased())
    for (column, text) in [(1, "A"), (2, "B"), (3, "C")] {
      precondition(crossing.cells[column].text == text && crossing.cells[column].kind == 1 &&
                   crossing.cells[column].style == attributes.style && crossing.cells[column].link == attributes.link &&
                   crossing.cells[column].protected && crossing.cells[column].flags & 2 != 0)
    }
    precondition(crossing.cells[4].kind == 0 && crossing.cells[4].style == attributes.style.erased())
    precondition(retainedCrossing.rows[0].cells[0].text == "猫" && retainedCrossing.rows[0].cells[3].text == "界")
    precondition(spanCrossing.hasValidInvariants(spanCrossing.primary))

    // The alternate screen also takes the generic collection transaction;
    // retain it before an ASCII span to make its COW contract explicit.
    let retainedAlternate = spanCrossing.alternate
    _ = spanCrossing.print(Array("XYZ".unicodeScalars), usingAlternate: true,
                           leftRightMargins: false, autoWrap: true, insertMode: false,
                           attributes: attributes)
    precondition(retainedAlternate.rows[0].cells.allSatisfy { $0.kind == 0 })

    // A span may fill a row, but the following scalar still owns the wrap and
    // must report its history append before further admission.
    var history = TerminalDocument(columns: 2, rows: 1)
    let yielded = history.print(Array("ABCD".unicodeScalars), usingAlternate: false,
                                leftRightMargins: false, autoWrap: true, insertMode: false,
                                attributes: attributes)
    precondition(yielded.consumedScalarCount == 3 && yielded.mutationCount == 3)
    precondition(yielded.effect.appendedHistoryCount == 1 && history.history.count == 1)
    precondition(history.history[0].cells[0].text == "A" && history.history[0].cells[1].text == "B")
  }

  static func alternateMultiwrapBatchDoesNotYieldForReplacements() {
    let attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(foreground: 3),
                                                      link: "https://example.test/alternate", protected: true)
    let offered = Array((String(repeating: "abcdef", count: 5) + "界e\u{301}XYZ").unicodeScalars)
    var batch = TerminalDocument(columns: 3, rows: 2)
    var scalar = TerminalDocument(columns: 3, rows: 2)
    let retained = batch.alternate
    let retainedCells = batch.alternate.rows[0].cells
    let effect = batch.print(offered, usingAlternate: true, leftRightMargins: false,
                             autoWrap: true, insertMode: false, attributes: attributes)
    for value in offered {
      _ = scalar.print(value, usingAlternate: true, leftRightMargins: false,
                       autoWrap: true, insertMode: false, attributes: attributes)
    }
    precondition(effect.consumedScalarCount == offered.count && effect.mutationCount == offered.count)
    precondition(effect.effect.appendedHistoryCount == 0 && batch.history.isEmpty)
    precondition(batch.alternate == scalar.alternate)
    precondition(batch.alternate.rows.allSatisfy { $0.id != 0 })
    precondition(retained.rows.allSatisfy { $0.cells.allSatisfy { $0.kind == 0 } })
    precondition(retainedCells.allSatisfy { $0.kind == 0 })
  }

  static func appendCountsPreserveYieldAndIdentities() {
    let attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
    for columns in 1...2 {
      var document = TerminalDocument(columns: columns, rows: 1)
      _ = document.print(Array(String(repeating: "A", count: columns).unicodeScalars), usingAlternate: false,
                         leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
      let oldID = document.primary.rows[0].id
      let nextID = max(oldID, document.alternate.rows[0].id) + 1
      let result = document.print(Array("界Z".unicodeScalars), usingAlternate: false,
                                  leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
      precondition(result.consumedScalarCount == 1 && result.mutationCount == 1)
      precondition(result.effect.appendedHistoryCount == 1 && document.history.count == 1)
      precondition(document.history[0].id == oldID && document.primary.rows[0].id == nextID)
      precondition(document.primary.rows[0].cells[0].text == "界")
      precondition(document.hasValidInvariants(document.primary))
      _ = document.index(usingAlternate: false, reverse: false, leftRightMargins: false, eraseStyle: TerminalStyle())
      precondition(document.primary.rows[0].id == nextID + 1)
    }
    var growth = TerminalDocument(columns: 2, rows: 1)
    _ = growth.print(Array("A©".unicodeScalars), usingAlternate: false, leftRightMargins: false,
                     autoWrap: true, insertMode: false, attributes: attributes)
    let nextID = max(growth.primary.rows[0].id, growth.alternate.rows[0].id) + 1
    let result = growth.print(Array("\u{fe0f}Z".unicodeScalars), usingAlternate: false, leftRightMargins: false,
                              autoWrap: true, insertMode: false, attributes: attributes)
    precondition(result.consumedScalarCount == 1 && result.effect.appendedHistoryCount == 1)
    precondition(growth.history.count == 1 && growth.primary.rows[0].id == nextID)
    precondition(growth.primary.rows[0].cells[0].text == "©\u{fe0f}" && growth.primary.rows[0].cells[1].kind == 3)
    _ = growth.index(usingAlternate: false, reverse: false, leftRightMargins: false, eraseStyle: TerminalStyle())
    precondition(growth.primary.rows[0].id == nextID + 1)
  }

  static func discardedAlternateReuseRespectsSnapshots() {
    func identity(_ row: TerminalRow) -> ObjectIdentifier {
      let value = Mirror(reflecting: row).children.first { $0.label == "storage" }!.value
      return ObjectIdentifier(value as AnyObject)
    }
    let rich = TerminalCell(text: "a\u{301}", kind: 1, style: TerminalStyle(background: 9),
                            link: "https://example.test/reuse", flags: 2, protected: true)
    var unique = TerminalRow(id: 7, cells: [rich, rich, rich])
    let uniqueIdentity = identity(unique)
    unique.resetForReuse(columns: 3, logicalCellCapacity: unique.retainedCellCapacity,
                         style: TerminalStyle(background: 4), id: 8)
    precondition(identity(unique) == uniqueIdentity && unique.id == 8 && unique.revision == 0 && !unique.softWrapped)
    precondition(unique.cells.allSatisfy { $0.text.isEmpty && $0.kind == 0 && $0.link == nil && !$0.protected && $0.flags == 0 && $0.style.background == 4 })
    var shared = TerminalRow(id: 9, cells: [rich, rich, rich])
    let retained = shared; let cells = shared.cells
    let sharedIdentity = identity(shared)
    shared.resetForReuse(columns: 3, logicalCellCapacity: shared.retainedCellCapacity,
                         style: TerminalStyle(), id: 10)
    precondition(identity(shared) != sharedIdentity)
    precondition(retained.cells[0] == rich && cells[0] == rich)

    let attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
    var document = TerminalDocument(columns: 2, rows: 1)
    let recycledIdentity = identity(document.alternate.rows[0])
    _ = document.print(Array("ABC".unicodeScalars), usingAlternate: true,
                       leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    precondition(identity(document.alternate.rows[0]) == recycledIdentity && document.alternate.rows[0].id != 0)

    var snapshotDocument = TerminalDocument(columns: 2, rows: 1)
    let priorIdentity = identity(snapshotDocument.alternate.rows[0])
    let screen = snapshotDocument.alternate
    let projection = snapshotDocument.alternate.rows[0].cells
    _ = snapshotDocument.print(Array("ABC".unicodeScalars), usingAlternate: true,
                               leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    precondition(identity(snapshotDocument.alternate.rows[0]) != priorIdentity)
    precondition(screen.rows[0].cells.allSatisfy { $0.kind == 0 } && projection.allSatisfy { $0.kind == 0 })

    var indexed = TerminalDocument(columns: 3, rows: 1)
    indexed.alternate.rows[0].setCell(rich, at: 0)
    let indexIdentity = identity(indexed.alternate.rows[0])
    let beforeID = indexed.alternate.rows[0].id
    _ = indexed.index(usingAlternate: true, reverse: false, leftRightMargins: false,
                      eraseStyle: TerminalStyle(background: 6))
    let forwardID: UInt64
    do {
      let forward = indexed.alternate.rows[0]
      precondition(identity(forward) == indexIdentity && forward.id != beforeID && forward.revision == 0 && !forward.softWrapped)
      precondition(forward.retainedStorageCost == 32 + UInt64(forward.retainedCellCapacity) * 64)
      precondition(forward.cells.allSatisfy { $0.text.isEmpty && $0.kind == 0 && $0.link == nil && !$0.protected && $0.flags == 0 && $0.style.background == 6 })
      forwardID = forward.id
    }
    _ = indexed.index(usingAlternate: true, reverse: true, leftRightMargins: false,
                      eraseStyle: TerminalStyle(background: 7))
    let reverse = indexed.alternate.rows[0]
    precondition(identity(reverse) == indexIdentity && reverse.id != forwardID && reverse.revision == 0)
    precondition(reverse.cells.allSatisfy { $0.style.background == 7 && $0.kind == 0 })
  }

  static func evictedPrimaryReuseRespectsSnapshots() {
    final class WeakStorage {
      weak var value: AnyObject?
      init(_ value: AnyObject) { self.value = value }
    }
    func storage(_ row: TerminalRow) -> AnyObject {
      Mirror(reflecting: row).children.first { $0.label == "storage" }!.value as AnyObject
    }
    func identity(_ row: TerminalRow) -> ObjectIdentifier { ObjectIdentifier(storage(row)) }
    let attributes = TerminalDocument.PrintAttributes(style: TerminalStyle(background: 7),
                                                       link: "https://example.test/retired", protected: true)
    func print(_ text: String, into document: inout TerminalDocument) {
      _ = document.print(Array(text.unicodeScalars), usingAlternate: false,
                         leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    }
    var document = TerminalDocument(columns: 3, rows: 1)
    print("abcD", into: &document)
    let evictedID = document.history[0].id
    let evictedStorage = identity(document.history[0])
    let liveStorage = WeakStorage(storage(document.history[0]))
    precondition(document.trimHistory(rowLimit: 0, byteLimit: 0) == 1)
    precondition(document.history.isEmpty && document.history.byteCount == 0)
    // The single evicted row stays alive without retaining it in this test.
    // This fails on the former allocate-every-primary-wrap implementation.
    precondition(liveStorage.value != nil)
    print("EFG", into: &document)
    precondition(identity(document.primary.rows[0]) == evictedStorage)
    precondition(document.primary.rows[0].id != evictedID && !document.primary.rows[0].softWrapped)
    precondition(document.primary.rows[0].cells[0].text == "G")
    precondition(document.primary.rows[0].cells.dropFirst().allSatisfy {
      $0.text.isEmpty && $0.link == nil && $0.flags == 0 && !$0.protected && $0.style.background == 7
    })
    precondition(document.history.count == 1 && document.history[0].cells.map(\.text) == ["D", "E", "F"])
    precondition(document.history.byteCount == document.history[0].retainedStorageCost)

    // Keeping the result alive must not keep the appended row alive. Core
    // needs only the admission count; the document owns the retained value.
    var heldResult = TerminalDocument(columns: 3, rows: 1)
    let result = heldResult.print(Array("abcD".unicodeScalars), usingAlternate: false,
                                   leftRightMargins: false, autoWrap: true, insertMode: false, attributes: attributes)
    let resultStorage = identity(heldResult.history[0])
    _ = heldResult.trimHistory(rowLimit: 0, byteLimit: 0)
    print("EFG", into: &heldResult)
    withExtendedLifetime(result) {
      precondition(identity(heldResult.primary.rows[0]) == resultStorage)
      precondition(result.effect.appendedHistoryCount == 1 && result.effect.lastPrinted == "D")
    }

    var shared = TerminalDocument(columns: 3, rows: 1)
    print("abcD", into: &shared)
    let heldHistory = shared.history
    let heldCells = shared.history[0].cells
    let sharedStorage = identity(shared.history[0])
    _ = shared.trimHistory(rowLimit: 0, byteLimit: 0)
    print("EFG", into: &shared)
    precondition(identity(shared.primary.rows[0]) != sharedStorage)
    precondition(heldHistory[0].cells.map(\.text) == ["a", "b", "c"])
    precondition(heldCells.map(\.text) == ["a", "b", "c"])
    precondition(heldHistory.byteCount == heldHistory[0].retainedStorageCost)

    var indexed = TerminalDocument(columns: 3, rows: 1)
    print("abcD", into: &indexed)
    let indexStorage = identity(indexed.history[0])
    _ = indexed.trimHistory(rowLimit: 0, byteLimit: 0)
    _ = indexed.index(usingAlternate: false, reverse: false, leftRightMargins: false,
                      eraseStyle: TerminalStyle(background: 9))
    precondition(identity(indexed.primary.rows[0]) == indexStorage)
    precondition(indexed.primary.rows[0].revision == 0 && !indexed.primary.rows[0].softWrapped)
    precondition(indexed.primary.rows[0].cells.allSatisfy {
      $0.text.isEmpty && $0.kind == 0 && $0.link == nil && $0.flags == 0 && !$0.protected && $0.style.background == 9
    })
    precondition(indexed.primary.rows[0].retainedStorageCost == 32 + UInt64(indexed.primary.rows[0].retainedCellCapacity) * 64)

    // Geometry changes consume the same bounded cache but allocate a correctly
    // shaped row; clearHistory releases even that one retirement candidate.
    _ = indexed.trimHistory(rowLimit: 0, byteLimit: 0)
    indexed.setSize(columns: 4, rows: 1)
    let resized = indexed.eraseRow(TerminalStyle(background: 5))
    precondition(resized.count == 4 && resized.cells.allSatisfy { $0.kind == 0 && $0.style.background == 5 })
    var clearing = TerminalDocument(columns: 3, rows: 1)
    print("abcD", into: &clearing)
    let clearedStorage = WeakStorage(storage(clearing.history[0]))
    _ = clearing.trimHistory(rowLimit: 0, byteLimit: 0)
    precondition(clearedStorage.value != nil)
    clearing.clearHistory()
    precondition(clearedStorage.value == nil)

    // A large trim keeps exactly one candidate, not the entire evicted prefix.
    var many = TerminalDocument(columns: 3, rows: 1)
    var oldOwners: [WeakStorage] = []
    for _ in 0..<8 {
      _ = many.index(usingAlternate: false, reverse: false, leftRightMargins: false, eraseStyle: TerminalStyle())
      oldOwners.append(WeakStorage(storage(many.history.last!)))
    }
    precondition(many.trimHistory(rowLimit: 0, byteLimit: 0) == 8)
    precondition(oldOwners.dropLast().allSatisfy { $0.value == nil } && oldOwners.last!.value != nil)

    // After warmup, repeated cap-pressure LF alternates two storage objects.
    // These IDs do not retain storage and therefore cannot manufacture COW.
    var steady = TerminalDocument(columns: 512, rows: 1)
    var owners: Set<ObjectIdentifier> = [identity(steady.primary.rows[0])]
    for _ in 0..<2_000 {
      _ = steady.index(usingAlternate: false, reverse: false, leftRightMargins: false, eraseStyle: TerminalStyle())
      owners.insert(identity(steady.primary.rows[0]))
      precondition(steady.trimHistory(rowLimit: 0, byteLimit: 0) == 1)
    }
    precondition(owners.count == 2)

    // Row count alone is not a memory bound: distinct OSC 8 links can make
    // even a narrow row expensive. Its cached history charge must reject it
    // without keeping the row or scanning its cells again during eviction.
    var oversized = TerminalHistory()
    func appendLinkedRow(to history: inout TerminalHistory) -> WeakStorage {
      var row = TerminalRow(columns: 64)
      for column in 0..<64 {
        let suffix = String(column)
        let link = String(repeating: "x", count: 8192 - suffix.utf8.count) + suffix
        row.setCell(TerminalCell(text: "x", kind: 1, link: link), at: column)
      }
      precondition(row.retainedStorageCost > 256 * 1024)
      let reference = WeakStorage(storage(row))
      history.append(row)
      return reference
    }
    let oversizedStorage = appendLinkedRow(to: &oversized)
    precondition(oversizedStorage.value != nil)
    precondition(oversized.trim(rows: 0, bytes: 0) == 1 && oversized.byteCount == 0)
    precondition(oversizedStorage.value == nil)
  }

  static func historyOwnerChargesAndTrimsOnce() {
    var history = TerminalHistory()
    let row = TerminalRow(columns: 3)
    history.append(row); history.append(row); history.append(row)
    let charge = row.retainedStorageCost
    precondition(history.byteCount == charge * 3 && history.count == 3)
    let retained = history[0]
    precondition(history.trim(rows: 10, bytes: Int(charge * 2)) == 1)
    precondition(history.count == 2 && history.byteCount == charge * 2 && retained == row)
    precondition(history.trim(rows: 10, bytes: Int(charge * 2 - 1)) == 1)
    precondition(history.count == 1 && history.byteCount == charge)
    precondition(history.trim(rows: 0, bytes: 0) == 1 && history.count == 0 && history.byteCount == 0)
    history.replace([row, row]); precondition(history.byteCount == charge * 2)
    history.removeAll(); precondition(history.count == 0 && history.byteCount == 0)
  }

  static func scalarStorageChargesUTF8WithoutRichText() {
    for (text, size) in [("A", 1), ("¢", 2), ("猫", 3), ("😀", 4)] {
      var row = TerminalRow(columns: 1)
      row.setCell(TerminalCell(text: text, kind: 1), at: 0)
      precondition(row.payloadCount == 0)
      precondition(row.retainedStorageCost == 32 + UInt64(row.retainedCellCapacity) * 64 + UInt64(size))
    }
  }

  static func historyOwnerRetainsSnapshotsAndHeterogeneousBoundaries() {
    var plain = TerminalRow(columns: 2)
    plain.setCell(TerminalCell(text: "A", kind: 1), at: 0)
    var rich = TerminalRow(columns: 2)
    rich.setCell(TerminalCell(text: "a\u{301}", kind: 1, style: TerminalStyle(background: 7),
                              link: "https://example.test/history", flags: 2, protected: true), at: 0)
    let plainCost = plain.retainedStorageCost, richCost = rich.retainedStorageCost
    var history = TerminalHistory(); history.append(plain); history.append(rich); history.append(plain)
    let retained = history
    precondition(history.trim(rows: 10, bytes: Int(richCost + plainCost)) == 1)
    precondition(history.rows == [rich, plain] && history.byteCount == richCost + plainCost)
    history.append(rich)
    precondition(retained.rows == [plain, rich, plain] && retained.byteCount == plainCost * 2 + richCost)
    var exact = TerminalHistory(); exact.append(plain); exact.append(rich)
    let total = exact.byteCount
    precondition(exact.trim(rows: 10, bytes: Int(total)) == 0)
    precondition(exact.trim(rows: 10, bytes: Int(total - 1)) == 1)
    precondition(exact.rows == [rich] && exact.byteCount == richCost)

    var fifo = TerminalHistory()
    for id in 1...600 {
      var row = plain; row.id = UInt64(id); fifo.append(row)
    }
    let snapshot = fifo
    precondition(fifo.trim(rows: 300, bytes: Int.max) == 300)
    precondition(fifo.count == 300 && fifo.byteCount == plainCost * 300)
    precondition(snapshot.count == 600 && snapshot.byteCount == plainCost * 600)
    precondition(fifo[0].id == 301 && fifo[299].id == 600 && snapshot[0].id == 1 && snapshot[599].id == 600)
    var appended = plain; appended.id = 601; fifo.append(appended)
    precondition(fifo.count == 301 && fifo[300].id == 601 && snapshot.count == 600 && snapshot[599].id == 600)
    fifo.removeAll(); precondition(fifo.isEmpty && fifo.byteCount == 0)
    fifo.replace([rich, plain]); precondition(fifo.rows == [rich, plain] && fifo.byteCount == richCost + plainCost)
  }

  static func historyRowIdentityIndexTracksTrimCompactionAndReplacement() {
    var row = TerminalRow(columns: 1)
    var history = TerminalHistory()
    for id in 1...600 { row.id = UInt64(id); history.append(row) }
    precondition(history.index(ofRowID: 1) == 0 && history.index(ofRowID: 600) == 599)
    precondition(history.index(ofRowID: 0) == nil)

    // Removing half the entries compacts the consumed front and reindexes the
    // retained absolute slots exactly once.
    precondition(history.trim(rows: 300, bytes: Int.max) == 300)
    precondition(history.index(ofRowID: 1) == nil && history.index(ofRowID: 301) == 0)
    precondition(history.index(ofRowID: 600) == 299)

    // A non-compacting front trim still converts the maintained absolute slot
    // to a logical history index.
    precondition(history.trim(rows: 260, bytes: Int.max) == 40)
    precondition(history.index(ofRowID: 341) == 0 && history.index(ofRowID: 600) == 259)
    row.id = 601; history.append(row)
    precondition(history.index(ofRowID: 601) == 260)

    row.id = 900; let replacement = row
    history.replace([replacement])
    precondition(history.index(ofRowID: 341) == nil && history.index(ofRowID: 900) == 0)
    history.removeAll()
    precondition(history.index(ofRowID: 900) == nil)

    // The runtime assigns unique IDs, but fixture mistakes must not let a
    // retired duplicate remove the newer entry's maintained lookup.
    var duplicate = TerminalHistory()
    row.id = 42; duplicate.append(row); duplicate.append(row)
    precondition(duplicate.trim(rows: 1, bytes: Int.max) == 1)
    precondition(duplicate.index(ofRowID: 42) == 0)
  }

  static func sparsePayloadsBoundStorageAndKeepLogicalBudget() {
    var row = TerminalRow(columns: 3)
    // Scalar text has no retained String payload; only the exceptional link
    // does. The logical charge remains the pre-slot row/cell contract.
    row.setScalar("A".unicodeScalars.first!, at: 0, kind: 1, style: TerminalStyle(),
                  link: nil, flags: 0, protected: false)
    precondition(row.payloadCount == 0)
    precondition(row.retainedStorageCost == 32 + 3 * 64 + 1)

    for turn in 0..<128 {
      let link = "https://example.test/link/\(turn)"
      row.setScalar("B".unicodeScalars.first!, at: turn % row.count, kind: 1,
                    style: TerminalStyle(), link: link, flags: 0, protected: false)
      precondition(row.payloadCount <= row.count)
    }
    for column in 0..<row.count { row.erase(at: column) }
    precondition(row.payloadCount == 0)
    precondition(row.retainedStorageCost == 32 + 3 * 64)

    row.setCell(TerminalCell(text: "a\u{301}", kind: 1, style: TerminalStyle(),
                             link: "https://example.test/cluster"), at: 1)
    precondition(row.payloadCount == 1 && row.cell(1).text == "a\u{301}")
    row.truncate(to: 1)
    precondition(row.payloadCount == 0 && row.count == 1)
  }

  static func logicalCapacityMatchesFormerRichArray() {
    // Array capacity is part of history admission, not an implementation
    // detail. Exercise awkward widths plus shrink/regrow against the actual
    // pre-slot element type so allocator rounding stays byte-for-byte stable.
    for width in [1, 2, 3, 4, 7, 17, 80] {
      var rich = Array(repeating: TerminalCell(), count: width)
      var row = TerminalRow(columns: width)
      func expected() -> UInt64 { 32 + UInt64(rich.capacity) * 64 }
      precondition(row.retainedStorageCost == expected())

      let shrunk = max(1, width / 2)
      rich = Array(rich.prefix(shrunk)); row.truncate(to: shrunk)
      precondition(row.retainedStorageCost == expected())

      let growth = width + 5
      rich.append(contentsOf: repeatElement(TerminalCell(), count: growth - shrunk))
      row.appendBlanks(growth - shrunk)
      precondition(row.retainedStorageCost == expected())

      row.setCell(TerminalCell(text: "é", kind: 1, style: TerminalStyle(), link: "https://example.test"), at: 0)
      precondition(row.retainedStorageCost == expected() + 2 + 20)
    }
  }

  static func richPayloadMovesAndProjectionsRemainIndependent() {
    let first = TerminalCell(text: "a\u{301}", kind: 1,
                             style: TerminalStyle(foreground: 1, background: 2, flags: 3),
                             link: "https://example.test/first", flags: 2, protected: true)
    let second = TerminalCell(text: "o\u{308}", kind: 1,
                              style: TerminalStyle(foreground: 4, background: 5, flags: 6),
                              link: "https://example.test/second", flags: 4, protected: false)
    let third = TerminalCell(text: "n\u{303}", kind: 1,
                             style: TerminalStyle(foreground: 7, background: 8, flags: 9),
                             link: "https://example.test/third", flags: 6, protected: true)
    var document = TerminalDocument(columns: 6, rows: 2)
    document.primary.rows[0].setCell(first, at: 1)
    document.primary.rows[0].setCell(second, at: 3)
    document.primary.rows[1].setCell(third, at: 1)
    let originalRow = document.primary.rows[0]
    let originalCells = document.primary.rows[0].cells

    var screen = document.primary
    document.shift(&screen, row: 0, column: 1, right: 5, count: 1,
                   inserting: true, eraseStyle: TerminalStyle())
    precondition(screen.rows[0].cell(2) == first && screen.rows[0].cell(4) == second)
    document.shift(&screen, row: 0, column: 1, right: 5, count: 1,
                   inserting: false, eraseStyle: TerminalStyle())
    precondition(screen.rows[0].cell(1) == first && screen.rows[0].cell(3) == second)

    document.scrollRectangle(&screen, top: 0, bottom: 1, left: 0, right: 5,
                             count: 1, up: true, eraseStyle: TerminalStyle())
    precondition(screen.rows[0].cell(1) == third && screen.rows[0].payloadCount == 1)
    precondition(screen.rows[1].payloadCount == 0)
    document.primary = screen
    document.primary.cursorRow = 0; document.primary.cursorColumn = 1
    _ = document.print("X".unicodeScalars.first!, usingAlternate: false,
                       leftRightMargins: false, autoWrap: true, insertMode: false,
                       attributes: TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false))
    precondition(document.primary.rows[0].payloadCount == 0)
    let shrunk = document.resize(document.primary, columns: 1, rows: 2)
    precondition(shrunk.rows[0].payloadCount == 0)

    // Both a row value and its read-only Cells view retain their original
    // slot/payload values after all later edits.
    precondition(originalRow.cell(1) == first && originalRow.cell(3) == second)
    precondition(originalCells[1] == first && originalCells[3] == second)

    var composed = TerminalRow(columns: 1)
    var decomposed = TerminalRow(columns: 1)
    composed.setCell(TerminalCell(text: "é", kind: 1), at: 0)
    decomposed.setCell(TerminalCell(text: "e\u{301}", kind: 1), at: 0)
    precondition(composed == decomposed, "row equality must retain String canonical semantics")
  }

  static func main() {
    let old = retainedSnapshot()
    populatedSnapshotsRemainImmutable()
    carriageReturnMutatesSelectedScreen()
    rangeLocalWidePairRepairPreservesSnapshots()
    printedReplacementKeepsRichPairBoundaries()
    documentOwnsIndexTransactions()
    documentOwnsSegmentationAndOrphans()
    batchWriterMatchesScalarTransactions()
    asciiSpanMatchesScalarTransactions()
    alternateMultiwrapBatchDoesNotYieldForReplacements()
    discardedAlternateReuseRespectsSnapshots()
    evictedPrimaryReuseRespectsSnapshots()
    appendCountsPreserveYieldAndIdentities()
    historyOwnerChargesAndTrimsOnce()
    scalarStorageChargesUTF8WithoutRichText()
    historyOwnerRetainsSnapshotsAndHeterogeneousBoundaries()
    historyRowIdentityIndexTracksTrimCompactionAndReplacement()
    sparsePayloadsBoundStorageAndKeepLogicalBudget()
    logicalCapacityMatchesFormerRichArray()
    richPayloadMovesAndProjectionsRemainIndependent()
    // `document` has been destroyed. Retention is real value/COW retention,
    // not a borrowed mutable grid whose lifetime happens to extend this call.
    precondition(old.rows[0].cells[0].text.isEmpty)
    precondition(old.rows[0].cells[0].kind == 0)
    print("PASS TerminalDocument ownership: snapshots, document segmentation, batch transactions, local wide-pair repair, cluster width, margin insert and clipped cells")
  }
}

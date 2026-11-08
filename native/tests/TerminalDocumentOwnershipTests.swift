import Foundation

// This exercises the document's ownership seam directly.  An immutable
// screen value retained by a publisher must survive both an in-place document
// mutation and destruction of the mutable document without sharing edited
// rows/cells with the next snapshot.
@main enum TerminalDocumentOwnershipTests {
  static func retainedSnapshot() -> TerminalScreen {
    var document = TerminalDocument(columns: 4, rows: 2)
    let old = document.primary
    _ = document.placeASCII("A", usingAlternate: false, leftRightMargins: false,
                            autoWrap: true, insertMode: false, style: TerminalStyle(),
                            link: nil, protected: false)
    precondition(document.primary.rows[0].cells[0].text == "A")
    precondition(old.rows[0].cells[0].text.isEmpty)
    return old
  }

  static func main() {
    let old = retainedSnapshot()
    // `document` has been destroyed. Retention is real value/COW retention,
    // not a borrowed mutable grid whose lifetime happens to extend this call.
    precondition(old.rows[0].cells[0].text.isEmpty)
    precondition(old.rows[0].cells[0].kind == 0)
    print("PASS TerminalDocument ownership: retained snapshot survives mutation and destruction")
  }
}

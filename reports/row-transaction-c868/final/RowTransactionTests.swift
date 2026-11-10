import Foundation

enum RowTransactionTests {
  static func printAll(_ text: String, document: inout TerminalDocument,
                       attributes: TerminalDocument.PrintAttributes, insert: Bool, wrap: Bool,
                       scalarwise: Bool) {
    let scalars = Array(text.unicodeScalars)
    var offset = 0
    while offset < scalars.count {
      let end = scalarwise ? offset + 1 : scalars.count
      let result = document.print(scalars[offset..<end], usingAlternate: false,
        leftRightMargins: false, autoWrap: wrap, insertMode: insert, attributes: attributes)
      precondition(result.consumedScalarCount > 0)
      offset += result.consumedScalarCount
    }
  }
  static func main() {
    let plain = TerminalDocument.PrintAttributes(style: TerminalStyle(), link: nil, protected: false)
    var untouched = TerminalDocument(columns: 32, rows: 4)
    let retained = untouched.primary
    let address = retained.rows.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) }
    for value in ["\u{200b}", "\u{fe0f}", "\u{200d}", "\u{7}\r\n"] {
      let result = untouched.print(value.unicodeScalars, usingAlternate: false,
        leftRightMargins: false, autoWrap: true, insertMode: false, attributes: plain)
      precondition(result.mutationCount == 0)
      precondition(untouched.primary.rows.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) } == address,
        "ignored input must not detach retained screen rows")
      precondition(untouched.primary == retained)
    }
    let styled = TerminalDocument.PrintAttributes(style: TerminalStyle(foreground: 0x02010203, flags: 1),
      link: "https://example.test/row", protected: true)
    let stages: [(String, TerminalDocument.PrintAttributes)] = [
      ("e\u{301}猫👩🏽‍💻🇳🇴" + String(repeating: "abc", count: 400), styled),
      ("\u{301}\u{fe0f}Z", plain),
      ("©\u{fe0f}" + String(repeating: "\u{301}", count: 70) + "A", styled),
      ("\u{600}a\u{200d}猫" + String(repeating: " 日本語한글 ", count: 12), plain)
    ]
    var cases = 0
    for width in [1, 2, 7, 32] {
      for insert in [false, true] {
        for wrap in [false, true] {
          var batch = TerminalDocument(columns: width, rows: 4)
          var reference = batch
          // Keep both values and rich rows alive across every stage; each
          // transaction must detach before its first write and preserve them.
          var heldScreens: [TerminalScreen] = []
          var heldRows: [[TerminalCell]] = []
          for (text, attributes) in stages {
            heldScreens.append(batch.primary)
            heldRows.append(batch.primary.rows.flatMap { Array($0.cells) })
            printAll(text, document: &batch, attributes: attributes, insert: insert, wrap: wrap, scalarwise: false)
            printAll(text, document: &reference, attributes: attributes, insert: insert, wrap: wrap, scalarwise: true)
            precondition(batch.primary == reference.primary && batch.history == reference.history,
              "row transaction differs from scalar stream: width \(width), insert \(insert), wrap \(wrap)")
            precondition(batch.hasValidInvariants(batch.primary))
            for index in heldScreens.indices {
              precondition(heldScreens[index].rows.flatMap { Array($0.cells) } == heldRows[index],
                "retained row changed under row transaction")
            }
            cases += 1
          }
        }
      }
    }
    print("PASS row transaction: ignored-input sharing, \(cases) mixed-write/retained-screen cases")
  }
}

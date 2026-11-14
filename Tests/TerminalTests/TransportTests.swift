import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

@Suite struct TransportTests {
  /// Every byte offset of bracket opening, Unicode payload and closing;
  /// idempotent cancel; unbracketed cancel; ordinary writes preserved.
  @Test static func cancelPaste() {
    let opening = Data("\u{1b}[200~".utf8)
    let closing = Data("\u{1b}[201~".utf8)
    let payload = Data("hello 日本語\rworld".utf8)
    let all = opening + payload + closing
    for offset in 0...all.count {
      var tx = WriteTransaction(id: 1, data: all, offset: offset, kind: .paste(bracketed: true))
      let written = all.prefix(offset)
      let first = tx.cancelPaste()
      #expect(first)
      let remaining = tx.data
      let second = tx.cancelPaste()
      #expect(!second)
      #expect(tx.data == remaining)
      if offset == 0 {
        #expect(remaining.isEmpty)
      } else if offset < opening.count {
        #expect(written + remaining == opening + closing)
      } else if offset < opening.count + payload.count {
        #expect(written + remaining == written + closing)
      } else {
        #expect(written + remaining == all)
      }
    }
    for offset in 0...payload.count {
      var tx = WriteTransaction(
        id: 2, data: payload, offset: offset, kind: .paste(bracketed: false))
      let cancelled = tx.cancelPaste()
      #expect(cancelled)
      #expect(tx.remaining == 0)
    }
    var normal = WriteTransaction(id: 3, data: payload, kind: .ordinary)
    let normalCancel = normal.cancelPaste()
    #expect(!normalCancel)
    #expect(normal.data == payload)
  }
}

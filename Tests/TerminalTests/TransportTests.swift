import Foundation

@main struct TransportTests {
  static func main() {
    let opening = Data("\u{1b}[200~".utf8)
    let closing = Data("\u{1b}[201~".utf8)
    let payload = Data("hello 日本語\rworld".utf8)
    let all = opening + payload + closing
    for offset in 0...all.count {
      var tx = WriteTransaction(id: 1, data: all, offset: offset, kind: .paste(bracketed: true))
      let written = all.prefix(offset)
      assert(tx.cancelPaste())
      let remaining = tx.data
      assert(!tx.cancelPaste())
      assert(tx.data == remaining)
      if offset == 0 {
        assert(remaining.isEmpty)
      } else if offset < opening.count {
        assert(written + remaining == opening + closing)
      } else if offset < opening.count + payload.count {
        assert(written + remaining == written + closing)
      } else {
        assert(written + remaining == all)
      }
    }
    for offset in 0...payload.count {
      var tx = WriteTransaction(
        id: 2, data: payload, offset: offset, kind: .paste(bracketed: false))
      assert(tx.cancelPaste())
      assert(tx.remaining == 0)
    }
    var normal = WriteTransaction(id: 3, data: payload, kind: .ordinary)
    assert(!normal.cancelPaste())
    assert(normal.data == payload)
    print(
      "PASS transport: every byte offset of bracket opening, Unicode payload and closing; idempotent cancel; unbracketed cancel; ordinary writes preserved"
    )
  }
}

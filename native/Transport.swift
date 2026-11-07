import Foundation

struct WriteTransaction {
  enum Kind {
    case ordinary
    case paste(bracketed: Bool)
  }
  let id: UInt64
  var data: Data
  var offset = 0
  var kind: Kind
  var remaining: Int { data.count - offset }
  // Returns remaining framing bytes. Already written bytes are immutable.
  mutating func cancelPaste() -> Bool {
    guard case .paste(let bracketed) = kind else { return false }
    if !bracketed || offset == 0 {
      data = Data()
      offset = 0
    } else {
      let opening = Data("\u{1b}[200~".utf8)
      let closing = Data("\u{1b}[201~".utf8)
      if offset < opening.count {
        data = opening.subdata(in: offset..<opening.count) + closing
      } else if offset >= data.count - closing.count {
        data = data.subdata(in: offset..<data.count)
      } else {
        data = closing
      }
      offset = 0
    }
    kind = .ordinary  // Cancellation is idempotent.
    return true
  }
}

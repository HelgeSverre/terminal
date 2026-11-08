import Foundation

// Incremental, allocation-bounded OSC 52 payload decoder. The parser owns
// transport framing; this type only accepts the base64 payload after `52;c;`.
// It never retains encoded input and commits decoded bytes only on a complete,
// strictly-valid RFC 4648 quantum.
final class OSC52Decoder {
  static let maximumDecodedBytes = 1_048_576
  static let maximumEncodedBytes = 1_398_104

  enum Result: Equatable { case accepting, rejected }
  enum Outcome: Equatable { case write(Data), query, reject }
  private enum State { case undecided, data, query, finished, rejected }
  private var carry: [UInt8] = []
  private(set) var encodedCount = 0
  private(set) var rejected = false
  private var state: State = .undecided
  // Do not reserve output space until a write can actually be delivered.  A
  // full owner queue still needs to validate and consume the stream, but must
  // not allocate up to a MiB only to discard it.
  private let acceptingWrites: Bool
  private var decoded = Data()

  init(acceptingWrites: Bool = true) {
    self.acceptingWrites = acceptingWrites
    if acceptingWrites { decoded.reserveCapacity(4096) }
  }

  func push(_ byte: UInt8) -> Result {
    guard !rejected else { return .rejected }
    switch state {
    case .undecided where byte == UInt8(ascii: "?"):
      state = .query
      return .accepting
    case .undecided:
      state = .data
    case .data:
      break
    case .query, .finished, .rejected:
      reject()
      return .rejected
    }
    encodedCount += 1
    guard encodedCount <= Self.maximumEncodedBytes else { reject(); return .rejected }
    guard base64Value(byte) != nil || byte == 61 else { reject(); return .rejected }
    carry.append(byte)
    guard carry.count == 4 else { return .accepting }
    guard decodeQuantum() else { reject(); return .rejected }
    carry.removeAll(keepingCapacity: true)
    return .accepting
  }

  func finish() -> Outcome {
    guard !rejected, carry.isEmpty else { return .reject }
    switch state {
    case .query: return .query
    case .undecided where acceptingWrites: return .write(decoded)
    case .data where acceptingWrites: return .write(decoded)
    case .finished where acceptingWrites: return .write(decoded)
    default: return .reject
    }
  }

  private func decodeQuantum() -> Bool {
    let padding = carry.reversed().prefix { $0 == 61 }.count
    guard padding <= 2, !carry.dropLast(padding).contains(61) else { return false }
    guard let a = base64Value(carry[0]), let b = base64Value(carry[1]) else { return false }
    let c = padding >= 2 ? 0 : base64Value(carry[2])
    let d = padding >= 1 ? 0 : base64Value(carry[3])
    guard let c, let d, (padding != 2 || b & 0x0f == 0), (padding != 1 || c & 0x03 == 0) else { return false }
    let values = [a, b, c, d]
    let count = 3 - padding
    guard !acceptingWrites || decoded.count + count <= Self.maximumDecodedBytes else { return false }
    if acceptingWrites {
      decoded.append((values[0] << 2) | (values[1] >> 4))
      if count > 1 { decoded.append((values[1] << 4) | (values[2] >> 2)) }
      if count > 2 { decoded.append((values[2] << 6) | values[3]) }
    }
    if padding > 0 { state = .finished }
    return true
  }

  private func reject() {
    rejected = true
    state = .rejected
    decoded.removeAll(keepingCapacity: false)
  }

  private func base64Value(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 65...90: return byte - 65
    case 97...122: return byte - 71
    case 48...57: return byte + 4
    case 43: return 62
    case 47: return 63
    default: return nil
    }
  }
}

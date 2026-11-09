import Foundation

// One value owns validation for preferences, automation and owner selection.
// Order has no semantic meaning: sorted unique scalars make equality stable.
struct TerminalSelectionWordProfile: Equatable, Codable {
  let punctuation: String
  static let standard = TerminalSelectionWordProfile(punctuation: "_-/.:~")!

  init?(punctuation: String) {
    guard punctuation.utf8.count <= 256, punctuation.unicodeScalars.count <= 64,
      punctuation.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.properties.generalCategory != .control })
    else { return nil }
    let values = Set(punctuation.unicodeScalars.map(\.value)).sorted()
    self.punctuation = String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
  }
  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    let punctuation = try value.decode(String.self)
    guard let profile = Self(punctuation: punctuation) else {
      throw DecodingError.dataCorruptedError(in: value, debugDescription: "Word characters require at most 64 non-whitespace, non-control Unicode scalars (256 UTF-8 bytes).")
    }
    self = profile
  }
  func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(punctuation)
  }
}

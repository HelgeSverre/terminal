import Foundation

/// A terminal owns only its pending composition. Replacement ranges cannot
/// reach text already sent to the PTY, even when an input method requests it.
struct MarkedTextStorage {
  static let maximumLength = 65_536
  private(set) var text = NSAttributedString(string: "")
  private(set) var selection = NSRange(location: 0, length: 0)
  private(set) var revision: UInt64 = 0
  var hasText: Bool { text.length > 0 }

  func valid(_ range: NSRange) -> Bool {
    guard range.location != NSNotFound && range.location >= 0 && range.length >= 0
      && range.location <= text.length && range.length <= text.length - range.location
    else { return false }
    // A String.Index converted from a UTF-16 offset can still describe the
    // middle of a surrogate pair. NSString replacement needs scalar-boundary
    // proof at both endpoints or it silently creates a replacement character.
    let characters = text.string as NSString
    func isScalarBoundary(_ offset: Int) -> Bool {
      guard offset > 0, offset < characters.length else { return true }
      return !((0xD800...0xDBFF).contains(characters.character(at: offset - 1))
        && (0xDC00...0xDFFF).contains(characters.character(at: offset)))
    }
    return isScalarBoundary(range.location) && isScalarBoundary(range.location + range.length)
  }
  @discardableResult mutating func update(
    _ value: NSAttributedString, selection: NSRange, replacement: NSRange
  ) -> Bool {
    let range = replacement.location == NSNotFound ? NSRange(location: 0, length: text.length) : replacement
    guard valid(range), value.length <= Self.maximumLength,
      text.length - range.length <= Self.maximumLength - value.length else { return false }
    let result = NSMutableAttributedString(attributedString: text)
    result.replaceCharacters(in: range, with: value)
    let location = selection.location == NSNotFound ? value.length : min(value.length, max(0, selection.location))
    let length = min(max(0, selection.length), value.length - location)
    text = result.copy() as! NSAttributedString
    self.selection = NSRange(location: range.location + location, length: length)
    revision &+= 1
    return true
  }
  func committing(_ value: String, replacement: NSRange) -> String? {
    guard replacement.location != NSNotFound else { return value }
    guard valid(replacement), value.utf16.count <= Self.maximumLength else { return nil }
    return (text.string as NSString).replacingCharacters(in: replacement, with: value)
  }
  mutating func clear() {
    text = NSAttributedString(string: "")
    selection = NSRange(location: 0, length: 0)
    revision &+= 1
  }
}

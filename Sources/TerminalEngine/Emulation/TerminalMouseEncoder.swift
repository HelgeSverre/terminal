import Foundation

/// Wire formats are independent of tracking (press, drag, all motion). Hosts
/// provide one-based cell and content-pixel positions in the terminal's size
/// report coordinate space, after applying their inset and backing scale.
package enum TerminalMouseEncoder {
  package static func encode(button: Int, release: Bool, modifiers: Int,
                             column: Int, row: Int, pixelX: Int, pixelY: Int,
                             encoding: Int, x10: Bool = false) -> Data {
    guard (0...255).contains(button), (0...28).contains(modifiers), column > 0, row > 0 else { return Data() }
    let modifier = x10 ? 0 : modifiers
    let code = (release ? 3 : button) + modifier + 32
    switch encoding {
    case 1006, 1016:
      let x = encoding == 1016 ? pixelX : column
      let y = encoding == 1016 ? pixelY : row
      guard x > 0, y > 0 else { return Data() }
      return Data("\u{1b}[<\(button + modifier);\(x);\(y)\(release ? "m" : "M")".utf8)
    case 1015:
      return Data("\u{1b}[\(code);\(column);\(row)M".utf8)
    case 1005:
      guard column <= 2015, row <= 2015 else { return Data() }
      let scalars = [code, column + 32, row + 32].compactMap(UnicodeScalar.init)
      return Data(("\u{1b}[M" + String(String.UnicodeScalarView(scalars))).utf8)
    default:
      guard column <= 223, row <= 223, code <= 255 else { return Data() }
      return Data([27, 91, 77, UInt8(code), UInt8(column + 32), UInt8(row + 32)])
    }
  }
}

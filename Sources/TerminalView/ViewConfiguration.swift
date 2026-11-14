import Foundation
import TerminalSession

/// What a host chooses for a terminal view.
package struct TerminalViewConfiguration {
  /// The font size, in points.
  package var fontSize: CGFloat
  /// Whether Option sends Escape before the key instead of composing a character.
  package var optionSendsEscape: Bool
  package var session: TerminalSessionConfiguration
  package init(fontSize: CGFloat = 14, optionSendsEscape: Bool = false,
       session: TerminalSessionConfiguration = TerminalSessionConfiguration()) {
    self.fontSize = fontSize
    self.optionSendsEscape = optionSendsEscape
    self.session = session
  }
}

/// Where the view finds what it loads at run time: the compiled shaders
/// (`Terminal.metallib`) and the fonts (`Fonts/`).
package enum TerminalResources {
  /// Set before the first view or renderer is created.
  nonisolated(unsafe) static var bundle: Bundle = .main
}

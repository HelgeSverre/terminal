import Foundation
import Metal
import TerminalHost

/// What a host chooses for a terminal view.
public struct TerminalViewConfiguration {
  /// The font size, in points.
  public var fontSize: CGFloat
  /// An installed fixed-pitch font family, such as "Menlo" or "Monaco".
  /// Nil, or a family the Mac does not have, gives the bundled Obel Mono.
  /// Icons the family lacks still come from the bundled symbols font.
  public var fontFamily: String?
  /// Whether runs of punctuation are drawn joined when the font has
  /// ligatures for them: `->`, `!=`, `===`. Off unless set. The bundled
  /// font has none; choose a `fontFamily` that does.
  public var ligatures = false
  /// The space between the view's edge and the text, in points.
  public var contentInset: CGFloat = 8
  /// Whether Option sends Escape before the key instead of composing a character.
  public var optionSendsEscape: Bool
  public var session: TerminalSessionConfiguration
  public init(fontSize: CGFloat = 14, fontFamily: String? = nil, optionSendsEscape: Bool = false,
       session: TerminalSessionConfiguration = TerminalSessionConfiguration()) {
    self.fontSize = fontSize
    self.fontFamily = fontFamily
    self.optionSendsEscape = optionSendsEscape
    self.session = session
  }
}

/// Where the view finds what it loads at run time: the fonts (`Fonts/`) and
/// the shaders, compiled (`Terminal.metallib`) or as source (`Terminal.metal`).
package enum TerminalResources {
  /// An app bundle that carries the compiled shaders is used as it is;
  /// otherwise the resources are the ones the package builds beside the
  /// program. Set before the first view or renderer is created.
  nonisolated(unsafe) package static var bundle: Bundle = {
    if Bundle.main.url(forResource: "Terminal", withExtension: "metallib") != nil { return .main }
    #if SWIFT_PACKAGE
    return .module
    #else
    return .main
    #endif
  }()

  /// The shaders: the compiled library when the bundle has one, otherwise
  /// the source, compiled now.
  static func shaders(for device: MTLDevice) throws -> MTLLibrary? {
    if let compiled = bundle.url(forResource: "Terminal", withExtension: "metallib") {
      return try device.makeLibrary(URL: compiled)
    }
    guard let source = bundle.url(forResource: "Terminal", withExtension: "metal") else { return nil }
    return try device.makeLibrary(source: String(contentsOf: source, encoding: .utf8), options: nil)
  }
}

/// Measurement switches the app turns on from its command line. The view and
/// the renderer never read the host's arguments themselves. Set before the
/// renderer is created.
package enum RenderingDiagnostics {
  /// A small glyph atlas, so that a smoke run fills it.
  nonisolated(unsafe) package static var atlasPressure = false
  /// No budget for glyphs outside the atlas, so that a smoke run exhausts it.
  nonisolated(unsafe) package static var atlasFallbackBudget = false
  /// Where to write the time of the first presented frame, as "frame <ns>".
  nonisolated(unsafe) package static var firstFrameFile: String?
}

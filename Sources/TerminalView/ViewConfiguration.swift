import Foundation
import Metal
import TerminalSession

/// What a host chooses for a terminal view.
public struct TerminalViewConfiguration {
  /// The font size, in points.
  public var fontSize: CGFloat
  /// Whether Option sends Escape before the key instead of composing a character.
  public var optionSendsEscape: Bool
  public var session: TerminalSessionConfiguration
  public init(fontSize: CGFloat = 14, optionSendsEscape: Bool = false,
       session: TerminalSessionConfiguration = TerminalSessionConfiguration()) {
    self.fontSize = fontSize
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

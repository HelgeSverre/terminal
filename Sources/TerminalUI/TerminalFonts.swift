#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The font families a terminal view can be given as `fontFamily`.
public enum TerminalFonts {
  /// The family a view uses when none is named.
  public static let defaultFamily = TerminalFont.family
  /// Families that come with the package and need not be installed: the
  /// default one first, then JetBrains Mono, Fira Code, Hack and IBM Plex
  /// Mono. JetBrains Mono and Fira Code have ligatures.
  public static let bundledFamilies = [TerminalFont.family] + TerminalFont.featured.map(\.family)
  /// The fixed-pitch families installed on this Mac, sorted, without the
  /// bundled ones. Asking walks every installed family, so ask when a
  /// font menu is opened rather than at launch.
  public static func installedFamilies() -> [String] {
    let bundled = Set(bundledFamilies.map { $0.lowercased() })
    let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
    return names.filter { family in
      guard !bundled.contains(family.lowercased()), !family.hasPrefix(".") else { return false }
      let font = CTFontCreateWithName(family as CFString, 12, nil)
      return (CTFontCopyFamilyName(font) as String) == family && CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
    }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }
}

import AppKit

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
    let manager = NSFontManager.shared
    let bundled = Set(bundledFamilies.map { $0.lowercased() })
    return manager.availableFontFamilies.filter { family in
      guard !bundled.contains(family.lowercased()), !family.hasPrefix("."),
        let font = manager.font(withFamily: family, traits: [], weight: 5, size: 12)
      else { return false }
      return font.isFixedPitch
    }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }
}

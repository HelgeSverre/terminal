// Copyright 2026 Helge Tesdal
//
// Derived from unicode-width 0.2.3 (Unicode 18.0.0), Copyright 2012-2026
// The Rust Project Developers, under Apache-2.0 OR MIT.  See
// native/THIRD_PARTY_NOTICES.md.

import Foundation

/// Unicode-18 terminal-cell width, with the non-CJK semantics of
/// `unicode-width` 0.2.3.  This deliberately operates on Unicode scalars
/// instead of `Character`: platform Unicode data must not change terminal
/// placement.
enum TerminalWidth {
  static let unicodeVersion = "18.0.0"
  static let unicodeWidthVersion = "0.2.3"

  static func width(of string: String) -> Int {
    var total = 0
    var next = WidthInfo.default
    for scalar in string.unicodeScalars.reversed() {
      let result = widthInString(scalar.value, next: next)
      total += result.add
      next = result.info
    }
    return total
  }

  // MARK: unicode-width's right-to-left sequence state machine

  private static func widthInString(_ scalar: UInt32, next originalNext: WidthInfo) -> (add: Int, info: WidthInfo) {
    var next = originalNext

    if next.isEmojiPresentation {
      if startsEmojiPresentationSequence(scalar) {
        return (next.isZWJEmojiPresentation ? 0 : 2, .emojiPresentation)
      }
      next = next.unsettingEmojiPresentation
    }

    // unicode-width intentionally treats all ASCII and C1 controls as one
    // terminal cell inside a string (unlike `UnicodeWidthChar::width`).
    if scalar <= 0xA0 {
      if scalar == 0x0A { return (1, .lineFeed) }
      if scalar == 0x0D, next == .lineFeed { return (0, .default) }
      return (1, .default)
    }

    if next != .default {
      if scalar == 0xFE0F { return (0, next.settingEmojiPresentation) }
      if scalar == 0xFE01 { return (0, next.settingVS123) }
      if scalar == 0xFE0E { return (0, next.settingTextPresentation) }

      if next.isTextPresentation {
        if startsNonIdeographicTextPresentationSequence(scalar) { return (1, .default) }
        next = next.unsettingTextPresentation
      }

      if next.isVS123 {
        switch scalar {
        case 0x2018, 0x2019, 0x201C, 0x201D: return (2, .default)
        default: next = next.unsettingVS123
        }
      }

      if next.isLigatureTransparent {
        if scalar == 0x200D { return (0, next.settingZWJBit) }
        if isLigatureTransparent(scalar) { return (0, next) }
      }

      switch (next, scalar) {
      // Arabic Lam-Alef ligature. `isTransparentZeroWidth` is table-derived,
      // not Foundation's Unicode implementation.
      case (.joiningGroupAlef, let value) where isJoiningGroupLam(value):
        return (0, .default)
      case (.joiningGroupAlef, let value) where isTransparentZeroWidth(value):
        return (0, .joiningGroupAlef)

      // Hebrew Alef-ZWJ-Lamed ligature.
      case (.zwjHebrewLetterLamed, 0x05D0): return (0, .default)

      // Khmer coeng signs.
      case (.khmerCoengEligibleLetter, 0x17D2): return (-1, .default)

      // Buginese <a, -i> ZWJ ya ligature.
      case (.zwjBugineseLetterYa, 0x1A17): return (0, .bugineseVowelSignIZWJLetterYa)
      case (.bugineseVowelSignIZWJLetterYa, 0x1A15): return (0, .default)

      // Tifinagh bi-consonants.
      case (.tifinaghConsonant, 0x2D7F), (.zwjTifinaghConsonant, 0x2D7F):
        return (1, .tifinaghJoinerConsonant)
      case (.zwjTifinaghConsonant, 0x2D31...0x2D65), (.zwjTifinaghConsonant, 0x2D6F):
        return (0, .default)
      case (.tifinaghJoinerConsonant, 0x2D31...0x2D65), (.tifinaghJoinerConsonant, 0x2D6F):
        return (-1, .default)

      // Lisu tone-letter combinations and Old Turkic ligature.
      case (.lisuToneLetterMyaNaJeu, 0xA4F8...0xA4FB): return (0, .default)
      case (.zwjOldTurkicLetterOrkhonI, 0x10C32): return (0, .default)

      // Emoji modifier.
      case (.emojiModifier, let value) where isEmojiModifierBase(value):
        return (0, .emojiPresentation)

      // Regional indicators.
      case (.regionalIndicator, 0x1F1E6...0x1F1FF), (.severalRegionalIndicator, 0x1F1E6...0x1F1FF):
        return (1, .severalRegionalIndicator)

      // Emoji ZWJ, keycap, flag, modifier and tag sequences.
      case (.emojiPresentation, 0x200D), (.severalRegionalIndicator, 0x200D),
           (.evenRegionalIndicatorZWJPresentation, 0x200D), (.oddRegionalIndicatorZWJPresentation, 0x200D),
           (.emojiModifier, 0x200D):
        return (0, .zwjEmojiPresentation)
      case (.zwjEmojiPresentation, 0x20E3): return (0, .keycapZWJEmojiPresentation)
      case (.vs16ZWJEmojiPresentation, let value) where startsEmojiPresentationSequence(value):
        return (0, .emojiPresentation)
      case (.vs16KeycapZWJEmojiPresentation, 0x30...0x39), (.vs16KeycapZWJEmojiPresentation, 0x23), (.vs16KeycapZWJEmojiPresentation, 0x2A):
        return (0, .emojiPresentation)
      case (.zwjEmojiPresentation, 0x1F1E6...0x1F1FF): return (1, .regionalIndicatorZWJPresentation)
      case (.regionalIndicatorZWJPresentation, 0x1F1E6...0x1F1FF), (.oddRegionalIndicatorZWJPresentation, 0x1F1E6...0x1F1FF):
        return (-1, .evenRegionalIndicatorZWJPresentation)
      case (.evenRegionalIndicatorZWJPresentation, 0x1F1E6...0x1F1FF):
        return (3, .oddRegionalIndicatorZWJPresentation)
      case (.zwjEmojiPresentation, 0x1F3FB...0x1F3FF): return (0, .emojiModifier)
      case (.zwjEmojiPresentation, 0xE007F): return (0, .tagEndZWJEmojiPresentation)
      case (.tagEndZWJEmojiPresentation, 0xE0061...0xE007A): return (0, .tagA1EndZWJEmojiPresentation)
      case (.tagA1EndZWJEmojiPresentation, 0xE0061...0xE007A): return (0, .tagA2EndZWJEmojiPresentation)
      case (.tagA2EndZWJEmojiPresentation, 0xE0061...0xE007A): return (0, .tagA3EndZWJEmojiPresentation)
      case (.tagA3EndZWJEmojiPresentation, 0xE0061...0xE007A): return (0, .tagA4EndZWJEmojiPresentation)
      case (.tagA4EndZWJEmojiPresentation, 0xE0061...0xE007A): return (0, .tagA5EndZWJEmojiPresentation)
      case (.tagA5EndZWJEmojiPresentation, 0xE0061...0xE007A): return (0, .tagA6EndZWJEmojiPresentation)
      case (.tagEndZWJEmojiPresentation, 0xE0030...0xE0039), (.tagA1EndZWJEmojiPresentation, 0xE0030...0xE0039), (.tagA2EndZWJEmojiPresentation, 0xE0030...0xE0039), (.tagA3EndZWJEmojiPresentation, 0xE0030...0xE0039), (.tagA4EndZWJEmojiPresentation, 0xE0030...0xE0039):
        return (0, .tagD1EndZWJEmojiPresentation)
      case (.tagD1EndZWJEmojiPresentation, 0xE0030...0xE0039): return (0, .tagD2EndZWJEmojiPresentation)
      case (.tagD2EndZWJEmojiPresentation, 0xE0030...0xE0039): return (0, .tagD3EndZWJEmojiPresentation)
      case (.tagA3EndZWJEmojiPresentation, 0x1F3F4), (.tagA4EndZWJEmojiPresentation, 0x1F3F4), (.tagA5EndZWJEmojiPresentation, 0x1F3F4), (.tagA6EndZWJEmojiPresentation, 0x1F3F4), (.tagD3EndZWJEmojiPresentation, 0x1F3F4):
        return (0, .emojiPresentation)
      case (.zwjEmojiPresentation, let value) where lookup(value).info == .emojiPresentation:
        return (0, .emojiPresentation)

      // Kirat Rai vowel-sign combinations.
      case (.kiratRaiVowelSignE, 0x16D63): return (0, .default)
      case (.kiratRaiVowelSignE, 0x16D67): return (0, .kiratRaiVowelSignAI)
      case (.kiratRaiVowelSignE, 0x16D68): return (1, .kiratRaiVowelSignE)
      case (.kiratRaiVowelSignE, 0x16D69): return (0, .default)
      case (.kiratRaiVowelSignAI, 0x16D63): return (0, .default)
      default: break
      }
    }

    let found = lookup(scalar)
    return (found.width, found.info)
  }

  private static func lookup(_ scalar: UInt32) -> (width: Int, info: WidthInfo) {
    let root = Int(TerminalWidthTables.widthRoot[Int(scalar >> 13)])
    let middle = Int(TerminalWidthTables.widthMiddle[root * 64 + Int((scalar >> 7) & 0x3F)])
    let packed = TerminalWidthTables.widthLeaves[middle * 32 + Int((scalar >> 2) & 0x1F)]
    let code = (packed >> UInt8(2 * (scalar & 3))) & 3
    guard code == 3 else { return (Int(code), .default) }
    switch scalar {
    case 0x0A: return (1, .lineFeed)
    case 0x05DC: return (1, .hebrewLetterLamed)
    case 0x0622...0x0882: return (1, .joiningGroupAlef)
    case 0x1780...0x17AF: return (1, .khmerCoengEligibleLetter)
    case 0x17D8: return (3, .default)
    case 0x1A10: return (1, .bugineseLetterYa)
    case 0x2D31...0x2D6F: return (1, .tifinaghConsonant)
    case 0xA4FC...0xA4FD: return (1, .lisuToneLetterMyaNaJeu)
    case 0xFE01: return (0, .variationSelector123)
    case 0xFE0E: return (0, .variationSelector15)
    case 0xFE0F: return (0, .variationSelector16)
    case 0x10C03: return (1, .oldTurkicLetterOrkhonI)
    case 0x16D67: return (1, .kiratRaiVowelSignE)
    case 0x16D68: return (1, .kiratRaiVowelSignAI)
    case 0x1F1E6...0x1F1FF: return (1, .regionalIndicator)
    case 0x1F3FB...0x1F3FF: return (2, .emojiModifier)
    default: return (2, .emojiPresentation)
    }
  }

  private static func startsEmojiPresentationSequence(_ scalar: UInt32) -> Bool {
    let top = scalar >> 10
    let leaf: Int
    switch top { case 0: leaf = 0; case 8: leaf = 1; case 9: leaf = 2; case 10: leaf = 3; case 12: leaf = 4; case 0x7C: leaf = 5; case 0x7D: leaf = 6; default: return false }
    let byte = TerminalWidthTables.emojiPresentationLeaves[leaf * 128 + Int((scalar >> 3) & 0x7F)]
    return ((byte >> UInt8(scalar & 7)) & 1) == 1
  }

  private static func startsNonIdeographicTextPresentationSequence(_ scalar: UInt32) -> Bool {
    let index: Int
    switch scalar >> 8 { case 0x23: index = 0; case 0x25: index = 1; case 0x26: index = 2; case 0x27: index = 3; case 0x2B: index = 4; case 0x1F0: index = 5; case 0x1F3: index = 6; case 0x1F4: index = 7; case 0x1F5: index = 8; case 0x1F6: index = 9; default: return false }
    return TerminalWidthTables.contains(TerminalWidthTables.textPresentationLeaves[index], UInt8(scalar & 0xFF))
  }

  private static func isEmojiModifierBase(_ scalar: UInt32) -> Bool {
    let index: Int
    switch scalar >> 8 { case 0x26: index = 0; case 0x27: index = 1; case 0x1F3: index = 2; case 0x1F4: index = 3; case 0x1F5: index = 4; case 0x1F6: index = 5; case 0x1F9: index = 6; case 0x1FA: index = 7; default: return false }
    return TerminalWidthTables.contains(TerminalWidthTables.emojiModifierLeaves[index], UInt8(scalar & 0xFF))
  }

  private static func isJoiningGroupLam(_ scalar: UInt32) -> Bool {
    scalar == 0x0644 || (0x06B5...0x06B8).contains(scalar) || scalar == 0x076A || scalar == 0x08A6 || scalar == 0x08C7
  }

  private static func isLigatureTransparent(_ scalar: UInt32) -> Bool {
    scalar == 0x034F || (0x17B4...0x17B5).contains(scalar) || (0x180B...0x180D).contains(scalar) || scalar == 0x180F || scalar == 0x200D || (0xFE00...0xFE0F).contains(scalar) || (0xE0100...0xE01EF).contains(scalar)
  }

  private static func isTransparentZeroWidth(_ scalar: UInt32) -> Bool {
    guard lookup(scalar).width == 0 else { return false }
    return !TerminalWidthTables.contains(TerminalWidthTables.nonTransparentZeroWidths, scalar)
  }
}

private struct WidthInfo: Equatable {
  let rawValue: UInt16
  init(_ rawValue: UInt16) { self.rawValue = rawValue }
  static let `default` = WidthInfo(0)
  static let lineFeed = WidthInfo(0x0001), emojiModifier = WidthInfo(0x0002), regionalIndicator = WidthInfo(0x0003), severalRegionalIndicator = WidthInfo(0x0004), emojiPresentation = WidthInfo(0x0005)
  static let zwjEmojiPresentation = WidthInfo(0x1006), vs16ZWJEmojiPresentation = WidthInfo(0x9006), keycapZWJEmojiPresentation = WidthInfo(0x1007), vs16KeycapZWJEmojiPresentation = WidthInfo(0x9007), regionalIndicatorZWJPresentation = WidthInfo(0x0009), evenRegionalIndicatorZWJPresentation = WidthInfo(0x000A), oddRegionalIndicatorZWJPresentation = WidthInfo(0x000B)
  static let tagEndZWJEmojiPresentation = WidthInfo(0x0010), tagD1EndZWJEmojiPresentation = WidthInfo(0x0011), tagD2EndZWJEmojiPresentation = WidthInfo(0x0012), tagD3EndZWJEmojiPresentation = WidthInfo(0x0013), tagA1EndZWJEmojiPresentation = WidthInfo(0x0019), tagA2EndZWJEmojiPresentation = WidthInfo(0x001A), tagA3EndZWJEmojiPresentation = WidthInfo(0x001B), tagA4EndZWJEmojiPresentation = WidthInfo(0x001C), tagA5EndZWJEmojiPresentation = WidthInfo(0x001D), tagA6EndZWJEmojiPresentation = WidthInfo(0x001E)
  static let kiratRaiVowelSignE = WidthInfo(0x0020), kiratRaiVowelSignAI = WidthInfo(0x0021), variationSelector123 = WidthInfo(0x0200), variationSelector15 = WidthInfo(0x4000), variationSelector16 = WidthInfo(0x8000)
  static let joiningGroupAlef = WidthInfo(0x30FF), hebrewLetterLamed = WidthInfo(0x3800), zwjHebrewLetterLamed = WidthInfo(0x3C00), bugineseLetterYa = WidthInfo(0x3801), zwjBugineseLetterYa = WidthInfo(0x3C01), bugineseVowelSignIZWJLetterYa = WidthInfo(0x3C02), tifinaghConsonant = WidthInfo(0x3803), zwjTifinaghConsonant = WidthInfo(0x3C03), tifinaghJoinerConsonant = WidthInfo(0x3C04), lisuToneLetterMyaNaJeu = WidthInfo(0x3C05), oldTurkicLetterOrkhonI = WidthInfo(0x3806), zwjOldTurkicLetterOrkhonI = WidthInfo(0x3C06), khmerCoengEligibleLetter = WidthInfo(0x3C07)
  // These are deliberately different bits in unicode-width's compact state:
  // 0x0800 means transparent to a preceding ligature; 0x2000 preserves the
  // base script state when variation presentation is applied.
  private static let presentationPreservationMask: UInt16 = 0x2000
  var isLigatureTransparent: Bool { rawValue & 0x0800 != 0 }
  var settingZWJBit: WidthInfo { WidthInfo(rawValue | 0x0400) }
  var isEmojiPresentation: Bool { rawValue & WidthInfo.variationSelector16.rawValue != 0 }
  var isZWJEmojiPresentation: Bool { rawValue & 0xB000 == 0x9000 }
  var settingEmojiPresentation: WidthInfo {
    if rawValue & WidthInfo.presentationPreservationMask != 0 || rawValue & 0x9000 == 0x1000 { return WidthInfo(rawValue | (0x8000 & ~0x4000 & ~0x0200)) }
    return .variationSelector16
  }
  var unsettingEmojiPresentation: WidthInfo { rawValue & WidthInfo.presentationPreservationMask != 0 ? WidthInfo(rawValue & ~0x8000) : .default }
  var isTextPresentation: Bool { rawValue & 0x4000 != 0 }
  var settingTextPresentation: WidthInfo { rawValue & WidthInfo.presentationPreservationMask != 0 ? WidthInfo(rawValue | (0x4000 & ~0x8000 & ~0x0200)) : .variationSelector15 }
  var unsettingTextPresentation: WidthInfo { WidthInfo(rawValue & ~0x4000) }
  var isVS123: Bool { rawValue & 0x0200 != 0 }
  var settingVS123: WidthInfo { rawValue & WidthInfo.presentationPreservationMask != 0 ? WidthInfo(rawValue | (0x0200 & ~0x4000 & ~0x8000)) : .variationSelector123 }
  var unsettingVS123: WidthInfo { WidthInfo(rawValue & ~0x0200) }
}

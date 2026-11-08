import Foundation

/// Terminal-oriented Unicode primitives with an explicit, narrow contract.
///
/// The Rust baseline is pinned to Unicode 18/UAX #29 rev. 49.  This component
/// uses generated Unicode 18 tables rather than delegating segmentation to
/// `Character` (whose data follows the host OS).  The strict official fixture
/// is the regression gate for this declared pin.
enum SwiftUnicode {
  static let unicode18Parity = true

  enum Category: Equatable {
    case other, cr, lf, control, l, v, t, lv, lvt, extend, zwj, spacingMark
    case prepend, regionalIndicator, extendedPictographic, incbConsonant, incbLinker
  }

  /// Constant-space UAX #29 state.  The rule ordering mirrors the Rust core;
  /// category coverage is intentionally exposed through `unicode18Parity`.
  struct Segmenter {
    private var previous: Category?
    private var regionalOdd = false
    private var extendedPictographicTail = false
    private var zwjAfterExtendedPictographic = false
    private var linkerTail = false

    mutating func push(_ scalar: Unicode.Scalar) -> Bool {
      push(scalar, category: SwiftUnicode.category(of: scalar))
    }

    mutating func push(_ scalar: Unicode.Scalar, category current: Category) -> Bool {
      let boundary: Bool
      switch (previous, current) {
      case (nil, _): boundary = true
      case (.some(.cr), .lf): boundary = false
      case (.some(.control), _), (.some(.cr), _), (.some(.lf), _), (_, .control), (_, .cr), (_, .lf):
        boundary = true
      case (.some(.l), .l), (.some(.l), .v), (.some(.l), .lv), (.some(.l), .lvt):
        boundary = false
      case (.some(.lv), .v), (.some(.lv), .t), (.some(.v), .v), (.some(.v), .t):
        boundary = false
      case (.some(.lvt), .t), (.some(.t), .t): boundary = false
      case (_, .extend), (_, .zwj), (_, .spacingMark), (.some(.prepend), _): boundary = false
      case (_, .incbConsonant) where linkerTail: boundary = false
      case (.some(.zwj), .extendedPictographic) where zwjAfterExtendedPictographic: boundary = false
      case (.some(.regionalIndicator), .regionalIndicator) where regionalOdd: boundary = false
      default: boundary = true
      }
      if boundary {
        regionalOdd = false
        extendedPictographicTail = false
        zwjAfterExtendedPictographic = false
        linkerTail = false
      }
      regionalOdd = current == .regionalIndicator && !regionalOdd
      let afterExtendedPictographic = extendedPictographicTail
      zwjAfterExtendedPictographic = current == .zwj && afterExtendedPictographic
      extendedPictographicTail = current == .extendedPictographic || (current == .extend && afterExtendedPictographic)
      if SwiftUnicode18Tables.isIncbLinker(scalar.value) {
        linkerTail = true
      } else if !((current == .extend || current == .zwj) && scalar.value != 0x200c) {
        linkerTail = false
      }
      previous = current
      return boundary
    }
  }

  /// Incremental UTF-8 decoder.  It never emits an incomplete scalar; callers
  /// can feed arbitrary transport chunks and call `finish()` at EOF.  Invalid
  /// data is represented as U+FFFD. Its byte-fed malformed-prefix behavior is
  /// checked against Swift's UTF-8 decoder; broader fixture replay remains a
  /// separate parity gate.
  struct UTF8Decoder {
    /// A byte can complete one scalar, or reject a pending prefix and then
    /// emit the current byte. The decoder therefore needs no heap-backed
    /// output collection on the hot per-byte path.
    enum Emission {
      case none
      case one(Unicode.Scalar)
      case two(Unicode.Scalar, Unicode.Scalar)
    }

    // This is always a viable, incomplete UTF-8 prefix. Its fixed capacity is
    // enough for the longest four-byte scalar and avoids allocating an Array
    // for every ASCII byte.
    private var first: UInt8 = 0
    private var second: UInt8 = 0
    private var third: UInt8 = 0
    private var pendingCount = 0

    private static let replacement = Unicode.Scalar(0xfffd)!

    @inline(__always)
    mutating func push(_ byte: UInt8) -> Emission {
      switch pendingCount {
      case 0:
        return begin(byte)
      case 1:
        guard isViableSecond(byte) else {
          return rejectPendingThenBegin(byte)
        }
        if sequenceLength == 2 {
          second = byte
          return emitComplete(length: 2)
        }
        second = byte
        pendingCount = 2
        return .none
      case 2:
        guard isContinuation(byte) else {
          return rejectPendingThenBegin(byte)
        }
        if sequenceLength == 3 {
          third = byte
          return emitComplete(length: 3)
        }
        third = byte
        pendingCount = 3
        return .none
      case 3:
        guard isContinuation(byte) else {
          return rejectPendingThenBegin(byte)
        }
        return emitComplete(length: 4, fourth: byte)
      default:
        preconditionFailure("UTF-8 prefix exceeds four bytes")
      }
    }

    @inline(__always)
    mutating func finish() -> Emission {
      guard pendingCount != 0 else { return .none }
      // A viable incomplete prefix is one maximal invalid subpart at EOF.
      pendingCount = 0
      return .one(Self.replacement)
    }

    @inline(__always)
    private mutating func begin(_ byte: UInt8) -> Emission {
      if byte < 0x80 { return .one(Unicode.Scalar(byte)) }
      guard Self.sequenceLength(for: byte) != nil else { return .one(Self.replacement) }
      first = byte
      pendingCount = 1
      return .none
    }

    @inline(__always)
    private mutating func rejectPendingThenBegin(_ byte: UInt8) -> Emission {
      pendingCount = 0
      switch begin(byte) {
      case .none:
        return .one(Self.replacement)
      case .one(let scalar):
        return .two(Self.replacement, scalar)
      case .two:
        preconditionFailure("starting a UTF-8 scalar cannot emit two values")
      }
    }

    @inline(__always)
    private var sequenceLength: Int {
      // `first` is installed only after `sequenceLength(for:)` accepts it.
      Self.sequenceLength(for: first)!
    }

    @inline(__always)
    private func isViableSecond(_ byte: UInt8) -> Bool {
      guard isContinuation(byte) else { return false }
      switch first {
      case 0xe0: return byte >= 0xa0
      case 0xed: return byte <= 0x9f
      case 0xf0: return byte >= 0x90
      case 0xf4: return byte <= 0x8f
      default: return true
      }
    }

    @inline(__always)
    private mutating func emitComplete(length: Int, fourth: UInt8 = 0) -> Emission {
      var value = UInt32(first & ((1 << (8 - length - 1)) - 1))
      value = (value << 6) | UInt32(second & 0x3f)
      if length >= 3 { value = (value << 6) | UInt32(third & 0x3f) }
      if length == 4 { value = (value << 6) | UInt32(fourth & 0x3f) }
      pendingCount = 0
      // The lead and second-byte checks rule out overlong, surrogate, and
      // above-range values before reaching here.
      return .one(Unicode.Scalar(value)!)
    }

    @inline(__always)
    private static func sequenceLength(for byte: UInt8) -> Int? {
      switch byte {
      case 0xc2...0xdf: return 2
      case 0xe0...0xef: return 3
      case 0xf0...0xf4: return 4
      default: return nil
      }
    }

    @inline(__always)
    private func isContinuation(_ byte: UInt8) -> Bool { byte & 0xc0 == 0x80 }

  }

  static func clusters(in text: String) -> [String] {
    var segmenter = Segmenter()
    var output: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
      if segmenter.push(scalar), !current.isEmpty { output.append(current); current = "" }
      current.unicodeScalars.append(scalar)
    }
    if !current.isEmpty { output.append(current) }
    return output
  }

  /// Cell width for an already formed cluster. The terminal will clamp a
  /// non-empty printable cluster to at least one cell when placing it.
  static func cellWidth(of cluster: String) -> Int {
    TerminalWidth.width(of: cluster)
  }

  // Mirrors the narrow no-base path in terminal-core::print. These scalars
  // are intentionally consumed rather than made visible orphan cells; other
  // zero-width scalars (notably combining marks and Prepend) remain placeable.
  static func isDefaultIgnorable(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x200b...0x200f, 0x202a...0x202e, 0x2060...0x206f,
         0xfe00...0xfe0f, 0xe0100...0xe01ef:
      return true
    default:
      return false
    }
  }

  static func category(of scalar: Unicode.Scalar) -> Category {
    let value = scalar.value
    // Generated Unicode 18 GCB + Extended_Pictographic + InCB-Consonant
    // classification, independent of the macOS Unicode database.
    switch SwiftUnicode18Tables.category(value) {
    case .Other: break
    case .CR: return .cr
    case .LF: return .lf
    case .Control: return .control
    case .Extend: return .extend
    case .Extended_Pictographic: return .extendedPictographic
    case .InCB_Consonant: return .incbConsonant
    case .L: return .l
    case .V: return .v
    case .T: return .t
    case .LV: return .lv
    case .LVT: return .lvt
    case .Prepend: return .prepend
    case .Regional_Indicator: return .regionalIndicator
    case .SpacingMark: return .spacingMark
    case .ZWJ: return .zwj
    }
    switch value {
    case 0x000d: return .cr
    case 0x000a: return .lf
    case 0x0000...0x0009, 0x000b...0x000c, 0x000e...0x001f, 0x007f...0x009f: return .control
    case 0x1100...0x115f, 0xa960...0xa97c: return .l
    case 0x1160...0x11a7, 0xd7b0...0xd7c6: return .v
    case 0x11a8...0x11ff, 0xd7cb...0xd7fb: return .t
    case 0xac00...0xd7a3:
      return (value - 0xac00) % 28 == 0 ? .lv : .lvt
    case 0x200d: return .zwj
    case 0x1f1e6...0x1f1ff: return .regionalIndicator
    case 0x0600...0x0605, 0x06dd, 0x070f, 0x0890...0x0891, 0x08e2, 0x0d4e, 0x110bd, 0x110cd: return .prepend
    case 0x0903, 0x093b, 0x093e...0x0940, 0x0949...0x094c, 0x0982...0x0983, 0x09be...0x09c0, 0x0bbe...0x0bc2, 0x0cc2...0x0cc4:
      return .spacingMark
    case 0x094d, 0x09cd, 0x0a4d, 0x0acd, 0x0b4d, 0x0ccd, 0x0d4d: return .incbLinker
    case 0x0915...0x0939, 0x0995...0x09b9, 0x0a15...0x0a39, 0x0a95...0x0ab9, 0x0b15...0x0b39, 0x0c15...0x0c39, 0x0d15...0x0d39:
      return .incbConsonant
    default: break
    }
    // `grapheme_cat_table` is complete for Unicode 18. Do not fall back to a
    // broad host-era heuristic here: it would incorrectly classify, for
    // example, U+2701 as Extended_Pictographic.
    return .other
  }

  private static func isExtend(_ value: UInt32) -> Bool {
    switch value {
    case 0x0300...0x036f, 0x0483...0x0489, 0x0591...0x05bd, 0x05bf, 0x05c1...0x05c2,
         0x0610...0x061a, 0x064b...0x065f, 0x0670, 0x06d6...0x06dc, 0x06df...0x06e4,
         0x06e7...0x06e8, 0x06ea...0x06ed, 0x0711, 0x0730...0x074a, 0x07a6...0x07b0,
         0x0816...0x0819, 0x081b...0x0823, 0x0825...0x0827, 0x0829...0x082d,
         0x0859...0x085b, 0x08d3...0x08e1, 0x08e3...0x0902, 0x093a, 0x093c, 0x0941...0x0948,
         0x094d, 0x0951...0x0957, 0x0962...0x0963, 0x1ab0...0x1aff, 0x1dc0...0x1dff,
         0x20d0...0x20ff, 0xfe00...0xfe0f, 0xfe20...0xfe2f, 0xe0100...0xe01ef:
      return true
    default: return false
    }
  }

  private static func isExtendedPictographic(_ value: UInt32) -> Bool {
    switch value {
    case 0x00a9, 0x00ae, 0x203c, 0x2049, 0x2122, 0x2139, 0x2194...0x21ff,
         0x2300...0x23ff, 0x2500...0x27ff, 0x2b00...0x2bff, 0x1f000...0x1faff:
      return true
    default: return false
    }
  }

  private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    switch value {
    case 0x1100...0x115f, 0x2329...0x232a, 0x2e80...0x303e, 0x3040...0xa4cf,
         0xac00...0xd7a3, 0xf900...0xfaff, 0xfe10...0xfe19, 0xfe30...0xfe6f,
         0xff00...0xff60, 0xffe0...0xffe6, 0x1f000...0x1faff, 0x20000...0x3fffd:
      return true
    default: return false
    }
  }
}

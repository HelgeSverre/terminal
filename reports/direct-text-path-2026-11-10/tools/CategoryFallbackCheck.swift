// Exhaustive check: does the hand-written fallback in TerminalText.category(of:) ever
// change the result for a scalar the generated table classifies as Other?
@main struct Check {
  static func main() {
    var differing = 0, linkersNotExtend = 0, total = 0
    for value in UInt32(0)...0x10FFFF {
      guard let scalar = Unicode.Scalar(value) else { continue }
      total += 1
      let table = Unicode18GraphemeTables.category(value)
      let full = TerminalText.category(of: scalar)
      if table == .Other && full != .other { differing += 1; print("D", String(value, radix: 16), full) }
      if Unicode18GraphemeTables.isIncbLinker(value) && full != .extend { linkersNotExtend += 1; print("linker", String(value, radix: 16), full) }
    }
    print("scalars \(total) table-Other-but-fallback-differs \(differing) linkers-not-extend \(linkersNotExtend)")
  }
}

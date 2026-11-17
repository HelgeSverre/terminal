import AppKit

#if TERMINAL_DIAGNOSTICS
/// A smoke run must never observe or mutate the user's clipboard. The report
/// path already belongs to the fixture, so it is a stable private-board scope.
func selectionSmokeReportPath() -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: "--selection-smoke"),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.path
}

func paneLifecycleSmokeReportPath() -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: "--pane-lifecycle-smoke"),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.path
}

func selectionSmokePasteboardName(reportPath: String) -> NSPasteboard.Name {
  var hash: UInt64 = 0xcbf29ce484222325
  for byte in reportPath.utf8 {
    hash ^= UInt64(byte)
    hash &*= 0x100000001b3
  }
  return NSPasteboard.Name("no.helgesverre.terminal.selection-smoke.\(String(hash, radix: 16))")
}
#endif

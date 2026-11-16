import AppKit
import Foundation
import Testing
@testable import TerminalHost

/// Opt-in investigation against a real Codex binary. Never submits a prompt.
/// Set TERMINAL_CODEX_INPUT_PROBE to the binary's absolute path and
/// TERMINAL_CODEX_PROBE_CWD to an already trusted directory.
@Suite(.serialized) @MainActor struct CodexInputProbeTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMINAL_CODEX_INPUT_PROBE"] != nil))
  func completeAndSplitMouseReportsAfterAnImagePaste() async throws {
    let binary = try #require(ProcessInfo.processInfo.environment["TERMINAL_CODEX_INPUT_PROBE"])
    let directory = try #require(ProcessInfo.processInfo.environment["TERMINAL_CODEX_PROBE_CWD"])
    let image = FileManager.default.temporaryDirectory.appendingPathComponent("terminal image \(UUID().uuidString).png")
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: image)
    defer { try? FileManager.default.removeItem(at: image) }
    let session = TerminalSession(launch: LaunchSpec(executable: binary,
      arguments: [binary, "-c", "check_for_update_on_startup=false"], cwd: directory,
      launcher: TestEnvironment.launcher))
    defer { session.close() }
    session.resize(cols: 120, rows: 50, cellWidth: 9, cellHeight: 19)
    var text = ""
    var bracketed = false
    var mouseMode = 0
    var sgr = false
    session.onSnapshot = {
      text = $0.rows.map { $0.cells.map(\.text).joined() }.joined(separator: "\n")
      bracketed = $0.modes.bracketed_paste
      mouseMode = Int($0.modes.mouse)
      sgr = $0.modes.sgr_mouse
    }
    try #require(await TestEnvironment.wait(seconds: 20) {
      // StartupDraft also shows a session header and enables these modes;
      // this only establishes that the input surface has appeared.
      bracketed && text.contains("OpenAI Codex") && text.contains("for shortcuts")
    }, "Codex did not reach its composer: \(text)")
    print("INFO Codex ready: bracketed=\(bracketed) mouse=\(mouseMode) sgr=\(sgr)")
    // The early plain-text composer intentionally does not attach images.
    // The settling delay separates that behavior from this positive control.
    _ = await TestEnvironment.wait(seconds: 2) { false }
    #expect(session.paste("'\(image.path)'"))
    session.rawInput(Data("\u{1b}[<35;114;47M".utf8))
    let attached = await TestEnvironment.wait(seconds: 2) {
      text.replacingOccurrences(of: " ", with: "").contains("[Image#1]")
    }
    print("INFO image attached=\(attached) path=\(image.path.debugDescription)")
    #expect(attached, "image paste: \(text)")
    session.rawInput(Data("COMPLETE_REPORT_CONTROL".utf8))
    try #require(await TestEnvironment.wait { text.contains("COMPLETE_REPORT_CONTROL") })
    #expect(!text.contains("[<35;114;47M"), "a complete report must be parsed as a mouse event")
    // Force a separate input read of ESC: this is an intentional malformed
    // delivery control, not a proposed terminal behavior.
    session.rawInput(Data([0x1b]))
    _ = await TestEnvironment.wait(seconds: 0.1) { false }
    session.rawInput(Data("[<35;114;47M".utf8))
    #expect(await TestEnvironment.wait { text.contains("[<35;114;47M") },
      "the split-report control did not reproduce the visible suffix: \(text)")
    print("INFO complete SGR report parsed; deliberately split ESC reproduced literal [<35;114;47M")
    session.close()
    var reaped = false
    #expect(await TestEnvironment.wait(seconds: 4) {
      session.statistics { reaped = $0["child_reaped"] as? Bool == true }
      return reaped
    }, "the diagnostic must reap its Codex child")
  }
}

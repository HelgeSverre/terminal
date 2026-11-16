import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalHost

@Suite(.serialized) @MainActor struct OpenTerminalFileTests {
  @Test func aFileLaunchReapsTheUnusedEarlyShell() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-early-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let early = LaunchSpec(executable: "/bin/sh", arguments: ["/bin/sh", "-c",
      "trap '' HUP; printf '%s' $$ > \"$1\"; exec /bin/sleep 30", "early", pidFile.path], cwd: "/tmp")
    EarlyChild.start(early, grid: (80, 24))
    try #require(await TestEnvironment.wait { FileManager.default.fileExists(atPath: pidFile.path) })
    let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
    let session = TerminalSession(launch: LaunchSpec(executable: "/usr/bin/true", arguments: ["true"], cwd: "/tmp"))
    defer { session.close() }
    #expect(await TestEnvironment.wait(seconds: 4) { kill(pid, 0) == -1 && errno == ESRCH },
      "the early shell must be ended and reaped when a file replaces it")
  }

  @Test func executesAHandedOffScriptWithLiteralPathAndItsOwnDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal open \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("it's a $(touch INJECTED) 猫.command")
    // Toolbox's generated files have a shebang, execute permission and remove
    // themselves. Run that contract through a real PTY, not just an argv check.
    try Data("#!/bin/sh\n/bin/rm -f -- \"$0\"\nprintf 'OPENED<%s>DIR<%s>' \"$0\" \"$PWD\"\nexit 7\n".utf8)
      .write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let launch = try OpenTerminalFile.launch(path: script.path, launcher: TestEnvironment.launcher)
    #expect(launch.arguments == [script.path])
    #expect(launch.cwd == root.path)
    let session = TerminalSession(launch: launch)
    defer { session.close() }
    var text = ""
    var end: SessionEnd?
    session.onSnapshot = { text = $0.rows.map { $0.cells.map(\.text).joined() }.joined() }
    session.onEnd = { end = $0 }
    #expect(await TestEnvironment.wait { end != nil && text.contains("DIR<") })
    #expect(end?.exitCode == 7)
    #expect(end?.closesPane == false, "keep command output visible after it exits")
    #expect(text.contains("OPENED<\(script.path)>DIR<\(root.path)>"), "\(text)")
    #expect(!FileManager.default.fileExists(atPath: script.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTED").path))
  }

  @Test func refusesMissingFilesDirectoriesAndNonexecutables() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal reject \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("not executable.command")
    try Data("exit 0\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
    for path in [root.path, script.path, root.appendingPathComponent("missing").path] {
      #expect(throws: (any Error).self) { try OpenTerminalFile.launch(path: path, launcher: nil) }
    }
    let binary = try OpenTerminalFile.launch(path: "/usr/bin/true", launcher: nil)
    #expect(binary.arguments == ["/usr/bin/true"])
  }
}

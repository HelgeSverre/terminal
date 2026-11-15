import Foundation
import Testing
@testable import TerminalHost

/// A launch with no helper program: the session starts the child itself.
@Suite @MainActor struct DirectLaunchTests {
  private func shell(_ script: String, cwd: String = "/tmp") -> LaunchSpec {
    LaunchSpec(executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], cwd: cwd)
  }
  private func screen(of session: TerminalSession) -> () -> String {
    final class Box { var text = "" }
    let box = Box()
    session.onSnapshot = { box.text = $0.rows.map { $0.cells.map(\.text).joined() }.joined(separator: "\n") }
    return { box.text }
  }

  @Test func theChildRunsOnItsOwnTerminalInTheDirectoryAsked() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("direct launch \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = #"printf 'TTY<%s>\r\n' "$(tty)"; printf 'DIR<%s|%s>\r\n' "$(pwd -P)" "$PWD"; "#
      + #"printf 'TERM<%s|%s>\r\n' "$TERM" "$TERM_PROGRAM"; printf 'SIZE<%s>\r\n' "$(stty size)"; "#
      + #"printf 'LEADER<%s>\r\n' "$(ps -o pgid=,tpgid= -p $$ | tr -s ' ' '-' | sed 's/^-//')-$$"; "#
      + #"printf 'FDS<'; for f in /dev/fd/*; do printf '%s ' "${f##*/}"; done; printf '>\r\n'; exit 7"#
    let session = TerminalSession(launch: shell(script, cwd: directory.path))
    defer { session.close() }
    let text = screen(of: session)
    var end: SessionEnd?
    session.onEnd = { end = $0 }
    #expect(await TestEnvironment.wait { end != nil })
    #expect(end?.exitCode == 7)
    _ = await TestEnvironment.wait { text().contains("FDS<") }
    let shown = text().replacingOccurrences(of: "\n", with: "")
    func between(_ open: String, _ close: String = ">") -> String? {
      guard let start = shown.range(of: open), let end = shown[start.upperBound...].range(of: close) else { return nil }
      return String(shown[start.upperBound..<end.lowerBound])
    }
    #expect(shown.contains("TTY</dev/ttys"), "\(shown)")
    // `pwd -P` names the directory by its real path, under /private.
    let places = try #require(between("DIR<")).split(separator: "|").map(String.init)
    #expect(places.count == 2 && places[0].hasSuffix(directory.path) && places[1] == directory.path, "\(shown)")
    #expect(shown.contains("TERM<xterm-256color|HelgeTerminal>"), "\(shown)")
    #expect(shown.contains("SIZE<24 80>"), "\(shown)")
    // The child leads its session, and inherits nothing beyond its terminal.
    // Its process group is its own and is the terminal's foreground group.
    let leader = try #require(between("LEADER<")).split(separator: "-")
    #expect(leader.count == 3 && Set(leader).count == 1, "\(shown)")
    let descriptors = try #require(between("FDS<")).split(separator: " ").compactMap { Int($0) }
    #expect(!descriptors.isEmpty && descriptors.allSatisfy { $0 <= 3 }, "\(descriptors)")
    #expect(session.processIdentifier != nil)
  }

  /// The terminal is the child's controlling terminal: Control-C typed into
  /// it interrupts the program in the foreground.
  @Test func controlCInterruptsTheForegroundProgram() async {
    let session = TerminalSession(launch: shell("printf DIRECT_READY; exec /bin/sleep 30"))
    defer { session.close() }
    let text = screen(of: session)
    var end: SessionEnd?
    session.onEnd = { end = $0 }
    #expect(await TestEnvironment.wait { text().contains("DIRECT_READY") })
    session.rawInput(Data([3]))
    #expect(await TestEnvironment.wait { end != nil })
    #expect(end?.terminatingSignal == SIGINT)
  }

  @Test func aLaunchThatCannotStartSaysWhichStepFailed() async {
    func failure(_ launch: LaunchSpec) async -> SessionLaunchFailure? {
      let session = TerminalSession(launch: launch)
      defer { session.close() }
      var failure: SessionLaunchFailure?
      session.onLaunchFailure = { failure = $0 }
      _ = await TestEnvironment.wait { failure != nil }
      return failure
    }
    #expect(await failure(LaunchSpec(executable: "/no/such/program", arguments: ["program"], cwd: "/tmp"))
      == .stage(.execute, errno: ENOENT))
    #expect(await failure(shell("true", cwd: "/no/such/directory")) == .stage(.workingDirectory, errno: ENOENT))
    #expect(await failure(shell("true", cwd: "/etc/hosts")) == .stage(.workingDirectory, errno: ENOTDIR))
  }

  @Test func theLoginShellNeedsNoLauncher() {
    let launch = LaunchSpec.loginShell(cwd: NSHomeDirectory())
    #expect(launch.launcher == nil && launch.isLoginShell && launch.isValid)
  }
}

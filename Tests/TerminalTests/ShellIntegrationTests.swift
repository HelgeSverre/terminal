import Foundation
import Testing
import TerminalInterop
@testable import TerminalEngine
@testable import TerminalHost

@Suite enum ShellIntegrationTests {
  static let resources = TestEnvironment.repository.appendingPathComponent("Sources/TerminalHost/Resources/ShellIntegration").path

  @Test static func startupContracts() {
    let bash = LaunchSpec(executable: "/bin/bash", arguments: ["/bin/bash"], cwd: "/",
                          shellIntegrationDirectory: resources).preparedShellIntegration()
    #expect(bash.arguments == ["/bin/bash", "--rcfile", resources + "/bash/rc.bash", "-i"])
    for arguments in [["/bin/bash", "-l"], ["/bin/bash", "-c", "true"], ["/bin/bash", "--norc"]] {
      let launch = LaunchSpec(executable: "/bin/bash", arguments: arguments, cwd: "/", shellIntegrationDirectory: resources)
      #expect(launch.preparedShellIntegration().arguments == arguments)
    }
    let fish = LaunchSpec(executable: "/opt/homebrew/bin/fish", arguments: ["fish", "-l"], cwd: "/",
                          shellIntegrationDirectory: resources).preparedShellIntegration()
    #expect(fish.arguments.prefix(2) == ["fish", "-l"])
    #expect(fish.arguments.contains("--init-command"))
    let missing = LaunchSpec(executable: "/bin/bash", arguments: ["bash"], cwd: "/",
                             shellIntegrationDirectory: resources + "/missing")
    #expect(missing.preparedShellIntegration().arguments == ["bash"])
  }

  @Test static func commandMetadataAndNavigation() throws {
    let terminal = try #require(helge_terminal_create(12, 3))
    defer { helge_terminal_destroy(terminal) }
    func feed(_ text: String) { OSC52ProtocolTests.feed(terminal, text, chunk: 1) }
    feed("\u{1b}]7;file://localhost/work\u{7}\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}false\r\n\u{1b}]133;C\u{7}failure\r\n\u{1b}]133;D;1\u{7}")
    let commands = swiftTerminalCommands(terminal)
    #expect(commands.count == 1)
    #expect(commands.first?.exitStatus == 1)
    #expect(commands.first?.completed == true)
    #expect(commands.first?.directory == "file://localhost/work")
    feed("more\r\nlines\r\nend\r\n")
    swiftTerminalNavigateCommand(terminal, older: true)
    #expect(swiftTerminalSnapshot(terminal, scroll: nil, now: 0).snapshot?.scroll_offset ?? 0 > 0)
    swiftTerminalNavigateCommand(terminal, older: false)
    #expect(swiftTerminalSnapshot(terminal, scroll: nil, now: 0).snapshot?.scroll_offset == 0)
    feed("\u{1b}[?1049h\u{1b}]133;C\u{7}\u{1b}]133;D;0\u{7}\u{1b}[?1049l")
    #expect(swiftTerminalCommands(terminal).count == 1)
    feed("\u{1b}c")
    #expect(swiftTerminalCommands(terminal).isEmpty)
  }

  @Test static func malformedMarkersAndBoundedRecords() {
    var history = TerminalCommandHistory()
    history.marker("D;99", row: 1, directory: nil)
    #expect(history.records.isEmpty)
    for row in 1...600 {
      history.marker("A", row: UInt64(row), directory: nil)
      history.marker("C", row: UInt64(row), directory: nil)
      history.marker("C", row: UInt64(row), directory: nil)
      history.marker("D;99999999999999999999999999", row: UInt64(row), directory: nil)
    }
    #expect(history.records.count == 512)
    #expect(history.records.first?.promptRowID == 89)
    #expect(history.records.last?.exitStatus == nil)
    #expect(history.records.last?.completed == true)
    history.marker("C", row: 601, directory: nil)
    history.marker("A", row: 602, directory: nil)
    history.marker("C", row: 602, directory: nil)
    history.marker("D;7", row: 602, directory: nil)
    #expect(history.records.last?.exitStatus == 7, "a missing D cannot poison subsequent commands")
  }

  @Test static func bashPreservesPromptAndTrap() throws {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["--norc", "-i", "-c", """
      PS1='user prompt> '; PROMPT_COMMAND=': user_hook'; trap ': user_debug' DEBUG
      before=$(trap -p DEBUG)
      source "$HOOKS"
      [[ $(trap -p DEBUG) == "$before" ]] || exit 41
      [[ $PROMPT_COMMAND == *': user_hook'* ]] || exit 42
      _helge_terminal_ready
      [[ $PS1 == 'user prompt> '* ]] || exit 43
      source "$HOOKS"
      printf 'HOOK_PRESERVED'
      """]
    process.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin", "TERM": "xterm",
                           "HOOKS": resources + "/bash/hooks.bash"]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: output, as: UTF8.self).contains("HOOK_PRESERVED"))
  }
}

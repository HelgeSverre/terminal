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

  @Test static func commandNavigationSurvivesWidthReflow() throws {
    let terminal = try #require(helge_terminal_create(12, 3))
    defer { helge_terminal_destroy(terminal) }
    func feed(_ text: String) { OSC52ProtocolTests.feed(terminal, text, chunk: 64) }
    func offset() -> Int? { swiftTerminalSnapshot(terminal, scroll: nil, now: 0).snapshot?.scroll_offset }
    func firstLine() -> String? {
      swiftTerminalSnapshot(terminal, scroll: nil, now: 0).snapshot?.rows.first?.cells.map(\.text).joined()
    }
    for name in ["first", "second"] {
      feed("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}\(name)\r\n\u{1b}]133;C\u{7}a long line of output that wraps\r\nmore\r\n\u{1b}]133;D;0\u{7}")
    }
    feed("tail\r\ntail\r\ntail\r\n")
    #expect(helge_terminal_resize(terminal, 20, 3))
    let before = swiftTerminalCommands(terminal)
    #expect(before.count == 2)
    swiftTerminalNavigateCommand(terminal, older: true)
    #expect(firstLine()?.hasPrefix("$ second") == true, "the newest prompt above the viewport")
    swiftTerminalNavigateCommand(terminal, older: true)
    #expect(firstLine()?.hasPrefix("$ first") == true)
    swiftTerminalNavigateCommand(terminal, older: false)
    #expect(firstLine()?.hasPrefix("$ second") == true)
    swiftTerminalNavigateCommand(terminal, older: false)
    #expect(offset() == 0)
    #expect(helge_terminal_resize(terminal, 20, 5), "a height change keeps row identities")
    #expect(swiftTerminalCommands(terminal) == before)
  }

  @Test static func commandRecordsFollowRemappedRowsAndKeepEvictedOnes() {
    var history = TerminalCommandHistory()
    history.marker("A", row: 1, directory: nil); history.marker("C", row: 2, directory: nil); history.marker("D;0", row: 3, directory: nil)
    history.marker("A", row: 4, directory: nil)
    #expect(history.rowIDs == [1, 2, 3, 4])
    history.remap([1: 11, 3: 13, 4: 14])
    #expect(history.records.first?.promptRowID == 11 && history.records.first?.commandRowID == 2 && history.records.first?.endRowID == 13)
    history.marker("C", row: 15, directory: nil)
    #expect(history.records.last?.promptRowID == 14, "a pending prompt follows its row too")
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
      # A value ending in a semicolon, as zoxide and `history -a;` leave it.
      (unset _HELGE_TERMINAL_BASH_INSTALLED; trap - DEBUG; PROMPT_COMMAND='user_ran=1;'
       source "$HOOKS"; eval "$PROMPT_COMMAND" >/dev/null 2>&1; [[ $user_ran == 1 ]]) || exit 44
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

  @Test static func fishPreservesPipelineStatus() throws {
    guard let executable = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["--no-config", "-i", "-c", """
      function fish_prompt
        printf 'PIPE_%s\\n' (string join , $pipestatus)
      end
      source "$HOOKS"
      false | true
      fish_prompt
      _helge_terminal_preexec
      false
      _helge_terminal_postexec
      """]
    process.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin", "TERM": "xterm",
                           "HOOKS": resources + "/fish/hooks.fish"]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(output.contains("PIPE_1,0"))
    #expect(output.contains("\u{1b}]133;D;1\u{7}"))
  }
}

@Suite(.serialized) @MainActor struct ShellIntegrationSessionTests {
  @Test func directBashLaunchReportsExitStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bash-hooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("PS1='bash> '; PROMPT_COMMAND=': original_hook'\n".utf8).write(to: directory.appendingPathComponent(".bashrc"))
    let session = TerminalSession(launch: LaunchSpec(executable: "/bin/bash", arguments: ["/bin/bash"],
      cwd: directory.path, environment: ["HOME": directory.path],
      shellIntegrationDirectory: ShellIntegrationTests.resources))
    defer { session.close() }
    var ready = false
    session.onSnapshot = { ready = $0.input_ready == true }
    #expect(await TestEnvironment.wait { ready })
    session.rawInput(Data("false\r".utf8))
    var commands: [TerminalCommandRecord] = []
    #expect(await TestEnvironment.wait {
      session.commandHistory { commands = $0 }
      return commands.last?.completed == true
    })
    #expect(commands.last?.exitStatus == 1)
  }

  @Test func directZshLaunchPreservesExplicitConfigAndReportsExitStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-hooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("PS1='integration> '; unset HISTFILE\n".utf8).write(to: directory.appendingPathComponent(".zshrc"))
    let session = TerminalSession(launch: LaunchSpec(executable: "/bin/zsh", arguments: ["/bin/zsh"],
      cwd: directory.path, environment: ["ZDOTDIR": directory.path],
      shellIntegrationDirectory: ShellIntegrationTests.resources))
    defer { session.close() }
    var ready = false
    session.onSnapshot = { ready = $0.input_ready == true }
    #expect(await TestEnvironment.wait { ready })
    session.rawInput(Data("false\r".utf8))
    var commands: [TerminalCommandRecord] = []
    #expect(await TestEnvironment.wait {
      session.commandHistory { commands = $0 }
      return commands.last?.completed == true
    })
    #expect(commands.last?.exitStatus == 1)
    #expect(commands.last?.directory?.hasPrefix("file://localhost/") == true)
  }
}

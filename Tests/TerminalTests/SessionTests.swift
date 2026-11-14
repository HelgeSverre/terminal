import Darwin
import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
import TerminalInterop
@testable import TerminalSession

/// Serialized: the scenarios share the process, and some change the process
/// environment (ZDOTDIR) or fill process-wide state while they run. Each test
/// gets its own instance, so `ownedSessions` is per scenario.
@Suite(.serialized) @MainActor final class SessionTests {
  var ownedSessions: [Session] = []
  func own(_ session: Session) -> Session {
    ownedSessions.append(session)
    return session
  }
  /// A scenario closes its sessions at its own boundary and again here, so a
  /// failed assertion cannot strand a PTY; then every child must be reaped.
  func expectOwnedReaped() async {
    ownedSessions.forEach { $0.close() }
    var unreaped = Set(ownedSessions.indices)
    var states: [Int: [String: Any]] = [:]
    let reaped = await TestEnvironment.wait(seconds: 2.25) {
      for index in unreaped {
        ownedSessions[index].statistics { values in
          states[index] = values
          if values["child_reaped"] as? Bool == true { unreaped.remove(index) }
        }
      }
      return unreaped.isEmpty
    }
    #expect(reaped, "owned session cleanup incomplete: unreaped=\(unreaped.sorted()), states=\(states)")
  }
  static func pause(_ seconds: TimeInterval) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
  }
  func spec(_ script: String) -> LaunchSpec { TestEnvironment.shell(script) }
  func zshSpec(launcher: String) -> LaunchSpec {
    LaunchSpec(executable: "/bin/zsh", arguments: ["/bin/zsh", "-l"], cwd: "/tmp", launcher: launcher)
  }
  /// The spawner finds the shell integration beside the launcher, at
  /// `../Resources/ShellIntegration`, as in the app bundle. The package's
  /// build products have no such layout, so this builds a minimal one from
  /// symlinks to the real launcher and the repository's integration scripts.
  static func integrationBundle() throws -> (root: URL, launcher: String) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-integration-bundle-\(UUID().uuidString)", isDirectory: true)
    let macOS = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let launcher = macOS.appendingPathComponent("TerminalLauncher")
    try FileManager.default.createSymbolicLink(atPath: launcher.path, withDestinationPath: TestEnvironment.launcher)
    try FileManager.default.createSymbolicLink(
      atPath: resources.appendingPathComponent("ShellIntegration").path,
      withDestinationPath: TestEnvironment.repository.appendingPathComponent("Resources/Terminal/ShellIntegration").path)
    return (root, launcher.path)
  }
  func rubySpec(_ script: String, _ arguments: [String]) -> LaunchSpec {
    LaunchSpec(
      executable: "/usr/bin/ruby", arguments: ["/usr/bin/ruby", "-e", script] + arguments,
      cwd: "/tmp", launcher: TestEnvironment.launcher)
  }
  static func selectionRow(_ snapshot: TerminalSnapshot, containing marker: String) -> Int? {
    snapshot.rows.firstIndex { row in row.cells.map(\.text).joined().contains(marker) }
  }
  static let shiftPress = TerminalKeyEvent(
    text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: 400,
    modifiers: 1, event: 0)
  static let commandPress = TerminalKeyEvent(
    text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: 403,
    modifiers: 9, event: 0)

  @Test func splitInheritsCWD() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    let splitFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal split 猫 #% \(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: splitFolder, withIntermediateDirectories: false)
    } catch {
      Issue.record("could not create split fixture: \(error)")
    }
    defer { try? FileManager.default.removeItem(at: splitFolder) }
    let splitAlias = splitFolder.appendingPathComponent("logical link")
    do {
      try FileManager.default.createSymbolicLink(atPath: splitAlias.path, withDestinationPath: splitFolder.path)
    } catch {
      Issue.record("could not create split alias: \(error)")
    }
    let splitURL = splitAlias.absoluteString
    let parent = own(Session(launch: LaunchSpec(executable: "/bin/sh",
      arguments: ["/bin/sh", "-c", "stty -echo; cd -- \"$1\"; printf '\\033]7;%s\\007SPLIT_CWD_READY' \"$2\"; IFS= read -r line",
        "split-fixture", splitAlias.path, splitURL], cwd: "/tmp", launcher: spec("").launcher)))
    var sibling: Session?
    var parentCWD: String?, childText = ""
    var parentEnded = false, siblingEnded = false, siblingMatched = false
    parent.onStatus = { if $0 == "Session finished" { parentEnded = true } }
    parent.onSnapshot = { snapshot in
      parentCWD = snapshot.cwd
      guard sibling == nil, snapshot.cwd == splitURL,
        snapshot.rows.flatMap({ $0.cells }).map({ $0.text }).joined().contains("SPLIT_CWD_READY")
      else { return }
      let launch = parent.siblingLaunch
      #expect(URL(fileURLWithPath: launch.cwd).resolvingSymlinksInPath().path == splitFolder.resolvingSymlinksInPath().path,
        "split sibling cwd resolved outside fixture: \(launch.cwd)")
      let child = self.own(Session(launch: LaunchSpec(executable: "/bin/sh",
        arguments: ["/bin/sh", "-c", "printf 'SPLIT_CHILD_PWD=%s\\n' \"$PWD\""],
        cwd: launch.cwd, launcher: self.spec("").launcher)))
      sibling = child
      child.onStatus = { if $0 == "Session finished" { siblingEnded = true } }
      child.onSnapshot = { snapshot in
        let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
        childText = text
        if let marker = text.range(of: "SPLIT_CHILD_PWD=") {
          let path = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
          let actual = try? FileManager.default.attributesOfItem(atPath: path)
          let expected = try? FileManager.default.attributesOfItem(atPath: splitAlias.path)
          siblingMatched = siblingMatched || (path == splitAlias.path && actual?[.systemFileNumber] as? NSNumber != nil &&
            actual?[.systemFileNumber] as? NSNumber == expected?[.systemFileNumber] as? NSNumber)
        }
      }
      #expect(parent.input("\n"), "split parent rejected completion input")
    }
    _ = await TestEnvironment.wait(seconds: 8) { parentEnded && siblingEnded && siblingMatched }
    parent.close(); sibling?.close()
    #expect(siblingMatched, "split_inherits_cwd")
    #expect(parentEnded && siblingEnded, "split_children_reaped")
    #expect(parentEnded && siblingEnded && siblingMatched,
      "split cwd: parent=\(parentEnded), child=\(siblingEnded), match=\(siblingMatched), cwd=\(String(describing: parentCWD)), childText=\(childText)")
    await expectOwnedReaped()
  }

  @Test func readBufferOwnedFIFOAndEOF() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Queue many distinct read events behind resumable parser work. Every DSR
    // reply must preserve its original position command even after the next
    // PTY read reuses scratch storage; a final snapshot alone cannot prove it.
    let readBufferScript = #"""
      stty raw -echo
      exec /usr/bin/ruby -e '
      STDOUT.sync = true
      payload = "X\e[500000b"
      expected = ""
      8192.times do |i|
        row = i % 20 + 1
        column = i / 20 % 60 + 1
        payload << "\e[#{row};#{column}H\e[6n"
        expected << "\e[#{row};#{column}R"
      end
      STDOUT.write(payload)
      received = STDIN.read(expected.bytesize)
      marker = received == expected ? "READ_BUFFER_FIFO_OK" : "READ_BUFFER_FIFO_BAD"
      print "\e[2J\e[H#{marker}"
      '
      """#
    let readBuffer = own(Session(launch: spec(readBufferScript)))
    var readBufferOK = false, readBufferFinished = false
    var readBufferStats: [String: Any] = [:]
    readBuffer.onSnapshot = { snapshot in
      readBufferOK = snapshot.rows.flatMap { $0.cells }.map(\.text).joined().contains("READ_BUFFER_FIFO_OK")
    }
    readBuffer.onStatus = { if $0 == "Session finished" { readBufferFinished = true } }
    _ = await TestEnvironment.wait(seconds: 8) { readBufferOK && readBufferFinished }
    readBuffer.statistics { readBufferStats = $0 }
    _ = await TestEnvironment.wait(seconds: 8) { !readBufferStats.isEmpty }
    let receivedBytes = (readBufferStats["bytes_read"] as? NSNumber)?.uint64Value ?? 0
    let parsedBytes = (readBufferStats["bytes_parsed"] as? NSNumber)?.uint64Value ?? 0
    #expect(readBufferOK && readBufferFinished && receivedBytes > 65_536 && receivedBytes == parsedBytes && readBufferStats["read_ended"] as? Bool == true && readBufferStats["parser_ended"] as? Bool == true && (readBufferStats["queued_output_bytes"] as? Int) == 0, "read-buffer FIFO/EOF: marker=\(readBufferOK), finished=\(readBufferFinished), read=\(receivedBytes), parsed=\(parsedBytes), stats=\(readBufferStats)")
    readBuffer.close()
    await expectOwnedReaped()
  }

  @Test func orderedModeEncodingAfterREP() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // A UI snapshot is deliberately coalesced, so it cannot timestamp parser order.
    // Check both sides of the resumable packet boundary directly, then exercise
    // Session's FIFO against a real PTY child below.
    if let orderingCore = terminal_create(80, 24) {
      defer { terminal_destroy(orderingCore) }
      let packet = Data("X\u{1b}[500000b\u{1b}[?2004h".utf8)
      let capture: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = {
        context, bytes, count in
        guard let context, let bytes, count > 0 else { return }
        Unmanaged<NSMutableData>.fromOpaque(context).takeUnretainedValue().append(bytes, length: count)
      }
      func encodePaste() -> Data {
        let encoded = NSMutableData()
        let accepted = "hello\nworld".withCString {
          terminal_input(orderingCore, $0, 1, 0, 0, Unmanaged.passUnretained(encoded).toOpaque(), capture)
        }
        #expect(accepted, "ordering core rejected paste input")
        return encoded as Data
      }
      let firstAccepted = packet.withUnsafeBytes {
        terminal_feed(orderingCore, $0.bindMemory(to: UInt8.self).baseAddress!, packet.count, 0)
      }
      #expect(firstAccepted < packet.count && terminal_has_work(orderingCore),
        "REP packet did not yield before its mode suffix")
      #expect(encodePaste() == Data("hello\rworld".utf8), "input_before_mode_suffix_is_unbracketed")
      var accepted = firstAccepted
      packet.withUnsafeBytes { packet in
        let bytes = packet.bindMemory(to: UInt8.self)
        while accepted < packet.count || terminal_has_work(orderingCore) {
          accepted += terminal_feed(orderingCore, bytes.baseAddress!.advanced(by: accepted), packet.count - accepted, 0)
        }
      }
      #expect(encodePaste() == Data("\u{1b}[200~hello\rworld\u{1b}[201~".utf8), "input_after_accepted_output_is_bracketed")
    } else {
      Issue.record("could not create ordering core")
    }
    // The child validates the final PTY receipt, independent of snapshot cadence.
    let orderedScript =
      "stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print \"X\\e[500000b\\e[?2004hREADY\"; s=STDIN.read(23); print(s==\"\\e[200~hello\\rworld\\e[201~\" ? \"\\r\\nORDERED_PASTE_OK\" : \"\\r\\nBAD_PASTE\")'"
    let ordered = own(Session(launch: spec(orderedScript)))
    var sent = false
    var done = false
    ordered.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !sent && text.contains("X") {
        sent = true
        #expect(ordered.input("hello\nworld", key: 1), "input_admitted_for_ordered_output")
      }
      if text.contains("ORDERED_PASTE_OK") { done = true }
    }
    _ = await TestEnvironment.wait(seconds: 10) { done }
    #expect(done, "the child must receive the paste bracketed by the mode the earlier REP output set")
    ordered.close()
    await expectOwnedReaped()
  }

  @Test func zshStartupGate() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // The bundled zsh integration emits A before its first line-init B. A
    // private FIFO makes that real boundary deterministic without a timer.
    let bundle = try Self.integrationBundle()
    defer { try? FileManager.default.removeItem(at: bundle.root) }
    zshFixture: do {
      let privateZdotdir = FileManager.default.temporaryDirectory
        .appendingPathComponent("terminal-zsh-ready-\(UUID().uuidString)", isDirectory: true)
      let releaseFIFO = privateZdotdir.appendingPathComponent("line-init-release")
      let previousZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
      defer {
        if let previousZdotdir { setenv("ZDOTDIR", previousZdotdir, 1) }
        else { unsetenv("ZDOTDIR") }
        try? FileManager.default.removeItem(at: privateZdotdir)
      }
      do {
        try FileManager.default.createDirectory(at: privateZdotdir, withIntermediateDirectories: true)
      } catch {
        Issue.record("could not create private ZDOTDIR fixture: \(error)")
      }
      guard mkfifo(releaseFIFO.path, 0o600) == 0 else {
        Issue.record("could not create startup FIFO: \(String(cString: strerror(errno)))")
        break zshFixture
      }
      let fifo = open(releaseFIFO.path, O_RDWR | O_NONBLOCK)
      guard fifo >= 0 else {
        Issue.record("could not open startup FIFO: \(String(cString: strerror(errno)))")
        break zshFixture
      }
      defer { close(fifo) }
      let quotedFIFO = "'" + releaseFIFO.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
      do {
        try """
          HISTFILE=/dev/null
          HISTSIZE=0
          SAVEHIST=0
          PROMPT='READY> '
          autoload -Uz add-zle-hook-widget
          typeset -g _terminal_ready_fifo=\(quotedFIFO)
          typeset -g _terminal_ready_fixture_waited=0
          function _terminal_ready_fixture_gate() {
            if (( ! _terminal_ready_fixture_waited )); then
              _terminal_ready_fixture_waited=1
              IFS= read -r _terminal_ready_release < "$_terminal_ready_fifo"
            fi
          }
          add-zle-hook-widget line-init _terminal_ready_fixture_gate
          """.write(
            to: privateZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
      } catch {
        Issue.record("could not write private zsh fixture: \(error)")
        break zshFixture
      }
      setenv("ZDOTDIR", privateZdotdir.path, 1)
      let readyShell = own(Session(launch: zshSpec(launcher: bundle.launcher)))
      var sawDrawing = false
      var sawReady = false
      var startupCommandAttempts = 0
      var admittedAtA = false
      var releaseSent = false
      var startupDone = false
      var admittedAfterB = false
      let outputMarker = "ZSH_STARTUP_GATE_OK"
      func admitStartupCommand(after snapshot: TerminalSnapshot) -> Bool {
        guard snapshot.input_ready == true else { return false }
        startupCommandAttempts += 1
        return readyShell.input("printf '%s%s\\n' ZSH_STARTUP_GATE_ OK\r")
      }
      readyShell.onSnapshot = { snapshot in
        if snapshot.at_prompt && snapshot.input_ready != true {
          sawDrawing = true
          admittedAtA = admitStartupCommand(after: snapshot)
          if !releaseSent {
            let release = Array("go\n".utf8)
            releaseSent = release.withUnsafeBytes {
              Darwin.write(fifo, $0.baseAddress, $0.count) == release.count
            }
          }
        }
        if snapshot.input_ready == true && releaseSent {
          sawReady = true
          if startupCommandAttempts == 0 {
            admittedAfterB = admitStartupCommand(after: snapshot)
          }
        }
        startupDone = snapshot.rows.map { row in
          row.cells.map { $0.text }.joined().trimmingCharacters(in: .whitespaces)
        }.contains(outputMarker)
      }
      _ = await TestEnvironment.wait(seconds: 5) { startupDone }
      let commandRan = admittedAfterB && startupDone
      #expect(sawDrawing && releaseSent && sawReady && !admittedAtA && startupCommandAttempts == 1, "zsh startup gate did not observe A then B: drawing=\(sawDrawing), released=\(releaseSent), ready=\(sawReady)")
      #expect(commandRan, "zsh startup command was not executed after B")
      readyShell.close()
    }
    await expectOwnedReaped()
  }

  @Test func committedTextRoundTrip() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Automation and IME commits use key=0: the C ABI must forward the full
    // committed string rather than silently reducing it to its first scalar.
    let committed = own(Session(launch: spec("stty raw -echo; exec /bin/cat")))
    var committedEchoed = false
    committed.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      committedEchoed = committedEchoed || text.contains("AUTOMATION_TEXT")
    }
    #expect(committed.input("AUTOMATION_TEXT\n"), "committed text input was rejected")
    _ = await TestEnvironment.wait(seconds: 5) { committedEchoed }
    #expect(committedEchoed, "committed_text_round_trip")
    committed.close()
    await expectOwnedReaped()
  }

  @Test func finishedPTYRefusesInput() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    let finished = own(Session(launch: spec("printf FINISHED_PTY_READY")))
    var finishedRead = false
    _ = await TestEnvironment.wait(seconds: 3) {
      finished.statistics { stats in finishedRead = stats["read_ended"] as? Bool == true }
      return finishedRead
    }
    #expect(finishedRead && !finished.input("unexpected input"), "a finished PTY must refuse text")
    var searchRetained = false
    finished.find("FINISHED_PTY_READY") { searchRetained = $0 == .found }
    _ = await TestEnvironment.wait(seconds: 3) { searchRetained }
    #expect(searchRetained, "a finished PTY must retain search")
    finished.close()
    await expectOwnedReaped()
  }

  @Test func finishedPTYRetainsActions() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // EOF ends PTY input, not the read-only terminal owner. A final immutable
    // screen must still prove selection/copy and a projected link activation
    // after the short-lived child has been reaped; ordinary text remains
    // rejected because there is no writer.
    let finishedActions = own(Session(launch: rubySpec(#"""
      STDOUT.sync = true
      print "FINISHED_SELECT \e]8;;https://example.test/finished\e\\FINISHED_LINK\e]8;;\e\\"
      """#, [])))
    var finishedActionSnapshot: TerminalSnapshot?
    var finishedActionReadEnded = false
    var finishedActionReaped = false
    var finishedActionSelectionRequested = false
    var finishedActionSelectionCompleted = false
    var finishedActionSelectionPublished = false
    var finishedActionCopyRequested = false
    var finishedActionCopyText: String?
    var finishedActionLinkRequested = false
    var finishedActionLinkAccepted = false
    var finishedActionSelectionBeforeLink: TerminalSelectionSnapshot?
    var finishedActionSelectionPreserved = false
    finishedActions.onStatus = { status in
      if status.hasPrefix("Process exited") { finishedActionReaped = true }
    }
    finishedActions.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map(\.text).joined()
      if text.contains("FINISHED_SELECT") { finishedActionSnapshot = snapshot }
      if finishedActionSelectionCompleted, !snapshot.selection.segments.isEmpty {
        finishedActionSelectionPublished = true
      }
      if finishedActionLinkAccepted,
         snapshot.selection == finishedActionSelectionBeforeLink {
        finishedActionSelectionPreserved = true
      }
    }
    _ = await TestEnvironment.wait(seconds: 3) {
      finishedActions.statistics { stats in
        finishedActionReadEnded = stats["read_ended"] as? Bool == true
      }
      return finishedActionReadEnded && finishedActionReaped && finishedActionSnapshot != nil
    }
    var finishedActionActivation: VisibleLinkProjection.Activation?
    if let snapshot = finishedActionSnapshot,
       let row = Self.selectionRow(snapshot, containing: "FINISHED_SELECT"),
       let start = snapshot.selectionHit(row: row, boundary: 0),
       let end = snapshot.selectionHit(row: row, boundary: "FINISHED_SELECT".utf8.count),
       let occurrence = VisibleLinkProjection(snapshot: snapshot).occurrences.first(where: {
         $0.target.absoluteString == "https://example.test/finished"
       })
    {
      finishedActionActivation = occurrence.activation
      finishedActionSelectionRequested = finishedActions.selection(
        .range(start: start, end: end, mode: .linear)) { result in
          if case .success = result { finishedActionSelectionCompleted = true }
        }
    }
    _ = await TestEnvironment.wait(seconds: 3) { finishedActionSelectionCompleted && finishedActionSelectionPublished }
    if let snapshot = finishedActionSnapshot, finishedActionSelectionCompleted,
       finishedActionSelectionPublished,
       !snapshot.selection.segments.isEmpty
    {
      finishedActionCopyRequested = finishedActions.selection(
        .copy(expectedSelectionRevision: snapshot.selection.revision)) { result in
          if case .success(let text) = result { finishedActionCopyText = text }
        }
    }
    _ = await TestEnvironment.wait(seconds: 3) { finishedActionCopyText != nil }
    if let activation = finishedActionActivation, finishedActionCopyText == "FINISHED_SELECT" {
      finishedActionSelectionBeforeLink = finishedActionSnapshot?.selection
      finishedActionLinkRequested = finishedActions.activateLink(activation) { result in
        if case .success(let target) = result {
          finishedActionLinkAccepted = target.absoluteString == "https://example.test/finished"
        }
      }
    }
    _ = await TestEnvironment.wait(seconds: 3) { finishedActionLinkAccepted && finishedActionSelectionPreserved }
    #expect(finishedActionReadEnded && finishedActionReaped && finishedActionSelectionRequested && finishedActionSelectionCompleted && finishedActionSelectionPublished && finishedActionCopyRequested && finishedActionCopyText == "FINISHED_SELECT" && finishedActionLinkRequested && finishedActionLinkAccepted && finishedActionSelectionPreserved, "finished PTY read-only actions: eof=\(finishedActionReadEnded), reaped=\(finishedActionReaped), selection=\(finishedActionSelectionCompleted), selection_published=\(finishedActionSelectionPublished), copy=\(String(describing: finishedActionCopyText)), link=\(finishedActionLinkAccepted), selection_preserved=\(finishedActionSelectionPreserved)")
    finishedActions.close()
    await expectOwnedReaped()
  }

  @Test func physicalKeyReachesPTY() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    let physical = own(Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print "PHYSICAL_READY"; key=STDIN.read(1); print(key=="!" ? "\r\nPHYSICAL_KEY_OK" : "\r\nPHYSICAL_KEY_BAD")'"#)))
    var physicalSent = false, physicalDone = false, physicalAdmitted = false
    physical.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !physicalSent && text.contains("PHYSICAL_READY") {
        physicalSent = true
        physicalAdmitted = physical.input(TerminalKeyEvent(
          text: "!", logical: "1", shifted: "!", baseLayout: "1", legacyText: "!", key: 200,
          modifiers: 1, event: 0))
      }
      physicalDone = physicalDone || text.contains("PHYSICAL_KEY_OK")
    }
    _ = await TestEnvironment.wait(seconds: 5) { physicalDone }
    #expect(physicalAdmitted && physicalDone, "the physical key event must reach the PTY as \"!\"")
    physical.close()
    await expectOwnedReaped()
  }

  @Test func typedKeyMetadataBounds() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Typed key metadata is retained across the owner queue. Enormous retained
    // or expanded wire input must be rejected before it can stall the PTY.
    let bounded = own(Session(launch: spec("sleep 1")))
    var boundedStatuses: [String] = []
    bounded.onStatus = { boundedStatuses.append($0) }
    let oversizedMetadata = TerminalKeyEvent(
      text: "", logical: String(repeating: "l", count: 2 * 1024 * 1024),
      shifted: "", baseLayout: "", legacyText: "", key: 200, modifiers: 0, event: 0)
    let oversizedLegacyMetadata = TerminalKeyEvent(
      text: "", logical: "", shifted: "", baseLayout: "",
      legacyText: String(repeating: "l", count: 2 * 1024 * 1024), key: 200, modifiers: 2, event: 0)
    let impossibleExpansion = TerminalKeyEvent(
      text: String(repeating: "x", count: 800_000), logical: "x",
      shifted: "", baseLayout: "x", legacyText: "", key: 200, modifiers: 0, event: 0)
    let shiftedKey = TerminalKeyEvent(
      text: "!", logical: "1", shifted: "!", baseLayout: "1", legacyText: "!", key: 200,
      modifiers: 1, event: 0)
    let modifierKey = TerminalKeyEvent(
      text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: 400,
      modifiers: 1, event: 0)
    let metadataRejected = !bounded.input(oversizedMetadata)
    let legacyMetadataRejected = !bounded.input(oversizedLegacyMetadata)
    let expansionRejected = !bounded.input(impossibleExpansion)
    #expect(bounded.input(shiftedKey) && bounded.input(modifierKey), "typed key paths must be admitted")
    await Self.pause(0.05)
    #expect(metadataRejected && boundedStatuses.contains("Input busy"), "oversized typed metadata must be rejected")
    #expect(legacyMetadataRejected && boundedStatuses.contains("Input busy"), "oversized typed legacy metadata must be rejected")
    #expect(expansionRejected && boundedStatuses.contains("Key input exceeds write limit"), "an impossible expansion must be rejected")
    bounded.close()
    #expect(!Self.shiftPress.isKeyAction && !Self.commandPress.isKeyAction,
      "modifier-only key events were classified as typing")
    await expectOwnedReaped()
  }

  @Test func modifierKeysPreserveViewport() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    func preservesModifierViewport(kitty: Bool) async -> Bool {
      let mode = kitty ? "print \"\\e[=8u\"; " : ""
      let read = kitty ? 2 : 1
      let modifierView = own(Session(launch: spec(
        "stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; \(mode)30.times{|i| print \"modifier#{i}\\r\\n\"}; print \"MODIFIER_READY\"; STDIN.read(\(read)); print \"MODIFIER_TICK\"; sleep 1'")))
      var phase = 0
      var revision: UInt64 = 0
      var rows: [RowSnapshot] = []
      var passed = false
      modifierView.onSnapshot = { snapshot in
        let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
        switch phase {
        case 0 where text.contains("MODIFIER_READY"):
          phase = 1
          modifierView.scroll(3)
        case 1 where !snapshot.following_tail:
          phase = 2
          revision = snapshot.revision
          rows = snapshot.rows
          #expect(modifierView.input(Self.shiftPress), "shift modifier input was rejected")
          #expect(modifierView.input(Self.commandPress), "command modifier input was rejected")
          if !kitty { modifierView.rawInput(Data([0])) }
        case 2 where snapshot.revision > revision:
          passed = !snapshot.following_tail && snapshot.scroll_offset == 3 && snapshot.rows == rows
          phase = 3
        default: break
        }
      }
      _ = await TestEnvironment.wait(seconds: 5) { phase == 3 }
      modifierView.close()
      return phase == 3 && passed
    }
    let legacyPreserved = await preservesModifierViewport(kitty: false)
    let kittyPreserved = await preservesModifierViewport(kitty: true)
    #expect(legacyPreserved, "modifier keys must preserve the anchored viewport (legacy keyboard mode)")
    #expect(kittyPreserved, "modifier keys must preserve the anchored viewport (kitty keyboard mode)")
    await expectOwnedReaped()
  }

  @Test func viewportAnchoringAndClosedInput() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // These events pass through the real owner FIFO and typed snapshot bridge.
    // Focus reports and a paired release must not make history jump to the tail.
    let view = own(Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; 30.times{|i| print "row#{i}\r\n"}; print "VIEW_READY"; STDIN.read(1); print "\r\nVIEW_NEW_OUTPUT"'"#)))
    var viewPhase = 0
    var capturedRows: [RowSnapshot] = []
    view.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      switch viewPhase {
      case 0 where text.contains("VIEW_READY"):
        viewPhase = 1
        view.scroll(3)
      case 1 where !snapshot.following_tail:
        #expect(snapshot.scroll_offset == 3, "scrolling must anchor the viewport")
        capturedRows = snapshot.rows
        viewPhase = 2
        #expect(view.input(key: 2, event: 1), "focus event was rejected")
        #expect(view.input("r", key: 200, event: 2), "key release event was rejected")
      case 2:
        #expect(!snapshot.following_tail && snapshot.scroll_offset == 3 && snapshot.rows == capturedRows, "focus and key release must preserve the anchored viewport")
        viewPhase = 3
        #expect(view.input("x", key: 200), "typing input was rejected")
      case 3 where text.contains("VIEW_NEW_OUTPUT"):
        #expect(snapshot.following_tail && snapshot.scroll_offset == 0, "typing must follow the tail")
        viewPhase = 4
      default: break
      }
    }
    _ = await TestEnvironment.wait(seconds: 5) { viewPhase == 4 }
    #expect(viewPhase == 4, "the viewport scenario stopped in phase \(viewPhase)")
    var shutdownStatuses: [String] = []
    view.onStatus = { shutdownStatuses.append($0) }
    view.close()
    #expect(!view.input(key: 2, event: 0), "closed session admitted focus event")
    #expect(!view.input("r", key: 200, event: 2), "closed session admitted key release")
    await Self.pause(0.05)
    #expect(!shutdownStatuses.contains { $0.hasPrefix("Input") }, "closed focus and key releases must be quiet")
    #expect(!view.input("user text"), "closed session admitted text")
    await Self.pause(0.05)
    #expect(shutdownStatuses.contains("Input closed"), "closed text input must be reported")
    await expectOwnedReaped()
  }

  @Test func rejectedResizePreservesFIFO() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // A rejected resize must not signal the PTY, and a semantic event queued
    // behind it must still reach the child under the retained old geometry.
    let rejectedResizeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-resize-rejection-\(UUID().uuidString)", isDirectory: true)
    let rejectedResizeReceipt = rejectedResizeDirectory.appendingPathComponent("winch.txt")
    do {
      try FileManager.default.createDirectory(at: rejectedResizeDirectory, withIntermediateDirectories: false)
    } catch {
      Issue.record("could not create rejected-resize fixture: \(error)")
    }
    defer { try? FileManager.default.removeItem(at: rejectedResizeDirectory) }
    let rejectedResizeScript = #"""
      STDOUT.sync = true
      trap("WINCH") { File.open(ARGV.fetch(0), "a") { |file| file.puts(`stty size`.strip) } }
      system("stty raw -echo")
      print "RESIZE_REJECT_READY"
      input = STDIN.read(1)
      print "RESIZE_REJECT_INPUT=#{input.ord} SIZE=#{`stty size`.strip}"
      """#
    let rejectedResize = own(Session(launch: rubySpec(rejectedResizeScript, [rejectedResizeReceipt.path])))
    var rejectedResizeRequested = false
    var rejectedResizeDelivered = false
    rejectedResize.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !rejectedResizeRequested && text.contains("RESIZE_REJECT_READY") {
        rejectedResizeRequested = true
        rejectedResize.resize(cols: 4096, rows: 4096)
        #expect(rejectedResize.input("r"), "rejected-resize input was not admitted")
      }
      if text.contains("RESIZE_REJECT_INPUT=114 SIZE=24 80") {
        rejectedResizeDelivered = snapshot.cols == 80 && snapshot.rows.count == 24
      }
    }
    _ = await TestEnvironment.wait(seconds: 8) { rejectedResizeDelivered }
    let rejectedResizeSignals = ((try? String(contentsOf: rejectedResizeReceipt, encoding: .utf8)) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(rejectedResizeRequested && rejectedResizeDelivered && rejectedResizeSignals.isEmpty, "rejected resize: requested=\(rejectedResizeRequested), delivered=\(rejectedResizeDelivered), winch=\(rejectedResizeSignals)")
    rejectedResize.close()
    await expectOwnedReaped()
  }

  @Test func rapidResizeReturnsBeforeInput() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // A resize back to the currently committed geometry is not a no-op while
    // an earlier resize remains queued: it is the size that is wanted, and
    // the later input must observe it. The earlier size is superseded and may
    // be skipped, so the child sees either no size change or both.
    let rapidResizeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-rapid-resize-\(UUID().uuidString)", isDirectory: true)
    let rapidResizeReceipt = rapidResizeDirectory.appendingPathComponent("winch.txt")
    do {
      try FileManager.default.createDirectory(at: rapidResizeDirectory, withIntermediateDirectories: false)
    } catch {
      Issue.record("could not create rapid-resize fixture: \(error)")
    }
    defer { try? FileManager.default.removeItem(at: rapidResizeDirectory) }
    let rapidResizeScript = #"""
      STDOUT.sync = true
      trap("WINCH") { File.open(ARGV.fetch(0), "a") { |file| file.puts(`stty size`.strip) } }
      system("stty raw -echo")
      print "RAPID_RESIZE_READY"
      input = STDIN.read(1)
      print "RAPID_RESIZE_INPUT=#{input.ord} SIZE=#{`stty size`.strip}"
      sleep 0.1
      """#
    let rapidResize = own(Session(launch: rubySpec(rapidResizeScript, [rapidResizeReceipt.path])))
    var rapidResizeRequested = false
    var rapidResizeDelivered = false
    rapidResize.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !rapidResizeRequested && text.contains("RAPID_RESIZE_READY") {
        rapidResizeRequested = true
        rapidResize.resize(cols: 20, rows: 24)
        rapidResize.resize(cols: 80, rows: 24)
        #expect(rapidResize.input("b"), "rapid-resize input was not admitted")
      }
      if text.contains("RAPID_RESIZE_INPUT=98 SIZE=24 80") {
        rapidResizeDelivered = snapshot.cols == 80 && snapshot.rows.count == 24
      }
    }
    _ = await TestEnvironment.wait(seconds: 8) { rapidResizeDelivered }
    let rapidResizeSignals = ((try? String(contentsOf: rapidResizeReceipt, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).map(String.init)
    #expect(rapidResizeRequested && rapidResizeDelivered && rapidResizeSignals.count <= 2, "rapid resize: requested=\(rapidResizeRequested), delivered=\(rapidResizeDelivered), winch=\(rapidResizeSignals)")
    rapidResize.close()
    await expectOwnedReaped()
  }

  @Test func committedResizeBeforeLaterInput() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // The reflow fixture builds enough wide history to require the bridge's
    // resumable path. Input and probes remain after the resize event until its
    // one coherent commit, where the PTY gets exactly one matching WINCH.
    let committedResizeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-resize-commit-\(UUID().uuidString)", isDirectory: true)
    let committedResizeReceipt = committedResizeDirectory.appendingPathComponent("winch.txt")
    do {
      try FileManager.default.createDirectory(at: committedResizeDirectory, withIntermediateDirectories: false)
    } catch {
      Issue.record("could not create committed-resize fixture: \(error)")
    }
    defer { try? FileManager.default.removeItem(at: committedResizeDirectory) }
    let committedResizeScript = #"""
      STDOUT.sync = true
      trap("WINCH") { File.open(ARGV.fetch(0), "a") { |file| file.puts(`stty size`.strip) } }
      system("stty raw -echo")
      row = "r" * 140
      50_000.times { |index| print "%05d %s\r\n" % [index, row] }
      print "RESIZE_COMMIT_READY"
      input = STDIN.read(1)
      print "RESIZE_COMMIT_INPUT=#{input.ord} SIZE=#{`stty size`.strip}"
      """#
    let committedResize = own(Session(launch: rubySpec(committedResizeScript, [committedResizeReceipt.path])))
    var committedResizeRequested = false
    var committedResizeDelivered = false
    var committedResizeProbe = false
    var committedResizeOwnerProbes = 0
    var committedResizeGeometries = Set<String>()
    var scheduleCommittedResizeProbe: (() -> Void)!
    scheduleCommittedResizeProbe = {
      committedResize.queue.async {
        DispatchQueue.main.async {
          guard !committedResizeDelivered else { return }
          committedResizeOwnerProbes += 1
          if committedResizeOwnerProbes < 2 { scheduleCommittedResizeProbe() }
        }
      }
    }
    committedResize.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !committedResizeRequested && text.contains("RESIZE_COMMIT_READY") {
        committedResizeRequested = true
        committedResize.resize(cols: 20, rows: 24)
        #expect(committedResize.input("c"), "committed-resize input was not admitted")
        committedResize.semanticProbe { _ in committedResizeProbe = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
          scheduleCommittedResizeProbe()
        }
      }
      if committedResizeRequested { committedResizeGeometries.insert("\(snapshot.cols)x\(snapshot.rows.count)") }
      if text.contains("RESIZE_COMMIT_INPUT=99 SIZE=24 20") {
        committedResizeDelivered = snapshot.cols == 20 && snapshot.rows.count == 24
      }
    }
    _ = await TestEnvironment.wait(seconds: 30) { committedResizeDelivered && committedResizeProbe }
    let committedResizeSignals = ((try? String(contentsOf: committedResizeReceipt, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).map(String.init)
    #expect(committedResizeRequested && committedResizeDelivered && committedResizeProbe && committedResizeOwnerProbes >= 2 && committedResizeGeometries.isSubset(of: Set(["80x24", "20x24"])) && committedResizeSignals == ["24 20"], "committed resize: requested=\(committedResizeRequested), delivered=\(committedResizeDelivered), semantic_probe=\(committedResizeProbe), owner_probes=\(committedResizeOwnerProbes), geometries=\(committedResizeGeometries), winch=\(committedResizeSignals)")
    committedResize.close()
    await expectOwnedReaped()
  }

  @Test func pendingResizeCloseCancels() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Post A and its close marker from one owner turn. A's admission runs
    // first, then the marker posts Close. The first pump runs after that marker
    // and can only begin the transaction; its continuation is queued behind
    // Close. This proves cancellation after begin and before advance without a
    // timer, extra production API, or a workload-size assumption.
    let cancelledResizeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-resize-cancel-\(UUID().uuidString)", isDirectory: true)
    let cancelledResizeReceipt = cancelledResizeDirectory.appendingPathComponent("winch.txt")
    do {
      try FileManager.default.createDirectory(at: cancelledResizeDirectory, withIntermediateDirectories: false)
    } catch {
      Issue.record("could not create cancelled-resize fixture: \(error)")
    }
    defer { try? FileManager.default.removeItem(at: cancelledResizeDirectory) }
    let cancelledResizeScript = #"""
      STDOUT.sync = true
      trap("WINCH") { File.open(ARGV.fetch(0), "a") { |file| file.puts(`stty size`.strip) } }
      system("stty raw -echo")
      print "RESIZE_CANCEL_READY"
      sleep 30
      """#
    let cancelledResize = own(Session(launch: rubySpec(cancelledResizeScript, [cancelledResizeReceipt.path])))
    var cancelledResizeRequested = false
    var cancelledResizeClosed = false
    var cancelledResizeReaped = false
    var cancelledResizeInputRejected = false
    cancelledResize.onStatus = { status in
      if status.hasPrefix("Process exited") { cancelledResizeReaped = true }
    }
    cancelledResize.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      guard !cancelledResizeRequested, text.contains("RESIZE_CANCEL_READY") else { return }
      cancelledResizeRequested = true
      cancelledResize.queue.async {
        cancelledResize.resize(cols: 20, rows: 24)
        cancelledResize.queue.async {
          cancelledResize.close()
          let inputRejected = !cancelledResize.input("x")
          DispatchQueue.main.async {
            cancelledResizeClosed = true
            cancelledResizeInputRejected = inputRejected
          }
        }
      }
    }
    _ = await TestEnvironment.wait(seconds: 8) { cancelledResizeReaped }
    let cancelledResizeSignals = ((try? String(contentsOf: cancelledResizeReceipt, encoding: .utf8)) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(cancelledResizeRequested && cancelledResizeClosed && cancelledResizeReaped && cancelledResizeInputRejected && cancelledResizeSignals.isEmpty, "cancelled resize: requested=\(cancelledResizeRequested), closed=\(cancelledResizeClosed), reaped=\(cancelledResizeReaped), input_rejected=\(cancelledResizeInputRejected), winch=\(cancelledResizeSignals)")
    await expectOwnedReaped()
  }

  @Test func selectionThroughSession() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Selection hits are proofs from the displayed snapshot. Let the child
    // overwrite the saved row before the owner sees the action, then exercise
    // a primary selection across an alternate-screen transition. The final
    // copy is followed in FIFO by a mode-changing PTY reply and an overwrite.
    let selectionScript = #"""
      STDOUT.sync = true
      system("stty raw -echo")
      print "STALE_TEXT"
      sleep 0.25
      print "\e[1;1HX"
      sleep 0.25
      print "\e[2J\e[HPRIMARY@TEXT"
      sleep 1
      print "\e[?1049hALT_TEXT"
      sleep 1
      print "\e[?1049l"
      input = STDIN.read(5)
      if input == "WORD\n"
        print "\e[?2004hRAW_CALLBACK_RECEIVED"
      end
      input = STDIN.read(1)
      if input == "q"
        print "ACCEPTED_INPUT_AFTER_COPY"
      end
      sleep 30
      """#
    let selectionSession = own(Session(launch: rubySpec(selectionScript, [])))
    var staleHit: TerminalSelectionHit?
    var staleRequested = false
    var staleRejected = false
    var primarySelectionRequested = false
    var primarySelectionCompleted = false
    var selectionWordProfileConfigured = false
    var accessibilityRangeRequested = false
    var accessibilityRangeCompleted = false
    var accessibilityCountersAreIndependent = false
    var accessibilityRequestedRange: NSRange?
    var accessibilityGetterCaptured = false
    var accessibilityRangeRoundTripped = false
    var accessibilityGetterRanges: [NSRange] = []
    var accessibilityGetterText: String?
    var selectionNonsemanticInputsSent = false
    var selectionNonsemanticOwnerProbe = false
    var selectionNonsemanticInputPreserved = false
    var alternateSelectionRequested = false
    var alternateSelectionCompleted = false
    var primaryRestored = false
    var selectionCopyRequested = false
    var selectionCopyText: String?
    var selectionCopyCompleted = false
    var selectionCopyBackpressureHeld = false
    var selectionCopyRawIssued = false
    var selectionCopyRawReached = false
    var selectionSemanticInputRequested = false
    var selectionModeAfterCopy = false
    var selectionClearedByAcceptedInput = false
    selectionSession.onSnapshot = { snapshot in
      if staleHit == nil, let row = Self.selectionRow(snapshot, containing: "STALE_TEXT") {
        staleHit = snapshot.selectionHit(row: row, boundary: 0)
      }
      if !staleRequested, let staleHit, snapshot.rows.indices.contains(staleHit.row),
         snapshot.rows[staleHit.row].revision != staleHit.rowRevision
      {
        staleRequested = selectionSession.selection(.begin(staleHit, granularity: .character)) { result in
          if case .failure(.staleTarget) = result { staleRejected = true }
        }
      }
      // This must use a received snapshot, not an independently constructed
      // presentation: snapshot revision tracks emulator mutations, whereas
      // presentation IDs identify immutable publications and intentionally
      // advance independently.
      if !snapshot.alternate, !accessibilityRangeRequested,
         let presentation = snapshot.selectionPresentation,
         presentation.snapshotID != snapshot.revision
      {
        let projection = AccessibilityProjection(snapshot: snapshot)
        if let stringRange = projection.text.range(of: "PRIMARY@TEXT") {
          let range = NSRange(stringRange, in: projection.text)
          if let request = projection.presentedRange(for: [range]) {
            accessibilityCountersAreIndependent = true
            accessibilityRequestedRange = range
            accessibilityRangeRequested = selectionSession.selection(
              .range(start: request.start, end: request.end, mode: request.mode)) { result in
                if case .success = result { accessibilityRangeCompleted = true }
              }
          }
        }
      }
      if !snapshot.alternate, accessibilityRangeCompleted, !accessibilityGetterCaptured,
         snapshot.selection.phase == .committed, !snapshot.selection.segments.isEmpty,
         let expectedRange = accessibilityRequestedRange
      {
        let projection = AccessibilityProjection(snapshot: snapshot)
        accessibilityGetterCaptured = true
        accessibilityGetterRanges = projection.selectedRanges()
        accessibilityGetterText = projection.selectedText()
        accessibilityRangeRoundTripped =
          accessibilityGetterRanges == [expectedRange]
          && accessibilityGetterText == "PRIMARY@TEXT"
      }
      if !snapshot.alternate, accessibilityGetterCaptured, !primarySelectionRequested,
         let row = Self.selectionRow(snapshot, containing: "PRIMARY@TEXT"),
         let hit = snapshot.selectionHit(row: row, boundary: "PRIMARY".utf8.count)
      {
        let profile = TerminalSelectionWordProfile(punctuation: "@")!
        selectionSession.configure(TerminalSessionConfiguration(selectionWordProfile: profile))
        selectionWordProfileConfigured = true
        primarySelectionRequested = selectionSession.selection(.begin(hit, granularity: .word)) { result in
          if case .success = result { primarySelectionCompleted = true }
        }
      }
      if snapshot.alternate, !alternateSelectionRequested,
         let row = Self.selectionRow(snapshot, containing: "ALT_TEXT"),
         let start = snapshot.selectionHit(row: row, boundary: 0),
         let end = snapshot.selectionHit(row: row, boundary: "ALT_TEXT".utf8.count)
      {
        alternateSelectionRequested = selectionSession.selection(.range(start: start, end: end, mode: .linear)) { result in
          if case .success = result { alternateSelectionCompleted = true }
        }
      }
      if !snapshot.alternate, primarySelectionCompleted, alternateSelectionCompleted,
         !snapshot.selection.segments.isEmpty
      {
        primaryRestored = true
        if !selectionCopyRequested {
          selectionCopyRequested = selectionSession.selection(
            .copy(expectedSelectionRevision: snapshot.selection.revision)) { result in
              if case .success(let text) = result {
                selectionCopyText = text
                selectionCopyCompleted = true
                selectionCopyRawIssued = true
                selectionSession.rawInput(Data("WORD\n".utf8))
              }
            }
          selectionCopyBackpressureHeld = !selectionSession.selection(
            .copy(expectedSelectionRevision: snapshot.selection.revision)) { _ in }
        }
      }
      if !snapshot.alternate, primarySelectionCompleted, !selectionNonsemanticInputsSent,
         !snapshot.selection.segments.isEmpty
      {
        selectionNonsemanticInputsSent =
          selectionSession.input(Self.shiftPress)
          && selectionSession.input(key: 2, event: 0)
          && selectionSession.input("r", key: 200, event: 2)
          && selectionSession.input("", key: 999)
        selectionSession.semanticProbe { _ in selectionNonsemanticOwnerProbe = true }
      }
      if !snapshot.alternate, selectionNonsemanticOwnerProbe, !snapshot.selection.segments.isEmpty {
        selectionNonsemanticInputPreserved = true
      }
      selectionModeAfterCopy = selectionModeAfterCopy
        || (snapshot.modes.bracketed_paste && Self.selectionRow(snapshot, containing: "RAW_CALLBACK_RECEIVED") != nil)
      selectionCopyRawReached = selectionCopyRawReached
        || Self.selectionRow(snapshot, containing: "RAW_CALLBACK_RECEIVED") != nil
      if selectionCopyRawReached, !selectionSemanticInputRequested {
        selectionSemanticInputRequested = selectionSession.input("q")
      }
      if Self.selectionRow(snapshot, containing: "ACCEPTED_INPUT_AFTER_COPY") != nil {
        selectionClearedByAcceptedInput = snapshot.selection.segments.isEmpty
      }
    }
    _ = await TestEnvironment.wait(seconds: 8) { staleRejected && selectionCopyCompleted && selectionCopyRawReached && selectionModeAfterCopy && selectionClearedByAcceptedInput }
    #expect(staleRequested && staleRejected, "stale selection: hit=\(staleHit != nil), requested=\(staleRequested), rejected=\(staleRejected)")
    #expect(primarySelectionRequested && primarySelectionCompleted && alternateSelectionRequested && alternateSelectionCompleted && primaryRestored, "cross-screen selection: primary=\(primarySelectionCompleted), alternate=\(alternateSelectionCompleted), restored=\(primaryRestored)")
    #expect(selectionCopyCompleted && selectionCopyText == "PRIMARY@TEXT" && selectionCopyRawReached, "selection copy: completed=\(selectionCopyCompleted), text=\(String(describing: selectionCopyText)), raw_receipt=\(selectionCopyRawReached)")
    #expect(selectionCopyCompleted && selectionModeAfterCopy, "selection mode FIFO: copy=\(selectionCopyCompleted), mode=\(selectionModeAfterCopy)")
    #expect(selectionWordProfileConfigured && primarySelectionCompleted && selectionCopyText == "PRIMARY@TEXT", "selection word profile: configured=\(selectionWordProfileConfigured), selected=\(primarySelectionCompleted), text=\(String(describing: selectionCopyText))")
    #expect(selectionNonsemanticInputsSent && selectionNonsemanticOwnerProbe && selectionNonsemanticInputPreserved, "selection nonsemantic input: sent=\(selectionNonsemanticInputsSent), probe=\(selectionNonsemanticOwnerProbe), preserved=\(selectionNonsemanticInputPreserved)")
    #expect(selectionCopyCompleted && selectionSemanticInputRequested && selectionClearedByAcceptedInput, "selection accepted input did not clear owner state: requested=\(selectionSemanticInputRequested), cleared=\(selectionClearedByAcceptedInput)")
    #expect(selectionCopyRawIssued && selectionCopyRawReached, "selection copy callback raw receipt: issued=\(selectionCopyRawIssued), received=\(selectionCopyRawReached)")
    #expect(selectionCopyRequested && selectionCopyBackpressureHeld, "selection copy completion did not retain its bounded delivery slot")
    #expect(accessibilityRangeRequested && accessibilityRangeCompleted && accessibilityCountersAreIndependent && accessibilityGetterCaptured && accessibilityRangeRoundTripped, "accessibility selection round trip: requested=\(accessibilityRangeRequested), completed=\(accessibilityRangeCompleted), independent_counters=\(accessibilityCountersAreIndependent), getter_snapshot=\(accessibilityGetterCaptured), expected=\(String(describing: accessibilityRequestedRange)), actual_ranges=\(accessibilityGetterRanges), actual_text=\(String(describing: accessibilityGetterText)), exact_getter=\(accessibilityRangeRoundTripped)")
    selectionSession.close()
    await expectOwnedReaped()
  }

  @Test func linkActivationHistoryProof() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Capture the activation only from the published link projection, then
    // let its unchanged row move into history before submitting it. Session
    // carries that exact URL plus immutable row proof; it must not reconstruct
    // a link from newer text or disturb the active selection state.
    let linkHistoryScript = #"""
      STDOUT.sync = true
      system("stty raw -echo")
      print "\e]8;;https://example.test/session-link\e\\https://example.test/session-link\e]8;;\e\\"
      if STDIN.read(1) == "h"
        print "\r\nfirst\r\nsecond\r\nLINK_HISTORY_READY"
      end
      sleep 30
      """#
    let linkHistory = own(Session(launch: rubySpec(linkHistoryScript, [])))
    var linkHistoryResizeRequested = false
    var linkHistoryActivation: VisibleLinkProjection.Activation?
    var linkHistoryOutputReceived = false
    var linkHistoryActivationRequested = false
    var linkHistoryAccepted = false
    var linkHistorySelectionBefore: TerminalSelectionSnapshot?
    var linkHistorySelectionPreserved = false
    linkHistory.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map(\.text).joined()
      if !linkHistoryResizeRequested, text.contains("https://example.test/session-link") {
        linkHistoryResizeRequested = true
        linkHistory.resize(cols: 80, rows: 2)
        return
      }
      if linkHistoryActivation == nil, snapshot.rows.count == 2,
         let occurrence = VisibleLinkProjection(snapshot: snapshot).occurrences.first(where: {
           $0.target.absoluteString == "https://example.test/session-link"
         }), let activation = occurrence.activation
      {
        linkHistoryActivation = activation
        linkHistorySelectionBefore = snapshot.selection
        linkHistory.rawInput(Data("h".utf8))
      }
      if text.contains("LINK_HISTORY_READY") { linkHistoryOutputReceived = snapshot.history_rows > 0 }
      if linkHistoryOutputReceived, !linkHistoryActivationRequested, let activation = linkHistoryActivation {
        linkHistoryActivationRequested = linkHistory.activateLink(activation) { result in
          if case .success(let target) = result {
            linkHistoryAccepted = target.absoluteString == "https://example.test/session-link"
          }
        }
      }
      if linkHistoryAccepted, snapshot.selection == linkHistorySelectionBefore {
        linkHistorySelectionPreserved = true
      }
    }
    _ = await TestEnvironment.wait(seconds: 8) { linkHistoryAccepted && linkHistorySelectionPreserved }
    #expect(linkHistoryResizeRequested && linkHistoryActivation != nil && linkHistoryOutputReceived && linkHistoryActivationRequested && linkHistoryAccepted && linkHistorySelectionPreserved, "link history activation: resize=\(linkHistoryResizeRequested), proof=\(linkHistoryActivation != nil), history=\(linkHistoryOutputReceived), requested=\(linkHistoryActivationRequested), accepted=\(linkHistoryAccepted), selection_preserved=\(linkHistorySelectionPreserved)")
    linkHistory.close()
    await expectOwnedReaped()
  }

  @Test func pendingLinkActivationClose() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Use a large presented snapshot so validation has a pending turn. Post A
    // (admission) and B (close) from one owner turn: A queues Pump P behind
    // B, P begins and queues its continuation behind Close, so Close cancels
    // after begin but before any advance without timing assumptions.
    let pendingLinkScript = #"""
      STDOUT.sync = true
      system("stty raw -echo")
      print "\e]8;;https://example.test/pending-link\e\\https://example.test/pending-link\e]8;;\e\\"
      sleep 30
      """#
    let pendingLink = own(Session(launch: rubySpec(pendingLinkScript, [])))
    var pendingLinkResizeRequested = false
    var pendingLinkActivation: VisibleLinkProjection.Activation?
    var pendingLinkAdmitted = false
    var pendingLinkCloseRequested = false
    var pendingLinkInputRejected = false
    var pendingLinkCancelledCallbacks = 0
    var pendingLinkReaped = false
    pendingLink.onStatus = { status in
      if status.hasPrefix("Process exited") { pendingLinkReaped = true }
    }
    pendingLink.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map(\.text).joined()
      if !pendingLinkResizeRequested, text.contains("https://example.test/pending-link") {
        pendingLinkResizeRequested = true
        pendingLink.resize(cols: 80, rows: 512)
        return
      }
      guard pendingLinkActivation == nil, snapshot.rows.count == 512,
            let occurrence = VisibleLinkProjection(snapshot: snapshot).occurrences.first(where: {
              $0.target.absoluteString == "https://example.test/pending-link"
            }), let activation = occurrence.activation
      else { return }
      pendingLinkActivation = activation
      pendingLink.queue.async {
        let admitted = pendingLink.activateLink(activation) { result in
          if case .failure(.cancelled) = result { pendingLinkCancelledCallbacks += 1 }
        }
        DispatchQueue.main.async { pendingLinkAdmitted = admitted }
        pendingLink.queue.async {
          pendingLink.close()
          let inputRejected = !pendingLink.input("x")
          DispatchQueue.main.async {
            pendingLinkCloseRequested = true
            pendingLinkInputRejected = inputRejected
          }
        }
      }
    }
    _ = await TestEnvironment.wait(seconds: 8) { pendingLinkReaped && pendingLinkCancelledCallbacks == 1 }
    #expect(pendingLinkResizeRequested && pendingLinkActivation != nil && pendingLinkAdmitted && pendingLinkCloseRequested && pendingLinkInputRejected && pendingLinkCancelledCallbacks == 1 && pendingLinkReaped, "pending link activation: resize=\(pendingLinkResizeRequested), proof=\(pendingLinkActivation != nil), admitted=\(pendingLinkAdmitted), close=\(pendingLinkCloseRequested), input_rejected=\(pendingLinkInputRejected), cancelled_callbacks=\(pendingLinkCancelledCallbacks), reaped=\(pendingLinkReaped)")
    await expectOwnedReaped()
  }

  @Test func pendingSelectionClose() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // A 4,096-row selection makes both capture and copy resumable. Queue a
    // direct owner probe and urgent close behind the first copy pump: the
    // probe must run between bounded turns, while Close cancels the operation
    // before it can publish a copied string and reaps the owned PTY.
    let pendingSelectionScript = #"""
      STDOUT.sync = true
      system("stty raw -echo")
      print "SELECTION_RESIZE_READY"
      STDIN.read(1)
      row = "x" * 79
      4096.times { print row, "\r\n" }
      print "SELECTION_COPY_READY"
      sleep 30
      """#
    let pendingSelection = own(Session(launch: rubySpec(pendingSelectionScript, [])))
    var pendingSelectionResizeRequested = false
    var pendingSelectionCaptureRequested = false
    var pendingSelectionCaptureCompleted = false
    var pendingSelectionCopyRequested = false
    var pendingSelectionCopyAdmitted = false
    var pendingSelectionOwnerProbe = false
    var pendingSelectionCloseRequested = false
    var pendingSelectionInputRejected = false
    var pendingSelectionCancelledCallbacks = 0
    var pendingSelectionReaped = false
    pendingSelection.onStatus = { status in
      if status.hasPrefix("Process exited") { pendingSelectionReaped = true }
    }
    pendingSelection.onSnapshot = { snapshot in
      if !pendingSelectionResizeRequested, Self.selectionRow(snapshot, containing: "SELECTION_RESIZE_READY") != nil {
        pendingSelectionResizeRequested = true
        pendingSelection.resize(cols: 80, rows: 4096)
        #expect(pendingSelection.input("g"), "pending selection fixture start was not admitted")
      }
      guard snapshot.rows.count == 4096,
            Self.selectionRow(snapshot, containing: "SELECTION_COPY_READY") != nil
      else { return }
      if !pendingSelectionCaptureRequested,
         let start = snapshot.selectionHit(row: 0, boundary: 0),
         let end = snapshot.selectionHit(row: snapshot.rows.count - 1, boundary: snapshot.cols)
      {
        pendingSelectionCaptureRequested = pendingSelection.selection(.range(start: start, end: end, mode: .linear)) { result in
          if case .success = result { pendingSelectionCaptureCompleted = true }
        }
      }
      guard pendingSelectionCaptureCompleted, !snapshot.selection.segments.isEmpty,
            !pendingSelectionCopyRequested
      else { return }
      pendingSelectionCopyRequested = true
      let copy = TerminalSelectionAction.copy(expectedSelectionRevision: snapshot.selection.revision)
      pendingSelection.queue.async {
        let admitted = pendingSelection.selection(copy) { result in
          if case .failure(.cancelled) = result { pendingSelectionCancelledCallbacks += 1 }
        }
        DispatchQueue.main.async { pendingSelectionCopyAdmitted = admitted }
        // A posts the copy admission, B posts C. A schedules the first pump P;
        // B schedules C after P. P begins/caches one bounded copy turn and
        // queues Q, then C runs before Q and queues urgent Close after it.
        pendingSelection.queue.async {
          pendingSelection.queue.async {
            DispatchQueue.main.async { pendingSelectionOwnerProbe = true }
            pendingSelection.close()
            let inputRejected = !pendingSelection.input("x")
            DispatchQueue.main.async {
              pendingSelectionCloseRequested = true
              pendingSelectionInputRejected = inputRejected
            }
          }
        }
      }
    }
    _ = await TestEnvironment.wait(seconds: 20) { pendingSelectionReaped && pendingSelectionCancelledCallbacks == 1 }
    #expect(pendingSelectionResizeRequested && pendingSelectionCaptureRequested && pendingSelectionCaptureCompleted && pendingSelectionCopyRequested && pendingSelectionCopyAdmitted && pendingSelectionOwnerProbe && pendingSelectionCloseRequested && pendingSelectionInputRejected && pendingSelectionCancelledCallbacks == 1 && pendingSelectionReaped, "pending selection: resize=\(pendingSelectionResizeRequested), capture=\(pendingSelectionCaptureCompleted), copy=\(pendingSelectionCopyAdmitted), probe=\(pendingSelectionOwnerProbe), close=\(pendingSelectionCloseRequested), input_rejected=\(pendingSelectionInputRejected), cancelled_callbacks=\(pendingSelectionCancelledCallbacks), reaped=\(pendingSelectionReaped)")
    await expectOwnedReaped()
  }

  @Test func historySearch() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    let searchable = own(Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; 3000.times{|i| print(i==1000 ? "SEARCH_NEEDLE\r\n" : "row#{i}\r\n")}; print "SEARCH_READY"; STDIN.read(1)'"#)))
    var searchReady = false
    var searchFound = false
    var searchHighlighted = false
    searchable.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      searchReady = searchReady || text.contains("SEARCH_READY")
      if !snapshot.search.isEmpty {
        searchHighlighted = !snapshot.following_tail && text.contains("SEARCH_NEEDLE")
      }
    }
    _ = await TestEnvironment.wait(seconds: 5) { searchReady }
    #expect(searchReady, "search fixture never reached ready marker")
    searchable.find("search_needle") { searchFound = $0 == .found }
    _ = await TestEnvironment.wait(seconds: 5) { searchFound && searchHighlighted }
    #expect(searchFound && searchHighlighted, "the search must be found and highlighted")
    // The accepted match set stays navigable and can be cleared.
    var navigated: HistorySearchPosition?
    var navigationAnswered = false
    searchable.searchNavigate(older: true) { navigated = $0; navigationAnswered = true }
    _ = await TestEnvironment.wait(seconds: 5) { navigationAnswered }
    #expect((navigated?.total ?? 0) >= 1 && navigated?.capped == false, "accepted matches must stay navigable")
    var clearedAnswered = false
    searchable.searchClear()
    searchable.searchNavigate(older: true) { clearedAnswered = $0 == nil }
    _ = await TestEnvironment.wait(seconds: 5) { clearedAnswered }
    #expect(clearedAnswered, "clearing a search must drop its matches")
    var replacementCancelled = false, latestCompleted = false, ownerProbeFast = false
    searchable.find("missing-query-one") { replacementCancelled = $0 == .cancelled }
    searchable.find("search_needle") { latestCompleted = $0 == .found }
    searchable.semanticProbe { delay in ownerProbeFast = delay < 100 }
    _ = await TestEnvironment.wait(seconds: 5) { latestCompleted }
    #expect(replacementCancelled, "a replaced search query must be cancelled")
    #expect(latestCompleted, "the latest search query must complete")
    #expect(ownerProbeFast, "the owner must answer a probe within 100 ms during a search")
    var closeCancelled = false
    searchable.find("missing-during-close") { closeCancelled = $0 == .cancelled }
    searchable.close()
    _ = await TestEnvironment.wait(seconds: 2) { closeCancelled }
    #expect(closeCancelled, "closing the session must cancel the running search")
    await expectOwnedReaped()
  }

  @Test func saturatedPTYCancelClose() async throws {
    defer { ownedSessions.forEach { $0.close() } }
    // Fill a non-reading child's PTY. Urgent cancellation and closure must still run.
    let blocked = own(Session(
      launch: spec(#"stty raw -echo; printf '\033[?2004hBLOCK_READY'; exec /bin/sleep 30"#)))
    var started = false
    var reaped = false
    var cancelTime = Date()
    blocked.onStatus = { text in
      if text.hasPrefix("Process exited") { reaped = true }
    }
    blocked.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !started && text.contains("BLOCK_READY") {
        started = true
        blocked.queue.suspend()
        #expect(blocked.input(String(repeating: "p", count: 1_048_576), key: 1), "a paste of one mebibyte must be accepted")
        #expect(!blocked.input(String(repeating: "p", count: 1_048_577), key: 1), "a paste over one mebibyte must be rejected")
        let slab = String(repeating: "f", count: 4096)
        for _ in 0..<1024 { if !blocked.input(slab) { break } }
        for _ in 0..<64 { if !blocked.input(key: 10) { break } }
        #expect(!blocked.input(key: 10), "ordinary input must report busy under ingress pressure")
        #expect(blocked.input("r", key: 200, event: 2), "a key release must be admitted under ingress pressure")
        blocked.queue.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          cancelTime = Date()
          blocked.cancelPaste()
          blocked.close()
        }
      }
    }
    _ = await TestEnvironment.wait(seconds: 8) { reaped }
    #expect(reaped, "a saturated session must be reaped after cancel and close")
    let elapsed = Date().timeIntervalSince(cancelTime)
    #expect(reaped && elapsed < 3, "cancel and close must finish in under three seconds")
    blocked.close()
    await expectOwnedReaped()
  }
}

import Darwin
import Foundation

@main struct SessionTests {
  @MainActor static func main() {
    let root = CommandLine.arguments[1]
    func spec(_ script: String) -> LaunchSpec {
      LaunchSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], cwd: "/tmp",
        launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher")
    }
    func zshSpec() -> LaunchSpec {
      LaunchSpec(
        executable: "/bin/zsh", arguments: ["/bin/zsh", "-l"], cwd: "/tmp",
        launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher")
    }
    func rubySpec(_ script: String, _ arguments: [String]) -> LaunchSpec {
      LaunchSpec(
        executable: "/usr/bin/ruby", arguments: ["/usr/bin/ruby", "-e", script] + arguments,
        cwd: "/tmp", launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher")
    }
    var checks = Dictionary(
      uniqueKeysWithValues: [
        "input_admitted_for_ordered_output", "input_before_mode_suffix_is_unbracketed",
        "input_after_accepted_output_is_bracketed", "ordered_mode_encoding_after_rep",
        "zsh_startup_gate_blocks_a", "zsh_startup_input_admitted_after_b",
        "rep_completed", "large_paste_accepted", "oversize_paste_rejected",
        "saturated_cancel_close_reaped", "cancel_close_under_three_seconds",
        "ordinary_ingress_busy", "release_admitted_under_ingress_pressure",
        "viewport_scroll_anchored", "focus_release_preserves_viewport", "typing_follows_tail",
        "search_found_and_highlighted", "search_replacement_cancelled",
        "search_latest_query_completed", "search_owner_probe_under_100ms", "search_close_cancelled",
        "closed_focus_and_key_releases_are_quiet",
        "closed_text_input_is_reported", "committed_text_round_trip", "all_owned_children_reaped",
        "finished_pty_refuses_text", "finished_pty_retains_search",
        "finished_pty_retains_selection_copy_and_link_actions",
        "physical_key_reaches_pty",
        "typed_metadata_rejected", "typed_legacy_metadata_rejected", "expanded_key_write_rejected",
        "typed_key_paths_admitted", "modifier_keys_preserve_anchored_viewport",
        "resize_rejection_preserves_fifo_and_pty", "resumable_resize_commits_before_later_input",
        "pending_resize_close_is_fair_and_cancels", "rapid_resize_returns_to_original_before_input",
        "selection_stale_hit_is_rejected", "selection_copy_is_immutable_before_later_output",
        "selection_fifo_preserves_output_mode_order", "selection_cross_screen_state_restores",
        "selection_word_profile_configuration_is_fifo",
        "selection_nonsemantic_input_preserves_owner_state",
        "selection_accepted_input_clears_owner_state", "selection_copy_callback_raw_reaches_pty",
        "selection_copy_delivery_is_bounded",
        "accessibility_presented_range_round_trips_through_session",
        "link_activation_accepts_unchanged_history_proof",
        "pending_link_activation_close_cancels_and_reaps",
        "pending_selection_close_is_fair_and_cancels",
      ].map { ($0, false) })
    checks["split_inherits_cwd"] = false
    checks["split_children_reaped"] = false
    var statuses: [String] = []
    let runID = UUID().uuidString
    let startedAt = ISO8601DateFormatter().string(from: Date())
    var failures: [String] = []
    var ownedSessions: [Session] = []
    func own(_ session: Session) -> Session {
      ownedSessions.append(session)
      return session
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
      guard !condition() else { return }
      let failure = message()
      failures.append(failure)
      FileHandle.standardError.write(Data("FAIL SessionTests [\(runID)]: \(failure)\n".utf8))
    }
    func selectionRow(_ snapshot: TerminalSnapshot, containing marker: String) -> Int? {
      snapshot.rows.firstIndex { row in row.cells.map(\.text).joined().contains(marker) }
    }
    let splitFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal split 猫 #% \(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: splitFolder, withIntermediateDirectories: false)
    } catch {
      expect(false, "could not create split fixture: \(error)")
    }
    defer { try? FileManager.default.removeItem(at: splitFolder) }
    let splitAlias = splitFolder.appendingPathComponent("logical link")
    do {
      try FileManager.default.createSymbolicLink(atPath: splitAlias.path, withDestinationPath: splitFolder.path)
    } catch {
      expect(false, "could not create split alias: \(error)")
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
      expect(URL(fileURLWithPath: launch.cwd).resolvingSymlinksInPath().path == splitFolder.resolvingSymlinksInPath().path,
        "split sibling cwd resolved outside fixture: \(launch.cwd)")
      let child = own(Session(launch: LaunchSpec(executable: "/bin/sh",
        arguments: ["/bin/sh", "-c", "printf 'SPLIT_CHILD_PWD=%s\\n' \"$PWD\""],
        cwd: launch.cwd, launcher: spec("").launcher)))
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
      expect(parent.input("\n"), "split parent rejected completion input")
    }
    let splitDeadline = Date().addingTimeInterval(8)
    while !(parentEnded && siblingEnded && siblingMatched) && Date() < splitDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    parent.close(); sibling?.close()
    checks["split_inherits_cwd"] = siblingMatched
    checks["split_children_reaped"] = parentEnded && siblingEnded
    expect(parentEnded && siblingEnded && siblingMatched,
      "split cwd: parent=\(parentEnded), child=\(siblingEnded), match=\(siblingMatched), cwd=\(String(describing: parentCWD)), childText=\(childText)")
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
        expect(accepted, "ordering core rejected paste input")
        return encoded as Data
      }
      let firstAccepted = packet.withUnsafeBytes {
        terminal_feed(orderingCore, $0.bindMemory(to: UInt8.self).baseAddress!, packet.count, 0)
      }
      expect(firstAccepted < packet.count && terminal_has_work(orderingCore),
        "REP packet did not yield before its mode suffix")
      checks["input_before_mode_suffix_is_unbracketed"] =
        encodePaste() == Data("hello\rworld".utf8)
      var accepted = firstAccepted
      packet.withUnsafeBytes { packet in
        let bytes = packet.bindMemory(to: UInt8.self)
        while accepted < packet.count || terminal_has_work(orderingCore) {
          accepted += terminal_feed(orderingCore, bytes.baseAddress!.advanced(by: accepted), packet.count - accepted, 0)
        }
      }
      checks["input_after_accepted_output_is_bracketed"] =
        encodePaste() == Data("\u{1b}[200~hello\rworld\u{1b}[201~".utf8)
    } else {
      expect(false, "could not create ordering core")
    }
    // The child validates the final PTY receipt, independent of snapshot cadence.
    let orderedScript =
      "stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print \"X\\e[500000b\\e[?2004hREADY\"; s=STDIN.read(23); print(s==\"\\e[200~hello\\rworld\\e[201~\" ? \"\\r\\nORDERED_PASTE_OK\" : \"\\r\\nBAD_PASTE\")'"
    let ordered = own(Session(launch: spec(orderedScript)))
    var sent = false
    var done = false
    ordered.onStatus = { statuses.append($0) }
    ordered.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !sent && text.contains("X") {
        sent = true
        checks["input_admitted_for_ordered_output"] = ordered.input("hello\nworld", key: 1)
      }
      if text.contains("ORDERED_PASTE_OK") {
        checks["ordered_mode_encoding_after_rep"] = true
        done = true
      }
    }
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    checks["rep_completed"] = done
    ordered.close()
    // The bundled zsh integration emits A before its first line-init B. A
    // private FIFO makes that real boundary deterministic without a timer.
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
        expect(false, "could not create private ZDOTDIR fixture: \(error)")
      }
      guard mkfifo(releaseFIFO.path, 0o600) == 0 else {
        expect(false, "could not create startup FIFO: \(String(cString: strerror(errno)))")
        break zshFixture
      }
      let fifo = open(releaseFIFO.path, O_RDWR | O_NONBLOCK)
      guard fifo >= 0 else {
        expect(false, "could not open startup FIFO: \(String(cString: strerror(errno)))")
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
        expect(false, "could not write private zsh fixture: \(error)")
        break zshFixture
      }
      setenv("ZDOTDIR", privateZdotdir.path, 1)
      let readyShell = own(Session(launch: zshSpec()))
      var sawDrawing = false
      var sawReady = false
      var startupCommandAttempts = 0
      var admittedAtA = false
      var releaseSent = false
      var startupDone = false
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
            checks["zsh_startup_input_admitted_after_b"] = admitStartupCommand(after: snapshot)
          }
        }
        startupDone = snapshot.rows.map { row in
          row.cells.map { $0.text }.joined().trimmingCharacters(in: .whitespaces)
        }.contains(outputMarker)
      }
      let zshDeadline = Date().addingTimeInterval(5)
      while !startupDone && Date() < zshDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      checks["zsh_startup_input_admitted_after_b"] =
        checks["zsh_startup_input_admitted_after_b"] == true && startupDone
      checks["zsh_startup_gate_blocks_a"] =
        sawDrawing && releaseSent && sawReady && !admittedAtA && startupCommandAttempts == 1
      expect(checks["zsh_startup_gate_blocks_a"] == true,
        "zsh startup gate did not observe A then B: drawing=\(sawDrawing), released=\(releaseSent), ready=\(sawReady)")
      expect(checks["zsh_startup_input_admitted_after_b"] == true,
        "zsh startup command was not executed after B")
      readyShell.close()
    }
    // Automation and IME commits use key=0: the C ABI must forward the full
    // committed string rather than silently reducing it to its first scalar.
    let committed = own(Session(launch: spec("stty raw -echo; exec /bin/cat")))
    var committedEchoed = false
    committed.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      committedEchoed = committedEchoed || text.contains("AUTOMATION_TEXT")
    }
    expect(committed.input("AUTOMATION_TEXT\n"), "committed text input was rejected")
    let committedDeadline = Date().addingTimeInterval(5)
    while !committedEchoed && Date() < committedDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["committed_text_round_trip"] = committedEchoed
    committed.close()
    let finished = own(Session(launch: spec("printf FINISHED_PTY_READY")))
    var finishedRead = false
    let finishedDeadline = Date().addingTimeInterval(3)
    while !finishedRead && Date() < finishedDeadline {
      finished.statistics { stats in finishedRead = stats["read_ended"] as? Bool == true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["finished_pty_refuses_text"] = finishedRead && !finished.input("unexpected input")
    finished.find("FINISHED_PTY_READY") { checks["finished_pty_retains_search"] = $0 == .found }
    let finishedSearchDeadline = Date().addingTimeInterval(3)
    while checks["finished_pty_retains_search"] != true && Date() < finishedSearchDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    finished.close()
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
    let finishedActionsEOFDeadline = Date().addingTimeInterval(3)
    while !(finishedActionReadEnded && finishedActionReaped && finishedActionSnapshot != nil)
      && Date() < finishedActionsEOFDeadline
    {
      finishedActions.statistics { stats in
        finishedActionReadEnded = stats["read_ended"] as? Bool == true
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    var finishedActionActivation: VisibleLinkProjection.Activation?
    if let snapshot = finishedActionSnapshot,
       let row = selectionRow(snapshot, containing: "FINISHED_SELECT"),
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
    let finishedSelectionDeadline = Date().addingTimeInterval(3)
    while !(finishedActionSelectionCompleted && finishedActionSelectionPublished)
      && Date() < finishedSelectionDeadline
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    if let snapshot = finishedActionSnapshot, finishedActionSelectionCompleted,
       finishedActionSelectionPublished,
       !snapshot.selection.segments.isEmpty
    {
      finishedActionCopyRequested = finishedActions.selection(
        .copy(expectedSelectionRevision: snapshot.selection.revision)) { result in
          if case .success(let text) = result { finishedActionCopyText = text }
        }
    }
    let finishedCopyDeadline = Date().addingTimeInterval(3)
    while finishedActionCopyText == nil && Date() < finishedCopyDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    if let activation = finishedActionActivation, finishedActionCopyText == "FINISHED_SELECT" {
      finishedActionSelectionBeforeLink = finishedActionSnapshot?.selection
      finishedActionLinkRequested = finishedActions.activateLink(activation) { result in
        if case .success(let target) = result {
          finishedActionLinkAccepted = target.absoluteString == "https://example.test/finished"
        }
      }
    }
    let finishedLinkDeadline = Date().addingTimeInterval(3)
    while !(finishedActionLinkAccepted && finishedActionSelectionPreserved)
      && Date() < finishedLinkDeadline
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["finished_pty_retains_selection_copy_and_link_actions"] =
      finishedActionReadEnded && finishedActionReaped && finishedActionSelectionRequested
      && finishedActionSelectionCompleted && finishedActionSelectionPublished && finishedActionCopyRequested
      && finishedActionCopyText == "FINISHED_SELECT" && finishedActionLinkRequested
      && finishedActionLinkAccepted && finishedActionSelectionPreserved
    expect(checks["finished_pty_retains_selection_copy_and_link_actions"] == true,
      "finished PTY read-only actions: eof=\(finishedActionReadEnded), reaped=\(finishedActionReaped), selection=\(finishedActionSelectionCompleted), selection_published=\(finishedActionSelectionPublished), copy=\(String(describing: finishedActionCopyText)), link=\(finishedActionLinkAccepted), selection_preserved=\(finishedActionSelectionPreserved)")
    finishedActions.close()
    let physical = own(Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print "PHYSICAL_READY"; key=STDIN.read(1); print(key=="!" ? "\r\nPHYSICAL_KEY_OK" : "\r\nPHYSICAL_KEY_BAD")'"#)))
    var physicalSent = false, physicalDone = false
    physical.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !physicalSent && text.contains("PHYSICAL_READY") {
        physicalSent = true
        checks["physical_key_reaches_pty"] = physical.input(TerminalKeyEvent(
          text: "!", logical: "1", shifted: "!", baseLayout: "1", legacyText: "!", key: 200,
          modifiers: 1, event: 0))
      }
      physicalDone = physicalDone || text.contains("PHYSICAL_KEY_OK")
    }
    let physicalDeadline = Date().addingTimeInterval(5)
    while !physicalDone && Date() < physicalDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["physical_key_reaches_pty"] = checks["physical_key_reaches_pty"] == true && physicalDone
    physical.close()
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
    checks["typed_metadata_rejected"] = !bounded.input(oversizedMetadata)
    checks["typed_legacy_metadata_rejected"] = !bounded.input(oversizedLegacyMetadata)
    checks["expanded_key_write_rejected"] = !bounded.input(impossibleExpansion)
    checks["typed_key_paths_admitted"] = bounded.input(shiftedKey) && bounded.input(modifierKey)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    checks["typed_metadata_rejected"] =
      checks["typed_metadata_rejected"] == true && boundedStatuses.contains("Input busy")
    checks["typed_legacy_metadata_rejected"] =
      checks["typed_legacy_metadata_rejected"] == true && boundedStatuses.contains("Input busy")
    checks["expanded_key_write_rejected"] =
      checks["expanded_key_write_rejected"] == true && boundedStatuses.contains("Key input exceeds write limit")
    bounded.close()
    let shiftPress = TerminalKeyEvent(
      text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: 400,
      modifiers: 1, event: 0)
    let commandPress = TerminalKeyEvent(
      text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: 403,
      modifiers: 9, event: 0)
    expect(!shiftPress.isKeyAction && !commandPress.isKeyAction,
      "modifier-only key events were classified as typing")
    func preservesModifierViewport(kitty: Bool) -> Bool {
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
          expect(modifierView.input(shiftPress), "shift modifier input was rejected")
          expect(modifierView.input(commandPress), "command modifier input was rejected")
          if !kitty { modifierView.rawInput(Data([0])) }
        case 2 where snapshot.revision > revision:
          passed = !snapshot.following_tail && snapshot.scroll_offset == 3 && snapshot.rows == rows
          phase = 3
        default: break
        }
      }
      let modifierDeadline = Date().addingTimeInterval(5)
      while phase != 3 && Date() < modifierDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      modifierView.close()
      return phase == 3 && passed
    }
    checks["modifier_keys_preserve_anchored_viewport"] =
      preservesModifierViewport(kitty: false) && preservesModifierViewport(kitty: true)
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
        checks["viewport_scroll_anchored"] = snapshot.scroll_offset == 3
        capturedRows = snapshot.rows
        viewPhase = 2
        expect(view.input(key: 2, event: 1), "focus event was rejected")
        expect(view.input("r", key: 200, event: 2), "key release event was rejected")
      case 2:
        checks["focus_release_preserves_viewport"] =
          !snapshot.following_tail && snapshot.scroll_offset == 3 && snapshot.rows == capturedRows
        viewPhase = 3
        expect(view.input("x", key: 200), "typing input was rejected")
      case 3 where text.contains("VIEW_NEW_OUTPUT"):
        checks["typing_follows_tail"] = snapshot.following_tail && snapshot.scroll_offset == 0
        viewPhase = 4
      default: break
      }
    }
    let viewDeadline = Date().addingTimeInterval(5)
    while viewPhase != 4 && Date() < viewDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    var shutdownStatuses: [String] = []
    view.onStatus = { shutdownStatuses.append($0) }
    view.close()
    expect(!view.input(key: 2, event: 0), "closed session admitted focus event")
    expect(!view.input("r", key: 200, event: 2), "closed session admitted key release")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    checks["closed_focus_and_key_releases_are_quiet"] = !shutdownStatuses.contains { $0.hasPrefix("Input") }
    expect(!view.input("user text"), "closed session admitted text")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    checks["closed_text_input_is_reported"] = shutdownStatuses.contains("Input closed")
    // A rejected resize must not signal the PTY, and a semantic event queued
    // behind it must still reach the child under the retained old geometry.
    let rejectedResizeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-resize-rejection-\(UUID().uuidString)", isDirectory: true)
    let rejectedResizeReceipt = rejectedResizeDirectory.appendingPathComponent("winch.txt")
    do {
      try FileManager.default.createDirectory(at: rejectedResizeDirectory, withIntermediateDirectories: false)
    } catch {
      expect(false, "could not create rejected-resize fixture: \(error)")
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
        expect(rejectedResize.input("r"), "rejected-resize input was not admitted")
      }
      if text.contains("RESIZE_REJECT_INPUT=114 SIZE=24 80") {
        rejectedResizeDelivered = snapshot.cols == 80 && snapshot.rows.count == 24
      }
    }
    let rejectedResizeDeadline = Date().addingTimeInterval(8)
    while !rejectedResizeDelivered && Date() < rejectedResizeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let rejectedResizeSignals = ((try? String(contentsOf: rejectedResizeReceipt, encoding: .utf8)) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    checks["resize_rejection_preserves_fifo_and_pty"] =
      rejectedResizeRequested && rejectedResizeDelivered && rejectedResizeSignals.isEmpty
    expect(checks["resize_rejection_preserves_fifo_and_pty"] == true,
      "rejected resize: requested=\(rejectedResizeRequested), delivered=\(rejectedResizeDelivered), winch=\(rejectedResizeSignals)")
    rejectedResize.close()
    // A resize back to the currently committed geometry is not a no-op while
    // an earlier resize remains queued. It must stay behind A and commit before
    // the later input observes the restored PTY size.
    let rapidResizeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-rapid-resize-\(UUID().uuidString)", isDirectory: true)
    let rapidResizeReceipt = rapidResizeDirectory.appendingPathComponent("winch.txt")
    do {
      try FileManager.default.createDirectory(at: rapidResizeDirectory, withIntermediateDirectories: false)
    } catch {
      expect(false, "could not create rapid-resize fixture: \(error)")
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
        expect(rapidResize.input("b"), "rapid-resize input was not admitted")
      }
      if text.contains("RAPID_RESIZE_INPUT=98 SIZE=24 80") {
        rapidResizeDelivered = snapshot.cols == 80 && snapshot.rows.count == 24
      }
    }
    let rapidResizeDeadline = Date().addingTimeInterval(8)
    while !rapidResizeDelivered && Date() < rapidResizeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let rapidResizeSignals = ((try? String(contentsOf: rapidResizeReceipt, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).map(String.init)
    checks["rapid_resize_returns_to_original_before_input"] =
      rapidResizeRequested && rapidResizeDelivered && (1...2).contains(rapidResizeSignals.count)
    expect(checks["rapid_resize_returns_to_original_before_input"] == true,
      "rapid resize: requested=\(rapidResizeRequested), delivered=\(rapidResizeDelivered), winch=\(rapidResizeSignals)")
    rapidResize.close()
    // The reflow fixture builds enough wide history to require the bridge's
    // resumable path. Input and probes remain after the resize event until its
    // one coherent commit, where the PTY gets exactly one matching WINCH.
    let committedResizeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("terminal-resize-commit-\(UUID().uuidString)", isDirectory: true)
    let committedResizeReceipt = committedResizeDirectory.appendingPathComponent("winch.txt")
    do {
      try FileManager.default.createDirectory(at: committedResizeDirectory, withIntermediateDirectories: false)
    } catch {
      expect(false, "could not create committed-resize fixture: \(error)")
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
        expect(committedResize.input("c"), "committed-resize input was not admitted")
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
    let committedResizeDeadline = Date().addingTimeInterval(30)
    while !(committedResizeDelivered && committedResizeProbe) && Date() < committedResizeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let committedResizeSignals = ((try? String(contentsOf: committedResizeReceipt, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).map(String.init)
    checks["resumable_resize_commits_before_later_input"] =
      committedResizeRequested && committedResizeDelivered && committedResizeProbe
      && committedResizeOwnerProbes >= 2
      && committedResizeGeometries.isSubset(of: Set(["80x24", "20x24"]))
      && committedResizeSignals == ["24 20"]
    expect(checks["resumable_resize_commits_before_later_input"] == true,
      "committed resize: requested=\(committedResizeRequested), delivered=\(committedResizeDelivered), semantic_probe=\(committedResizeProbe), owner_probes=\(committedResizeOwnerProbes), geometries=\(committedResizeGeometries), winch=\(committedResizeSignals)")
    committedResize.close()
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
      expect(false, "could not create cancelled-resize fixture: \(error)")
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
    let cancelledResizeDeadline = Date().addingTimeInterval(8)
    while !cancelledResizeReaped && Date() < cancelledResizeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let cancelledResizeSignals = ((try? String(contentsOf: cancelledResizeReceipt, encoding: .utf8)) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    checks["pending_resize_close_is_fair_and_cancels"] =
      cancelledResizeRequested && cancelledResizeClosed && cancelledResizeReaped
      && cancelledResizeInputRejected && cancelledResizeSignals.isEmpty
    expect(checks["pending_resize_close_is_fair_and_cancels"] == true,
      "cancelled resize: requested=\(cancelledResizeRequested), closed=\(cancelledResizeClosed), reaped=\(cancelledResizeReaped), input_rejected=\(cancelledResizeInputRejected), winch=\(cancelledResizeSignals)")
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
      if staleHit == nil, let row = selectionRow(snapshot, containing: "STALE_TEXT") {
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
         let row = selectionRow(snapshot, containing: "PRIMARY@TEXT"),
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
         let row = selectionRow(snapshot, containing: "ALT_TEXT"),
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
          selectionSession.input(shiftPress)
          && selectionSession.input(key: 2, event: 0)
          && selectionSession.input("r", key: 200, event: 2)
          && selectionSession.input("", key: 999)
        selectionSession.semanticProbe { _ in selectionNonsemanticOwnerProbe = true }
      }
      if !snapshot.alternate, selectionNonsemanticOwnerProbe, !snapshot.selection.segments.isEmpty {
        selectionNonsemanticInputPreserved = true
      }
      selectionModeAfterCopy = selectionModeAfterCopy
        || (snapshot.modes.bracketed_paste && selectionRow(snapshot, containing: "RAW_CALLBACK_RECEIVED") != nil)
      selectionCopyRawReached = selectionCopyRawReached
        || selectionRow(snapshot, containing: "RAW_CALLBACK_RECEIVED") != nil
      if selectionCopyRawReached, !selectionSemanticInputRequested {
        selectionSemanticInputRequested = selectionSession.input("q")
      }
      if selectionRow(snapshot, containing: "ACCEPTED_INPUT_AFTER_COPY") != nil {
        selectionClearedByAcceptedInput = snapshot.selection.segments.isEmpty
      }
    }
    let selectionDeadline = Date().addingTimeInterval(8)
    while !(staleRejected && selectionCopyCompleted && selectionCopyRawReached
      && selectionModeAfterCopy && selectionClearedByAcceptedInput)
      && Date() < selectionDeadline
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["selection_stale_hit_is_rejected"] = staleRequested && staleRejected
    checks["selection_cross_screen_state_restores"] =
      primarySelectionRequested && primarySelectionCompleted && alternateSelectionRequested
      && alternateSelectionCompleted && primaryRestored
    checks["selection_copy_is_immutable_before_later_output"] =
      selectionCopyCompleted && selectionCopyText == "PRIMARY@TEXT" && selectionCopyRawReached
    checks["selection_fifo_preserves_output_mode_order"] =
      selectionCopyCompleted && selectionModeAfterCopy
    checks["selection_word_profile_configuration_is_fifo"] =
      selectionWordProfileConfigured && primarySelectionCompleted && selectionCopyText == "PRIMARY@TEXT"
    checks["selection_nonsemantic_input_preserves_owner_state"] =
      selectionNonsemanticInputsSent && selectionNonsemanticOwnerProbe && selectionNonsemanticInputPreserved
    checks["selection_accepted_input_clears_owner_state"] =
      selectionCopyCompleted && selectionSemanticInputRequested && selectionClearedByAcceptedInput
    checks["selection_copy_callback_raw_reaches_pty"] =
      selectionCopyRawIssued && selectionCopyRawReached
    checks["selection_copy_delivery_is_bounded"] =
      selectionCopyRequested && selectionCopyBackpressureHeld
    checks["accessibility_presented_range_round_trips_through_session"] =
      accessibilityRangeRequested && accessibilityRangeCompleted
      && accessibilityCountersAreIndependent && accessibilityGetterCaptured
      && accessibilityRangeRoundTripped
    expect(checks["selection_stale_hit_is_rejected"] == true,
      "stale selection: hit=\(staleHit != nil), requested=\(staleRequested), rejected=\(staleRejected)")
    expect(checks["selection_cross_screen_state_restores"] == true,
      "cross-screen selection: primary=\(primarySelectionCompleted), alternate=\(alternateSelectionCompleted), restored=\(primaryRestored)")
    expect(checks["selection_copy_is_immutable_before_later_output"] == true,
      "selection copy: completed=\(selectionCopyCompleted), text=\(String(describing: selectionCopyText)), raw_receipt=\(selectionCopyRawReached)")
    expect(checks["selection_fifo_preserves_output_mode_order"] == true,
      "selection mode FIFO: copy=\(selectionCopyCompleted), mode=\(selectionModeAfterCopy)")
    expect(checks["selection_word_profile_configuration_is_fifo"] == true,
      "selection word profile: configured=\(selectionWordProfileConfigured), selected=\(primarySelectionCompleted), text=\(String(describing: selectionCopyText))")
    expect(checks["selection_nonsemantic_input_preserves_owner_state"] == true,
      "selection nonsemantic input: sent=\(selectionNonsemanticInputsSent), probe=\(selectionNonsemanticOwnerProbe), preserved=\(selectionNonsemanticInputPreserved)")
    expect(checks["selection_accepted_input_clears_owner_state"] == true,
      "selection accepted input did not clear owner state: requested=\(selectionSemanticInputRequested), cleared=\(selectionClearedByAcceptedInput)")
    expect(checks["selection_copy_callback_raw_reaches_pty"] == true,
      "selection copy callback raw receipt: issued=\(selectionCopyRawIssued), received=\(selectionCopyRawReached)")
    expect(checks["selection_copy_delivery_is_bounded"] == true,
      "selection copy completion did not retain its bounded delivery slot")
    expect(checks["accessibility_presented_range_round_trips_through_session"] == true,
      "accessibility selection round trip: requested=\(accessibilityRangeRequested), completed=\(accessibilityRangeCompleted), independent_counters=\(accessibilityCountersAreIndependent), getter_snapshot=\(accessibilityGetterCaptured), expected=\(String(describing: accessibilityRequestedRange)), actual_ranges=\(accessibilityGetterRanges), actual_text=\(String(describing: accessibilityGetterText)), exact_getter=\(accessibilityRangeRoundTripped)")
    selectionSession.close()
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
    let linkHistoryDeadline = Date().addingTimeInterval(8)
    while !(linkHistoryAccepted && linkHistorySelectionPreserved) && Date() < linkHistoryDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["link_activation_accepts_unchanged_history_proof"] =
      linkHistoryResizeRequested && linkHistoryActivation != nil && linkHistoryOutputReceived
      && linkHistoryActivationRequested && linkHistoryAccepted && linkHistorySelectionPreserved
    expect(checks["link_activation_accepts_unchanged_history_proof"] == true,
      "link history activation: resize=\(linkHistoryResizeRequested), proof=\(linkHistoryActivation != nil), history=\(linkHistoryOutputReceived), requested=\(linkHistoryActivationRequested), accepted=\(linkHistoryAccepted), selection_preserved=\(linkHistorySelectionPreserved)")
    linkHistory.close()
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
    let pendingLinkDeadline = Date().addingTimeInterval(8)
    while !(pendingLinkReaped && pendingLinkCancelledCallbacks == 1) && Date() < pendingLinkDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["pending_link_activation_close_cancels_and_reaps"] =
      pendingLinkResizeRequested && pendingLinkActivation != nil && pendingLinkAdmitted
      && pendingLinkCloseRequested && pendingLinkInputRejected
      && pendingLinkCancelledCallbacks == 1 && pendingLinkReaped
    expect(checks["pending_link_activation_close_cancels_and_reaps"] == true,
      "pending link activation: resize=\(pendingLinkResizeRequested), proof=\(pendingLinkActivation != nil), admitted=\(pendingLinkAdmitted), close=\(pendingLinkCloseRequested), input_rejected=\(pendingLinkInputRejected), cancelled_callbacks=\(pendingLinkCancelledCallbacks), reaped=\(pendingLinkReaped)")
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
      if !pendingSelectionResizeRequested, selectionRow(snapshot, containing: "SELECTION_RESIZE_READY") != nil {
        pendingSelectionResizeRequested = true
        pendingSelection.resize(cols: 80, rows: 4096)
        expect(pendingSelection.input("g"), "pending selection fixture start was not admitted")
      }
      guard snapshot.rows.count == 4096,
            selectionRow(snapshot, containing: "SELECTION_COPY_READY") != nil
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
    let pendingSelectionDeadline = Date().addingTimeInterval(20)
    while !(pendingSelectionReaped && pendingSelectionCancelledCallbacks == 1)
      && Date() < pendingSelectionDeadline
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["pending_selection_close_is_fair_and_cancels"] =
      pendingSelectionResizeRequested && pendingSelectionCaptureRequested
      && pendingSelectionCaptureCompleted && pendingSelectionCopyRequested
      && pendingSelectionCopyAdmitted && pendingSelectionOwnerProbe
      && pendingSelectionCloseRequested && pendingSelectionInputRejected
      && pendingSelectionCancelledCallbacks == 1 && pendingSelectionReaped
    expect(checks["pending_selection_close_is_fair_and_cancels"] == true,
      "pending selection: resize=\(pendingSelectionResizeRequested), capture=\(pendingSelectionCaptureCompleted), copy=\(pendingSelectionCopyAdmitted), probe=\(pendingSelectionOwnerProbe), close=\(pendingSelectionCloseRequested), input_rejected=\(pendingSelectionInputRejected), cancelled_callbacks=\(pendingSelectionCancelledCallbacks), reaped=\(pendingSelectionReaped)")
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
    let readyDeadline = Date().addingTimeInterval(5)
    while !searchReady && Date() < readyDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    expect(searchReady, "search fixture never reached ready marker")
    searchable.find("search_needle") { searchFound = $0 == .found }
    let findDeadline = Date().addingTimeInterval(5)
    while !(searchFound && searchHighlighted) && Date() < findDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["search_found_and_highlighted"] = searchFound && searchHighlighted
    searchable.find("missing-query-one") { checks["search_replacement_cancelled"] = $0 == .cancelled }
    searchable.find("search_needle") { checks["search_latest_query_completed"] = $0 == .found }
    searchable.semanticProbe { delay in checks["search_owner_probe_under_100ms"] = delay < 100 }
    let replaceDeadline = Date().addingTimeInterval(5)
    while checks["search_latest_query_completed"] != true && Date() < replaceDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    searchable.find("missing-during-close") { checks["search_close_cancelled"] = $0 == .cancelled }
    searchable.close()
    let cancelDeadline = Date().addingTimeInterval(2)
    while checks["search_close_cancelled"] != true && Date() < cancelDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    // Fill a non-reading child's PTY. Urgent cancellation and closure must still run.
    let blocked = own(Session(
      launch: spec(#"stty raw -echo; printf '\033[?2004hBLOCK_READY'; exec /bin/sleep 30"#)))
    var started = false
    var reaped = false
    var cancelTime = Date()
    blocked.onStatus = { text in
      statuses.append(text)
      if text.hasPrefix("Process exited") { reaped = true }
    }
    blocked.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !started && text.contains("BLOCK_READY") {
        started = true
        blocked.queue.suspend()
        checks["large_paste_accepted"] = blocked.input(
          String(repeating: "p", count: 1_048_576), key: 1)
        checks["oversize_paste_rejected"] = !blocked.input(
          String(repeating: "p", count: 1_048_577), key: 1)
        let slab = String(repeating: "f", count: 4096)
        for _ in 0..<1024 { if !blocked.input(slab) { break } }
        for _ in 0..<64 { if !blocked.input(key: 10) { break } }
        checks["ordinary_ingress_busy"] = !blocked.input(key: 10)
        checks["release_admitted_under_ingress_pressure"] = blocked.input("r", key: 200, event: 2)
        blocked.queue.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          cancelTime = Date()
          blocked.cancelPaste()
          blocked.close()
        }
      }
    }
    let closeDeadline = Date().addingTimeInterval(8)
    while !reaped && Date() < closeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["saturated_cancel_close_reaped"] = reaped
    let elapsed = Date().timeIntervalSince(cancelTime)
    checks["cancel_close_under_three_seconds"] = reaped && elapsed < 3
    blocked.close()
    // Every session was explicitly closed at its scenario boundary. Repeat that
    // cleanup on every terminal path so a failed assertion cannot strand a PTY.
    ownedSessions.forEach { $0.close() }
    let cleanupDeadline = Date().addingTimeInterval(2.25)
    var cleanupStats: [[String: Any]] = []
    var allChildrenReaped = false
    repeat {
      var samples: [[String: Any]] = []
      for session in ownedSessions {
        session.statistics { samples.append($0) }
      }
      while samples.count < ownedSessions.count && Date() < cleanupDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      cleanupStats = samples
      allChildrenReaped = cleanupStats.count == ownedSessions.count
        && cleanupStats.allSatisfy { $0["child_reaped"] as? Bool == true }
      if !allChildrenReaped && Date() < cleanupDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
    } while !allChildrenReaped && Date() < cleanupDeadline
    let childReapStates: [[String: Any]] = cleanupStats.enumerated().map { index, statistics in
      let reaped = (statistics["child_reaped"] as? Bool) ?? false
      let pid: Int32 = (statistics["child_pid"] as? Int32)
        ?? ((statistics["child_pid"] as? NSNumber)?.int32Value ?? -1)
      return ["session": index, "child_reaped": reaped,
        "child_reaped_reported": statistics["child_reaped"] != nil, "child_pid": pid]
    }
    let unreapedPIDs = cleanupStats.compactMap { statistics -> Int32? in
      guard statistics["child_reaped"] as? Bool != true else { return nil }
      return (statistics["child_pid"] as? Int32)
        ?? (statistics["child_pid"] as? NSNumber)?.int32Value
    }.filter { $0 > 0 }
    checks["all_owned_children_reaped"] = allChildrenReaped
    expect(checks["all_owned_children_reaped"] == true,
      "owned session cleanup incomplete: states=\(childReapStates), unreaped_pids=\(unreapedPIDs)")
    let passed = failures.isEmpty && checks.values.allSatisfy { $0 }
    let report: [String: Any] = [
      "run_id": runID, "started_at": startedAt,
      "finished_at": ISO8601DateFormatter().string(from: Date()),
      "checks": checks, "passed": passed, "failures": failures,
      "cancel_to_reap_seconds": elapsed, "statuses": statuses,
      "resumable_reflow": [
        "rejected_winch": rejectedResizeSignals,
        "rapid_winch": rapidResizeSignals,
        "committed_winch": committedResizeSignals,
        "cancelled_winch": cancelledResizeSignals,
        "committed_owner_probes": committedResizeOwnerProbes,
        "cancelled_close_after_begin": cancelledResizeClosed,
      ],
      "owned_session_cleanup": ["reported": cleanupStats.count, "expected": ownedSessions.count,
        "all_children_reaped": allChildrenReaped, "unreaped_pids": unreapedPIDs,
        "states": childReapStates],
    ]
    let reportURL = URL(fileURLWithPath: root + "/reports/session-tests.json")
    var reportWriteFailed = false
    do {
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: reportURL, options: .atomic)
      print("SESSION_TEST_REPORT=\(reportURL.path) run_id=\(runID) passed=\(passed)")
      if !passed {
        let reportText = String(data: data, encoding: .utf8) ?? "unserializable report"
        FileHandle.standardError.write(Data("FAIL SessionTests [\(runID)]: \(reportText)\n".utf8))
      }
    } catch {
      reportWriteFailed = true
      FileHandle.standardError.write(Data("FAIL SessionTests [\(runID)]: could not write report at \(reportURL.path): \(error)\n".utf8))
    }
    if !passed || reportWriteFailed { exit(1) }
    print(
      "PASS session: REP ordering, lossless admission, live-mode paste encoding, saturation/cancel/close, owned-child reaping"
    )
  }
}

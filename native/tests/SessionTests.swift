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
        "physical_key_reaches_pty",
        "typed_metadata_rejected", "typed_legacy_metadata_rejected", "expanded_key_write_rejected",
        "typed_key_paths_admitted", "modifier_keys_preserve_anchored_viewport",
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

import Foundation

@main struct SessionTests {
  @MainActor static func main() {
    let root = CommandLine.arguments[1]
    func spec(_ script: String) -> LaunchSpec {
      LaunchSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], cwd: "/tmp",
        launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher")
    }
    var checks = Dictionary(
      uniqueKeysWithValues: [
        "input_admitted_for_ordered_output", "input_before_mode_suffix_is_unbracketed",
        "input_after_accepted_output_is_bracketed", "ordered_mode_encoding_after_rep",
        "physical_key_reaches_pty",
        "modifier_keys_preserve_anchored_viewport",
        "typed_metadata_rejected", "typed_legacy_metadata_rejected", "expanded_key_write_rejected",
        "typed_key_paths_admitted",
        "rep_completed", "large_paste_accepted", "oversize_paste_rejected",
        "saturated_cancel_close_reaped", "cancel_close_under_three_seconds",
        "ordinary_ingress_busy", "release_admitted_under_ingress_pressure",
        "viewport_scroll_anchored", "focus_release_preserves_viewport", "typing_follows_tail",
        "search_found_and_highlighted", "search_replacement_cancelled",
        "search_latest_query_completed", "search_owner_probe_under_100ms", "search_close_cancelled",
        "closed_focus_and_key_releases_are_quiet",
        "closed_text_input_is_reported",
        "finished_pty_refuses_text", "finished_pty_retains_search",
      ].map { ($0, false) })
    var statuses: [String] = []
    // A UI snapshot is intentionally coalesced, so it cannot timestamp parser order.
    // Check both sides of the boundary directly: an input encoded while REP still
    // holds the suffix is plain, while the same input after accepting the packet is
    // bracketed. This is the ordering that Session's FIFO preserves for its PTY data.
    let orderingCore = terminal_create(80, 24)!
    defer { terminal_destroy(orderingCore) }
    let orderingPacket = Data("X\u{1b}[500000b\u{1b}[?2004h".utf8)
    let capture: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = {
      context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      Unmanaged<NSMutableData>.fromOpaque(context).takeUnretainedValue().append(bytes, length: count)
    }
    func encodePaste() -> Data {
      let encoded = NSMutableData()
      let accepted = "hello\nworld".withCString {
        terminal_input(
          orderingCore, $0, 1, 0, 0, Unmanaged.passUnretained(encoded).toOpaque(), capture)
      }
      precondition(accepted)
      return encoded as Data
    }
    let firstAccepted = orderingPacket.withUnsafeBytes {
      terminal_feed(orderingCore, $0.bindMemory(to: UInt8.self).baseAddress!, orderingPacket.count, 0)
    }
    precondition(firstAccepted < orderingPacket.count && terminal_has_work(orderingCore))
    checks["input_before_mode_suffix_is_unbracketed"] =
      encodePaste() == Data("hello\rworld".utf8)
    var accepted = firstAccepted
    orderingPacket.withUnsafeBytes { packet in
      let bytes = packet.bindMemory(to: UInt8.self)
      while accepted < orderingPacket.count || terminal_has_work(orderingCore) {
        accepted += terminal_feed(
          orderingCore, bytes.baseAddress!.advanced(by: accepted), orderingPacket.count - accepted, 0)
      }
    }
    checks["input_after_accepted_output_is_bracketed"] =
      encodePaste() == Data("\u{1b}[200~hello\rworld\u{1b}[201~".utf8)
    // The PTY session must make that same final-mode decision for a live child.
    let orderedScript =
      "stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print \"X\\e[500000b\\e[?2004hREADY\"; s=STDIN.read(23); print(s==\"\\e[200~hello\\rworld\\e[201~\" ? \"\\r\\nORDERED_PASTE_OK\" : \"\\r\\nBAD_PASTE\")'"
    let ordered = Session(launch: spec(orderedScript))
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
    // Exercise the full typed physical-key queue and PTY write path. Mapping
    // tests alone cannot detect accidentally sending the unshifted logical key
    // to a legacy program.
    let physical = Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print "PHYSICAL_READY"; key=STDIN.read(1); print(key=="!" ? "\r\nPHYSICAL_KEY_OK" : "\r\nPHYSICAL_KEY_BAD")'"#))
    var physicalSent = false
    var physicalDone = false
    physical.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      if !physicalSent && text.contains("PHYSICAL_READY") {
        physicalSent = true
        precondition(physical.input(TerminalKeyEvent(
          text: "!", logical: "1", shifted: "!", baseLayout: "1", legacyText: "!", key: 200,
          modifiers: 1, event: 0)))
      }
      physicalDone = physicalDone || text.contains("PHYSICAL_KEY_OK")
    }
    let physicalDeadline = Date().addingTimeInterval(5)
    while !physicalDone && Date() < physicalDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["physical_key_reaches_pty"] = physicalDone
    physical.close()
    // Typed physical-key metadata is retained across the owner queue. It must
    // be charged in full, and a Kitty-associated-text expansion that cannot
    // ever fit the PTY cap must be rejected before it can stall the queue.
    let bounded = Session(launch: spec("sleep 1"))
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
    // Modifier-only events must not be treated as typing just because Kitty
    // happens to encode them. Exercise the ordered PTY path in both default
    // and all-keys mode while the user is reading retained output.
    let shiftPress = TerminalKeyEvent(
      text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: 400, modifiers: 1, event: 0)
    let commandPress = TerminalKeyEvent(
      text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: 403, modifiers: 9, event: 0)
    precondition(!shiftPress.isKeyAction)
    precondition(!commandPress.isKeyAction)
    func preservesModifierViewport(kitty: Bool) -> Bool {
      let mode = kitty ? "print \"\\e[=8u\"; " : ""
      let read = kitty ? 2 : 1
      let modifierView = Session(launch: spec(
        "stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; \(mode)30.times{|i| print \"modifier#{i}\\r\\n\"}; print \"MODIFIER_READY\"; STDIN.read(\(read)); print \"MODIFIER_TICK\"; sleep 1'"))
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
          precondition(modifierView.input(shiftPress))
          precondition(modifierView.input(commandPress))
          if !kitty { modifierView.rawInput(Data([0])) }
        case 2 where snapshot.revision > revision:
          passed = !snapshot.following_tail && snapshot.scroll_offset == 3 && snapshot.rows == rows
          phase = 3
        default: break
        }
      }
      let deadline = Date().addingTimeInterval(5)
      while phase != 3 && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      modifierView.close()
      return phase == 3 && passed
    }
    checks["modifier_keys_preserve_anchored_viewport"] =
      preservesModifierViewport(kitty: false) && preservesModifierViewport(kitty: true)
    // A finished child can leave its screen open. Its input admission must
    // close before callers (including AppleScript) are told text was accepted.
    let finished = Session(launch: spec("printf FINISHED_PTY_READY"))
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
    // These events pass through the real owner FIFO and typed snapshot bridge.
    // Focus reports and a paired release must not make history jump to the tail.
    let view = Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; 30.times{|i| print "row#{i}\r\n"}; print "VIEW_READY"; STDIN.read(1); print "\r\nVIEW_NEW_OUTPUT"'"#))
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
        precondition(view.input(key: 2, event: 1))
        precondition(view.input("r", key: 200, event: 2))
      case 2:
        checks["focus_release_preserves_viewport"] =
          !snapshot.following_tail && snapshot.scroll_offset == 3 && snapshot.rows == capturedRows
        viewPhase = 3
        precondition(view.input("x", key: 200))
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
    precondition(!view.input(key: 2, event: 0))
    precondition(!view.input("r", key: 200, event: 2))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    checks["closed_focus_and_key_releases_are_quiet"] = !shutdownStatuses.contains { $0.hasPrefix("Input") }
    precondition(!view.input("user text"))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    checks["closed_text_input_is_reported"] = shutdownStatuses.contains("Input closed")
    let searchable = Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; 3000.times{|i| print(i==1000 ? "SEARCH_NEEDLE\r\n" : "row#{i}\r\n")}; print "SEARCH_READY"; STDIN.read(1)'"#))
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
    precondition(searchReady)
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
    let blocked = Session(
      launch: spec(#"stty raw -echo; printf '\033[?2004hBLOCK_READY'; exec /bin/sleep 30"#))
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
    let report: [String: Any] = [
      "checks": checks, "passed": checks.values.allSatisfy { $0 },
      "cancel_to_reap_seconds": elapsed, "statuses": statuses,
    ]
    let data = try! JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: root + "/reports/session-tests.json"))
    precondition(checks.values.allSatisfy { $0 }, String(data: data, encoding: .utf8)!)
    print(
      "PASS session: REP ordering, lossless admission, live-mode paste encoding, saturation/cancel/close, owned-child reaping"
    )
  }
}

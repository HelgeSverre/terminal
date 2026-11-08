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
        "accepted_input_during_rep", "input_before_mode_suffix", "ordered_mode_encoding_after_rep",
        "rep_completed", "large_paste_accepted", "oversize_paste_rejected",
        "saturated_cancel_close_reaped", "cancel_close_under_three_seconds",
        "ordinary_ingress_busy", "release_admitted_under_ingress_pressure",
        "viewport_scroll_anchored", "focus_release_preserves_viewport", "typing_follows_tail",
        "search_found_and_highlighted", "search_replacement_cancelled",
        "search_latest_query_completed", "search_owner_probe_under_100ms", "search_close_cancelled",
        "closed_focus_and_key_releases_are_quiet",
        "closed_text_input_is_reported", "committed_text_round_trip",
      ].map { ($0, false) })
    var statuses: [String] = []
    let splitFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal split 猫 #% \(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: splitFolder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: splitFolder) }
    let splitAlias = splitFolder.appendingPathComponent("logical link")
    try! FileManager.default.createSymbolicLink(atPath: splitAlias.path, withDestinationPath: splitFolder.path)
    let splitURL = splitAlias.absoluteString
    let parent = Session(launch: LaunchSpec(executable: "/bin/sh",
      arguments: ["/bin/sh", "-c", "stty -echo; cd -- \"$1\"; printf '\\033]7;%s\\007SPLIT_CWD_READY' \"$2\"; IFS= read -r line",
        "split-fixture", splitAlias.path, splitURL], cwd: "/tmp", launcher: spec("").launcher))
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
      precondition(URL(fileURLWithPath: launch.cwd).resolvingSymlinksInPath().path == splitFolder.resolvingSymlinksInPath().path)
      let child = Session(launch: LaunchSpec(executable: "/bin/sh",
        arguments: ["/bin/sh", "-c", "printf 'SPLIT_CHILD_PWD=%s\\n' \"$PWD\""],
        cwd: launch.cwd, launcher: spec("").launcher))
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
      precondition(parent.input("\n"))
    }
    let splitDeadline = Date().addingTimeInterval(8)
    while !(parentEnded && siblingEnded && siblingMatched) && Date() < splitDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    parent.close(); sibling?.close()
    precondition(parentEnded && siblingEnded && siblingMatched,
      "split cwd: parent=\(parentEnded), child=\(siblingEnded), match=\(siblingMatched), cwd=\(String(describing: parentCWD)), childText=\(childText)")
    // The first partial REP snapshot arrives before its suffix sets bracketed paste.
    // Input admitted at that point must wait for the accepted byte event to finish.
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
        checks["input_before_mode_suffix"] = !snapshot.modes.bracketed_paste
        checks["accepted_input_during_rep"] = ordered.input("hello\nworld", key: 1)
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
    // Automation and IME commits use key=0: the C ABI must forward the full
    // committed string rather than silently reducing it to its first scalar.
    let committed = Session(launch: spec("stty raw -echo; exec /bin/cat"))
    var committedEchoed = false
    committed.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      committedEchoed = committedEchoed || text.contains("AUTOMATION_TEXT")
    }
    precondition(committed.input("AUTOMATION_TEXT\n"))
    let committedDeadline = Date().addingTimeInterval(5)
    while !committedEchoed && Date() < committedDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["committed_text_round_trip"] = committedEchoed
    committed.close()
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

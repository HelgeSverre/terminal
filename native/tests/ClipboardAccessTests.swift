import AppKit
import Foundation

@MainActor private final class Fixture {
  let sessionID = UUID()
  var live = true
  var completions: [Bool] = []

  func request(data: Data = Data("fixture".utf8)) -> ClipboardWriteRequest {
    ClipboardWriteRequest(
      sessionID: sessionID, data: data, live: { [weak self] in self?.live == true },
      completion: { [weak self] allowed, completion in
        self?.completions.append(allowed)
        completion(allowed)
      })
  }
}

@main struct ClipboardAccessTests {
  @MainActor static func main() {
    let root = CommandLine.arguments[1]
    let runID = UUID().uuidString
    var failures: [String] = []
    var checks = Dictionary(uniqueKeysWithValues: [
      "private_pasteboard_preserved", "allow_writes_once", "prompt_rate_limited",
      "denial_latches_session", "queued_same_session_denied", "stale_queue_denied",
      "invalid_utf8_denied", "request_resolution_is_one_shot", "overflow_denied",
      "cancel_dismisses_active", "late_decision_cannot_write", "next_queued_completes",
      "pty_write_reaches_private_pasteboard", "eof_cancels_pending_write",
      "late_close_handler_delivered_once", "read_query_denied_without_host_request",
      "all_owned_children_reaped",
    ].map { ($0, false) })
    var ownedSessions: [Session] = []
    func own(_ session: Session) -> Session {
      ownedSessions.append(session)
      return session
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
      guard !condition() else { return }
      let failure = message()
      failures.append(failure)
      FileHandle.standardError.write(Data("FAIL ClipboardAccessTests [\(runID)]: \(failure)\n".utf8))
    }
    func drain(until condition: @escaping () -> Bool, timeout: TimeInterval = 3) {
      let deadline = Date().addingTimeInterval(timeout)
      while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
    }
    func spec(_ script: String) -> LaunchSpec {
      LaunchSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], cwd: "/tmp",
        launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher")
    }

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("terminal-clipboard-test-\(runID)"))
    let original = Data("original fixture".utf8)
    pasteboard.clearContents()
    expect(pasteboard.setData(original, forType: .string), "could not seed private pasteboard")
    checks["private_pasteboard_preserved"] = pasteboard.data(forType: .string) == original
    var decisions: [(ClipboardAccessDecision) -> Void] = []
    var dismissals = 0
    var now: TimeInterval = 0
    let access = ClipboardAccess(pasteboard: pasteboard, decide: { _, _, completion in
      decisions.append(completion)
      return { dismissals += 1 }
    }, clock: { now })
    func takeDecision(_ context: String) -> ((ClipboardAccessDecision) -> Void)? {
      guard !decisions.isEmpty else {
        expect(false, "missing clipboard decision for \(context)")
        return nil
      }
      return decisions.removeFirst()
    }

    let allowed = Fixture()
    access.request(allowed.request(data: Data("allowed fixture".utf8)), from: nil)
    takeDecision("allowed")?(.allow)
    checks["allow_writes_once"] = pasteboard.data(forType: .string) == Data("allowed fixture".utf8)
      && allowed.completions == [true]
    access.request(allowed.request(data: Data("too soon".utf8)), from: nil)
    checks["prompt_rate_limited"] = decisions.isEmpty && allowed.completions == [true, false]
    now += 1

    let denied = Fixture()
    access.request(denied.request(data: Data("denied fixture".utf8)), from: nil)
    takeDecision("denied")?(.deny)
    access.request(denied.request(data: Data("denied again".utf8)), from: nil)
    checks["denial_latches_session"] = decisions.isEmpty && denied.completions == [false, false]
      && pasteboard.data(forType: .string) == Data("allowed fixture".utf8)
    now += 1

    let queuedSameSession = Fixture()
    access.request(queuedSameSession.request(data: Data("first same-session".utf8)), from: nil)
    now += 1
    access.request(queuedSameSession.request(data: Data("second same-session".utf8)), from: nil)
    takeDecision("same-session")?(.deny)
    checks["queued_same_session_denied"] = decisions.isEmpty && queuedSameSession.completions == [false, false]
    now += 1

    let liveBeforeStale = Fixture()
    let staleQueued = Fixture()
    access.request(liveBeforeStale.request(data: Data("live first".utf8)), from: nil)
    now += 1
    access.request(staleQueued.request(data: Data("stale queued".utf8)), from: nil)
    staleQueued.live = false
    takeDecision("live before stale")?(.allow)
    checks["stale_queue_denied"] = decisions.isEmpty && staleQueued.completions == [false]
      && pasteboard.data(forType: .string) == Data("live first".utf8)

    let invalid = Fixture()
    access.request(invalid.request(data: Data([0xff])), from: nil)
    checks["invalid_utf8_denied"] = decisions.isEmpty && invalid.completions == [false]

    let oneShot = Fixture()
    let oneShotRequest = oneShot.request()
    var oneShotResults: [Bool] = []
    oneShotRequest.resolve(false) { oneShotResults.append($0) }
    oneShotRequest.resolve(true) { oneShotResults.append($0) }
    checks["request_resolution_is_one_shot"] = oneShot.completions == [false] && oneShotResults == [false]

    now += 1
    let queued = (0..<ClipboardAccess.maximumPending + 1).map { _ in Fixture() }
    let queuedRequests = queued.map { $0.request() }
    for request in queuedRequests { access.request(request, from: nil) }
    checks["overflow_denied"] = decisions.count == 1 && queued.last?.completions == [false]
    let cancelledDecision = takeDecision("active cancellation")
    access.cancel(sessionID: queuedRequests[0].sessionID)
    checks["cancel_dismisses_active"] = dismissals == 1 && decisions.count == 1
    takeDecision("next queued")?(.allow)
    cancelledDecision?(.allow)
    checks["late_decision_cannot_write"] = queued[0].completions == [false]
      && pasteboard.data(forType: .string) == Data("fixture".utf8)
    checks["next_queued_completes"] = queued[1].completions == [true]
    while let decision = decisions.popLast() { decision(.deny) }

    let orderedPasteboard = NSPasteboard(name: NSPasteboard.Name("terminal-clipboard-pty-\(runID)"))
    let orderedAccess = ClipboardAccess(pasteboard: orderedPasteboard) { _, _, completion in
      completion(.allow)
      return nil
    }
    let writer = own(Session(launch: spec(
      "stty raw -echo; printf '\\033]52;c;cHR5IGZpeHR1cmU=\\007WRITE_READY'; exec /bin/cat >/dev/null")))
    writer.onClipboardWrite = { request in orderedAccess.request(request, from: nil) }
    drain(until: { orderedPasteboard.data(forType: .string) == Data("pty fixture".utf8) })
    checks["pty_write_reaches_private_pasteboard"] =
      orderedPasteboard.data(forType: .string) == Data("pty fixture".utf8)
    writer.close()

    let closedPasteboard = NSPasteboard(name: NSPasteboard.Name("terminal-clipboard-closed-\(runID)"))
    let closedOriginal = Data("closed original".utf8)
    closedPasteboard.clearContents()
    expect(closedPasteboard.setData(closedOriginal, forType: .string), "could not seed closed private pasteboard")
    var closedDecision: ((ClipboardAccessDecision) -> Void)?
    let closedAccess = ClipboardAccess(pasteboard: closedPasteboard) { _, _, completion in
      closedDecision = completion
      return nil
    }
    let closed = own(Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print "\e]52;c;Y2xvc2VkIGZpeHR1cmU=\a"; STDIN.read(1)'"#)))
    var eofCancelled = false
    closed.onClipboardWrite = { [weak closed] request in
      closedAccess.request(request, from: nil)
      closed?.rawInput(Data([0x78]))
    }
    closed.setClipboardClosedHandler { sessionID in
      eofCancelled = true
      closedAccess.cancel(sessionID: sessionID)
    }
    drain(until: { closedDecision != nil && eofCancelled })
    closedDecision?(.allow)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    checks["eof_cancels_pending_write"] = eofCancelled
      && closedPasteboard.data(forType: .string) == closedOriginal
    closed.close()

    let late = own(Session(launch: spec("printf LATE_CLOSE_READY")))
    var lateCloseNotifications = 0
    drain(until: {
      var readEnded = false
      late.statistics { readEnded = $0["read_ended"] as? Bool == true }
      return readEnded
    })
    late.setClipboardClosedHandler { _ in lateCloseNotifications += 1 }
    drain(until: { lateCloseNotifications == 1 })
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    checks["late_close_handler_delivered_once"] = lateCloseNotifications == 1
    late.close()

    let reader = own(Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print "\e]52;c;?\a"; answer=STDIN.read(9); print(answer == "\e]52;c;\e\\" ? "READ_DENIED_OK" : "READ_BAD")'"#)))
    var queryRequestedHostClipboard = false
    var readDenied = false
    reader.onClipboardWrite = { _ in queryRequestedHostClipboard = true }
    reader.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      readDenied = text.contains("READ_DENIED_OK")
    }
    drain(until: { readDenied })
    checks["read_query_denied_without_host_request"] = readDenied && !queryRequestedHostClipboard
    reader.close()

    ownedSessions.forEach { $0.close() }
    var unreaped = Set(ownedSessions.indices)
    let cleanupDeadline = Date().addingTimeInterval(3)
    while !unreaped.isEmpty && Date() < cleanupDeadline {
      for index in unreaped {
        ownedSessions[index].statistics { values in
          if values["child_reaped"] as? Bool == true { unreaped.remove(index) }
        }
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    checks["all_owned_children_reaped"] = unreaped.isEmpty
    expect(unreaped.isEmpty, "clipboard fixture children were not reaped: \(unreaped)")

    let passed = failures.isEmpty && checks.values.allSatisfy { $0 }
    let report: [String: Any] = [
      "run_id": runID, "checks": checks, "failures": failures, "passed": passed,
      "owned_sessions": ownedSessions.count, "unreaped_sessions": unreaped.sorted(),
    ]
    let reportURL = URL(fileURLWithPath: root + "/reports/clipboard-access-tests.json")
    var reportWriteFailed = false
    do {
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: reportURL, options: .atomic)
      print("CLIPBOARD_TEST_REPORT=\(reportURL.path) run_id=\(runID) passed=\(passed)")
    } catch {
      reportWriteFailed = true
      FileHandle.standardError.write(Data("FAIL ClipboardAccessTests [\(runID)]: could not write report: \(error)\n".utf8))
    }
    if !passed || reportWriteFailed { exit(1) }
    print("PASS clipboard: one-shot, queued/cancelled decisions, EOF/late close, and private PTY OSC 52")
  }
}

import AppKit
import Foundation

@MainActor private final class Fixture {
  let sessionID = UUID()
  var live = true
  var completions: [Bool] = []
  func request(data: Data = Data("fixture".utf8)) -> ClipboardWriteRequest {
    ClipboardWriteRequest(
      requestID: UInt64(completions.count + 1), sessionID: sessionID, data: data,
      live: { [weak self] in self?.live == true },
      complete: { [weak self] allowed, completion in
        self?.completions.append(allowed)
        completion(allowed)
      })
  }
}

@main struct ClipboardAccessTests {
  @MainActor static func main() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("terminal-clipboard-test-\(UUID().uuidString)"))
    let original = Data("original fixture".utf8)
    pasteboard.clearContents()
    precondition(pasteboard.setData(original, forType: .string))
    var decisions: [(ClipboardAccessDecision) -> Void] = []
    var dismissals = 0
    var now: TimeInterval = 0
    let access = ClipboardAccess(pasteboard: pasteboard, decide: { _, _, completion in
      decisions.append(completion)
      return { dismissals += 1 }
    }, clock: { now })

    let allowed = Fixture()
    access.request(allowed.request(data: Data("allowed fixture".utf8)), from: nil)
    precondition(decisions.count == 1)
    decisions.removeFirst()(.allow)
    precondition(pasteboard.data(forType: .string) == Data("allowed fixture".utf8))
    precondition(allowed.completions == [true])
    access.request(allowed.request(data: Data("too soon".utf8)), from: nil)
    precondition(decisions.isEmpty, "an allowed prompt is rate limited for its session")
    precondition(allowed.completions == [true, false])
    now += 1
    access.request(allowed.request(data: Data("allowed after cooldown".utf8)), from: nil)
    precondition(decisions.count == 1)
    decisions.removeFirst()(.allow)
    precondition(allowed.completions == [true, false, true])

    let denied = Fixture()
    access.request(denied.request(data: Data("denied fixture".utf8)), from: nil)
    precondition(decisions.count == 1)
    decisions.removeFirst()(.deny)
    precondition(pasteboard.data(forType: .string) == Data("allowed after cooldown".utf8))
    precondition(denied.completions == [false])
    access.request(denied.request(data: Data("denied again".utf8)), from: nil)
    precondition(decisions.isEmpty, "a denial suppresses later prompts for this session")
    precondition(denied.completions == [false, false])

    now += 1
    let queuedSameSession = Fixture()
    access.request(queuedSameSession.request(data: Data("first same-session".utf8)), from: nil)
    precondition(decisions.count == 1)
    now += 1
    access.request(queuedSameSession.request(data: Data("second same-session".utf8)), from: nil)
    decisions.removeFirst()(.deny)
    precondition(decisions.isEmpty, "a queued request is rechecked after a same-session denial")
    precondition(queuedSameSession.completions == [false, false])

    now += 1
    let liveBeforeStale = Fixture()
    let staleQueued = Fixture()
    access.request(liveBeforeStale.request(data: Data("live first".utf8)), from: nil)
    precondition(decisions.count == 1)
    now += 1
    access.request(staleQueued.request(data: Data("stale queued".utf8)), from: nil)
    staleQueued.live = false
    decisions.removeFirst()(.allow)
    precondition(decisions.isEmpty, "a stale queued request is denied before presentation")
    precondition(staleQueued.completions == [false])

    let invalid = Fixture()
    access.request(invalid.request(data: Data([0xff])), from: nil)
    precondition(decisions.isEmpty, "non-UTF-8 text never reaches the pasteboard prompt")
    precondition(invalid.completions == [false])

    let stale = Fixture()
    let staleRequest = stale.request(data: Data("stale fixture".utf8))
    access.request(staleRequest, from: nil)
    stale.live = false
    precondition(decisions.count == 1)
    decisions.removeFirst()(.allow)
    precondition(pasteboard.data(forType: .string) == Data("live first".utf8))
    precondition(stale.completions == [false])

    now += 1
    let queued = (0..<ClipboardAccess.maximumPending + 1).map { _ in Fixture() }
    let queuedRequests = queued.map { $0.request() }
    for request in queuedRequests { access.request(request, from: nil) }
    precondition(decisions.count == 1, "only one prompt is visible")
    precondition(queued.last?.completions == [false], "overflow is denied without a prompt")
    let cancelledDecision = decisions.removeFirst()
    access.cancel(sessionID: queuedRequests[0].sessionID)
    precondition(dismissals == 1, "cancelling an active request dismisses its presentation")
    precondition(decisions.count == 1, "cancelling the active sheet admits the next session")
    decisions.removeFirst()(.allow)
    cancelledDecision(.allow)
    precondition(queued[0].completions == [false], "a cancelled active request cannot write")
    precondition(queued[1].completions == [true], "the next session can complete without the old callback")
    while !decisions.isEmpty { decisions.removeFirst()(.deny) }
    precondition(queued.dropLast().allSatisfy { $0.completions.count <= 1 })

    let root = CommandLine.arguments[1]
    func spec(_ script: String) -> LaunchSpec {
      LaunchSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], cwd: "/tmp",
        launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher")
    }
    let orderedPasteboard = NSPasteboard(
      name: NSPasteboard.Name("terminal-clipboard-pty-\(UUID().uuidString)"))
    let orderedAccess = ClipboardAccess(pasteboard: orderedPasteboard) { _, _, completion in
      completion(.allow)
      return nil
    }
    let writer = Session(launch: spec("printf '\\033]52;c;cHR5IGZpeHR1cmU=\\007WRITE_READY'; sleep 1"))
    writer.onClipboardWrite = { request in orderedAccess.request(request, from: nil) }
    let writeDeadline = Date().addingTimeInterval(3)
    while orderedPasteboard.data(forType: .string) != Data("pty fixture".utf8) && Date() < writeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(orderedPasteboard.data(forType: .string) == Data("pty fixture".utf8))
    writer.close()

    let closedPasteboard = NSPasteboard(
      name: NSPasteboard.Name("terminal-clipboard-closed-\(UUID().uuidString)"))
    let closedOriginal = Data("closed original".utf8)
    closedPasteboard.clearContents()
    precondition(closedPasteboard.setData(closedOriginal, forType: .string))
    var closedDecision: ((ClipboardAccessDecision) -> Void)?
    let closedAccess = ClipboardAccess(pasteboard: closedPasteboard) { _, _, completion in
      closedDecision = completion
      return nil
    }
    let closed = Session(launch: spec("printf '\\033]52;c;Y2xvc2VkIGZpeHR1cmU=\\007'"))
    var eofCancelled = false
    closed.onClipboardWrite = { request in closedAccess.request(request, from: nil) }
    closed.setClipboardClosedHandler { sessionID in
      eofCancelled = true
      closedAccess.cancel(sessionID: sessionID)
    }
    let closedDeadline = Date().addingTimeInterval(3)
    while (closedDecision == nil || !eofCancelled) && Date() < closedDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(closedDecision != nil && eofCancelled)
    closedDecision?(.allow)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(closedPasteboard.data(forType: .string) == closedOriginal)
    closed.close()

    let interleaved = Session(launch: spec("printf '\\033]52;c;aW50ZXJsZWF2ZWQ=\\007'; sleep 0.05"))
    var closeNotifications = 0
    interleaved.setClipboardClosedHandler { _ in closeNotifications += 1 }
    interleaved.onClipboardWrite = { _ in interleaved.close() }
    let interleavedDeadline = Date().addingTimeInterval(3)
    while closeNotifications == 0 && Date() < interleavedDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(closeNotifications == 1, "close and EOF share one owner-confined cancellation")

    let reader = Session(launch: spec(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print "\e]52;c;?\a"; answer=STDIN.read(9); print(answer == "\e]52;c;\e\\" ? "READ_DENIED_OK" : "READ_BAD")'"#))
    var queryRequestedHostClipboard = false
    var readDenied = false
    reader.onClipboardWrite = { _ in queryRequestedHostClipboard = true }
    reader.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      readDenied = text.contains("READ_DENIED_OK")
    }
    let readDeadline = Date().addingTimeInterval(3)
    while !readDenied && Date() < readDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    reader.close()
    precondition(readDenied && !queryRequestedHostClipboard)
    print("PASS clipboard: private pasteboard allow/deny/stale/closed/bounds and real PTY OSC 52 read denial")
  }
}

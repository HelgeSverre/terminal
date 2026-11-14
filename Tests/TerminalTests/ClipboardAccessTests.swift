import AppKit
import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

/// Serialized: every test writes to a private named pasteboard and the
/// tests share the helpers below.
@Suite(.serialized) @MainActor struct ClipboardAccessTests {
  @MainActor final class WriteFixture {
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

  /// The sessions one test started, so it can close them and check that
  /// their children were reaped.
  final class Owned {
    var sessions: [Session] = []
    func own(_ session: Session) -> Session {
      sessions.append(session)
      return session
    }
    func closeAll() { sessions.forEach { $0.close() } }
    func expectReaped() async {
      closeAll()
      var unreaped = Set(sessions.indices)
      let reaped = await TestEnvironment.wait(seconds: 3) {
        for index in unreaped {
          sessions[index].statistics { values in
            if values["child_reaped"] as? Bool == true { unreaped.remove(index) }
          }
        }
        return unreaped.isEmpty
      }
      #expect(reaped, "clipboard fixture children were not reaped: \(unreaped)")
    }
  }

  static func pause(_ seconds: TimeInterval) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
  }
  static func pasteboard(_ name: String) -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("terminal-clipboard-\(name)-\(UUID().uuidString)"))
  }
  static func text(_ snapshot: TerminalSnapshot) -> String {
    snapshot.rows.flatMap(\.cells).map(\.text).joined()
  }
  static func selectedSession(
    _ owned: Owned, _ value: String, display: String? = nil, selection: Range<Int>? = nil,
    trailingOutput: String? = nil
  ) async -> (Session, UInt64)? {
    let displayed = display ?? value
    let selectedRange = selection ?? 0..<value.count
    let suffix = trailingOutput.map { "; sleep 0.15; printf '\($0)'" } ?? ""
    let session = owned.own(Session(launch: TestEnvironment.shell("sleep 0.05; printf '\(displayed)'\(suffix); sleep 1")))
    var latest: TerminalSnapshot?
    session.onSnapshot = { latest = $0 }
    _ = await TestEnvironment.wait(seconds: 3) { latest.map(text)?.contains(displayed) == true }
    guard let shown = latest, let presentation = shown.selectionPresentation,
      let start = presentation.hit(row: 0, boundary: selectedRange.lowerBound),
      let end = presentation.hit(row: 0, boundary: selectedRange.upperBound)
    else {
      Issue.record("missing presentation for copy fixture \(value)")
      return nil
    }
    var selectionResult: Result<String?, TerminalSelectionFailure>?
    guard session.selection(.range(start: start, end: end, mode: .linear), completion: { selectionResult = $0 }) else {
      Issue.record("selection admission failed for copy fixture \(value)")
      return nil
    }
    _ = await TestEnvironment.wait(seconds: 3) {
      guard let latest else { return false }
      return selectionResult != nil && latest.selection.phase == .committed
    }
    guard let selectionResult, case .success = selectionResult,
      let revision = latest?.selection.revision, revision > 0
    else {
      Issue.record("selection failed for copy fixture \(value): \(String(describing: selectionResult))")
      return nil
    }
    return (session, revision)
  }

  /// Everything the access object decides without a PTY: the private
  /// pasteboard is preserved, one allowed write lands once, a second write
  /// right after it is decided too, a denial latches the session, queued and stale requests are
  /// denied, resolution is one-shot, overflow is denied, cancelling dismisses
  /// the active prompt, a late decision cannot write, and the next queued
  /// request completes. The blocks share one access object and clock.
  @Test static func accessPolicy() {
    let pasteboard = pasteboard("policy")
    let original = Data("original fixture".utf8)
    pasteboard.clearContents()
    #expect(pasteboard.setData(original, forType: .string), "could not seed private pasteboard")
    #expect(pasteboard.data(forType: .string) == original, "private pasteboard must be preserved")
    var decisions: [(ClipboardAccessDecision) -> Void] = []
    var dismissals = 0
    let access = ClipboardAccess(pasteboard: pasteboard, decide: { _, _, completion in
      decisions.append(completion)
      return { dismissals += 1 }
    })
    func takeDecision(_ context: String) -> ((ClipboardAccessDecision) -> Void)? {
      guard !decisions.isEmpty else {
        Issue.record("missing clipboard decision for \(context)")
        return nil
      }
      return decisions.removeFirst()
    }

    // allow_writes_once
    let allowed = WriteFixture()
    access.request(allowed.request(data: Data("allowed fixture".utf8)), from: nil)
    takeDecision("allowed")?(.allow)
    #expect(pasteboard.data(forType: .string) == Data("allowed fixture".utf8))
    #expect(allowed.completions == [true])
    // back_to_back_write_is_decided
    access.request(allowed.request(data: Data("right after".utf8)), from: nil)
    takeDecision("back to back")?(.allow)
    #expect(pasteboard.data(forType: .string) == Data("right after".utf8))
    #expect(allowed.completions == [true, true], "a quick second write must not be dropped")

    // denial_latches_session
    let denied = WriteFixture()
    access.request(denied.request(data: Data("denied fixture".utf8)), from: nil)
    takeDecision("denied")?(.deny)
    access.request(denied.request(data: Data("denied again".utf8)), from: nil)
    #expect(decisions.isEmpty && denied.completions == [false, false], "a denial must latch the session")
    #expect(pasteboard.data(forType: .string) == Data("right after".utf8))

    // queued_same_session_denied
    let queuedSameSession = WriteFixture()
    access.request(queuedSameSession.request(data: Data("first same-session".utf8)), from: nil)
    access.request(queuedSameSession.request(data: Data("second same-session".utf8)), from: nil)
    takeDecision("same-session")?(.deny)
    #expect(decisions.isEmpty && queuedSameSession.completions == [false, false])

    // stale_queue_denied
    let liveBeforeStale = WriteFixture()
    let staleQueued = WriteFixture()
    access.request(liveBeforeStale.request(data: Data("live first".utf8)), from: nil)
    access.request(staleQueued.request(data: Data("stale queued".utf8)), from: nil)
    staleQueued.live = false
    takeDecision("live before stale")?(.allow)
    #expect(decisions.isEmpty && staleQueued.completions == [false])
    #expect(pasteboard.data(forType: .string) == Data("live first".utf8))

    // invalid_utf8_denied
    let invalid = WriteFixture()
    access.request(invalid.request(data: Data([0xff])), from: nil)
    #expect(decisions.isEmpty && invalid.completions == [false])

    // request_resolution_is_one_shot
    let oneShot = WriteFixture()
    let oneShotRequest = oneShot.request()
    var oneShotResults: [Bool] = []
    oneShotRequest.resolve(false) { oneShotResults.append($0) }
    oneShotRequest.resolve(true) { oneShotResults.append($0) }
    #expect(oneShot.completions == [false] && oneShotResults == [false])

    // overflow_denied
    let queued = (0..<ClipboardAccess.maximumPending + 1).map { _ in WriteFixture() }
    let queuedRequests = queued.map { $0.request() }
    for request in queuedRequests { access.request(request, from: nil) }
    #expect(decisions.count == 1 && queued.last?.completions == [false])
    let cancelledDecision = takeDecision("active cancellation")
    access.cancel(sessionID: queuedRequests[0].sessionID)
    // cancel_dismisses_active
    #expect(dismissals == 1 && decisions.count == 1)
    takeDecision("next queued")?(.allow)
    cancelledDecision?(.allow)
    // late_decision_cannot_write
    #expect(queued[0].completions == [false])
    #expect(pasteboard.data(forType: .string) == Data("fixture".utf8))
    // next_queued_completes
    #expect(queued[1].completions == [true])
    while let decision = decisions.popLast() { decision(.deny) }
  }

  /// The default decision allows every write without a prompt, also when
  /// there is no window to show one on, and writes from several panes in a row.
  @Test static func defaultAllowsEveryWriteWithoutAsking() {
    let pasteboard = pasteboard("default")
    let access = ClipboardAccess(pasteboard: pasteboard)
    let panes = [WriteFixture(), WriteFixture(), WriteFixture()]
    for (index, pane) in panes.enumerated() {
      for write in 0..<2 {
        let text = "pane \(index) write \(write)"
        access.request(pane.request(data: Data(text.utf8)), from: nil)
        #expect(pasteboard.data(forType: .string) == Data(text.utf8), "\(text) did not land")
      }
      #expect(pane.completions == [true, true])
    }
  }

  @Test static func ptyWriteReachesPrivatePasteboard() async {
    let owned = Owned()
    let orderedPasteboard = pasteboard("pty")
    let orderedAccess = ClipboardAccess(pasteboard: orderedPasteboard) { _, _, completion in
      completion(.allow)
      return nil
    }
    let writer = owned.own(Session(launch: TestEnvironment.shell(
      "stty raw -echo; printf '\\033]52;c;cHR5IGZpeHR1cmU=\\007WRITE_READY'; exec /bin/cat >/dev/null")))
    writer.onClipboardWrite = { request in orderedAccess.request(request, from: nil) }
    _ = await TestEnvironment.wait(seconds: 3) { orderedPasteboard.data(forType: .string) == Data("pty fixture".utf8) }
    #expect(orderedPasteboard.data(forType: .string) == Data("pty fixture".utf8))
    writer.close()
    await owned.expectReaped()
  }

  @Test static func eofCancelsPendingWrite() async {
    let owned = Owned()
    let closedPasteboard = pasteboard("closed")
    let closedOriginal = Data("closed original".utf8)
    closedPasteboard.clearContents()
    #expect(closedPasteboard.setData(closedOriginal, forType: .string), "could not seed closed private pasteboard")
    var closedDecision: ((ClipboardAccessDecision) -> Void)?
    let closedAccess = ClipboardAccess(pasteboard: closedPasteboard) { _, _, completion in
      closedDecision = completion
      return nil
    }
    let closed = owned.own(Session(launch: TestEnvironment.shell(
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
    _ = await TestEnvironment.wait(seconds: 3) { closedDecision != nil && eofCancelled }
    closedDecision?(.allow)
    await pause(0.05)
    #expect(eofCancelled)
    #expect(closedPasteboard.data(forType: .string) == closedOriginal)
    closed.close()
    await owned.expectReaped()
  }

  @Test static func lateCloseHandlerDeliveredOnce() async {
    let owned = Owned()
    let late = owned.own(Session(launch: TestEnvironment.shell("printf LATE_CLOSE_READY")))
    var lateCloseNotifications = 0
    // `statistics` answers on a later turn, so the flag outlives each poll.
    var readEnded = false
    _ = await TestEnvironment.wait(seconds: 3) {
      late.statistics { readEnded = $0["read_ended"] as? Bool == true }
      return readEnded
    }
    late.setClipboardClosedHandler { _ in lateCloseNotifications += 1 }
    _ = await TestEnvironment.wait(seconds: 3) { lateCloseNotifications == 1 }
    await pause(0.05)
    #expect(lateCloseNotifications == 1)
    late.close()
    await owned.expectReaped()
  }

  @Test static func readQueryDeniedWithoutHostRequest() async {
    let owned = Owned()
    let reader = owned.own(Session(launch: TestEnvironment.shell(
      #"stty raw -echo; exec /usr/bin/ruby -e 'STDOUT.sync=true; print "\e]52;c;?\a"; answer=STDIN.read(9); print(answer == "\e]52;c;\e\\" ? "READ_DENIED_OK" : "READ_BAD")'"#)))
    var queryRequestedHostClipboard = false
    var readDenied = false
    reader.onClipboardWrite = { _ in queryRequestedHostClipboard = true }
    reader.onSnapshot = { snapshot in
      let text = snapshot.rows.flatMap { $0.cells }.map { $0.text }.joined()
      readDenied = text.contains("READ_DENIED_OK")
    }
    _ = await TestEnvironment.wait(seconds: 3) { readDenied }
    #expect(readDenied && !queryRequestedHostClipboard)
    reader.close()
    await owned.expectReaped()
  }

  @Test static func userCopyEmptyString() async {
    let owned = Owned()
    let copyPasteboard = pasteboard("copy-empty")
    let copyAccess = ClipboardAccess(pasteboard: copyPasteboard)
    guard let (empty, revision) = await selectedSession(owned, "", display: "x", selection: 1..<2) else {
      await owned.expectReaped(); return
    }
    copyPasteboard.clearContents()
    let beforeEmptyCopy = Data("before empty copy".utf8)
    #expect(copyPasteboard.setData(beforeEmptyCopy, forType: .string), "could not seed empty-copy pasteboard")
    let changeCount = copyPasteboard.changeCount
    copyAccess.copy(from: empty, selectionRevision: revision)
    // Cocoa omits a zero-length string from `string(forType:)`; a changed
    // private pasteboard generation proves this successful empty selection
    // was copied rather than treated as a non-copy (`nil`).
    _ = await TestEnvironment.wait(seconds: 3) {
      copyPasteboard.changeCount != changeCount
        && copyPasteboard.data(forType: .string) != beforeEmptyCopy
    }
    #expect(copyPasteboard.changeCount != changeCount)
    #expect(copyPasteboard.data(forType: .string) != beforeEmptyCopy)
    await owned.expectReaped()
  }

  /// A completion from an older copy request is rejected and the newer one wins.
  @Test static func userCopyNewerRequestWins() async {
    let owned = Owned()
    let copyPasteboard = pasteboard("copy-newer")
    let copyAccess = ClipboardAccess(pasteboard: copyPasteboard)
    guard let (first, firstRevision) = await selectedSession(owned, "first pane"),
      let (second, secondRevision) = await selectedSession(owned, "second pane")
    else { await owned.expectReaped(); return }
    copyPasteboard.clearContents()
    copyAccess.copy(from: first, selectionRevision: firstRevision)
    copyAccess.copy(from: second, selectionRevision: secondRevision)
    _ = await TestEnvironment.wait(seconds: 3) { copyPasteboard.data(forType: .string) == Data("second pane".utf8) }
    #expect(copyPasteboard.data(forType: .string) == Data("second pane".utf8))
    await owned.expectReaped()
  }

  @Test static func userCopyExternalChangeWins() async {
    let owned = Owned()
    let copyPasteboard = pasteboard("copy-external")
    let copyAccess = ClipboardAccess(pasteboard: copyPasteboard)
    guard let (external, revision) = await selectedSession(owned, "external source") else {
      await owned.expectReaped(); return
    }
    copyPasteboard.clearContents()
    copyAccess.copy(from: external, selectionRevision: revision)
    copyPasteboard.clearContents()
    _ = copyPasteboard.setData(Data("outside owner".utf8), forType: .string)
    await pause(0.2)
    #expect(copyPasteboard.data(forType: .string) == Data("outside owner".utf8))
    await owned.expectReaped()
  }

  @Test static func userCopyCaptureSurvivesLaterPTYMutation() async {
    let owned = Owned()
    let copyPasteboard = pasteboard("copy-capture")
    let copyAccess = ClipboardAccess(pasteboard: copyPasteboard)
    guard let (captured, revision) = await selectedSession(owned, "captured text", trailingOutput: "CHANGED") else {
      await owned.expectReaped(); return
    }
    copyPasteboard.clearContents()
    copyAccess.copy(from: captured, selectionRevision: revision)
    _ = await TestEnvironment.wait(seconds: 3) { copyPasteboard.data(forType: .string) == Data("captured text".utf8) }
    var mutatedAfterCopy = false
    captured.onSnapshot = { mutatedAfterCopy = text($0).contains("CHANGED") }
    _ = await TestEnvironment.wait(seconds: 0.5) { mutatedAfterCopy }
    #expect(mutatedAfterCopy)
    #expect(copyPasteboard.data(forType: .string) == Data("captured text".utf8))
    await owned.expectReaped()
  }

  @Test static func userCopyClosedSessionCannotWrite() async {
    let owned = Owned()
    let copyPasteboard = pasteboard("copy-closed")
    let copyAccess = ClipboardAccess(pasteboard: copyPasteboard)
    guard let (closedCopy, revision) = await selectedSession(owned, "closed source") else {
      await owned.expectReaped(); return
    }
    copyPasteboard.clearContents()
    _ = copyPasteboard.setData(Data("before close".utf8), forType: .string)
    closedCopy.close()
    copyAccess.copy(from: closedCopy, selectionRevision: revision)
    await pause(0.1)
    #expect(copyPasteboard.data(forType: .string) == Data("before close".utf8))
    await owned.expectReaped()
  }

  /// A user copy made after an OSC 52 write was allowed beats that write's
  /// delayed completion, and a later allowed OSC 52 write beats the copy.
  @Test static func copyOrderingAgainstOSC52() async {
    let owned = Owned()
    let orderingPasteboard = pasteboard("ordering")
    var orderingDecisions: [(ClipboardAccessDecision) -> Void] = []
    let orderingAccess = ClipboardAccess(pasteboard: orderingPasteboard, decide: { _, _, completion in
      orderingDecisions.append(completion)
      return nil
    })
    guard let (copySource, revision) = await selectedSession(owned, "user ordering") else {
      await owned.expectReaped(); return
    }
    var delayedOSC52Completion: ((Bool) -> Void)?
    let delayedOSC52 = ClipboardWriteRequest(
      sessionID: UUID(), data: Data("stale osc52".utf8), live: { true },
      completion: { allowed, completion in
        if allowed { delayedOSC52Completion = completion }
        else { completion(false) }
      })
    orderingAccess.request(delayedOSC52, from: nil)
    orderingDecisions.removeFirst()(.allow)
    orderingAccess.copy(from: copySource, selectionRevision: revision)
    delayedOSC52Completion?(true)
    _ = await TestEnvironment.wait(seconds: 3) { orderingPasteboard.data(forType: .string) == Data("user ordering".utf8) }
    #expect(orderingPasteboard.data(forType: .string) == Data("user ordering".utf8), "a newer user copy must beat a stale OSC 52 write")

    orderingAccess.copy(from: copySource, selectionRevision: revision)
    let laterOSC52 = WriteFixture()
    orderingAccess.request(laterOSC52.request(data: Data("later osc52".utf8)), from: nil)
    if orderingDecisions.isEmpty {
      Issue.record("missing later OSC 52 decision")
    } else {
      orderingDecisions.removeFirst()(.allow)
      _ = await TestEnvironment.wait(seconds: 3) { orderingPasteboard.data(forType: .string) == Data("later osc52".utf8) }
      #expect(orderingPasteboard.data(forType: .string) == Data("later osc52".utf8), "a later allowed OSC 52 write must beat the user copy")
    }
    await owned.expectReaped()
  }

  @Test static func rejectedCopyPreservesAllowedOSC52() async {
    let owned = Owned()
    let orderingPasteboard = pasteboard("rejected")
    var orderingDecisions: [(ClipboardAccessDecision) -> Void] = []
    let orderingAccess = ClipboardAccess(pasteboard: orderingPasteboard, decide: { _, _, completion in
      orderingDecisions.append(completion)
      return nil
    })
    guard let (rejectedCopy, revision) = await selectedSession(owned, "rejected copy") else {
      await owned.expectReaped(); return
    }
    var delayedAllowedCompletion: ((Bool) -> Void)?
    let delayedAllowed = ClipboardWriteRequest(
      sessionID: UUID(), data: Data("allowed after rejection".utf8), live: { true },
      completion: { allowed, completion in
        if allowed { delayedAllowedCompletion = completion }
        else { completion(false) }
      })
    orderingAccess.request(delayedAllowed, from: nil)
    if orderingDecisions.isEmpty {
      Issue.record("missing delayed allowed OSC 52 decision")
    } else {
      orderingDecisions.removeFirst()(.allow)
      rejectedCopy.close()
      orderingAccess.copy(from: rejectedCopy, selectionRevision: revision)
      delayedAllowedCompletion?(true)
      _ = await TestEnvironment.wait(seconds: 3) { orderingPasteboard.data(forType: .string) == Data("allowed after rejection".utf8) }
      #expect(orderingPasteboard.data(forType: .string) == Data("allowed after rejection".utf8))
    }
    await owned.expectReaped()
  }
}

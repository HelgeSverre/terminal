import AppKit
import Foundation

@MainActor private final class Fixture {
  var live = true
  var completions: [Bool] = []
  func request(data: Data = Data("fixture".utf8)) -> ClipboardWriteRequest {
    ClipboardWriteRequest(
      requestID: UInt64(completions.count + 1), sessionID: UUID(), data: data,
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
    let access = ClipboardAccess(pasteboard: pasteboard) { _, _, completion in
      decisions.append(completion)
    }

    let allowed = Fixture()
    access.request(allowed.request(data: Data("allowed fixture".utf8)), from: nil)
    precondition(decisions.count == 1)
    decisions.removeFirst()(.allow)
    precondition(pasteboard.data(forType: .string) == Data("allowed fixture".utf8))
    precondition(allowed.completions == [true])

    let denied = Fixture()
    access.request(denied.request(data: Data("denied fixture".utf8)), from: nil)
    precondition(decisions.count == 1)
    decisions.removeFirst()(.deny)
    precondition(pasteboard.data(forType: .string) == Data("allowed fixture".utf8))
    precondition(denied.completions == [false])

    let stale = Fixture()
    let staleRequest = stale.request(data: Data("stale fixture".utf8))
    access.request(staleRequest, from: nil)
    stale.live = false
    precondition(decisions.count == 1)
    decisions.removeFirst()(.allow)
    precondition(pasteboard.data(forType: .string) == Data("allowed fixture".utf8))
    precondition(stale.completions == [false])

    let queued = (0..<ClipboardAccess.maximumPending + 1).map { _ in Fixture() }
    let queuedRequests = queued.map { $0.request() }
    for request in queuedRequests { access.request(request, from: nil) }
    precondition(decisions.count == 1, "only one prompt is visible")
    precondition(queued.last?.completions == [false], "overflow is denied without a prompt")
    access.cancel(sessionID: queuedRequests[0].sessionID)
    while !decisions.isEmpty { decisions.removeFirst()(.deny) }
    precondition(queued[0].completions == [false], "a cancelled active request cannot write")
    precondition(queued.dropLast().allSatisfy { $0.completions.count <= 1 })

    let root = CommandLine.arguments[1]
    func spec(_ script: String) -> LaunchSpec {
      LaunchSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], cwd: "/tmp",
        launcher: root + "/dist/Terminal.app/Contents/MacOS/TerminalLauncher")
    }
    let orderedPasteboard = NSPasteboard(
      name: NSPasteboard.Name("terminal-clipboard-pty-\(UUID().uuidString)"))
    let orderedAccess = ClipboardAccess(pasteboard: orderedPasteboard) { _, _, completion in completion(.allow) }
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
    }
    let closed = Session(launch: spec("printf '\\033]52;c;Y2xvc2VkIGZpeHR1cmU=\\007'; sleep 1"))
    closed.onClipboardWrite = { request in closedAccess.request(request, from: nil) }
    let closedDeadline = Date().addingTimeInterval(3)
    while closedDecision == nil && Date() < closedDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(closedDecision != nil)
    closed.close()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    closedDecision?(.allow)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(closedPasteboard.data(forType: .string) == closedOriginal)

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

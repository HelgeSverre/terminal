import AppKit

private final class RequestFixture {
  let sessionID = UUID()
  var live = true
  var resolutions: [Bool] = []

  func request(_ text: String) -> ClipboardWriteRequest {
    ClipboardWriteRequest(
      sessionID: sessionID, data: Data(text.utf8), live: { [weak self] in self?.live == true },
      completion: { [weak self] allowed, completed in
        DispatchQueue.main.async {
          self?.resolutions.append(allowed)
          completed(allowed)
        }
      })
  }
}

@main struct ClipboardAccessTests {
  @MainActor static func main() {
    func drain(until condition: @escaping () -> Bool) {
      let deadline = Date().addingTimeInterval(1)
      while !condition() && deadline.timeIntervalSinceNow > 0 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(condition())
    }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("terminal-swift-clipboard-\(UUID().uuidString)"))
    var decisions: [(ClipboardAccessDecision) -> Void] = []
    var now: TimeInterval = 0
    let access = ClipboardAccess(
      pasteboard: pasteboard,
      decide: { _, _, completion in decisions.append(completion); return nil },
      clock: { now })

    let allowed = RequestFixture()
    access.request(allowed.request("allowed"), from: nil)
    precondition(decisions.count == 1)
    decisions.removeFirst()(.allow)
    drain { allowed.resolutions == [true] }
    precondition(pasteboard.data(forType: .string) == Data("allowed".utf8))

    now += 2
    let denied = RequestFixture()
    access.request(denied.request("denied"), from: nil)
    precondition(decisions.count == 1)
    decisions.removeFirst()(.deny)
    access.request(denied.request("suppressed"), from: nil)
    drain { denied.resolutions == [false, false] }
    precondition(pasteboard.data(forType: .string) == Data("allowed".utf8))

    now += 2
    let cancelled = RequestFixture()
    access.request(cancelled.request("cancelled"), from: nil)
    precondition(decisions.count == 1)
    access.cancel(sessionID: cancelled.sessionID)
    decisions.removeFirst()(.allow)
    drain { cancelled.resolutions == [false] }
    precondition(pasteboard.data(forType: .string) == Data("allowed".utf8))
    print("PASS swift clipboard: allow, deny suppression, close cancellation and pasteboard ordering")
  }
}

#if os(iOS)
import Testing
import UIKit
import iOSCheck
import TerminalHost
import TerminalUI

@MainActor @Suite(.serialized) struct TextInputTests {
  private func wait(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
  }
  @Test func compositionCommitsOnceAndDoesNotEditTerminalOutput() async {
    let replay = Replay("shell output")
    let session = TerminalSession(transport: replay)
    defer { session.close() }
    let view = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), session: session, rendering: nil)
    view.layoutIfNeeded()
    view.setMarkedText("日本語", selectedRange: NSRange(location: 2, length: 1))
    #expect(view.markedTextRange != nil)
    #expect(view.text(in: view.markedTextRange!) == "日本語")
    #expect(replay.sent.isEmpty)
    view.unmarkText()
    view.unmarkText()
    #expect(view.markedTextRange == nil)
    let deadline = Date().addingTimeInterval(3)
    while replay.sent.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(replay.sent == "日本語")
    #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 0)
  }

  @Test func deletionUsesWholeComposedCharactersAndRangesStayBounded() {
    let session = TerminalSession(transport: Replay(""))
    defer { session.close() }
    let view = TerminalCanvasView(frame: .zero, session: session, rendering: nil)
    let text = "a👩‍💻e\u{301}"
    view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
    view.deleteBackward()
    #expect(view.text(in: view.markedTextRange!) == "a👩‍💻")
    view.deleteBackward()
    #expect(view.text(in: view.markedTextRange!) == "a")
    #expect(view.position(from: view.endOfDocument, offset: 1) == nil)
    view.setMarkedText(String(repeating: "界", count: 20_000), selectedRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 16_384)
    view.insertText("committed")
    #expect(view.markedTextRange == nil)
  }

  @Test func asynchronousOutputPreservesCompositionButDocumentResetCancelsIt() async throws {
    let transport = TextInputTransport()
    let session = TerminalSession(transport: transport, startsAtFirstGrid: true)
    defer { session.close() }
    let view = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), session: session, rendering: nil)
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: view.bounds)
    window.rootViewController = UIViewController()
    window.rootViewController!.view.addSubview(view)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.setNeedsLayout(); view.layoutIfNeeded()
    #expect(await wait { view.visibleText.contains("ready") })

    view.setMarkedText("日本語", selectedRange: NSRange(location: 1, length: 1))
    transport.receive("\r\nasynchronous shell output")
    #expect(await wait { view.visibleText.contains("asynchronous shell output") })
    let pending = try #require(view.markedTextRange)
    #expect(view.text(in: pending) == "日本語")
    let selected = try #require(view.selectedTextRange)
    #expect(view.offset(from: view.beginningOfDocument, to: selected.start) == 1)
    #expect(view.offset(from: selected.start, to: selected.end) == 1)
    #expect(transport.sent.isEmpty)

    // RIS replaces the document while keeping the same viewport geometry.
    transport.receive("\u{1b}creset complete")
    #expect(await wait { view.visibleText.contains("reset complete") })
    #expect(view.markedTextRange == nil)
    #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 0)
    #expect(transport.sent.isEmpty)
  }

  @Test func blankAndClearedTerminalRetainAnAccessibleInputControl() async throws {
    let transport = TextInputTransport(initialOutput: "")
    let session = TerminalSession(transport: transport, startsAtFirstGrid: true)
    defer { session.close() }
    let view = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), session: session, rendering: nil)
    let initial = try #require(view.accessibilityElements as? [UIAccessibilityElement])
    #expect(initial.contains { $0.accessibilityLabel == "Terminal" })

    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: view.bounds)
    window.rootViewController = UIViewController()
    window.rootViewController!.view.addSubview(view)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.setNeedsLayout(); view.layoutIfNeeded()
    #expect(await wait { transport.started })
    transport.receive("visible output")
    #expect(await wait { view.visibleText.contains("visible output") })
    transport.receive("\u{1b}[2J\u{1b}[H")
    #expect(await wait { view.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

    let cleared = try #require(view.accessibilityElements as? [UIAccessibilityElement])
    let terminal = try #require(cleared.first { $0.accessibilityLabel == "Terminal" })
    #expect(terminal.accessibilityTraits.contains(.button))
    #expect(terminal.accessibilityActivate())
    #expect(view.isFirstResponder)
    let actions = terminal.accessibilityCustomActions?.map(\.name) ?? []
    #expect(actions.contains("Find"))
    #expect(actions.contains("Older output"))
    #expect(actions.contains("Newer output"))
  }

  @Test func selectionSearchAndAccessibleLinksUsePresentedOutput() async throws {
    let session = TerminalSession(transport: Replay("needle\r\nhttps://example.com/\r\n"), startsAtFirstGrid: true)
    defer { session.close() }
    let view = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), session: session, rendering: nil)
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: view.bounds)
    window.rootViewController = UIViewController()
    window.rootViewController!.view.addSubview(view)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.setNeedsLayout(); view.layoutIfNeeded()
    #expect(await wait { view.visibleText.contains("needle") })
    view.selectAll(nil)
    #expect(await wait { view.hasSelection })
    let selected: String? = await withCheckedContinuation { continuation in
      view.selectedText { continuation.resume(returning: $0) }
    }
    #expect(selected?.contains("needle") == true)
    view.clearSelection()
    #expect(await wait { !view.hasSelection })
    let position: HistorySearchPosition? = await withCheckedContinuation { continuation in
      session.search("needle") { _, position in continuation.resume(returning: position) }
    }
    #expect(position?.total == 1)
    view.showFind()
    #expect(view.subviews.contains { $0 is UIStackView })
    view.hideFind()
    let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])
    #expect(elements.contains { $0.accessibilityLabel?.contains("needle") == true })
    let link = try #require(elements.first { $0.accessibilityTraits.contains(.link) })
    var opened: URL?
    view.onOpenLink = { opened = $0; return true }
    #expect(link.accessibilityActivate())
    #expect(await wait { opened?.absoluteString == "https://example.com/" })
  }
}

/// Test ingress and captured writes cross the transport queue and MainActor;
/// protect both with the same lock rather than exposing its connection state.
private final class TextInputTransport: TerminalTransport {
  private let lock = NSLock()
  private var connection: TerminalConnection?
  private var typed = Data()
  private let initialOutput: String
  init(initialOutput: String = "ready") { self.initialOutput = initialOutput }
  var started: Bool { lock.lock(); defer { lock.unlock() }; return connection != nil }
  var sent: Data { lock.lock(); defer { lock.unlock() }; return typed }
  func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
    lock.lock(); self.connection = connection; lock.unlock()
    connection.receive(Data(initialOutput.utf8))
  }
  func receive(_ text: String) {
    lock.lock(); let connection = connection; lock.unlock()
    connection?.receive(Data(text.utf8))
  }
  func send(_ bytes: Data) { lock.lock(); typed.append(bytes); lock.unlock() }
  func close() { lock.lock(); connection = nil; lock.unlock() }
}
#endif

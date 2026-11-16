import AppKit
import Testing
@testable import TerminalHost
@testable import TerminalUI

@Suite(.serialized) @MainActor enum LinkTargetPreviewTests {
  private final class Line: TerminalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedConnection: TerminalConnection?
    var connection: TerminalConnection? { lock.lock(); defer { lock.unlock() }; return storedConnection }
    func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
      lock.lock(); storedConnection = connection; lock.unlock()
    }
    func send(_ bytes: Data) {}
  }
  private final class HoverWindow: NSWindow {
    var pointer = NSPoint.zero
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
  }

  @Test static func cursorUpdatesDoNotDismissCommandHover() async throws {
    _ = NSApplication.shared
    let line = Line()
    let session = TerminalSession(transport: line)
    let view = TerminalCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 300),
      session: session, rendering: nil, clipboard: nil)
    let window = HoverWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { session.close(); window.contentView = nil; window.close() }
    try #require(await TestEnvironment.wait { line.connection != nil })
    line.connection?.receive(Data("\u{1b}]8;;https://example.org/sign-in\u{1b}\\example link\u{1b}]8;;\u{1b}\\".utf8))
    try #require(await TestEnvironment.wait { view.visibleText.contains("example link") })
    window.pointer = view.convert(NSPoint(x: 20, y: 16), to: nil)
    let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: window.pointer,
      modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 0, pressure: 0))
    view.mouseMoved(with: moved)
    let preview = try #require(view.subviews.compactMap { $0 as? LinkTargetPreview }.first)

    // Adding the destination view triggers cursor invalidation. The native
    // trace has the correct pointer location but no Command modifier.
    let cursor = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: window.pointer,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 2, trackingNumber: 0, userData: nil))
    for _ in 0..<3 {
      view.cursorUpdate(with: cursor)
      #expect(preview.superview === view, "cursor refresh must preserve the visible destination while Cmd is held")
    }

    let offLink = try #require(NSEvent.mouseEvent(with: .mouseMoved,
      location: view.convert(NSPoint(x: 400, y: 100), to: nil), modifierFlags: .command,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 0, pressure: 0))
    view.mouseMoved(with: offLink)
    #expect(!view.subviews.contains { $0 is LinkTargetPreview }, "moving off the link must dismiss its destination")
    view.mouseMoved(with: moved)
    #expect(view.subviews.contains { $0 is LinkTargetPreview }, "moving back onto the link must restore its destination")

    let released = try #require(NSEvent.keyEvent(with: .flagsChanged, location: window.pointer,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    view.flagsChanged(with: released)
    #expect(!view.subviews.contains { $0 is LinkTargetPreview }, "releasing Cmd must still dismiss the destination")
  }

  @Test static func showsDestinationWithoutMisleadingUserInfo() throws {
    let preview = LinkTargetPreview(frame: .zero)
    let target = try #require(URL(string: "https://github.com@actual.example/login?q=test"))
    preview.show(target, colors: .standard)
    let label = try #require(preview.subviews.first as? NSTextField)
    #expect(label.stringValue == "https://actual.example/login?q=test")
    #expect(preview.accessibilityValue() as? String == target.absoluteString)
    #expect(preview.hitTest(.zero) == nil)
  }

  @Test static func staysInsideNarrowPanesAndMovesAwayFromThePointer() throws {
    let preview = LinkTargetPreview(frame: .zero)
    preview.show(try #require(URL(string: "https://example.com/" + String(repeating: "long-path/", count: 30))),
      colors: .standard)
    let bounds = NSRect(x: 0, y: 0, width: 180, height: 120)
    preview.position(in: bounds, pointer: .zero)
    #expect(bounds.contains(preview.frame))
    #expect(preview.frame.maxY == bounds.maxY - 8)
    let pointer = NSPoint(x: preview.frame.midX, y: preview.frame.midY)
    preview.position(in: bounds, pointer: pointer)
    #expect(preview.frame.minY == 8)
    #expect(!preview.frame.contains(pointer))
  }
}

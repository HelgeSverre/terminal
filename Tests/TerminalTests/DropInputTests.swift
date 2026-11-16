import AppKit
import Foundation
import Testing
@testable import TerminalHost
@testable import TerminalUI

/// Records the bytes leaving the real view/session/encoder path.
private final class DropTransport: TerminalTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var storedConnection: TerminalConnection?
  private var storedBytes = Data()
  var connection: TerminalConnection? { lock.lock(); defer { lock.unlock() }; return storedConnection }
  var bytes: Data { lock.lock(); defer { lock.unlock() }; return storedBytes }
  func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
    lock.lock(); storedConnection = connection; lock.unlock()
  }
  func send(_ bytes: Data) { lock.lock(); storedBytes.append(bytes); lock.unlock() }
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {}
  func close() { lock.lock(); storedConnection = nil; lock.unlock() }
}

@MainActor private final class FileDrop: NSObject, NSDraggingInfo {
  let draggingPasteboard = NSPasteboard(name: .init("terminal-drop-test-\(UUID().uuidString)"))
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggingLocation: NSPoint { .zero }
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Suite(.serialized) @MainActor struct DropInputTests {
  @Test func fileDropIsBracketedAndTheFollowingMouseReportIsOutsideThePaste() async throws {
    _ = NSApplication.shared
    let transport = DropTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    let view = TerminalCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000), session: session,
      rendering: nil, clipboard: nil)
    session.resize(cols: 114, rows: 47, cellWidth: 9, cellHeight: 19)
    var ready = false
    view.onObservedSnapshot = {
      ready = $0.modes.bracketed_paste && $0.modes.mouse == 1003 && $0.modes.sgr_mouse
        && $0.cols == 114 && $0.rows.count == 47
    }
    try #require(await TestEnvironment.wait { transport.connection != nil })
    transport.connection?.receive(Data("\u{1b}[?2004h\u{1b}[?1003h\u{1b}[?1006h".utf8))
    try #require(await TestEnvironment.wait { ready })
    let drop = FileDrop()
    defer { drop.draggingPasteboard.releaseGlobally() }
    let path = "/Users/example/Library/Application Support/CleanShot/it's an image.png"
    drop.draggingPasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
    #expect(view.performDragOperation(drop))
    let move = try #require(NSEvent.mouseEvent(with: .mouseMoved,
      location: view.convert(NSPoint(x: 100_000, y: 100_000), to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    view.mouseMoved(with: move)
    let expected = Data(("\u{1b}[200~'" + path.replacingOccurrences(of: "'", with: "'\\''")
      + "'\u{1b}[201~\u{1b}[<35;114;47M").utf8)
    #expect(await TestEnvironment.wait { transport.bytes == expected },
      "actual wire bytes: \(String(decoding: transport.bytes, as: UTF8.self).debugDescription)")
  }
}

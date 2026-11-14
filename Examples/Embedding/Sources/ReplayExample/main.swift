import AppKit
import TerminalHost
import TerminalUI

/// Plays a file of terminal output into a session, as an SSH channel or a
/// serial line would deliver it. The session calls these methods on one
/// private queue; `receive` and `end` may be called from any thread.
final class Replay: TerminalTransport, @unchecked Sendable {
  private let recording: Data
  private let reader = DispatchQueue(label: "replay")
  private var stopped = false   // read and written on `reader`

  init(recording: Data) { self.recording = recording }

  func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
    reader.async { [self] in
      var offset = 0
      while offset < recording.count, !stopped {
        // A file can outrun the terminal; wait while it is behind.
        if connection.bufferedByteCount > 1 << 20 { usleep(2_000); continue }
        let end = min(recording.count, offset + 4096)
        connection.receive(recording.subdata(in: offset..<end))
        offset = end
        usleep(4_000)
      }
      connection.receive(Data("\r\n[end of recording]\r\n".utf8))
      connection.end()
    }
  }
  /// What the user types and the terminal answers. A recording has no use
  /// for it; an SSH channel would write it to the remote side.
  func send(_ bytes: Data) {}
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {}
  func close() { reader.async { self.stopped = true } }
}

@MainActor final class Host: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private var session: TerminalSession?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = CommandLine.arguments
    let recording = arguments.count > 1
      ? (FileManager.default.contents(atPath: arguments[1]) ?? Data())
      : Data("\u{1b}[1mReplayExample\u{1b}[0m plays a file of terminal output:\r\n\r\n  script -q demo.typescript ls -la\r\n  swift run ReplayExample demo.typescript\r\n".utf8)

    let session = TerminalSession(transport: Replay(recording: recording), startsAtFirstGrid: true)
    let view = TerminalCanvasView(
      frame: .zero, session: session, rendering: try? TerminalRendering(),
      clipboard: ClipboardAccess(writingTo: .general))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: view.contentSize(columns: 100, rows: 30)),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.contentView = view
    window.title = "Replay"
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    self.window = window
    self.session = session

    // A transport's end is the session's end; the screen stays to be read.
    session.onEnd = { end in
      window.title = end.transportError == nil ? "Replay (finished)" : "Replay (failed)"
    }
    session.onBell = { NSSound.beep() }
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let host = Host()
app.delegate = host
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem()
editItem.submenu = TerminalEditMenu.make()
menu.addItem(appItem)
menu.addItem(editItem)
app.mainMenu = menu
app.run()

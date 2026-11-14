import AppKit
import TerminalSession
import TerminalView

/// One window holding one terminal that runs the login shell.
final class Host: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private var rendering: TerminalRendering?
  private let clipboard = ClipboardAccess(writingTo: .general)

  func applicationDidFinishLaunching(_ notification: Notification) {
    // One renderer serves every terminal view of the app.
    do { rendering = try TerminalRendering() } catch { NSLog("No renderer: \(error)") }

    // The child is started through the launcher, which this example expects
    // beside its own executable: `swift build --product TerminalLauncher`.
    let launcher = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("TerminalLauncher").path
    let session = Session(
      launch: .loginShell(cwd: NSHomeDirectory(), launcher: launcher), startsAtFirstGrid: true)
    let view = TerminalCanvasView(
      frame: .zero, session: session, rendering: rendering, clipboard: clipboard,
      configuration: TerminalViewConfiguration(fontSize: 13))

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: view.contentSize(columns: 100, rows: 30)),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.contentView = view
    window.title = "Embedded terminal"
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    self.window = window

    view.onTitle = { [weak window] title in window?.title = title }
    session.onStatus = { status in NSLog("Session: \(status)") }
    // The shell has exited and its last output is on screen.
    session.onEnd = { _ in NSApp.terminate(nil) }
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let host = Host()
app.delegate = host
app.setActivationPolicy(.regular)

// Copy, Paste, Select All and Find reach the focused terminal through the menu.
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

import AppKit
import TerminalSession
import TerminalView

// Usage: OursHost COMMAND [ARGUMENT...]
// Runs the command in one 100 × 30 terminal and exits when it ends.
let command = Array(CommandLine.arguments.dropFirst())
guard !command.isEmpty else {
  FileHandle.standardError.write(Data("Usage: OursHost COMMAND [ARGUMENT...]\n".utf8))
  exit(2)
}

final class Host: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private var rendering: TerminalRendering?

  func applicationDidFinishLaunching(_ notification: Notification) {
    do { rendering = try TerminalRendering() } catch { NSLog("No renderer: \(error)"); exit(3) }
    let launcher = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("TerminalLauncher").path
    let session = Session(
      launch: LaunchSpec(
        executable: command[0], arguments: command, cwd: FileManager.default.currentDirectoryPath, launcher: launcher),
      startsAtFirstGrid: true)
    let view = TerminalCanvasView(
      frame: .zero, session: session, rendering: rendering, clipboard: nil,
      configuration: TerminalViewConfiguration(fontSize: 14))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: view.contentSize(columns: 100, rows: 30)),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = view
    window.title = "OursHost"
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    self.window = window
    session.onStatus = { status in
      if status.hasPrefix("Launch") { NSLog("Session: \(status)"); exit(4) }
    }
    session.onEnd = { end in exit(end.exitedCleanly ? 0 : 1) }
    NSApp.activate(ignoringOtherApps: true)
  }
}

let app = NSApplication.shared
let host = Host()
app.delegate = host
app.setActivationPolicy(.regular)
app.run()

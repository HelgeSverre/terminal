import AppKit
import SwiftTerm

// Usage: SwiftTermHost [--metal] COMMAND [ARGUMENT...]
// Runs the command in one 100 × 30 SwiftTerm view and exits when it ends.
// SwiftTerm draws with Core Graphics unless --metal is given.
var arguments = Array(CommandLine.arguments.dropFirst())
let metal = arguments.first == "--metal"
if metal { arguments.removeFirst() }
guard !arguments.isEmpty else {
  FileHandle.standardError.write(Data("Usage: SwiftTermHost [--metal] COMMAND [ARGUMENT...]\n".utf8))
  exit(2)
}

final class Host: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let font = NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let cell = ("W" as NSString).size(withAttributes: [.font: font])
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    // The view reserves room for its scroller beside the text; this width
    // gives it exactly 100 columns at this font.
    let style = NSScroller.preferredScrollerStyle
    let scroller = NSScroller.scrollerWidth(for: style == .overlay ? .small : .regular, scrollerStyle: style)
    let size = NSSize(width: ceil(cell.width * 100 + scroller), height: ceil(lineHeight * 30.5))
    let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: size))
    view.font = font
    view.processDelegate = self
    if metal {
      do { try view.setUseMetal(true) } catch { NSLog("No Metal renderer: \(error)"); exit(3) }
    }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = view
    window.title = metal ? "SwiftTermHost (Metal)" : "SwiftTermHost (Core Graphics)"
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    self.window = window
    view.startProcess(
      executable: arguments[0], args: Array(arguments.dropFirst()),
      currentDirectory: FileManager.default.currentDirectoryPath)
    NSApp.activate(ignoringOtherApps: true)
  }

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func processTerminated(source: TerminalView, exitCode: Int32?) { exit(exitCode == 0 ? 0 : 1) }
}

let app = NSApplication.shared
let host = MainActor.assumeIsolated { Host() }
app.delegate = host
app.setActivationPolicy(.regular)
app.run()

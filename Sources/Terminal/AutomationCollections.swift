import AppKit
import TerminalUI

/// Read-only, freshly resolved wrappers keep Cocoa scripting collections from
/// retaining closed panes and expose the same identifiers as command targeting.
@objc(TerminalScriptWindow) final class TerminalScriptWindow: NSObject {
  let controller: TerminalWindow
  init(_ controller: TerminalWindow) { self.controller = controller }
  @objc var identifier: String { controller.automationID }
  @objc var name: String { controller.window?.title ?? "Terminal" }
  @objc var terminalTabs: [TerminalScriptTab] {
    let windows = controller.window?.tabbedWindows ?? controller.window.map { [$0] } ?? []
    return windows.compactMap { ($0.windowController as? TerminalWindow).map { TerminalScriptTab($0, parent: self) } }
  }
  override var objectSpecifier: NSScriptObjectSpecifier? {
    NSUniqueIDSpecifier(containerClassDescription: NSApp.classDescription as? NSScriptClassDescription,
      containerSpecifier: nil, key: "terminalWindows", uniqueID: identifier)
  }
}

@objc(TerminalScriptTab) final class TerminalScriptTab: NSObject {
  let controller: TerminalWindow
  let parent: TerminalScriptWindow
  init(_ controller: TerminalWindow, parent: TerminalScriptWindow) { self.controller = controller; self.parent = parent }
  @objc var identifier: String { controller.automationID }
  @objc var name: String { controller.window?.title ?? "Terminal" }
  @objc var terminalPanes: [TerminalScriptPane] { controller.panes.map { TerminalScriptPane($0, parent: self) } }
  override var objectSpecifier: NSScriptObjectSpecifier? {
    NSUniqueIDSpecifier(containerClassDescription: parent.classDescription as? NSScriptClassDescription,
      containerSpecifier: parent.objectSpecifier, key: "terminalTabs", uniqueID: identifier)
  }
}

@objc(TerminalScriptPane) final class TerminalScriptPane: NSObject {
  weak var pane: TerminalCanvasView?
  let parent: TerminalScriptTab
  init(_ pane: TerminalCanvasView, parent: TerminalScriptTab) { self.pane = pane; self.parent = parent }
  @objc var identifier: String { pane.map { "no.helgesverre.terminal.pane." + $0.automationID } ?? "" }
  @objc var workingDirectory: String { pane?.session.deliveredDirectory ?? "" }
  @objc var selectedText: String { pane?.accessibilitySelectedText() ?? "" }
  override var objectSpecifier: NSScriptObjectSpecifier? {
    NSUniqueIDSpecifier(containerClassDescription: parent.classDescription as? NSScriptClassDescription,
      containerSpecifier: parent.objectSpecifier, key: "terminalPanes", uniqueID: identifier)
  }
}

extension NSApplication {
  @objc var terminalWindows: [TerminalScriptWindow] {
    guard let delegate = delegate as? AppDelegate, delegate.acceptsAutomation else { return [] }
    var seen = Set<ObjectIdentifier>()
    return delegate.windows.compactMap { controller in
      guard let window = controller.window else { return nil }
      let representative = window.tabbedWindows?.first ?? window
      guard seen.insert(ObjectIdentifier(representative)).inserted,
        let first = representative.windowController as? TerminalWindow else { return nil }
      return TerminalScriptWindow(first)
    }
  }
}

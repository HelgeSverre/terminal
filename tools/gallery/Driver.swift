import AppKit
import ApplicationServices

enum GalleryFailure: Error { case invalid(String) }

private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func frame(_ element: AXUIElement) throws -> CGRect {
  guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else {
    throw GalleryFailure.invalid("missing AX frame")
  }
  var point = CGPoint.zero, extent = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
    throw GalleryFailure.invalid("invalid AX frame")
  }
  return CGRect(origin: point, size: extent)
}

private func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
  guard depth < 10 else { return [] }
  return [element] + ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap { descendants($0, depth: depth + 1) }
}

@main enum Main {
  @MainActor static func main() throws {
    guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[2]) else {
      throw GalleryFailure.invalid("Usage: Driver overview|panes ownedPID output")
    }
    guard AXIsProcessTrusted(), let running = NSRunningApplication(processIdentifier: pid),
      running.executableURL?.path == ProcessInfo.processInfo.environment["TERMINAL_GALLERY_EXECUTABLE"] else {
      throw GalleryFailure.invalid("owned app or Accessibility unavailable")
    }
    let app = AXUIElementCreateApplication(pid)
    func window() throws -> AXUIElement {
      guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1 else {
        throw GalleryFailure.invalid("expected one owned window")
      }
      return windows[0]
    }
    func panes() throws -> [AXUIElement] {
      try descendants(window()).filter {
        (attribute($0, kAXRoleAttribute) as? String) == kAXTextAreaRole
          && (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix("no.helgesverre.terminal.pane.") == true
      }
    }
    func waitForPanes(_ count: Int) throws -> [AXUIElement] {
      let deadline = ProcessInfo.processInfo.systemUptime + 6
      repeat {
        if let value = try? panes(), value.count == count { return value }
        Thread.sleep(forTimeInterval: 0.03)
      } while ProcessInfo.processInfo.systemUptime < deadline
      throw GalleryFailure.invalid("pane creation timed out")
    }
    func foreground() throws {
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw GalleryFailure.invalid("owned app lost foreground") }
    }
    func key(_ flags: CGEventFlags) throws {
      try foreground()
      for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: down)!
        event.flags = flags; event.postToPid(pid)
      }
    }
    func click(_ point: CGPoint) throws {
      try foreground()
      for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
      }
    }
    func focus(_ pane: AXUIElement) throws {
      let identifier = attribute(pane, kAXIdentifierAttribute) as? String
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      repeat {
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, attribute(focused as! AXUIElement, kAXIdentifierAttribute) as? String == identifier { return }
        Thread.sleep(forTimeInterval: 0.02)
      } while ProcessInfo.processInfo.systemUptime < deadline
      throw GalleryFailure.invalid("pane did not receive focus")
    }
    running.activate(options: [])
    let activationDeadline = ProcessInfo.processInfo.systemUptime + 3
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && ProcessInfo.processInfo.systemUptime < activationDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    try foreground()
    _ = try waitForPanes(1)
    let owned = try window()
    var position = CGPoint(x: 260, y: 140), size = CGSize(width: 1400, height: 850)
    guard AXUIElementSetAttributeValue(owned, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &position)!) == .success,
      AXUIElementSetAttributeValue(owned, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!) == .success else {
      throw GalleryFailure.invalid("window geometry rejected")
    }
    if CommandLine.arguments[1] == "panes" {
      try key(.maskCommand); _ = try waitForPanes(2)
      let first = try panes().min { try frame($0).minX < frame($1).minX }!
      let firstFrame = try frame(first)
      try click(CGPoint(x: firstFrame.midX, y: firstFrame.midY)); try focus(first)
      try key([.maskCommand, .maskShift]); _ = try waitForPanes(3)
    } else if CommandLine.arguments[1] != "overview" { throw GalleryFailure.invalid("unknown gallery scenario") }
    _ = try window()
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = infos.filter {
      guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return false }
      return true
    }
    guard matches.count == 1, let windowID = matches[0][kCGWindowNumber as String] as? NSNumber else { throw GalleryFailure.invalid("owned CG window correlation failed") }
    let data: [String: Any] = ["pid": pid, "window": windowID.intValue, "scenario": CommandLine.arguments[1], "executable": running.executableURL!.path]
    try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("identity.json"))
  }
}

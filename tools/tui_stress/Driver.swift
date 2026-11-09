import AppKit
import ApplicationServices

enum TUIStressFailure: Error { case invalid(String) }

private func ax(_ element: AXUIElement, _ attribute: String) -> Any? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

private func frame(_ element: AXUIElement) throws -> CGRect {
  guard let position = ax(element, kAXPositionAttribute), let size = ax(element, kAXSizeAttribute),
    CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID()
  else { throw TUIStressFailure.invalid("missing AX frame") }
  var point = CGPoint.zero, extent = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
    extent.width > 0, extent.height > 0
  else { throw TUIStressFailure.invalid("invalid AX frame") }
  return CGRect(origin: point, size: extent)
}

private func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
  guard depth < 10 else { return [] }
  return [element] + ((ax(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap { descendants($0, depth: depth + 1) }
}

private func rectJSON(_ rect: CGRect) -> [Double] {
  [rect.minX, rect.minY, rect.width, rect.height]
}

private func writeJSON(_ value: [String: Any], to path: URL) throws {
  try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
}

private func nestedDividers(_ frames: [CGRect]) throws -> (outer: CGPoint, inner: CGPoint) {
  guard frames.count == 3 else { throw TUIStressFailure.invalid("nested layout needs exactly three panes") }
  let leftX = frames.map(\.minX).min()!
  let left = frames.filter { abs($0.minX - leftX) <= 1 }.sorted { $0.minY < $1.minY }
  let right = frames.filter { abs($0.minX - leftX) > 1 }
  guard left.count == 2, right.count == 1 else { throw TUIStressFailure.invalid("expected two left panes and one right pane") }
  let top = left[0], bottom = left[1], spanning = right[0]
  func near(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) <= 1 }
  func dividerGap(_ start: CGFloat, _ end: CGFloat) -> Bool { (0...2).contains(end - start) }
  guard near(top.maxX, bottom.maxX), near(top.minY, spanning.minY), near(bottom.maxY, spanning.maxY),
    dividerGap(top.maxX, spanning.minX), dividerGap(bottom.maxX, spanning.minX), dividerGap(top.maxY, bottom.minY) else {
    throw TUIStressFailure.invalid("expected nested left layout adjacency")
  }
  return (CGPoint(x: (top.maxX + spanning.minX) / 2, y: spanning.midY),
    CGPoint(x: top.midX, y: (top.maxY + bottom.minY) / 2))
}

private struct VerticalStackLayout {
  let leaves: [CGRect]
  let dividerPoints: [CGPoint]
  let targetDividerY: [CGFloat]
}

private func verticalStackLayout(_ frames: [CGRect]) throws -> VerticalStackLayout {
  guard frames.count == 3 else { throw TUIStressFailure.invalid("final stack needs exactly three panes") }
  let ordered = frames.sorted { $0.minY < $1.minY }
  let first = ordered[0]
  guard ordered.allSatisfy({ $0.width > 40 && $0.height > 40 && abs($0.minX - first.minX) <= 1 && abs($0.maxX - first.maxX) <= 1 }) else {
    throw TUIStressFailure.invalid("final panes are not positive full-width leaves")
  }
  guard (0..<2).allSatisfy({ index in
    let gap = ordered[index + 1].minY - ordered[index].maxY
    return (0...2).contains(gap)
  }) else { throw TUIStressFailure.invalid("final stack is overlapping or has a missing divider adjacency") }
  guard Set(ordered.map { "\($0.minX.rounded())/\($0.minY.rounded())/\($0.width.rounded())/\($0.height.rounded())" }).count == 3 else {
    throw TUIStressFailure.invalid("final stack has duplicate pane geometry")
  }
  let top = ordered[0].minY, bottom = ordered[2].maxY
  let target = [top + (bottom - top) / 3, top + 2 * (bottom - top) / 3]
  return VerticalStackLayout(leaves: ordered,
    dividerPoints: [CGPoint(x: first.midX, y: (ordered[0].maxY + ordered[1].minY) / 2),
      CGPoint(x: first.midX, y: (ordered[1].maxY + ordered[2].minY) / 2)], targetDividerY: target)
}

private func verticalStack(_ frames: [CGRect]) throws {
  _ = try verticalStackLayout(frames)
}

private func balancedInspectionStack(_ frames: [CGRect]) throws -> VerticalStackLayout {
  let layout = try verticalStackLayout(frames)
  let heights = layout.leaves.map(\.height)
  guard heights.allSatisfy({ $0 >= 280 }), (heights.max()! - heights.min()!) <= 12 else {
    throw TUIStressFailure.invalid("final inspection panes did not balance near one-third height")
  }
  return layout
}

@MainActor private final class Driver {
  private let pid: pid_t
  private let directory: URL
  private let app: AXUIElement
  private let running: NSRunningApplication
  private var preparedWindow: Int?
  private var events: [[String: Any]] = []

  init(pid: pid_t, directory: URL) throws {
    guard AXIsProcessTrusted(), let running = NSRunningApplication(processIdentifier: pid),
      running.executableURL?.path == ProcessInfo.processInfo.environment["TERMINAL_TUI_STRESS_EXECUTABLE"]
    else { throw TUIStressFailure.invalid("owned process or Accessibility precondition unavailable") }
    self.pid = pid; self.directory = directory; self.running = running; app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
  }

  private func note(_ phase: String, _ values: [String: Any] = [:]) {
    var event = values; event["phase"] = phase; event["uptime"] = ProcessInfo.processInfo.systemUptime
    events.append(event)
  }

  private func window() throws -> AXUIElement {
    guard let windows = ax(app, kAXWindowsAttribute) as? [AXUIElement] else { throw TUIStressFailure.invalid("AX windows unavailable") }
    if let preparedWindow {
      let matching = windows.filter { (try? cgWindowID($0)) == preparedWindow }
      guard matching.count == 1 else { throw TUIStressFailure.invalid("prepared owned window is missing or ambiguous") }
      return matching[0]
    }
    guard windows.count == 1 else { throw TUIStressFailure.invalid("expected one owned window, found \(windows.count)") }
    return windows[0]
  }

  private func cgWindowID(_ window: AXUIElement) throws -> Int {
    let wanted = try frame(window)
    let matches = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter { info in
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let bounds = info[kCGWindowBounds as String] as? [String: Any], let actual = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return false }
      return abs(actual.minX - wanted.minX) <= 1 && abs(actual.minY - wanted.minY) <= 1 &&
        abs(actual.width - wanted.width) <= 1 && abs(actual.height - wanted.height) <= 1
    }
    guard matches.count == 1, let id = matches[0][kCGWindowNumber as String] as? NSNumber else {
      throw TUIStressFailure.invalid("cannot correlate owned AX and CG window")
    }
    return id.intValue
  }

  private func panes() throws -> [AXUIElement] {
    let panes = descendants(try window()).filter {
      guard let identifier = ax($0, kAXIdentifierAttribute) as? String else { return false }
      return identifier.hasPrefix("no.helgesverre.terminal.pane.")
    }
    return try panes.sorted {
      let lhs = try frame($0), rhs = try frame($1)
      return lhs.minY == rhs.minY ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
    }
  }

  private func waitForPanes(_ count: Int, timeout: TimeInterval = 6) throws -> [AXUIElement] {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var lastCount: Int?
    repeat {
      if let value = try? panes() {
        lastCount = value.count
        if value.count == count { return value }
      }
      Thread.sleep(forTimeInterval: 0.03)
    } while ProcessInfo.processInfo.systemUptime < deadline
    note("pane_wait_timeout", ["expected_count": count, "last_count": lastCount as Any? ?? NSNull(), "state": diagnosticState()])
    throw TUIStressFailure.invalid("timed out waiting for \(count) panes")
  }

  private func diagnosticState() -> [String: Any] {
    var snapshot: [String: Any] = ["frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier as Any? ?? NSNull(),
      "running_terminated": running.isTerminated]
    var focused: CFTypeRef?
    let focusStatus = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
    snapshot["app_focused_ax_error"] = focusStatus.rawValue
    if focusStatus == .success, let focused {
      snapshot["app_focused_identifier"] = ax(focused as! AXUIElement, kAXIdentifierAttribute) as? String ?? "unavailable"
    }
    if let current = try? panes() {
      snapshot["panes"] = current.map { pane in
        ["identifier": ax(pane, kAXIdentifierAttribute) as? String ?? "unavailable",
          "frame": (try? rectJSON(frame(pane))) as Any? ?? NSNull()]
      }
    }
    if let window = try? window() {
      snapshot["window_frame"] = (try? rectJSON(frame(window))) as Any? ?? NSNull()
      snapshot["window_cg_id"] = (try? cgWindowID(window)) as Any? ?? NSNull()
    }
    return snapshot
  }

  private func recordPaneGeometry(_ phase: String) {
    guard let current = try? panes() else {
      note(phase, ["panes_unavailable": true])
      return
    }
    let geometry: [[String: Any]] = current.map { pane in
      ["identifier": ax(pane, kAXIdentifierAttribute) as? String ?? "unavailable",
        "frame": (try? rectJSON(frame(pane))) as Any? ?? NSNull()]
    }
    note(phase, ["panes": geometry])
  }

  private func foreground() throws {
    guard !running.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      throw TUIStressFailure.invalid("owned app lost foreground; input stopped")
    }
  }

  private func key(_ flags: CGEventFlags, keyCode: CGKeyCode) throws {
    try foreground()
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
      event.flags = flags; event.postToPid(pid)
    }
    note("key_posted", ["target_pid": pid, "key_code": keyCode, "flags": flags.rawValue, "events": 2])
  }

  private func click(_ point: CGPoint) throws {
    try mouse(.leftMouseDown, point, phase: "click")
    try mouse(.leftMouseUp, point, phase: "click")
    note("click_posted", ["target_pid": pid, "point": [point.x, point.y], "events": 2])
  }

  private func mouse(_ type: CGEventType, _ point: CGPoint, phase: String) throws {
    try foreground()
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
      throw TUIStressFailure.invalid("cannot create mouse event")
    }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
    note("mouse_posted", ["phase_name": phase, "type": type.rawValue, "point": [point.x, point.y], "route": "hid"])
  }

  private func leftButtonPressed() -> Bool {
    CGEventSource.buttonState(.combinedSessionState, button: .left)
  }

  private func postMouseUp(_ point: CGPoint, phase: String) {
    let foregroundOwned = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let pressedBefore = leftButtonPressed()
    guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
      note("mouse_up_unavailable", ["phase_name": phase])
      return
    }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    if foregroundOwned { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
    note("mouse_up_posted", ["phase_name": phase, "point": [point.x, point.y],
      "route": foregroundOwned ? "hid" : "pid_cancel", "left_pressed_before": pressedBefore,
      "left_pressed_immediately_after": leftButtonPressed()])
    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    while leftButtonPressed() && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    note("mouse_up_ack", ["phase_name": phase, "left_pressed_after": leftButtonPressed(),
      "acknowledged": !leftButtonPressed()])
  }

  private func awaitFocus(_ pane: AXUIElement) throws {
    guard let expected = ax(pane, kAXIdentifierAttribute) as? String else {
      throw TUIStressFailure.invalid("pane has no AX identifier")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    repeat {
      var focused: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
      let identifier = status == .success ? focused.flatMap { ax($0 as! AXUIElement, kAXIdentifierAttribute) as? String } : nil
      if identifier == expected { return }
      Thread.sleep(forTimeInterval: 0.02)
    } while ProcessInfo.processInfo.systemUptime < deadline
    note("focus_wait_timeout", ["expected_identifier": expected, "state": diagnosticState()])
    throw TUIStressFailure.invalid("clicked pane did not become AX focused before shortcut")
  }

  private func drag(_ start: CGPoint, delta: CGPoint, phase: String) throws {
    recordPaneGeometry("\(phase)_pre_geometry")
    try mouse(.mouseMoved, start, phase: phase)
    try mouse(.leftMouseDown, start, phase: phase)
    note("mouse_down_state", ["phase_name": phase, "left_pressed_after": leftButtonPressed()])
    var last = start
    do {
      for step in 1...30 {
        try foreground()
        let fraction = Double(step) / 30
        last = CGPoint(x: start.x + delta.x * fraction, y: start.y + delta.y * fraction)
        try mouse(.leftMouseDragged, last, phase: phase)
        Thread.sleep(forTimeInterval: 1.0 / 60)
      }
    } catch {
      postMouseUp(last, phase: phase)
      recordPaneGeometry("\(phase)_post_geometry")
      throw error
    }
    postMouseUp(last, phase: phase)
    recordPaneGeometry("\(phase)_post_geometry")
    note(phase, ["gesture_complete": true, "start": [start.x, start.y], "delta": [delta.x, delta.y]])
  }

  private func resize(_ size: CGSize, phase: String) throws {
    var value = size
    guard AXUIElementSetAttributeValue(try window(), kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &value)!) == .success else {
      throw TUIStressFailure.invalid("window resize rejected")
    }
    note(phase, ["width": size.width, "height": size.height])
  }

  private func finalStackLayout(timeout: TimeInterval = 3) throws -> VerticalStackLayout {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
      if let frames = try? panes().map(frame), let layout = try? verticalStackLayout(frames) { return layout }
      Thread.sleep(forTimeInterval: 0.03)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw TUIStressFailure.invalid("final vertical stack did not settle")
  }

  private func balanceFinalStack() throws -> [CGRect] {
    var layout = try finalStackLayout()
    // The lower divider belongs to the outer split that allocates the nested
    // top subtree. Move that parent boundary first; moving it after the inner
    // divider would resize the child allocation and undo its balance.
    for index in [1, 0] {
      layout = try finalStackLayout()
      let start = layout.dividerPoints[index]
      try drag(start, delta: CGPoint(x: 0, y: layout.targetDividerY[index] - start.y), phase: "final_stack_balance_\(index)")
    }
    layout = try finalStackLayout()
    layout = try balancedInspectionStack(layout.leaves)
    note("final_stack_balanced", ["panes": layout.leaves.map(rectJSON), "target_divider_y": layout.targetDividerY])
    return layout.leaves
  }

  private func cellPixelMetrics(_ pane: AXUIElement, in window: AXUIElement) throws -> [String: Any] {
    var range = CFRange(location: 0, length: 1), result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(pane, kAXBoundsForRangeParameterizedAttribute as CFString,
      AXValueCreate(.cfRange, &range)!, &result) == .success, let result else {
      throw TUIStressFailure.invalid("cannot measure native cell bounds")
    }
    var cell = CGRect.zero
    guard AXValueGetValue(result as! AXValue, .cgRect, &cell), cell.width > 0, cell.height > 0 else {
      throw TUIStressFailure.invalid("invalid native cell bounds")
    }
    let windowFrame = try frame(window)
    let mainTop = NSScreen.screens[0].frame.maxY
    let appKitCenter = CGPoint(x: windowFrame.midX, y: mainTop - windowFrame.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitCenter) }) else {
      throw TUIStressFailure.invalid("window screen unavailable")
    }
    let scale = screen.backingScaleFactor
    return ["cell_width_pixels": Int((cell.width * scale).rounded()),
      "cell_height_pixels": Int((cell.height * scale).rounded()), "backing_scale": scale]
  }

  func prepare() throws {
    running.activate(options: [])
    _ = try waitForPanes(1)
    let visible = NSScreen.screens[0].visibleFrame
    guard visible.width >= 1080, visible.height >= 760 else { throw TUIStressFailure.invalid("requires a 1080×760-point visible screen") }
    var origin = CGPoint(x: visible.minX + 28, y: NSScreen.screens[0].frame.maxY - visible.maxY + 28)
    let owned = try window()
    guard AXUIElementSetAttributeValue(owned, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!) == .success else { throw TUIStressFailure.invalid("window position rejected") }
    try resize(CGSize(width: 1040, height: 720), phase: "prepare_size")
    Thread.sleep(forTimeInterval: 0.2)
    preparedWindow = try cgWindowID(owned)
    let current = try frame(owned)
    var identity: [String: Any] = ["pid": pid, "window": preparedWindow!, "executable": running.executableURL!.path,
      "frame": rectJSON(current), "capture_scope": "Window-only video. Marker analysis is intentionally inconclusive for real workloads."]
    identity.merge(try cellPixelMetrics(try panes()[0], in: owned)) { _, new in new }
    try writeJSON(identity, to: directory.appendingPathComponent("identity.json"))
  }

  func exercise() throws {
    defer { try? writeJSON(["pid": pid, "events": events], to: directory.appendingPathComponent("input-events.json")) }
    let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("identity.json"))) as! [String: Any]
    guard identity["pid"] as? Int32 == pid, let savedWindow = identity["window"] as? Int,
      identity["executable"] as? String == running.executableURL?.path else { throw TUIStressFailure.invalid("prepared identity mismatch") }
    preparedWindow = savedWindow
    try foreground()
    try key(.maskCommand, keyCode: 2) // Cmd-D: split right
    _ = try waitForPanes(2); note("split_right")
    let initial = try panes(); let left = try frame(initial[0])
    try click(CGPoint(x: left.midX, y: left.midY)); try awaitFocus(initial[0])
    try key([.maskCommand, .maskShift], keyCode: 2) // Cmd-Shift-D: split below
    var current = try waitForPanes(3); note("split_below")
    let before = try current.map(frame)
    let initialDividers = try nestedDividers(before)
    try drag(initialDividers.outer, delta: CGPoint(x: -90, y: 0), phase: "outer_divider_drag")
    current = try waitForPanes(3)
    let afterOuter = try current.map(frame)
    let afterOuterDividers = try nestedDividers(afterOuter)
    try drag(afterOuterDividers.inner, delta: CGPoint(x: 0, y: 55), phase: "inner_divider_drag")
    // Exercise the ownership/teardown path for an active pane, then recreate a
    // sibling. This catches stale renderer surfaces and inherited-session state.
    recordPaneGeometry("pre_close_geometry")
    let paneFrames = try panes().map { ($0, try frame($0)) }
    let leftX = paneFrames.map(\.1.minX).min()!
    let rightCandidates = paneFrames.filter { $0.1.minX > leftX + 1 }.sorted { $0.1.height > $1.1.height }
    guard let closeTarget = rightCandidates.first,
      (rightCandidates.dropFirst().first.map { closeTarget.1.height > $0.1.height + 1 } ?? true) else {
      throw TUIStressFailure.invalid("cannot identify unique full-height right sibling to close")
    }
    try click(CGPoint(x: closeTarget.1.midX, y: closeTarget.1.midY)); try awaitFocus(closeTarget.0)
    try key(.maskCommand, keyCode: 13) // Cmd-W: close focused pane, not window while split
    _ = try waitForPanes(2); note("close_pane")
    recordPaneGeometry("post_close_geometry")
    let survivor = try panes().sorted { try frame($0).minX < frame($1).minX }.first!
    try click(CGPoint(x: try frame(survivor).midX, y: try frame(survivor).midY)); try awaitFocus(survivor)
    try key([.maskCommand, .maskShift], keyCode: 2) // Cmd-Shift-D: recreate nested sibling
    current = try waitForPanes(3); note("resplit_below"); recordPaneGeometry("post_resplit_geometry")
    let corner = try frame(try window())
    try drag(CGPoint(x: corner.maxX - 2, y: corner.maxY - 2), delta: CGPoint(x: -80, y: -55), phase: "window_corner_drag")
    for index in 0..<72 {
      try resize(CGSize(width: index.isMultiple(of: 2) ? 920 : 1040, height: index.isMultiple(of: 3) ? 640 : 720), phase: "rapid_window_resize")
      Thread.sleep(forTimeInterval: 0.018)
    }
    try resize(CGSize(width: 1040, height: 1200), phase: "final_inspection_size")
    current = try waitForPanes(3)
    _ = current
    let finalFrames = try balanceFinalStack()
    note("final_layout", ["panes": finalFrames.map { [$0.minX, $0.minY, $0.width, $0.height] }])
    FileManager.default.createFile(atPath: directory.appendingPathComponent("final-output").path, contents: Data())
    let workload = ProcessInfo.processInfo.environment["TERMINAL_TUI_STRESS_WORKLOAD"] ?? "unknown"
    let workloadMarker = workload == "codex" ? "TUI_STRESS_RESPONSE" : "TUI_STRESS_FILES_LISTING_READY"
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    var settled: [[String: Any]] = []
    repeat {
      settled = try panes().map { pane in
        let value = ax(pane, kAXValueAttribute) as? String ?? ""
        return ["identifier": ax(pane, kAXIdentifierAttribute) as? String ?? "unavailable",
          "frame": rectJSON(try frame(pane)), "value_utf8_bytes": value.lengthOfBytes(using: .utf8),
          "public_fixture_marker_visible": value.contains("TUI_STRESS_\(workload.uppercased())_PANE_"),
          "actual_workload_marker_visible": value.contains(workloadMarker)]
      }
      if settled.allSatisfy({ $0["actual_workload_marker_visible"] as? Bool == true }) { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard settled.allSatisfy({ $0["actual_workload_marker_visible"] as? Bool == true }) else {
      throw TUIStressFailure.invalid("final settled pane is missing the real workload marker")
    }
    try writeJSON(["pid": pid, "workload": workload, "actual_workload_marker": workloadMarker,
      "panes": settled, "invariant": "every final pane visibly contains its real workload output marker after resize settles; any wrapper marker is diagnostic-only and not a workload proof"],
      to: directory.appendingPathComponent("final-screen.json"))
  }

}

@main enum Main {
  @MainActor static func main() throws {
    if CommandLine.arguments.contains("--self-test") {
      let top = CGRect(x: 10, y: 20, width: 100, height: 60)
      let right = CGRect(x: 111, y: 20, width: 90, height: 121)
      let bottom = CGRect(x: 10, y: 81, width: 100, height: 60)
      let dividers = try nestedDividers([top, right, bottom])
      precondition(dividers.outer == CGPoint(x: 110.5, y: 80.5) && dividers.inner == CGPoint(x: 60, y: 80.5))
      do { _ = try nestedDividers([top, bottom, CGRect(x: 210, y: 20, width: 90, height: 121)]); preconditionFailure("disconnected layout accepted") }
      catch TUIStressFailure.invalid { }
      do { _ = try nestedDividers([top, right]); preconditionFailure("ambiguous pane count accepted") }
      catch TUIStressFailure.invalid { }
      let stack = [CGRect(x: 10, y: 20, width: 190, height: 70), CGRect(x: 10, y: 91, width: 190, height: 70), CGRect(x: 10, y: 162, width: 190, height: 70)]
      try verticalStack(stack)
      do { try verticalStack([top, right, bottom]); preconditionFailure("old T layout accepted as final stack") }
      catch TUIStressFailure.invalid { }
      do { try verticalStack([stack[0], CGRect(x: 10, y: 95, width: 190, height: 70), stack[2]]); preconditionFailure("gapped stack accepted") }
      catch TUIStressFailure.invalid { }
      let inspection = [CGRect(x: 10, y: 20, width: 190, height: 390), CGRect(x: 10, y: 411, width: 190, height: 390), CGRect(x: 10, y: 802, width: 190, height: 390)]
      let balanced = try balancedInspectionStack(inspection)
      precondition(abs(balanced.targetDividerY[0] - 410.6666666667) < 0.01)
      do { _ = try balancedInspectionStack([inspection[0], CGRect(x: 10, y: 411, width: 190, height: 300), CGRect(x: 10, y: 712, width: 190, height: 480)]); preconditionFailure("unbalanced inspection stack accepted") }
      catch TUIStressFailure.invalid { }
      print("PASS TUI stress driver layout topology rejection tests; no GUI/input executed")
      return
    }
    guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[2]), pid > 0 else {
      throw TUIStressFailure.invalid("Usage: Driver prepare|exercise ownedPID output")
    }
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let driver = try Driver(pid: pid, directory: URL(fileURLWithPath: CommandLine.arguments[3]))
    switch CommandLine.arguments[1] {
    case "prepare": try driver.prepare()
    case "exercise": try driver.exercise()
    default: throw TUIStressFailure.invalid("unknown mode")
    }
  }
}

import AppKit
import ApplicationServices

enum Failure: Error { case invalid(String) }
struct WindowQueryFailure: Error, CustomStringConvertible {
  let status: AXError
  var description: String { "AXWindows query failed with AXError \(status.rawValue) (\(status))" }
}
func initialWindowQuery<T>(query: () throws -> T, retry: (Int, WindowQueryFailure) -> Void) throws -> T {
  // Retry only AX's cannotComplete messaging failure for the new exercise
  // client's initial query; window ambiguity/absence is not a transport error.
  for attempt in 1...3 {
    do { return try query() }
    catch let failure as WindowQueryFailure where failure.status == .cannotComplete && attempt < 3 {
      retry(attempt, failure)
    }
  }
  throw Failure.invalid("Unreachable initial window query state")
}
func attribute(_ element: AXUIElement, _ name: String) -> Any? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func frame(_ element: AXUIElement) throws -> CGRect {
  guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
    CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else {
    throw Failure.invalid("Missing AX frame")
  }
  var point = CGPoint.zero, extent = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
    throw Failure.invalid("Invalid AX frame")
  }
  return CGRect(origin: point, size: extent)
}
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
  guard depth < 10 else { return [] }
  let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
  return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}
func write(_ object: [String: Any], to url: URL) throws {
  try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
func rectJSON(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height] }
func uniqueAXFrameIndex(_ frames: [CGRect?], target: CGRect) throws -> Int {
  guard frames.allSatisfy({ $0 != nil }) else { throw Failure.invalid("Cannot correlate an owned AX window with unavailable frame") }
  let matches = frames.indices.filter { index in
    let candidate = frames[index]!
    return candidate.width > 0 && candidate.height > 0 &&
      zip(rectJSON(candidate), rectJSON(target)).allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) <= 1 }
  }
  guard matches.count == 1 else { throw Failure.invalid("Expected one AX window matching prepared CG frame; found \(matches.count)") }
  return matches[0]
}
struct NestedDividers {
  let outer: CGPoint
  let inner: CGPoint
}
func nestedDividers(top: CGRect, right: CGRect, bottom: CGRect) throws -> NestedDividers {
  func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
  func gap(_ start: CGFloat, _ end: CGFloat) -> Bool { (0...2).contains(end - start) }
  guard [top, right, bottom].allSatisfy({ rectJSON($0).allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }),
    near(top.minX, bottom.minX), near(top.maxX, bottom.maxX),
    near(top.minY, right.minY), near(bottom.maxY, right.maxY),
    gap(top.maxX, right.minX), gap(bottom.maxX, right.minX), gap(top.maxY, bottom.minY) else {
    throw Failure.invalid("Expected pane0 above pane2 on left, pane1 spanning right; actual AX adjacency differs")
  }
  return NestedDividers(outer: CGPoint(x: (top.maxX + right.minX) / 2, y: right.midY),
    inner: CGPoint(x: top.midX, y: (top.maxY + bottom.minY) / 2))
}

struct WindowMatch {
  let info: [String: Any]
  let correlation: [String: Any]
}
func matchWindow(_ infos: [[String: Any]], pid: pid_t, axFrame: CGRect) throws -> WindowMatch {
  // AXPosition and CGWindowBounds both use global top-left screen points.
  // Neither AppKit's bottom-left conversion nor Retina pixel scaling belongs here.
  let tolerance = 1.0
  guard rectJSON(axFrame).allSatisfy({ $0.isFinite }), axFrame.width > 0, axFrame.height > 0 else {
    throw Failure.invalid("Invalid AX window frame for capture correlation")
  }
  let candidates = infos.filter {
    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
      ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
  }
  let matches: [WindowMatch] = candidates.compactMap { info in
    guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let x = bounds["X"] as? NSNumber, let y = bounds["Y"] as? NSNumber,
      let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber,
      let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
    let cgFrame = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
    let cg = rectJSON(cgFrame), ax = rectJSON(axFrame)
    let delta = zip(cg, ax).map { $0 - $1 }
    guard cg.allSatisfy({ $0.isFinite }), cgFrame.width > 0, cgFrame.height > 0,
      delta.allSatisfy({ abs($0) <= tolerance }) else { return nil }
    return WindowMatch(info: info, correlation: ["ax_frame": ax, "cg_frame": cg,
      "delta_xywh_points": delta, "tolerance_points": tolerance,
      "coordinate_space": "global top-left logical screen points; no scale or Y inversion",
      "same_pid_layer_zero_candidates": candidates.count, "matching_candidates": 1,
      "matched_window": number])
  }
  guard matches.count == 1 else {
    throw Failure.invalid("Expected one AX-correlated owned CG window; found \(matches.count) among \(candidates.count) candidates")
  }
  return matches[0]
}

@MainActor final class Driver {
  let pid: pid_t, directory: URL, app: AXUIElement
  let running: NSRunningApplication
  var events: [[String: Any]] = []
  var preparedWindowID: Int?
  init(pid: pid_t, directory: URL) throws {
    guard AXIsProcessTrusted() else { throw Failure.invalid("Accessibility unavailable; no permission prompt requested") }
    guard let running = NSRunningApplication(processIdentifier: pid),
      running.executableURL?.path == ProcessInfo.processInfo.environment["TERMINAL_RENDER_PROOF_EXECUTABLE"] else {
      throw Failure.invalid("Owned PID does not match supplied frozen executable")
    }
    self.pid = pid; self.directory = directory; self.running = running
    app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
  }
  func window() throws -> AXUIElement {
    var value: CFTypeRef?
    let started = ProcessInfo.processInfo.systemUptime
    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    let windows = value as? [AXUIElement]
    var observation: [String: Any] = ["phase": "ax_windows_query", "host_time": ProcessInfo.processInfo.systemUptime,
      "target_pid": pid, "helper_pid": ProcessInfo.processInfo.processIdentifier,
      "ax_error": status.rawValue, "query_seconds": ProcessInfo.processInfo.systemUptime - started,
      "app_terminated": running.isTerminated]
    if let value { observation["value_type_id"] = CFGetTypeID(value) }
    if let windows { observation["window_count"] = windows.count }
    // Keep the raw query result even when failure happens before exercise's first
    // phase, or during prepare. No unrelated window titles/content is recorded.
    try recordWindowQuery(observation)
    guard status == .success else { throw WindowQueryFailure(status: status) }
    guard let windows else { throw Failure.invalid("AXWindows succeeded with unexpected or missing value type") }
    guard let preparedWindowID else {
      guard windows.count == 1 else { throw Failure.invalid("Expected exactly one initial owned AX window; AXWindows returned \(windows.count)") }
      return windows[0]
    }
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let targets = infos.filter {
      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
      ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
      ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == preparedWindowID
    }
    guard targets.count == 1, let bounds = targets[0][kCGWindowBounds as String] as? [String: Any],
      let target = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
      throw Failure.invalid("Prepared owned CG window is missing or ambiguous")
    }
    let frames = windows.map { try? frame($0) }
    let metadata: [[String: Any]] = windows.indices.map { index in
      var item: [String: Any] = ["index": index]
      item["role"] = attribute(windows[index], kAXRoleAttribute) as? String ?? "unavailable"
      item["subrole"] = attribute(windows[index], kAXSubroleAttribute) as? String ?? "unavailable"
      if let frame = frames[index] { item["frame"] = rectJSON(frame) } else { item["frame_unavailable"] = true }
      return item
    }
    try recordWindowQuery(["phase": "ax_prepared_window_selection", "host_time": ProcessInfo.processInfo.systemUptime,
      "target_pid": pid, "helper_pid": ProcessInfo.processInfo.processIdentifier, "prepared_window": preparedWindowID,
      "prepared_cg_frame": rectJSON(target), "owned_ax_windows": metadata])
    let selected = try uniqueAXFrameIndex(frames, target: target)
    return windows[selected]
  }
  func recordWindowQuery(_ observation: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]); data.append(10)
    let path = directory.appendingPathComponent("ax-window-queries.jsonl")
    if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
    let file = try FileHandle(forWritingTo: path)
    defer { try? file.close() }
    try file.seekToEnd(); try file.write(contentsOf: data)
  }
  func windowInfo() throws -> WindowMatch {
    let axFrame = try frame(window())
    var infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    if let preparedWindowID { infos = infos.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == preparedWindowID } }
    return try matchWindow(infos, pid: pid, axFrame: axFrame)
  }
  func pane(_ id: Int) throws -> AXUIElement {
    for item in descendants(try window()) {
      if let name = attribute(item, kAXIdentifierAttribute) as? String,
        name.hasPrefix("no.helgesverre.terminal.pane."),
        let text = attribute(item, kAXValueAttribute) as? String, text.hasPrefix("PANE_\(id) ") { return item }
    }
    throw Failure.invalid("Synthetic pane \(id) is not ready")
  }
  func awaitPane(_ id: Int) throws -> AXUIElement {
    for _ in 0..<100 {
      if let pane = try? pane(id) { return pane }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw Failure.invalid("Timed out waiting for synthetic pane \(id)")
  }
  func foreground() throws {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      !running.isTerminated else { throw Failure.invalid("Owned PID lost foreground; input stopped") }
  }
  func awaitFocusedPane(_ id: Int) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    repeat {
      try foreground()
      let target = try pane(id)
      guard let targetIdentifier = attribute(target, kAXIdentifierAttribute) as? String else {
        throw Failure.invalid("Target pane has no AX identifier")
      }
      var value: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(target, kAXFocusedAttribute as CFString, &value)
      let focused = value as? Bool
      var focusedElement: CFTypeRef?
      let appStatus = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement)
      var focusedIdentifier: String?
      if appStatus == .success, let focusedElement, CFGetTypeID(focusedElement) == AXUIElementGetTypeID() {
        focusedIdentifier = attribute(focusedElement as! AXUIElement, kAXIdentifierAttribute) as? String
      }
      note("await_pane_focus", ["pane": id, "ax_error": status.rawValue, "focused": focused as Any? ?? NSNull(),
        "expected_pane_identifier": targetIdentifier, "app_focus_ax_error": appStatus.rawValue,
        "app_focused_identifier": focusedIdentifier as Any? ?? NSNull()])
      // The app's focused element identifies the actual first responder. Retain
      // the pane's AXFocused mapping independently rather than assuming NSView
      // defaults expose both attributes identically.
      if appStatus == .success && focusedIdentifier == targetIdentifier { return }
      guard ProcessInfo.processInfo.systemUptime < deadline else { break }
      Thread.sleep(forTimeInterval: 0.02)
    } while true
    throw Failure.invalid("App AXFocusedUIElement did not identify clicked pane \(id) before split")
  }
  func verifiedNestedLayout() throws -> NestedDividers {
    let top = try frame(pane(0)), right = try frame(pane(1)), bottom = try frame(pane(2))
    note("nested_layout", ["panes": [rectJSON(top), rectJSON(right), rectJSON(bottom)]])
    let dividers = try nestedDividers(top: top, right: right, bottom: bottom)
    note("nested_layout_verified", ["outer_divider": [dividers.outer.x, dividers.outer.y],
      "inner_divider": [dividers.inner.x, dividers.inner.y]])
    return dividers
  }
  func note(_ phase: String, _ data: [String: Any] = [:]) {
    var row = data; row["phase"] = phase; row["host_time"] = ProcessInfo.processInfo.systemUptime
    events.append(row)
  }
  func size(_ width: Double, _ height: Double) throws {
    var value = CGSize(width: width, height: height)
    guard AXUIElementSetAttributeValue(try window(), kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &value)!) == .success else {
      throw Failure.invalid("Owned window size rejected")
    }
  }
  func key(_ flags: CGEventFlags) throws {
    try foreground()
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: down)!
      event.flags = flags
      event.postToPid(pid)
    }
  }
  func mouse(_ type: CGEventType, _ point: CGPoint, phase: String) throws {
    try foreground()
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    try foreground()
    event.post(tap: .cghidEventTap)
    note(phase, ["type": type.rawValue, "point": [point.x, point.y]])
  }
  func click(_ point: CGPoint) throws {
    try mouse(.leftMouseDown, point, phase: "focus_owned_pane")
    try mouse(.leftMouseUp, point, phase: "focus_owned_pane")
  }
  func drag(_ point: CGPoint, delta: CGPoint, phase: String) throws {
    try mouse(.mouseMoved, point, phase: phase)
    try mouse(.leftMouseDown, point, phase: phase)
    defer {
      // Cancel only the owned process if focus changes during a gesture.
      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { up.post(tap: .cghidEventTap) }
      else { up.postToPid(pid) }
      note(phase, ["mouse_up_posted": true])
    }
    for index in 1...120 {
      Thread.sleep(forTimeInterval: 1.0 / 60)
      let factor = (1 - cos(Double(index) / 120 * 2 * Double.pi)) / 2
      try mouse(.leftMouseDragged, CGPoint(x: point.x + delta.x * factor, y: point.y + delta.y * factor), phase: phase)
      if index.isMultiple(of: 20) {
        do { note(phase, ["window_correlation": try windowInfo().correlation]) }
        catch { note(phase, ["window_correlation_unavailable": String(describing: error)]) }
      }
    }
    note(phase, ["gesture_complete": true])
  }
  func prepare() throws {
    running.activate(options: [])
    _ = try awaitPane(0)
    let visible = NSScreen.screens[0].visibleFrame
    guard visible.width >= 1180, visible.height >= 860 else { throw Failure.invalid("Proof requires a 1180×860-point visible screen") }
    var origin = CGPoint(x: visible.minX + 30, y: NSScreen.screens[0].frame.maxY - visible.maxY + 30)
    guard AXUIElementSetAttributeValue(try window(), kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!) == .success else {
      throw Failure.invalid("Cannot position owned window inside screen")
    }
    try size(1100, 800)
    Thread.sleep(forTimeInterval: 0.3)
    let pane = try pane(0)
    var range = CFRange(location: 0, length: 1), result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(pane, kAXBoundsForRangeParameterizedAttribute as CFString,
      AXValueCreate(.cfRange, &range)!, &result) == .success, let result else {
      throw Failure.invalid("Cannot independently measure native cell geometry")
    }
    var cell = CGRect.zero
    guard AXValueGetValue(result as! AXValue, .cgRect, &cell), cell.width > 0, cell.height > 0 else { throw Failure.invalid("Bad native cell bounds") }
    let windowFrame = try frame(window())
    let mainTop = NSScreen.screens[0].frame.maxY
    let appKitCenter = CGPoint(x: windowFrame.midX, y: mainTop - windowFrame.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitCenter) }) else { throw Failure.invalid("Window screen unavailable") }
    let scale = screen.backingScaleFactor
    let match = try windowInfo()
    try write(["pid": pid, "window": match.info[kCGWindowNumber as String]!, "executable": running.executableURL!.path,
      "window_correlation": match.correlation,
      "cell_width_pixels": Int((cell.width * scale).rounded()), "cell_height_pixels": Int((cell.height * scale).rounded()),
      "backing_scale": scale, "initial_window_frame": rectJSON(windowFrame),
      "oracle_scope": "Independent AX cell dimensions; no same-frame native pane references or drawable presentation callbacks"],
      to: directory.appendingPathComponent("identity.json"))
  }
  func exercise() throws {
    defer { try? write(["pid": pid, "events": events], to: directory.appendingPathComponent("input-events.json")) }
    Thread.sleep(forTimeInterval: 0.5)
    let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("identity.json"))) as! [String: Any]
    guard let savedID = identity["window"] as? Int, identity["pid"] as? Int32 == pid,
      identity["executable"] as? String == running.executableURL?.path else {
      throw Failure.invalid("Prepared identity does not match the owned app")
    }
    preparedWindowID = savedID
    let match = try initialWindowQuery(query: { try windowInfo() }, retry: { attempt, failure in
      note("initial_ax_transport_retry", ["attempt": attempt, "ax_error": failure.status.rawValue])
      Thread.sleep(forTimeInterval: 0.1)
    })
    guard (match.info[kCGWindowNumber as String] as? NSNumber) == (identity["window"] as? NSNumber) else {
      throw Failure.invalid("AX window no longer matches the prepared capture window")
    }
    note("exercise_window_verified", ["window_correlation": match.correlation])
    note("split_right")
    try key(.maskCommand)
    _ = try awaitPane(1)
    let first = try frame(pane(0))
    try click(CGPoint(x: first.minX + 30, y: first.minY + 25))
    try awaitFocusedPane(0)
    note("split_below")
    try key([.maskCommand, .maskShift])
    _ = try awaitPane(2)
    Thread.sleep(forTimeInterval: 1)
    let layout = try verifiedNestedLayout()
    try drag(layout.outer, delta: CGPoint(x: -140, y: 0), phase: "native_outer_divider")
    let afterOuter = try verifiedNestedLayout()
    try drag(afterOuter.inner, delta: CGPoint(x: 0, y: 70), phase: "native_inner_divider")
    let windowFrame = try frame(window())
    try drag(CGPoint(x: windowFrame.maxX - 2, y: windowFrame.maxY - 2), delta: CGPoint(x: -100, y: -70), phase: "native_window_resize")
    note("programmatic_window_begin")
    for index in 0..<60 {
      try size(index.isMultiple(of: 2) ? 1000 : 1100, index.isMultiple(of: 3) ? 740 : 800)
      Thread.sleep(forTimeInterval: 0.035)
    }
    try size(1100, 800)
    Thread.sleep(forTimeInterval: 0.3)
    note("final_static_output", ["final_barcode_encoding": "0x8000 | (rows<<8) | columns; rows1...127, columns1...255", "panes": [0, 1, 2]])
    try Data().write(to: directory.appendingPathComponent("final-output"))
  }
}

@main enum Main {
  @MainActor static func main() throws {
    if CommandLine.arguments == [CommandLine.arguments[0], "--clock"] {
      print(ProcessInfo.processInfo.systemUptime)
      return
    }
    if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
      precondition(rectJSON(CGRect(x: 1, y: 2, width: 3, height: 4)) == [1, 2, 3, 4])
      let ax = CGRect(x: -1100, y: -250, width: 900, height: 700)
      func candidate(_ id: Int, _ rect: CGRect, pid: Int = 42, layer: Int = 0) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowNumber as String: id,
         kCGWindowBounds as String: ["X": rect.minX, "Y": rect.minY, "Width": rect.width, "Height": rect.height]]
      }
      let wanted = candidate(7, ax)
      let unrelated = [candidate(8, ax.offsetBy(dx: 100, dy: 0)), candidate(9, ax, pid: 99), candidate(10, ax, layer: 1)]
      let selected = try matchWindow(unrelated + [wanted], pid: 42, axFrame: ax)
      precondition(selected.info[kCGWindowNumber as String] as? Int == 7)
      precondition((try? matchWindow(unrelated, pid: 42, axFrame: ax)) == nil)
      precondition((try? matchWindow([wanted, candidate(11, ax)], pid: 42, axFrame: ax)) == nil)
      precondition((try? matchWindow([candidate(7, ax.offsetBy(dx: 0.5, dy: -0.5))], pid: 42, axFrame: ax)) != nil)
      precondition((try? matchWindow([candidate(7, ax.offsetBy(dx: 1.1, dy: 0))], pid: 42, axFrame: ax)) == nil)
      precondition((try? matchWindow([candidate(7, CGRect(x: -2200, y: -500, width: 1800, height: 1400))], pid: 42, axFrame: ax)) == nil)
      print("PASS AX/CG unique window correlation: wrong PID/layer/frame, duplicate, scale and tolerance cases; no GUI/input executed")
      let auxiliary = ax.offsetBy(dx: 100, dy: 100)
      let selectedAX = try uniqueAXFrameIndex([auxiliary, ax], target: ax)
      precondition(selectedAX == 1)
      let repeatedAuxiliary = try uniqueAXFrameIndex([auxiliary, auxiliary, ax], target: ax)
      precondition(repeatedAuxiliary == 2)
      precondition((try? uniqueAXFrameIndex([ax, ax], target: ax)) == nil)
      precondition((try? uniqueAXFrameIndex([auxiliary], target: ax)) == nil)
      precondition((try? uniqueAXFrameIndex([nil, ax], target: ax)) == nil)
      print("PASS prepared AX window selection: nonmatching auxiliaries accepted; duplicate target/missing/unreadable frames rejected")
      let top = CGRect(x: 30, y: 96, width: 549.5, height: 385.5)
      let right = CGRect(x: 580.5, y: 96, width: 549.5, height: 772)
      let bottom = CGRect(x: 30, y: 482.5, width: 549.5, height: 385.5)
      let dividers = try nestedDividers(top: top, right: right, bottom: bottom)
      precondition(dividers.outer == CGPoint(x: 580, y: 482))
      precondition(dividers.inner == CGPoint(x: 304.75, y: 482))
      // Frozen failed-run geometry: pane0 full left; pane1/pane2 split right.
      precondition((try? nestedDividers(top: CGRect(x: 30, y: 96, width: 549.5, height: 772),
        right: CGRect(x: 580.5, y: 96, width: 549.5, height: 385.5),
        bottom: CGRect(x: 580.5, y: 482.5, width: 549.5, height: 385.5))) == nil)
      precondition((try? nestedDividers(top: top, right: right, bottom: bottom.offsetBy(dx: 0, dy: 10))) == nil)
      print("PASS nested divider geometry: expected adjacency accepted; recorded wrong-side split and gap rejected")
      var queries = 0, retries = 0
      let recovered: Int = try initialWindowQuery(query: {
        queries += 1
        if queries < 3 { throw WindowQueryFailure(status: .cannotComplete) }
        return 7
      }, retry: { _, _ in retries += 1 })
      precondition(recovered == 7 && queries == 3 && retries == 2)
      queries = 0
      let exhausted: Int? = try? initialWindowQuery(query: {
        queries += 1; throw WindowQueryFailure(status: .cannotComplete)
      }, retry: { _, _ in })
      precondition(exhausted == nil && queries == 3)
      let permanentFailures: [Error] = [WindowQueryFailure(status: .apiDisabled), Failure.invalid("zero or multiple windows"), Failure.invalid("identity mismatch")]
      for failure in permanentFailures {
        queries = 0; retries = 0
        let rejected: Int? = try? initialWindowQuery(query: { queries += 1; throw failure }, retry: { _, _ in retries += 1 })
        precondition(rejected == nil && queries == 1 && retries == 0)
      }
      print("PASS initial AX transport retry: cannotComplete bounded to3; permission, absent/ambiguous and identity errors fail immediately")
      return
    }
    guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[2]), pid > 0 else {
      throw Failure.invalid("Usage: Driver prepare|exercise ownedPID output")
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let driver = try Driver(pid: pid, directory: URL(fileURLWithPath: CommandLine.arguments[3]))
    switch CommandLine.arguments[1] {
    case "prepare": try driver.prepare()
    case "exercise": try driver.exercise()
    default: throw Failure.invalid("Unknown driver mode")
    }
  }
}

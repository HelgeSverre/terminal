import AppKit
import QuartzCore

final class TerminalCanvasView: NSView, NSTextInputClient {
  let automationID = UUID().uuidString
  let session: Session
  private let rendering: TerminalRendering?
  private var surface: TerminalRendering.SurfaceLease?
  private var snapshot: TerminalSnapshot?
  private var accessible: AccessibilityProjection?
  private var lastAccessibleSelection = NSRange(location: NSNotFound, length: 0)
  private var accessibilityNotificationScheduled = false
  private var accessibilityValueChanged = false
  private var accessibilitySelectionChanged = false
  private var pendingSnapshot: TerminalSnapshot?
  private var selection: GridSelection?
  private var dragging = false
  private var originatingKey: NSEvent?
  private struct DeliveredKey {
    let key: UInt32
    let text: String
    let logical: String
    let shifted: String
    let baseLayout: String
    let legacyText: String
    let consumedModifiers: UInt32
  }
  private var terminalKeys: [UInt16: DeliveredKey] = [:]
  private var modifierState = NativeKeyMap.ModifierState()
  private var marked = NSMutableAttributedString(string: "")
  private var cancellingComposition = false
  private var markedSelection = NSRange(location: 0, length: 0)
  private var cellWidth = 9
  private var cellHeight = 19
  private var fontPoints: CGFloat = 14
  private var focused = false
  private var tracking: NSTrackingArea?
  var onStatus: ((String) -> Void)?
  var onTitle: ((String) -> Void)?
  var onObservedSnapshot: ((TerminalSnapshot) -> Void)?
  func refresh() { redraw() }
  func contentSize(columns: Int, rows: Int) -> NSSize {
    updateGeometry()
    return NSSize(
      width: CGFloat(columns * cellWidth + 2 * insetPixels) / scale,
      height: CGFloat(rows * cellHeight + 2 * insetPixels) / scale)
  }
  func geometryReport() -> [String: Any] {
    let metal = layer as? CAMetalLayer
    let renderingStatus = rendering?.surfaceStatus(surface, layer: metal)
    return [
      "frame": NSStringFromRect(frame), "bounds": NSStringFromRect(bounds),
      "layer_frame": NSStringFromRect(layer?.frame ?? .zero),
      "drawable_size": NSStringFromSize(metal?.drawableSize ?? .zero),
      "contents_gravity": layer?.contentsGravity.rawValue ?? "",
      "contents_placement": layerContentsPlacement.rawValue,
      "contents_are_flipped": layer?.contentsAreFlipped() ?? false,
      "renderer_matches_layer": renderingStatus?.attached ?? false,
      "completed_snapshot_revision": renderingStatus?.completedSnapshotRevision ?? 0,
      "display_link_target_timestamp": renderingStatus?.lastTargetTimestamp ?? 0,
      "display_link_presentation_target_timestamp":
        renderingStatus?.lastPresentationTargetTimestamp ?? 0,
      "focused": focused,
      "first_responder": window?.firstResponder === self,
    ]
  }

  override var acceptsFirstResponder: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var isOpaque: Bool { true }
  override func updateLayer() { redraw() }
  override var isFlipped: Bool { true }
  override func makeBackingLayer() -> CALayer { CAMetalLayer() }
  init(frame: NSRect, session: Session) {
    self.session = session
    rendering = (NSApp.delegate as? AppDelegate)?.rendering
    super.init(frame: frame)
    fontPoints = TerminalPreferences.load().fontSize
    session.configure(TerminalPreferences.load().session)
    wantsLayer = true
    // Let AppKit map top-left placement into the backing layer's coordinate
    // system. Direct layer gravity has different vertical meaning when flipped.
    layerContentsPlacement = .topLeft
    layer?.masksToBounds = true
    if let layer = layer as? CAMetalLayer, let rendering {
      surface = rendering.attach(layer)
    } else {
      NSLog("Metal initialization failed: no Metal rendering service")
    }
    registerForDraggedTypes([.fileURL, .string])
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("Terminal pane")
    setAccessibilityIdentifier("no.helgesverre.terminal.pane." + automationID)
    session.onSnapshot = { [weak self] value in
      guard let self else { return }
      onObservedSnapshot?(value)
      if let old = snapshot, old.history_epoch != value.history_epoch {
        selection = nil
        pendingSnapshot = nil
      }
      if let old = snapshot,
        old.document_epoch != value.document_epoch || old.screen_epoch != value.screen_epoch
          || old.geometry_epoch != value.geometry_epoch
      {
        // A frozen selection/preedit cannot hide a new screen or target old
        // coordinates after a destructive reset or committed geometry change.
        selection = nil
        pendingSnapshot = nil
        if hasMarkedText() {
          cancelComposition()
        }
      }
      if selection != nil {
        pendingSnapshot = value
        return
      }
      display(value)
    }
    session.onStatus = { [weak self] status in self?.onStatus?(status) }
    session.onClipboardWrite = { [weak self] request in
      guard let self, let delegate = NSApp.delegate as? AppDelegate else {
        request.resolve(false) { _ in }
        return
      }
      delegate.clipboardAccess.request(request, from: self.window)
    }
    session.setClipboardClosedHandler { sessionID in
      (NSApp.delegate as? AppDelegate)?.clipboardAccess.cancel(sessionID: sessionID)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  func detachRenderingSurface() {
    guard let surface else { return }
    rendering?.detach(surface)
    self.surface = nil
  }
  deinit {
    detachRenderingSurface()
  }
  private func display(_ value: TerminalSnapshot) {
    snapshot = value
    accessible = AccessibilityProjection(snapshot: value)
    onTitle?(value.title)
    setAccessibilityValue(accessible?.text ?? "")
    accessibilityChanged(value: true)
    redraw()
  }
  private func accessibilityChanged(value: Bool = false, selection: Bool = false) {
    accessibilityValueChanged = accessibilityValueChanged || value
    accessibilitySelectionChanged = accessibilitySelectionChanged || selection
    guard !accessibilityNotificationScheduled else { return }
    accessibilityNotificationScheduled = true
    // Keep the latest projection immediately readable while coalescing noisy
    // output notifications. The trailing wake also announces the final frame.
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
      guard let self else { return }
      accessibilityNotificationScheduled = false
      let valueChanged = accessibilityValueChanged
      let selectionChanged = accessibilitySelectionChanged
      accessibilityValueChanged = false
      accessibilitySelectionChanged = false
      if valueChanged { NSAccessibility.post(element: self, notification: .valueChanged) }
      if selectionChanged {
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
      }
    }
  }
  override func accessibilityNumberOfCharacters() -> Int { accessible?.length ?? 0 }
  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: accessible?.length ?? 0)
  }
  override func accessibilitySelectedTextRange() -> NSRange {
    guard let accessible else { return NSRange(location: 0, length: 0) }
    if selection == nil && snapshot?.following_tail == false {
      return NSRange(location: NSNotFound, length: 0)
    }
    let caret = (snapshot?.cursor.row ?? 0) * accessible.columns + (snapshot?.cursor.col ?? 0)
    return accessible.textRange(
      gridStart: selection?.lower ?? caret, gridEnd: selection?.upper ?? caret)
  }
  override func setAccessibilitySelectedTextRange(_ range: NSRange) {
    guard let cells = accessible?.gridRange(for: range) else { return }
    selection = GridSelection(start: cells.lowerBound, end: cells.upperBound)
    redraw()
  }
  override func accessibilitySelectedText() -> String? {
    accessible?.string(in: accessibilitySelectedTextRange())
  }
  override func accessibilityString(for range: NSRange) -> String? { accessible?.string(in: range) }
  override func accessibilityRange(for index: Int) -> NSRange {
    accessible?.range(for: index) ?? NSRange(location: NSNotFound, length: 0)
  }
  override func accessibilityRange(forLine line: Int) -> NSRange {
    accessible?.range(forLine: line) ?? NSRange(location: NSNotFound, length: 0)
  }
  override func accessibilityLine(for index: Int) -> Int { accessible?.line(for: index) ?? -1 }
  override func accessibilityInsertionPointLineNumber() -> Int {
    accessibilityLine(for: accessibilitySelectedTextRange().location)
  }
  override func accessibilityRange(for point: NSPoint) -> NSRange {
    guard let window, let accessible else { return NSRange(location: NSNotFound, length: 0) }
    let local = convert(
      window.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
    guard bounds.contains(local) else { return NSRange(location: NSNotFound, length: 0) }
    let row = max(0, Int((local.y * scale - CGFloat(insetPixels)) / CGFloat(cellHeight)))
    let col = max(
      0,
      min(
        accessible.columns - 1, Int((local.x * scale - CGFloat(insetPixels)) / CGFloat(cellWidth))))
    let index = row * accessible.columns + col
    let offset = accessible.textRange(gridStart: index, gridEnd: index).location
    return accessible.range(for: offset)
  }
  override func accessibilityFrame(for range: NSRange) -> NSRect {
    guard let window, let accessible else { return .zero }
    var frame = NSRect.null
    for span in accessible.spans(for: range) {
      let width = range.length == 0 ? 1 : max(1, span.cells * cellWidth)
      let rect = NSRect(
        x: CGFloat(insetPixels + min(accessible.columns, span.column) * cellWidth) / scale,
        y: CGFloat(insetPixels + span.row * cellHeight) / scale,
        width: CGFloat(width) / scale, height: CGFloat(cellHeight) / scale)
      frame = frame.union(rect)
    }
    guard !frame.isNull else { return .zero }
    frame = frame.intersection(bounds)
    guard !frame.isNull else { return .zero }
    return window.convertToScreen(convert(frame, to: nil))
  }
  override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if selector == NSSelectorFromString("setAccessibilityValue:")
      || selector == NSSelectorFromString("setAccessibilitySelectedText:")
    {
      return false
    }
    return super.isAccessibilitySelectorAllowed(selector)
  }
  func applyPreferences() {
    fontPoints = TerminalPreferences.load().fontSize
    session.configure(TerminalPreferences.load().session)
    updateGeometry()
  }
  func updateFocus() {
    let value = window?.isKeyWindow == true && window?.firstResponder === self
    if !value {
      releaseOwnedKeys()
      if hasMarkedText() { cancelComposition() }
    }
    if focused != value {
      if value { modifierState.beginFocus(modifiers: modifiers(NSEvent.modifierFlags)) }
      focused = value
      session.input(key: 2, event: value ? 1 : 0)
      redraw()
    }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self,
      userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseMoved(with event: NSEvent) {
    if snapshot?.modes.mouse == 1003 { _ = reportMouse(event, button: 35, release: false) }
  }
  override func rightMouseDragged(with event: NSEvent) {
    _ = reportMouse(event, button: 34, release: false)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.acceptsMouseMovedEvents = true
    updateGeometry()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateGeometry()
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateGeometry()
  }
  override func becomeFirstResponder() -> Bool {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.updateFocus()
      (NSApp.delegate as? AppDelegate)?.rememberFocus(self)
    }
    return true
  }
  override func resignFirstResponder() -> Bool {
    releaseOwnedKeys()
    if focused {
      focused = false
      session.input(key: 2, event: 0)
    }
    cancelComposition()
    redraw()
    return true
  }
  private var insetPixels: Int { Int((TerminalTheme.contentInset * scale).rounded()) }
  private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
  private func updateGeometry() {
    guard bounds.width > 16, bounds.height > 16 else { return }
    let font = TerminalFont.appKit(size: fontPoints)
    cellWidth = max(
      1, Int(ceil(("M" as NSString).size(withAttributes: [.font: font]).width * scale)))
    cellHeight = max(1, Int(ceil((font.ascender - font.descender + 3) * scale)))
    if let layer = layer as? CAMetalLayer {
      layer.contentsScale = scale
      layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    let cols = max(
      1, min(4096, Int((bounds.width * scale - CGFloat(2 * insetPixels)) / CGFloat(cellWidth))))
    let rows = max(
      1, min(4096, Int((bounds.height * scale - CGFloat(2 * insetPixels)) / CGFloat(cellHeight))))
    clearSelection()
    session.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    inputContext?.invalidateCharacterCoordinates()
    redraw()
  }
  private func redraw() {
    let selected = accessibilitySelectedTextRange()
    if selected != lastAccessibleSelection {
      lastAccessibleSelection = selected
      accessibilityChanged(selection: true)
    }
    guard let value = snapshot, !isHidden, window?.isMiniaturized != true,
      window?.occlusionState.contains(.visible) == true
    else { return }
    if let surface {
      rendering?.request(
        surface, latest: RenderRequest(
        snapshot: value, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
        inset: insetPixels, cellWidth: cellWidth, cellHeight: cellHeight,
        fontSize: fontPoints * scale,
        focused: focused, scrolled: !value.following_tail,
        selection: selection, marked: marked.string))
    }
  }
  private func clearSelection() {
    selection = nil
    if let value = pendingSnapshot {
      pendingSnapshot = nil
      display(value)
    }
  }
  @discardableResult private func send(
    _ text: String = "", key: UInt32 = 0, mods: UInt32 = 0, event: UInt32 = 0
  ) -> Bool {
    let accepted = session.input(text, key: key, modifiers: mods, event: event)
    if accepted && key != 2 && event != 2 {
      clearSelection()
    }
    redraw()
    return accepted
  }
  private func physicalEvent(_ mapped: NativeKeyMap.KeyEvent, event: UInt32) -> TerminalKeyEvent {
    TerminalKeyEvent(
      text: mapped.text, logical: mapped.logical, shifted: mapped.shifted,
      baseLayout: mapped.baseLayout, legacyText: mapped.legacyText, key: mapped.key,
      modifiers: mapped.modifiers, event: event)
  }
  @discardableResult private func sendKey(_ mapped: NativeKeyMap.KeyEvent, event: UInt32) -> Bool {
    let input = physicalEvent(mapped, event: event)
    let accepted = session.input(input)
    if accepted && input.isKeyAction { clearSelection() }
    redraw()
    return accepted
  }
  // Scripted text is a committed text operation, not a synthetic key event.
  // Keep the input-method and selection transitions owned by the canvas.
  @discardableResult func submitAutomationText(_ text: String) -> Bool {
    let accepted = send(text)
    if accepted { cancelComposition() }
    return accepted
  }
  private func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    NativeKeyMap.modifiers(flags)
  }
  override func keyDown(with event: NSEvent) {
    originatingKey = event
    defer { originatingKey = nil }
    if hasMarkedText() {
      interpretKeyEvents([event])
      return
    }
    switch NativeKeyMap.route(event) {
    case .shortcut(let text):
      if session.shortcut(text) { clearSelection() }
      redraw()
    case .encoded(let mapped):
      if sendKey(mapped, event: event.isARepeat ? 1 : 0) {
        terminalKeys[event.keyCode] = DeliveredKey(
          key: mapped.key, text: mapped.text, logical: mapped.logical, shifted: mapped.shifted,
          baseLayout: mapped.baseLayout, legacyText: mapped.legacyText, consumedModifiers: 0)
      }
    case .inputMethod:
      interpretKeyEvents([event])
    }
  }
  override func keyUp(with event: NSEvent) {
    guard let delivered = terminalKeys.removeValue(forKey: event.keyCode) else { return }
    session.input(TerminalKeyEvent(
      text: delivered.text, logical: delivered.logical, shifted: delivered.shifted,
      baseLayout: delivered.baseLayout, legacyText: delivered.legacyText, key: delivered.key,
      modifiers: modifiers(event.modifierFlags) & ~delivered.consumedModifiers, event: 2))
  }
  override func flagsChanged(with event: NSEvent) {
    guard let modifier = NativeKeyMap.modifierEvent(event) else { return }
    guard let resolved = modifierState.resolve(modifier) else { return }
    _ = sendKey(resolved.event, event: resolved.release ? 2 : 0)
  }
  private func releaseOwnedKeys() {
    let flags = modifiers(NSEvent.modifierFlags)
    for delivered in terminalKeys.values {
      session.input(TerminalKeyEvent(
        text: delivered.text, logical: delivered.logical, shifted: delivered.shifted,
        baseLayout: delivered.baseLayout, legacyText: delivered.legacyText, key: delivered.key,
        modifiers: flags & ~delivered.consumedModifiers, event: 2))
    }
    terminalKeys.removeAll()
    for release in modifierState.releaseAll(modifiers: flags) {
      session.input(TerminalKeyEvent(
        text: "", logical: "", shifted: "", baseLayout: "", legacyText: "", key: release.key,
        modifiers: release.modifiers, event: 2))
    }
  }
  func insertText(_ string: Any, replacementRange: NSRange) {
    guard !cancellingComposition else { return }
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    let composing = hasMarkedText()
    marked.mutableString.setString("")
    markedSelection = NSRange(location: 0, length: 0)
    if !composing, text.unicodeScalars.count == 1, let event = originatingKey {
      let consumed: UInt32 =
        !TerminalPreferences.load().optionSendsEscape && event.modifierFlags.contains(.option)
        ? 2 : 0
      let mods = modifiers(event.modifierFlags) & ~consumed
      let mapped = NativeKeyMap.textEvent(event, text: text, modifiers: mods)
      if sendKey(mapped, event: event.isARepeat ? 1 : 0) {
        terminalKeys[event.keyCode] = DeliveredKey(
          key: mapped.key, text: mapped.text, logical: mapped.logical, shifted: mapped.shifted,
          baseLayout: mapped.baseLayout, legacyText: mapped.legacyText, consumedModifiers: consumed)
      }
    } else {
      send(text)
    }
    inputContext?.invalidateCharacterCoordinates()
  }
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard !cancellingComposition else { return }
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    marked = NSMutableAttributedString(string: text)
    markedSelection = selectedRange
    inputContext?.invalidateCharacterCoordinates()
    redraw()
  }
  func unmarkText() {
    let text = marked.string
    marked.mutableString.setString("")
    markedSelection = NSRange(location: 0, length: 0)
    if !cancellingComposition && !text.isEmpty { send(text) }
    redraw()
  }
  private func cancelComposition() {
    guard !cancellingComposition else { return }
    cancellingComposition = true
    marked.mutableString.setString("")
    markedSelection = NSRange(location: 0, length: 0)
    inputContext?.discardMarkedText()
    cancellingComposition = false
    inputContext?.invalidateCharacterCoordinates()
    redraw()
  }
  func hasMarkedText() -> Bool { marked.length > 0 }
  func markedRange() -> NSRange {
    hasMarkedText()
      ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  func selectedRange() -> NSRange { markedSelection }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.underlineStyle, .foregroundColor, .backgroundColor]
  }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard hasMarkedText(), range.location <= marked.length else { return nil }
    let r = NSIntersectionRange(range, NSRange(location: 0, length: marked.length))
    actualRange?.pointee = r
    return marked.attributedSubstring(from: r)
  }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let cursor = snapshot?.cursor
    let rect = NSRect(
      x: CGFloat(insetPixels + (cursor?.col ?? 0) * cellWidth) / scale,
      y: CGFloat(insetPixels + (cursor?.row ?? 0) * cellHeight) / scale,
      width: CGFloat(cellWidth) / scale,
      height: CGFloat(cellHeight) / scale)
    actualRange?.pointee = range
    return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
  }
  override func doCommand(by selector: Selector) {
    switch NSStringFromSelector(selector) {
    case "insertNewline:": send(key: 22)
    case "insertTab:": send(key: 21)
    case "deleteBackward:": send(key: 20)
    case "moveLeft:": send(key: 13)
    case "moveRight:": send(key: 12)
    case "moveUp:": send(key: 10)
    case "moveDown:": send(key: 11)
    case "cancelOperation:":
      cancelComposition()
      send(key: 23)
    default: break
    }
  }
  private func cellIndex(_ event: NSEvent) -> Int {
    guard let value = snapshot else { return 0 }
    let p = convert(event.locationInWindow, from: nil)
    let row = max(
      0, min(value.rows.count - 1, Int((p.y * scale - CGFloat(insetPixels)) / CGFloat(cellHeight))))
    var col = max(
      0, min(value.cols - 1, Int((p.x * scale - CGFloat(insetPixels)) / CGFloat(cellWidth))))
    if value.rows[row].cells[col].kind == "Continuation" { col = max(0, col - 1) }
    return row * value.cols + col
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if reportMouse(event, button: 0, release: false) { return }
    clearSelection()
    dragging = true
    let index = cellIndex(event)
    selection = GridSelection(start: index, end: index)
    if event.clickCount == 2, let value = snapshot {
      let row = index / value.cols
      let col = index % value.cols
      func word(_ c: CellSnapshot) -> Bool {
        c.text.unicodeScalars.contains {
          CharacterSet.alphanumerics.contains($0) || "_-/.:~".unicodeScalars.contains($0)
        }
      }
      var a = col
      var b = col + 1
      while a > 0 && word(value.rows[row].cells[a - 1]) { a -= 1 }
      while b < value.cols && word(value.rows[row].cells[b]) { b += 1 }
      selection = GridSelection(start: row * value.cols + a, end: row * value.cols + b)
      dragging = false
    } else if event.clickCount >= 3, let value = snapshot {
      selection = GridSelection(
        start: index / value.cols * value.cols, end: (index / value.cols + 1) * value.cols)
      dragging = false
    }
    if event.modifierFlags.contains(.command), let value = snapshot,
      let link = value.rows[index / value.cols].cells[index % value.cols].link,
      let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme ?? "")
    {
      NSWorkspace.shared.open(url)
    }
    redraw()
  }
  override func mouseDragged(with event: NSEvent) {
    if reportMouse(event, button: 32, release: false) { return }
    guard dragging, let start = selection?.start, let value = snapshot else { return }
    let index = cellIndex(event)
    selection = GridSelection(
      start: start,
      end: index
        + (value.rows[index / value.cols].cells[index % value.cols].kind == "Lead2" ? 2 : 1))
    redraw()
  }
  override func mouseUp(with event: NSEvent) {
    if reportMouse(event, button: 0, release: true) { return }
    dragging = false
    if selection?.lower == selection?.upper { clearSelection() }
    redraw()
  }
  override func rightMouseDown(with event: NSEvent) {
    if !reportMouse(event, button: 2, release: false) {
      let menu = NSMenu()
      menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
      menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
  }
  override func rightMouseUp(with event: NSEvent) {
    _ = reportMouse(event, button: 2, release: true)
  }
  private func reportMouse(_ event: NSEvent, button: Int, release: Bool) -> Bool {
    guard let value = snapshot, value.modes.mouse != 0, !event.modifierFlags.contains(.shift) else {
      return false
    }
    let index = cellIndex(event)
    let x = index % value.cols + 1
    let y = index / value.cols + 1
    if button & 32 != 0 && value.modes.mouse < 1002 { return true }
    if release && value.modes.mouse == 9 { return true }
    let modifier =
      (event.modifierFlags.contains(.option) ? 8 : 0)
      + (event.modifierFlags.contains(.control) ? 16 : 0)
    if value.modes.sgr_mouse {
      session.rawInput(Data("\u{1b}[<\(button+modifier);\(x);\(y)\(release ? "m":"M")".utf8))
    } else if x <= 223 && y <= 223 {
      session.rawInput(
        Data([
          27, 91, 77, UInt8((release ? 3 : button) + modifier + 32), UInt8(x + 32), UInt8(y + 32),
        ]))
    }
    return true
  }
  override func scrollWheel(with event: NSEvent) {
    guard let value = snapshot else { return }
    if value.modes.mouse != 0 && !event.modifierFlags.contains(.shift) {
      for _ in 0..<min(10, max(1, Int(abs(event.scrollingDeltaY)))) {
        _ = reportMouse(event, button: event.scrollingDeltaY > 0 ? 64 : 65, release: false)
      }
    } else {
      let amount = Int(event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 3 : 1))
      clearSelection()
      session.scroll(amount)
    }
  }
  @objc func copy(_ sender: Any?) {
    guard let selection, let value = snapshot else { return }
    var text = ""
    for r in 0..<value.rows.count {
      let start = max(0, selection.lower - r * value.cols)
      var end = min(value.cols, selection.upper - r * value.cols)
      let originalEnd = end
      guard start < end else { continue }
      let row = value.rows[r]
      if end == value.cols {
        while end > start && row.cells[end - 1].kind == "Empty"
          && row.cells[end - 1].style.background.index == nil
          && row.cells[end - 1].style.background.rgb == nil
        { end -= 1 }
      }
      var piece = ""
      for c in start..<end {
        let cell = row.cells[c]
        piece += cell.kind == "Empty" ? " " : cell.text
      }
      text += piece
      if originalEnd == value.cols && !row.soft_wrapped && selection.upper > (r + 1) * value.cols {
        text += "\n"
      }
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  @objc func cancelPaste(_ sender: Any?) { session.cancelPaste() }
  @objc func clearScreen(_ sender: Any?) {
    session.clearDisplay()
  }
  @objc func paste(_ sender: Any?) {
    if let text = NSPasteboard.general.string(forType: .string) { send(text, key: 1) }
  }
  override func selectAll(_ sender: Any?) {
    guard let value = snapshot else { return }
    selection = GridSelection(start: 0, end: value.cols * value.rows.count)
    redraw()
  }
  @objc func increaseFont(_ sender: Any?) {
    fontPoints = min(40, fontPoints + 1)
    updateGeometry()
  }
  @objc func decreaseFont(_ sender: Any?) {
    fontPoints = max(8, fontPoints - 1)
    updateGeometry()
  }
  @objc func resetFont(_ sender: Any?) {
    fontPoints = 14
    updateGeometry()
  }
  @objc func find(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "Find in scrollback"
    alert.addButton(withTitle: "Find")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    alert.accessoryView = field
    guard let window else { return }
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
      let query = field.stringValue
      self?.session.find(query) { [weak self] outcome in
        self?.onStatus?(outcome.message)
      }
    }
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      send(
        urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(
          separator: " "), key: 1)
      return true
    }
    if let text = sender.draggingPasteboard.string(forType: .string) {
      send(text, key: 1)
      return true
    }
    return false
  }
}

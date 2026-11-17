#if os(macOS)
import AppKit
import QuartzCore
import TerminalEngine
import TerminalHost

public final class TerminalCanvasView: NSView, NSTextInputClient {
  package let automationID: String
  public let session: TerminalSession
  private let rendering: TerminalRendering?
  private let clipboard: ClipboardAccess?
  private var configuration: TerminalViewConfiguration
  private var surface: TerminalRendering.SurfaceLease?
  private var snapshot: TerminalSnapshot?
  private var accessible: AccessibilityProjection?
  private var accessibleHistory: AccessibleHistory?
  private var hoveredLink: VisibleLinkProjection.Occurrence?
  private var linkTargetPreview: LinkTargetPreview?
  private var linkModifierMonitor: Any?
  private var localLinkPress = false
  private var selectionNotice: NSTextField?
  private var lastAccessibleSelection: [NSRange] = []
  private var accessibilityNotificationScheduled = false
  private var accessibilityValueChanged = false
  private var accessibilitySelectionChanged = false
  private var dragging = false
  /// Event number of a click that AppKit admitted through `acceptsFirstMouse`
  /// while the window was not key, and whether that click is still pressed.
  private var activatingClick: Int?
  private var activatingPress = false
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
  private var composition = MarkedTextStorage()
  private var preeditCache: (revision: UInt64, columns: Int, rows: Int, row: Int, column: Int, value: PreeditPresentation)?
  private var cancellingComposition = false
  private var compositionMousePress = false
  private var cellWidth = 9
  private var cellHeight = 19
  private var scrollAccumulator = ScrollAccumulator()
  private var viewportPresentation = ViewportPresentation()
  private var pendingViewportAnchor: Int?
  private var blinkWake: DispatchWorkItem?
  private var blinkDeadline: TimeInterval?
  private var visibilityObservers: [NSObjectProtocol] = []
  var presentationOffsetPixels: CGFloat {
    guard pendingViewportAnchor == nil, snapshot?.presentationOverscan != nil else { return 0 }
    return viewportPresentation.fraction * CGFloat(cellHeight)
  }
  var presentationGeometry: ViewportGeometry {
    ViewportGeometry(inset: CGFloat(insetPixels), cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight), offset: presentationOffsetPixels)
  }
  private var presentationSnapshot: TerminalSnapshot? {
    guard let snapshot else { return nil }
    return presentationOffsetPixels == 0 ? snapshot : snapshot.includingPresentationOverscan()
  }
  private var fontPoints: CGFloat = 14
  private var focused = false
  private var tracking: NSTrackingArea?
  private weak var findBar: TerminalFindBar?
  // Invalidates completions of superseded queries and of a closed bar.
  private var findGeneration = 0
  private var findPending = false
  package var onStatus: ((String) -> Void)?
  public var onTitle: ((String) -> Void)?
  public var onActivated: (() -> Void)?
  /// Called when the user opens a link (Command-click). Return true when
  /// the host has dealt with it; otherwise, and when unset, the view opens
  /// it with the workspace.
  public var onOpenLink: ((URL) -> Bool)?
  /// Called with the context menu before it is shown, holding Copy and
  /// Paste. The host adds, removes or reorders items.
  public var onContextMenu: ((NSMenu) -> Void)?
  /// Called when this view has become the window's first responder.
  public var onFocused: (() -> Void)?
  package var onObservedSnapshot: ((TerminalSnapshot) -> Void)?
  package func refresh() { redraw() }
  public func contentSize(columns: Int, rows: Int) -> NSSize {
    updateMetrics()
    return NSSize(
      width: CGFloat(columns * cellWidth + 2 * insetPixels) / scale,
      height: CGFloat(rows * cellHeight + 2 * insetPixels) / scale)
  }
  package func geometryReport() -> [String: Any] {
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

  public override var acceptsFirstResponder: Bool { true }
  /// Accept the click that activates an unfocused window so it focuses the
  /// pane under the pointer instead of restoring the previously focused pane.
  /// AppKit asks only for clicks in non-key windows; that click only focuses.
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    if let event, event.type == .leftMouseDown { activatingClick = event.eventNumber }
    return true
  }
  public override var wantsUpdateLayer: Bool { true }
  public override var isOpaque: Bool { true }
  public override func updateLayer() { redraw() }
  public override var isFlipped: Bool { true }
  public override func makeBackingLayer() -> CALayer { CAMetalLayer() }
  /// Without `rendering` the view draws nothing; without `clipboard` it
  /// refuses clipboard writes and copies nothing.
  public init(frame: NSRect, session: TerminalSession, rendering: TerminalRendering?, clipboard: ClipboardAccess?,
       configuration: TerminalViewConfiguration = TerminalViewConfiguration(), automationID: String = UUID().uuidString) {
    self.automationID = automationID
    self.session = session
    self.rendering = rendering
    self.clipboard = clipboard
    self.configuration = configuration
    super.init(frame: frame)
    fontPoints = configuration.fontSize
    session.attachView()
    session.configure(configuration.session)
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
    // Every pane observes modifier changes so Cmd reveals the link beneath
    // the pointer even when another pane owns the keyboard responder.
    linkModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.updateLinkHoverForCurrentPointer(modifiers: event.modifierFlags)
      return event
    }
    session.onSnapshot = { [weak self] value in
      guard let self else { return }
      onObservedSnapshot?(value)
      if let old = snapshot,
        old.selectionPresentation?.documentGeneration != value.selectionPresentation?.documentGeneration
          || old.alternate != value.alternate || old.geometry_epoch != value.geometry_epoch
      {
        // Composition is pane-local, while selection belongs to the owner.
        if hasMarkedText() {
          cancelComposition()
        }
      }
      display(value)
    }
    session.onViewStatus = { [weak self] status in self?.onStatus?(status) }
    session.onClipboardWrite = { [weak self] request in
      guard let self, let clipboard = self.clipboard else {
        request.resolve(false) { _ in }
        return
      }
      clipboard.request(request, from: self.window)
    }
    session.setClipboardClosedHandler { [weak clipboard] sessionID in
      clipboard?.cancel(sessionID: sessionID)
    }
  }
  public required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  package func detachRenderingSurface() {
    guard let surface else { return }
    rendering?.detach(surface)
    self.surface = nil
  }
  deinit {
    blinkWake?.cancel()
    visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
    if let linkModifierMonitor { NSEvent.removeMonitor(linkModifierMonitor) }
    detachRenderingSurface()
    let session = session
    MainActor.assumeIsolated { session.detachView() }
  }
  private func display(_ value: TerminalSnapshot) {
    let previousSelectionRevision = snapshot?.selection.revision
    let geometryChanged = snapshot?.geometry_epoch != value.geometry_epoch
      || snapshot?.alternate != value.alternate
      || snapshot?.viewport_clamp_revision != value.viewport_clamp_revision
    let beganReportingMouse = snapshot?.modes.mouse != value.modes.mouse && value.modes.mouse != 0
    if geometryChanged || beganReportingMouse || value.following_tail && pendingViewportAnchor == nil {
      viewportPresentation.reset(offset: value.scroll_offset)
      pendingViewportAnchor = nil
    } else if pendingViewportAnchor == nil || pendingViewportAnchor == value.scroll_offset {
      pendingViewportAnchor = nil
      viewportPresentation.reconcile(offset: value.scroll_offset)
    }
    snapshot = value
    accessible = AccessibilityProjection(snapshot: presentationSnapshot ?? value)
    if hasMarkedText() { inputContext?.invalidateCharacterCoordinates() }
    if previousSelectionRevision != value.selection.revision,
      let failure = value.selection.issue {
      showSelectionNotice(failure)
    }
    updateLinkHoverForCurrentPointer(modifiers: NSEvent.modifierFlags)
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
  public override func accessibilityNumberOfCharacters() -> Int { accessible?.length ?? 0 }
  public override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: accessible?.length ?? 0)
  }
  public override func accessibilitySelectedTextRange() -> NSRange {
    guard let accessible else { return NSRange(location: 0, length: 0) }
    let ranges = accessible.selectedRanges()
    if ranges.count == 1 { return ranges[0] }
    if ranges.count > 1 { return NSRange(location: NSNotFound, length: 0) }
    if snapshot?.selection.phase == .committed || snapshot?.following_tail == false {
      return NSRange(location: NSNotFound, length: 0)
    }
    let caret = (snapshot?.cursor.row ?? 0) * accessible.columns + (snapshot?.cursor.col ?? 0)
    return accessible.textRange(gridStart: caret, gridEnd: caret)
  }
  public override func accessibilitySelectedTextRanges() -> [NSValue]? {
    guard let accessible else { return [] }
    let ranges = accessible.selectedRanges()
    if !ranges.isEmpty { return ranges.map { NSValue(range: $0) } }
    let caret = accessibilitySelectedTextRange()
    return caret.location == NSNotFound ? [] : [NSValue(range: caret)]
  }
  public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
    setAccessibilitySelectedTextRanges([NSValue(range: range)])
  }
  public override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
    let ranges = ranges?.map(\.rangeValue) ?? []
    if ranges.isEmpty || ranges.allSatisfy({ $0.length == 0 }) {
      requestSelection(.clear)
      return
    }
    guard let range = accessible?.presentedRange(for: ranges) else { return }
    requestSelection(.range(start: range.start, end: range.end, mode: range.mode))
  }
  public override func accessibilitySelectedText() -> String? {
    accessible?.selectedText()
  }
  public override func accessibilityString(for range: NSRange) -> String? { accessible?.string(in: range) }
  public override func accessibilityChildren() -> [Any]? {
    var children: [Any] = accessible?.linkElements(parent: self, activate: { [weak self] activation in
      self?.activateLink(activation) ?? false
    }) ?? []
    if let selectionNotice { children.append(selectionNotice) }
    if let linkTargetPreview { children.append(linkTargetPreview) }
    if let accessibleHistory { children.append(accessibleHistory) }
    return children
  }
  public override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    [NSAccessibilityCustomAction(name: "Read output history", handler: { [weak self] in
      self?.readAccessibleHistory(.latest) ?? false
    })]
  }
  @discardableResult private func readAccessibleHistory(_ request: TerminalHistoryPageRequest) -> Bool {
    session.accessibilityHistory(request) { [weak self] page in
      guard let self else { return }
      guard let page else {
        NSAccessibility.post(element: self, notification: .announcementRequested,
          userInfo: [.announcement: "History position expired. Read output history again.",
                     .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return
      }
      if let history = accessibleHistory { history.update(page) }
      else {
        accessibleHistory = AccessibleHistory(page: page, parent: self, navigate: { [weak self] request in
          self?.readAccessibleHistory(request) ?? false
        })
      }
      NSAccessibility.post(element: self, notification: .layoutChanged)
      if let history = accessibleHistory { NSAccessibility.post(element: history, notification: .valueChanged) }
      NSAccessibility.post(element: self, notification: .announcementRequested,
        userInfo: [.announcement: "Output history ready, \(page.rows.count) rows. Navigate to Terminal output history.",
                   .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
  }
  public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    accessible?.attributedString(in: range, fontSize: fontPoints, fontFamily: configuration.fontFamily, parent: self, activate: { [weak self] activation in
      self?.activateLink(activation) ?? false
    })
  }
  public override func accessibilityStyleRange(for index: Int) -> NSRange {
    accessible?.styleRange(for: index) ?? NSRange(location: NSNotFound, length: 0)
  }
  public override func accessibilityRange(for index: Int) -> NSRange {
    accessible?.range(for: index) ?? NSRange(location: NSNotFound, length: 0)
  }
  public override func accessibilityRange(forLine line: Int) -> NSRange {
    accessible?.range(forLine: line) ?? NSRange(location: NSNotFound, length: 0)
  }
  public override func accessibilityLine(for index: Int) -> Int { accessible?.line(for: index) ?? -1 }
  public override func accessibilityInsertionPointLineNumber() -> Int {
    accessibilityLine(for: accessibilitySelectedTextRange().location)
  }
  public override func accessibilityRange(for point: NSPoint) -> NSRange {
    guard let window, let accessible else { return NSRange(location: NSNotFound, length: 0) }
    let local = convert(
      window.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
    guard bounds.contains(local) else { return NSRange(location: NSNotFound, length: 0) }
    let row = presentationGeometry.row(at: local.y * scale)
    guard row >= 0, row < (presentationSnapshot?.rows.count ?? 0) else {
      return NSRange(location: NSNotFound, length: 0)
    }
    let col = max(
      0,
      min(
        accessible.columns - 1, Int((local.x * scale - CGFloat(insetPixels)) / CGFloat(cellWidth))))
    let index = row * accessible.columns + col
    let offset = accessible.textRange(gridStart: index, gridEnd: index).location
    return accessible.range(for: offset)
  }
  public override func accessibilityFrame(for range: NSRange) -> NSRect {
    guard let window, let accessible else { return .zero }
    var frame = NSRect.null
    for span in accessible.spans(for: range) {
      let width = range.length == 0 ? 1 : max(1, span.cells * cellWidth)
      let pixels = presentationGeometry.rect(row: span.row, column: min(accessible.columns, span.column))
      let rect = NSRect(x: pixels.minX / scale, y: pixels.minY / scale,
        width: CGFloat(width) / scale, height: pixels.height / scale)
      frame = frame.union(rect)
    }
    guard !frame.isNull else { return .zero }
    frame = frame.intersection(bounds)
    guard !frame.isNull else { return .zero }
    return window.convertToScreen(convert(frame, to: nil))
  }
  public override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if selector == NSSelectorFromString("setAccessibilityValue:")
      || selector == NSSelectorFromString("setAccessibilitySelectedText:")
    {
      return false
    }
    return super.isAccessibilitySelectorAllowed(selector)
  }
  public func apply(_ configuration: TerminalViewConfiguration) {
    self.configuration = configuration
    fontPoints = configuration.fontSize
    session.configure(configuration.session)
    findBar?.apply(TerminalChromeColors(configuration.session.colors))
    updateLinkTargetPreview()
    updateGeometry()
  }
  package func updateFocus() {
    let value = window?.isKeyWindow == true && window?.firstResponder === self
    if !value {
      if dragging {
        dragging = false
        _ = session.selection(.commit)
      }
      hoveredLink = nil
      updateLinkTargetPreview()
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
  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self,
      userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  public override func mouseMoved(with event: NSEvent) {
    updateLinkHover(locationInWindow: event.locationInWindow, modifiers: event.modifierFlags)
    if !event.modifierFlags.contains(.command), snapshot?.modes.mouse == 1003 {
      _ = reportMouse(event, button: 35, release: false)
    }
  }
  public override func mouseEntered(with event: NSEvent) {
    updateLinkHover(locationInWindow: event.locationInWindow, modifiers: event.modifierFlags)
  }
  public override func mouseExited(with event: NSEvent) {
    if hoveredLink != nil {
      hoveredLink = nil
      updateLinkTargetPreview()
      redraw()
    }
  }
  public override func cursorUpdate(with event: NSEvent) {
    // Cursor invalidation must not turn into a synthetic pointer/key transition.
    // Mouse, modifier and snapshot events maintain the current hover target.
    (hoveredLink == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
  }
  public override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

  private func linkOccurrence(locationInWindow: NSPoint) -> VisibleLinkProjection.Occurrence? {
    guard let snapshot, snapshot.cols > 0, !snapshot.rows.isEmpty else { return nil }
    let point = convert(locationInWindow, from: nil)
    let x = point.x * scale - CGFloat(insetPixels)
    let y = point.y * scale - CGFloat(insetPixels) - presentationOffsetPixels
    let viewportY = point.y * scale - CGFloat(insetPixels)
    guard x >= 0, y >= 0, viewportY >= 0,
      viewportY < CGFloat(snapshot.rows.count * cellHeight) else { return nil }
    let column = Int(x / CGFloat(cellWidth))
    let row = Int(y / CGFloat(cellHeight))
    guard column < snapshot.cols, row < (presentationSnapshot?.rows.count ?? snapshot.rows.count) else { return nil }
    return accessible?.occurrence(atGrid: row * snapshot.cols + column)
  }
  /// The only UI boundary that opens links. Session first validates the
  /// immutable presentation proof on its owner queue; this view never
  /// reinterprets grid cells, labels, or a newer snapshot.
  private func activateLink(_ activation: VisibleLinkProjection.Activation) -> Bool {
    let admitted = session.activateLink(activation) { [weak self] result in
      switch result {
      case .success(let target):
        self?.open(target)
      case .failure(let failure):
        self?.showSelectionNotice(failure)
      }
    }
    if !admitted { showSelectionNotice(.busy) }
    return admitted
  }
  private func updateLinkHoverForCurrentPointer(modifiers: NSEvent.ModifierFlags) {
    guard let window else {
      hoveredLink = nil
      updateLinkTargetPreview()
      return
    }
    updateLinkHover(locationInWindow: window.mouseLocationOutsideOfEventStream, modifiers: modifiers)
  }
  private func updateLinkHover(locationInWindow: NSPoint, modifiers: NSEvent.ModifierFlags) {
    let point = convert(locationInWindow, from: nil)
    let active = window?.isKeyWindow == true && bounds.contains(point)
    let value = active && modifiers.contains(.command)
      ? linkOccurrence(locationInWindow: locationInWindow) : nil
    if hoveredLink != value { hoveredLink = value; redraw() }
    updateLinkTargetPreview(pointer: point)
    if active { (value == nil ? NSCursor.iBeam : NSCursor.pointingHand).set() }
  }
  private func updateLinkTargetPreview(pointer: NSPoint? = nil) {
    guard let target = hoveredLink?.target else {
      linkTargetPreview?.removeFromSuperview()
      linkTargetPreview = nil
      return
    }
    let preview = linkTargetPreview ?? LinkTargetPreview(frame: .zero)
    if linkTargetPreview == nil {
      linkTargetPreview = preview
      addSubview(preview)
    }
    preview.show(target, colors: TerminalChromeColors(configuration.session.colors))
    let location = pointer ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
    preview.position(in: bounds, pointer: location)
  }
  public override func rightMouseDragged(with event: NSEvent) {
    _ = reportMouse(event, button: 34, release: false)
  }
  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
    visibilityObservers.removeAll()
    if let window {
      for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification] {
        visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: window,
          queue: .main) { [weak self] _ in self?.redraw() })
      }
    }
    window?.acceptsMouseMovedEvents = true
    updateGeometry()
  }
  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateGeometry()
  }
  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateGeometry()
  }
  public override func becomeFirstResponder() -> Bool {
    // The window owns title publication.  Notify it synchronously so changing
    // panes immediately restores this pane's cached title, even if a later
    // responder change moves focus into a transient control.
    onActivated?()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.updateFocus()
      self.onFocused?()
    }
    return true
  }
  public override func resignFirstResponder() -> Bool {
    releaseOwnedKeys()
    if focused {
      focused = false
      session.input(key: 2, event: 0)
    }
    cancelComposition()
    redraw()
    return true
  }
  private var insetPixels: Int { Int((min(200, max(0, configuration.contentInset)) * scale).rounded()) }
  private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
  /// Grid sizing is also needed before the first AppKit layout pass, when the
  /// canvas still has a zero frame. Keep font metrics independent of bounds so
  /// a requested startup grid does not use the seed cell dimensions.
  private func updateMetrics() {
    let font = TerminalFont.appKit(size: fontPoints, family: configuration.fontFamily)
    cellWidth = max(
      1, Int(ceil(("M" as NSString).size(withAttributes: [.font: font]).width * scale)))
    cellHeight = max(1, Int(ceil((font.ascender - font.descender + 3) * scale)))
  }
  /// The grid the view's bounds hold at the current font, or nil while the
  /// view is too small to hold one.
  /// The text on screen, one line per row, without trailing spaces.
  public var visibleText: String {
    guard let snapshot else { return "" }
    return snapshot.rows.map { row in
      // The second cell of a wide character holds nothing of its own.
      var line = row.cells.map { $0.kind == "Continuation" ? "" : ($0.text.isEmpty ? " " : $0.text) }.joined()
      while line.hasSuffix(" ") { line.removeLast() }
      return line
    }.joined(separator: "\n")
  }
  /// The grid the view's bounds hold at the current font, or nil while the
  /// view is too small to hold one.
  public var gridSize: (columns: Int, rows: Int)? { gridForBounds }
  package var gridForBounds: (columns: Int, rows: Int)? {
    guard bounds.width > 16, bounds.height > 16, cellWidth > 0, cellHeight > 0 else { return nil }
    return (
      max(1, min(4096, Int((bounds.width * scale - CGFloat(2 * insetPixels)) / CGFloat(cellWidth)))),
      max(1, min(4096, Int((bounds.height * scale - CGFloat(2 * insetPixels)) / CGFloat(cellHeight))))
    )
  }

  private func updateGeometry() {
    guard bounds.width > 16, bounds.height > 16 else { return }
    updateMetrics()
    if let layer = layer as? CAMetalLayer {
      layer.contentsScale = scale
      layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    guard let (cols, rows) = gridForBounds else { return }
    rendering?.prewarm(
      cellWidth: cellWidth, cellHeight: cellHeight, fontSize: fontPoints * scale, family: configuration.fontFamily)
    session.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    positionSelectionNotice()
    updateLinkTargetPreview()
    inputContext?.invalidateCharacterCoordinates()
    redraw()
  }
  private func showSelectionNotice(_ failure: TerminalSelectionFailure) {
    guard window != nil else { return }
    let message: String
    switch failure {
    case .evicted: message = "Selected text left scrollback."
    case .changedContent: message = "Selected text changed."
    case .staleTarget: message = "Output changed. Select the text again."
    case .limitExceeded: message = "Selection is too large."
    case .busy: message = "Selection is busy. Try again."
    case .noSelection, .cancelled: return
    }
    selectionNotice?.removeFromSuperview()
    let notice = NSTextField(labelWithString: "  \(message)  ")
    notice.font = .systemFont(ofSize: 11)
    let chrome = TerminalChromeColors(configuration.session.colors)
    notice.textColor = TerminalTheme.color(chrome.secondary)
    notice.backgroundColor = TerminalTheme.color(chrome.background)
    notice.drawsBackground = true
    notice.alignment = .center
    notice.lineBreakMode = .byTruncatingTail
    notice.wantsLayer = true
    notice.layer?.cornerRadius = 4
    notice.layer?.masksToBounds = true
    notice.setAccessibilityLabel(message)
    notice.setAccessibilityIdentifier("no.helgesverre.terminal.selection-notice")
    selectionNotice = notice
    addSubview(notice)
    positionSelectionNotice()
    NSAccessibility.post(element: self, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak notice] in
      guard let self, let notice, selectionNotice === notice else { return }
      notice.removeFromSuperview()
      selectionNotice = nil
    }
  }
  private func positionSelectionNotice() {
    guard let notice = selectionNotice else { return }
    notice.sizeToFit()
    let width = min(notice.frame.width, max(1, bounds.width - 16))
    notice.frame = NSRect(x: max(8, bounds.width - width - 8), y: 8,
      width: width, height: max(20, notice.frame.height))
  }
  @discardableResult private func requestSelection(_ action: TerminalSelectionAction) -> Bool {
    let admitted = session.selection(action)
    if !admitted { showSelectionNotice(.busy) }
    return admitted
  }
  private var requestedFirstFrame = false
  private func scheduleBlink(_ deadline: TimeInterval?) {
    guard deadline != blinkDeadline else { return }
    blinkWake?.cancel()
    blinkWake = nil
    blinkDeadline = deadline
    guard let deadline else { return }
    let wake = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.blinkWake = nil
      self.blinkDeadline = nil
      self.redraw()
    }
    blinkWake = wake
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, deadline - CACurrentMediaTime()), execute: wake)
  }
  private func redraw() {
    let selected = accessibilitySelectedTextRanges()?.map(\.rangeValue) ?? []
    if selected != lastAccessibleSelection {
      lastAccessibleSelection = selected
      accessibilityChanged(selection: true)
    }
    // The window server reports a new window visible some 25 ms after it is
    // ordered in. The first frame does not wait for that report, so the
    // window arrives with its content instead of blank.
    let awaitsFirstFrame = !requestedFirstFrame && window?.isVisible == true
    guard let value = presentationSnapshot, !isHiddenOrHasHiddenAncestor, window?.isMiniaturized != true,
      window?.occlusionState.contains(.visible) == true || awaitsFirstFrame
    else { scheduleBlink(nil); return }
    let shape = configuration.cursorStyle.flatMap {
      (1...6).contains(Int($0)) ? Int($0) : nil
    } ?? value.cursor.shape
    let blink = TerminalBlinkPresentation(now: CACurrentMediaTime(), cursorShape: shape,
      cursor: value.cursor.visible && value.following_tail && focused,
      text: value.rows.contains { $0.cells.contains { $0.style.blink && !$0.style.conceal && !$0.text.isEmpty } }, active: true)
    scheduleBlink(blink.nextDeadline)
    if let surface {
      requestedFirstFrame = true
      rendering?.request(
        surface, latest: RenderRequest(
        snapshot: value, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
        inset: insetPixels, cellWidth: cellWidth, cellHeight: cellHeight,
        fontSize: fontPoints * scale,
        focused: focused, marked: composition.text.string,
        linkUnderline: hoveredLink?.gridSegments ?? [], colors: configuration.session.colors,
        fontFamily: configuration.fontFamily, ligatures: configuration.ligatures,
        backingScale: max(1, Int(scale.rounded())), cursorVisible: blink.cursorVisible,
        textVisible: blink.textVisible, cursorShape: shape,
        scrollOffsetPixels: Float(presentationOffsetPixels), viewportRows: snapshot?.rows.count,
        preedit: preeditPresentation))
    }
  }
  @discardableResult private func send(
    _ text: String = "", key: UInt32 = 0, mods: UInt32 = 0, event: UInt32 = 0
  ) -> Bool {
    let accepted = session.input(text, key: key, modifiers: mods, event: event)
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
    redraw()
    return accepted
  }
  // Scripted text is a committed text operation, not a synthetic key event.
  // Composition remains attached to the original pane. Session owns selection
  // transitions for accepted semantic input.
  @discardableResult package func submitAutomationText(_ text: String) -> Bool {
    let accepted = send(text)
    if accepted { cancelComposition() }
    return accepted
  }
  private func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    NativeKeyMap.modifiers(flags)
  }
  public override func keyDown(with event: NSEvent) {
    originatingKey = event
    defer { originatingKey = nil }
    if hasMarkedText() {
      interpretKeyEvents([event])
      return
    }
    switch NativeKeyMap.route(event, optionSendsEscape: NativeKeyMap.optionSendsEscape(event.modifierFlags, configuration: configuration)) {
    case .shortcut(let text):
      _ = session.shortcut(text)
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
  /// ⌘Z, ⇧⌘Z and ⌘X belong to the Edit menu's text items, which would take
  /// them even while disabled. Typed into the terminal they go to its program.
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, TerminalEditMenu.isTextOnlyKey(event) else {
      return super.performKeyEquivalent(with: event)
    }
    keyDown(with: event)
    return true
  }
  public override func keyUp(with event: NSEvent) {
    guard let delivered = terminalKeys.removeValue(forKey: event.keyCode) else { return }
    session.input(TerminalKeyEvent(
      text: delivered.text, logical: delivered.logical, shifted: delivered.shifted,
      baseLayout: delivered.baseLayout, legacyText: delivered.legacyText, key: delivered.key,
      modifiers: modifiers(event.modifierFlags) & ~delivered.consumedModifiers, event: 2))
  }
  public override func flagsChanged(with event: NSEvent) {
    updateLinkHoverForCurrentPointer(modifiers: event.modifierFlags)
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
  public func insertText(_ string: Any, replacementRange: NSRange) {
    guard !cancellingComposition else { return }
    let inserted = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    guard let text = composition.committing(inserted, replacement: replacementRange) else { return }
    let composing = hasMarkedText()
    composition.clear()
    if !composing, text.unicodeScalars.count == 1, let event = originatingKey {
      let consumed: UInt32 =
        !NativeKeyMap.optionSendsEscape(event.modifierFlags, configuration: configuration) && event.modifierFlags.contains(.option)
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
  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard !cancellingComposition else { return }
    let text = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    guard composition.update(text, selection: selectedRange, replacement: replacementRange) else { return }
    inputContext?.invalidateCharacterCoordinates()
    redraw()
  }
  public func unmarkText() {
    let text = composition.text.string
    composition.clear()
    if !cancellingComposition && !text.isEmpty { send(text) }
    redraw()
  }
  private func cancelComposition() {
    guard !cancellingComposition else { return }
    cancellingComposition = true
    composition.clear()
    inputContext?.discardMarkedText()
    cancellingComposition = false
    inputContext?.invalidateCharacterCoordinates()
    redraw()
  }
  var preeditPresentation: PreeditPresentation? {
    guard hasMarkedText(), let snapshot else { return nil }
    if let cache = preeditCache, cache.revision == composition.revision,
      cache.columns == snapshot.cols, cache.rows == snapshot.rows.count,
      cache.row == snapshot.cursor.row, cache.column == snapshot.cursor.col { return cache.value }
    let value = PreeditPresentation(text: composition.text, selection: composition.selection,
      columns: snapshot.cols, rows: snapshot.rows.count,
      cursorRow: snapshot.cursor.row, cursorColumn: snapshot.cursor.col)
    preeditCache = (composition.revision, snapshot.cols, snapshot.rows.count,
      snapshot.cursor.row, snapshot.cursor.col, value)
    return value
  }
  public func hasMarkedText() -> Bool { composition.hasText }
  public func markedRange() -> NSRange {
    hasMarkedText()
      ? NSRange(location: 0, length: composition.text.length) : NSRange(location: NSNotFound, length: 0)
  }
  public func selectedRange() -> NSRange { composition.selection }
  public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.underlineStyle, .markedClauseSegment]
  }
  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
    guard hasMarkedText(), range.location != NSNotFound, range.location >= 0,
      range.length >= 0, range.location <= composition.text.length else { return nil }
    let r = NSRange(location: range.location, length: min(range.length, composition.text.length - range.location))
    actualRange?.pointee = r
    return composition.text.attributedSubstring(from: r)
  }
  public func characterIndex(for point: NSPoint) -> Int {
    guard let window, let preedit = preeditPresentation else { return NSNotFound }
    let local = convert(window.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
    guard bounds.contains(local) else { return NSNotFound }
    let row = presentationGeometry.row(at: local.y * scale)
    return preedit.characterIndex(row: row,
      column: Double((local.x * scale - CGFloat(insetPixels)) / CGFloat(cellWidth)))
  }
  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
    let cursor = snapshot?.cursor
    let segment = preeditPresentation?.firstSegment(for: range)
    guard !hasMarkedText() || segment != nil else { return .zero }
    guard hasMarkedText() || range == NSRange(location: 0, length: 0) else { return .zero }
    actualRange?.pointee = segment?.range ?? NSRange(location: 0, length: 0)
    let pixels = presentationGeometry.rect(row: segment?.row ?? cursor?.row ?? 0,
      column: segment?.column ?? cursor?.col ?? 0, cells: max(1, segment?.cells ?? 1))
    let rect = NSRect(x: pixels.minX / scale, y: pixels.minY / scale,
      width: pixels.width / scale, height: pixels.height / scale)
    return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
  }
  public override func doCommand(by selector: Selector) {
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
    let row = max(0, min(value.rows.count - 1, presentationGeometry.row(at: p.y * scale)))
    let col = max(
      0, min(value.cols - 1, Int((p.x * scale - CGFloat(insetPixels)) / CGFloat(cellWidth))))
    return row * value.cols + col
  }
  private func selectionHit(_ event: NSEvent) -> TerminalSelectionHit? {
    guard let value = presentationSnapshot, value.cols > 0, !value.rows.isEmpty else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    let row = max(0, min(value.rows.count - 1, presentationGeometry.row(at: point.y * scale)))
    let boundary = max(0, min(value.cols,
      Int((point.x * scale - CGFloat(insetPixels)) / CGFloat(cellWidth))))
    return value.selectionHit(row: row, boundary: boundary)
  }
  public override func mouseDown(with event: NSEvent) {
    compositionMousePress = false
    localLinkPress = false
    dragging = false
    window?.makeFirstResponder(self)
    activatingPress = activatingClick == event.eventNumber
    activatingClick = nil
    // Neither select nor report the activating click to the terminal program.
    if activatingPress { return }
    if hasMarkedText() {
      // The input source gets first refusal for clause/caret clicks.
      if inputContext?.handleEvent(event) == true { compositionMousePress = true; return }
      cancelComposition()
    }
    if event.clickCount == 1, event.modifierFlags.contains(.command),
      let occurrence = linkOccurrence(locationInWindow: event.locationInWindow) {
      // Resolve against the displayed generation at the user gesture; a
      // previously hovered or cached target never drives activation.
      dragging = false
      localLinkPress = true
      guard let activation = occurrence.activation else {
        showSelectionNotice(.staleTarget)
        return
      }
      _ = activateLink(activation)
      return
    }
    if reportMouse(event, button: 0, release: false) { return }
    guard let hit = selectionHit(event) else { return }
    let granularity: TerminalSelectionGranularity = event.modifierFlags.contains(.option)
      ? .rectangular : event.clickCount >= 3 ? .line : event.clickCount == 2 ? .word : .character
    dragging = requestSelection(.begin(hit, granularity: granularity))
  }
  public override func mouseDragged(with event: NSEvent) {
    if compositionMousePress { _ = inputContext?.handleEvent(event); return }
    if localLinkPress || activatingPress { return }
    if dragging {
      if let hit = selectionHit(event) { requestSelection(.extend(hit)) }
    } else { _ = reportMouse(event, button: 32, release: false) }
  }
  public override func mouseUp(with event: NSEvent) {
    if compositionMousePress {
      compositionMousePress = false
      _ = inputContext?.handleEvent(event)
      return
    }
    if activatingPress { activatingPress = false; return }
    if localLinkPress { localLinkPress = false; return }
    if dragging {
      dragging = false
      requestSelection(.commit)
    } else { _ = reportMouse(event, button: 0, release: true) }
  }
  /// The context menu as the host has left it.
  func contextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Previous Command", action: #selector(previousCommand(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Next Command", action: #selector(nextCommand(_:)), keyEquivalent: "")
    onContextMenu?(menu)
    return menu
  }
  @objc public func previousCommand(_ sender: Any?) { session.navigateCommand(older: true) }
  @objc public func nextCommand(_ sender: Any?) { session.navigateCommand(older: false) }
  /// Hands a validated link to the host, or opens it. Returns whether the
  /// view opened it itself.
  @discardableResult func open(_ target: URL) -> Bool {
    if onOpenLink?(target) == true { return false }
    NSWorkspace.shared.open(target)
    return true
  }
  public override func rightMouseDown(with event: NSEvent) {
    if !reportMouse(event, button: 2, release: false) {
      NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }
  }
  public override func rightMouseUp(with event: NSEvent) {
    _ = reportMouse(event, button: 2, release: true)
  }
  public override func rightMouseDragged(with event: NSEvent) {
    _ = reportMouse(event, button: 34, release: false)
  }
  public override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 { _ = reportMouse(event, button: 1, release: false) }
  }
  public override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 { _ = reportMouse(event, button: 1, release: true) }
  }
  public override func otherMouseDragged(with event: NSEvent) {
    if event.buttonNumber == 2 { _ = reportMouse(event, button: 33, release: false) }
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
    let point = convert(event.locationInWindow, from: nil)
    let pixels = NativeMouseCoordinates.position(point, scale: scale, inset: insetPixels,
      width: value.cols * cellWidth, height: value.rows.count * cellHeight)
    let encoding = value.modes.mouse_encoding ?? (value.modes.sgr_mouse ? 1006 : 0)
    session.rawInput(TerminalMouseEncoder.encode(button: button, release: release, modifiers: modifier,
      column: x, row: y, pixelX: pixels.x, pixelY: pixels.y, encoding: encoding, x10: value.modes.mouse == 9))
    return true
  }
  public override func scrollWheel(with event: NSEvent) {
    guard let value = snapshot else { return }
    if event.hasPreciseScrollingDeltas, !value.alternate, value.rows.count < 4096,
      value.modes.mouse == 0 || event.modifierFlags.contains(.shift) {
      let lines = viewportPresentation.scroll(delta: event.scrollingDeltaY,
        lineHeight: CGFloat(cellHeight) / scale, maximum: value.history_rows)
      if lines != 0 {
        pendingViewportAnchor = viewportPresentation.anchor
        session.scroll(lines)
      } else {
        accessible = AccessibilityProjection(snapshot: presentationSnapshot ?? value)
        updateLinkHoverForCurrentPointer(modifiers: event.modifierFlags)
        redraw()
      }
      return
    }
    viewportPresentation.reset(offset: value.scroll_offset)
    pendingViewportAnchor = nil
    accessible = AccessibilityProjection(snapshot: value)
    redraw()
    let lines = scrollAccumulator.lines(for: event, lineHeight: CGFloat(cellHeight) / scale)
    guard lines != 0 else { return }
    if value.modes.mouse != 0 && !event.modifierFlags.contains(.shift) {
      for _ in 0..<abs(lines) {
        _ = reportMouse(event, button: lines > 0 ? 64 : 65, release: false)
      }
    } else {
      session.scroll(lines)
    }
  }
  /// Whether text is selected.
  public var hasSelection: Bool { snapshot.map { $0.selection.phase != .none } ?? false }
  /// The selected text, as Copy would put it on the pasteboard. Gives nil
  /// when nothing is selected or the selection changed before it was read.
  public func selectedText(_ completion: @escaping @MainActor (String?) -> Void) {
    guard let value = snapshot, value.selection.phase != .none else { return completion(nil) }
    let admitted = session.selection(.copy(expectedSelectionRevision: value.selection.revision)) { result in
      completion((try? result.get()) ?? nil)
    }
    if !admitted { completion(nil) }
  }
  /// Removes the selection.
  public func clearSelection() { _ = session.selection(.clear) }
  @objc public func copy(_ sender: Any?) {
    guard let value = snapshot, value.selection.phase != .none, let clipboard else { return }
    clipboard.copy(from: session, selectionRevision: value.selection.revision)
  }
  /// Copy is offered only when there is a selection to copy.
  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard item.action == #selector(copy(_:)) else { return true }
    return snapshot.map { $0.selection.phase != .none } ?? false
  }
  /// Stops a paste that is still being delivered.
  @objc public func cancelPaste(_ sender: Any?) { session.cancelPaste() }
  /// Clears the display, keeping the prompt being edited.
  @objc public func clearScreen(_ sender: Any?) {
    session.clearDisplay()
  }
  /// Pastes the general pasteboard's text.
  @objc public func paste(_ sender: Any?) {
    if let text = NSPasteboard.general.string(forType: .string) { send(text, key: 1) }
  }
  public override func selectAll(_ sender: Any?) {
    guard let value = snapshot,
      let start = value.selectionHit(row: 0, boundary: 0),
      let end = value.selectionHit(row: value.rows.count - 1, boundary: value.cols)
    else { return }
    requestSelection(.range(start: start, end: end, mode: .linear))
  }
  /// Automation submits the same immutable displayed-row proof as a gesture.
  @discardableResult package func selectVisibleText(
    fromRow: Int, fromColumn: Int, toRow: Int, toColumn: Int
  ) -> Bool {
    guard let value = snapshot,
      let start = value.selectionHit(row: fromRow, boundary: fromColumn),
      let end = value.selectionHit(row: toRow, boundary: toColumn) else { return false }
    return requestSelection(.range(start: start, end: end, mode: .linear))
  }
  @objc package func increaseFont(_ sender: Any?) {
    fontPoints = min(40, fontPoints + 1)
    updateGeometry()
  }
  @objc package func decreaseFont(_ sender: Any?) {
    fontPoints = max(8, fontPoints - 1)
    updateGeometry()
  }
  @objc package func resetFont(_ sender: Any?) {
    fontPoints = 14
    updateGeometry()
  }
  /// Gives the view a find bar, which the Find actions then open. The host
  /// owns the bar's place in the layout: add it as a sibling over the top
  /// edge of this view, `TerminalFindBar.height` tall. It hides itself.
  public func attach(findBar: TerminalFindBar) {
    self.findBar = findBar
    findBar.apply(TerminalChromeColors(configuration.session.colors))
    findBar.onQuery = { [weak self] query in self?.runFind(query) }
    findBar.onStep = { [weak self] older in self?.stepFind(older: older) }
    findBar.onClose = { [weak self] in self?.closeFind() }
  }
  /// Opens the attached find bar. Without one, nothing happens; a host with
  /// its own search interface calls `TerminalSession.search` instead.
  @objc public func find(_ sender: Any?) {
    guard let findBar else { return }
    let reopening = findBar.isHidden
    findBar.open()
    // Closing cleared the decorations; an earlier query is searched again.
    if reopening { runFind(findBar.query) }
  }
  @objc public func findNext(_ sender: Any?) { stepFind(older: true) }
  @objc public func findPrevious(_ sender: Any?) { stepFind(older: false) }
  private func runFind(_ query: String) {
    findGeneration += 1
    guard let findBar else { return }
    guard !query.isEmpty else {
      findPending = false
      session.searchClear()
      findBar.show(.idle)
      return
    }
    let generation = findGeneration
    findPending = true
    findBar.show(.searching)
    session.search(query, options: findBar.options) { [weak self] outcome, position in
      guard let self, self.findGeneration == generation, let findBar = self.findBar else { return }
      self.findPending = false
      switch outcome {
      case .found:
        if let position {
          findBar.show(.matches(index: position.index, total: position.total, capped: position.capped))
        } else { findBar.show(.noMatches) }
      case .missing: findBar.show(.noMatches)
      // A newer query or a close already owns the label.
      case .cancelled: break
      case .changed: findBar.show(.failed("Output changed"))
      case .invalidQuery: findBar.show(.failed("Invalid search expression"))
      case .resourceLimit: findBar.show(.failed("Search limit exceeded"))
      }
    }
  }
  private func stepFind(older: Bool) {
    guard let findBar else { return }
    if findBar.isHidden { find(nil); return }
    let query = findBar.query
    // Return during a running search waits for it instead of restarting it.
    guard !query.isEmpty, !findPending else { return }
    // Without an accepted match set there is nothing to step through; this
    // also picks up output that arrived after a search found nothing.
    guard case .matches = findBar.result else { runFind(query); return }
    let generation = findGeneration
    session.searchNavigate(older: older) { [weak self] position in
      guard let self, self.findGeneration == generation, let findBar = self.findBar else { return }
      if let position {
        findBar.show(.matches(index: position.index, total: position.total, capped: position.capped))
      } else {
        // Every retained match was overwritten or evicted; search afresh.
        self.runFind(query)
      }
    }
  }
  private func closeFind() {
    findGeneration += 1
    findPending = false
    session.searchClear()
    findBar?.dismiss()
    window?.makeFirstResponder(self)
  }
  public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
#endif

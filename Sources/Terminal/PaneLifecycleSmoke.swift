import AppKit
import QuartzCore

/// Exercises nested pane structural edits and their minimum-size invariants.
/// It owns only explicit `/bin/sh` sessions and stores geometry—not terminal
/// output—in its report.
@MainActor final class PaneLifecycleSmokeTest {
  private static var active: PaneLifecycleSmokeTest?

  private let controller: TerminalWindow
  private let path: String
  private var top: TerminalCanvasView?
  private var right: TerminalCanvasView?
  private var bottom: TerminalCanvasView?
  private var narrowLeaf: TerminalCanvasView?
  private var nestedLeaves: [NSView] = []
  private var resizeBaseline: NSSize?
  private var before: Geometry?
  private var after: Geometry?
  private var observedTitles: [ObjectIdentifier: String] = [:]
  private var backgroundSessionFinished = false
  private var presentationPreferencesBeforeToggle: TerminalPreferences?
  private var titlesOffMinimum = NSSize.zero
  private var finished = false
  private var focusThief: NSWindow?

  init(window: TerminalWindow, path: String) {
    controller = window
    self.path = path
  }

  static func start(window: TerminalWindow, path: String) {
    let test = PaneLifecycleSmokeTest(window: window, path: path)
    active = test
    test.schedule(.initial)
  }

  /// One structural operation per turn keeps the smoke observable if AppKit
  /// defers a layout transaction; it also avoids forcing a renderer display.
  private enum Step: String {
    case initial, titleSetup, waitForInactiveTitle, waitForActiveTitle, waitForBackgroundTitle
    case waitForBackgroundExit, deactivateWindow, clickInactivePane, verifyInactiveClick, nest, position, closeRight, verifyPromotion, resplit, verifyResplit
    case headersOff, headersOn, verifyHeadersOn
    case prepareNarrowLeaf, positionNarrowLeaf, splitNarrowLeaf, verifyNarrowLeaf
    case resizeNarrowSmaller, verifyNarrowSmaller, resizeNarrowLarger, verifyNarrowLarger
  }

  private func schedule(_ step: Step) {
    DispatchQueue.main.async { [weak self] in self?.advance(step) }
  }

  private func advance(_ step: Step) {
    guard !finished else { return }
    breadcrumb(step)
    switch step {
    case .initial:
      guard let window = controller.window, let initial = controller.panes.first else {
        return finish(error: "missing initial pane")
      }
      top = initial
      window.makeFirstResponder(initial)
      controller.splitVertical(nil)
      guard controller.panes.count == 2 else {
        return finish(error: "vertical split did not create right pane")
      }
      right = controller.panes.last
      schedule(.titleSetup)

    case .titleSetup:
      guard let top, let right else { return finish(error: "missing panes for title ownership") }
      observeTitle(top)
      observeTitle(right)
      let originalStatus = right.onStatus
      right.onStatus = { [weak self] text in
        originalStatus?(text)
        if text == "Session finished" { self?.backgroundSessionFinished = true }
      }
      emitTitle("inactive-left", to: top)
      waitFor(.waitForInactiveTitle) { [weak self] in
        self?.observedTitles[ObjectIdentifier(top)] == "inactive-left"
      }

    case .waitForInactiveTitle:
      guard let window = controller.window, let right else {
        return finish(error: "missing window while checking inactive title")
      }
      guard window.title == "Terminal" else {
        return finish(error: "inactive pane published its title", extra: ["window_title": window.title])
      }
      emitTitle("active-right", to: right)
      waitFor(.waitForActiveTitle) { [weak self] in
        self?.observedTitles[ObjectIdentifier(right)] == "active-right" && window.title == "active-right"
      }

    case .waitForActiveTitle:
      guard let window = controller.window, let top else {
        return finish(error: "missing panes while checking active title")
      }
      guard window.title == "active-right" else {
        return finish(error: "active pane title was not published", extra: ["window_title": window.title])
      }
      emitTitle("background-left", to: top)
      waitFor(.waitForBackgroundTitle) { [weak self] in
        self?.observedTitles[ObjectIdentifier(top)] == "background-left"
      }

    case .waitForBackgroundTitle:
      guard let window = controller.window, let top, let right else {
        return finish(error: "missing panes while checking background title")
      }
      guard window.title == "active-right" else {
        return finish(error: "background pane overwrote active title", extra: ["window_title": window.title])
      }
      window.makeFirstResponder(top)
      guard window.title == "background-left" else {
        return finish(error: "focus change did not restore cached pane title",
          extra: ["window_title": window.title])
      }
      right.session.statistics { [weak self] statistics in
        guard let self, let pid = statistics["child_pid"] as? Int32, pid > 0 else {
          self?.finish(error: "missing background session pid")
          return
        }
        if Darwin.kill(pid, SIGTERM) != 0 {
          self.finish(error: "could not terminate background session")
          return
        }
        self.waitFor(.waitForBackgroundExit) { [weak self] in self?.backgroundSessionFinished == true }
      }

    case .waitForBackgroundExit:
      guard let window = controller.window else { return finish(error: "window disappeared after background exit") }
      guard window.title == "background-left" else {
        return finish(error: "background session exit overwrote active title",
          extra: ["window_title": window.title])
      }
      schedule(.deactivateWindow)

    case .deactivateWindow:
      guard let window = controller.window, let top else {
        return finish(error: "missing panes before inactive-window click")
      }
      // Focus the left pane, then move key status to another window: the
      // terminal window keeps `top` as its first responder while unfocused.
      window.makeFirstResponder(top)
      let thief = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
        styleMask: [.titled], backing: .buffered, defer: false)
      thief.isReleasedWhenClosed = false
      thief.makeKeyAndOrderFront(nil)
      focusThief = thief
      waitFor(.clickInactivePane) { !window.isKeyWindow }

    case .clickInactivePane:
      guard let window = controller.window, let top, let right else {
        return finish(error: "missing panes for inactive-window click")
      }
      guard !window.isKeyWindow, window.firstResponder === top else {
        return finish(error: "inactive-window click fixture did not deactivate the window",
          extra: ["key": window.isKeyWindow, "top_focused": window.firstResponder === top])
      }
      // The first click on a non-key window goes through NSWindow.sendEvent,
      // which consults acceptsFirstMouse before delivering mouseDown.
      let point = right.convert(NSPoint(x: right.bounds.midX, y: right.bounds.midY), to: nil)
      for (type, number) in [(NSEvent.EventType.leftMouseDown, 9_001), (.leftMouseUp, 9_002)] {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        else { return finish(error: "could not synthesize inactive-window click") }
        window.sendEvent(event)
      }
      waitFor(.verifyInactiveClick) { window.firstResponder === right }

    case .verifyInactiveClick:
      guard let window = controller.window, let right else {
        return finish(error: "missing panes after inactive-window click")
      }
      focusThief?.close()
      focusThief = nil
      guard window.firstResponder === right else {
        return finish(error: "first click on an unfocused window did not focus the clicked pane")
      }
      schedule(.nest)

    case .nest:
      guard let window = controller.window, let top else {
        return finish(error: "missing pane while building nested layout")
      }
      window.makeFirstResponder(top)
      controller.splitHorizontal(nil)
      guard controller.panes.count == 3 else {
        return finish(error: "horizontal split did not create bottom pane")
      }
      bottom = controller.panes.last
      schedule(.position)

    case .position:
      guard let window = controller.window, let top, let right, let bottom,
        let inner = panePresentation(top)?.superview as? NSSplitView,
        let outer = inner.superview as? NSSplitView,
        let rightPresentation = panePresentation(right),
        outer.arrangedSubviews.contains(where: { $0 === rightPresentation })
      else { return finish(error: "nested split topology was not created") }
      // First establish valid tiling, then emulate asymmetric user drags.
      // NSSplitView's divider constraints require valid child frames.
      settle(window)
      outer.setPosition(outer.bounds.width * 0.61, ofDividerAt: 0)
      outer.adjustSubviews()
      inner.setPosition(inner.bounds.height * 0.63, ofDividerAt: 0)
      inner.adjustSubviews()
      settle(window)
      before = Geometry(top: top, bottom: bottom, in: window)
      guard before?.isValid == true else {
        return finish(error: "invalid pre-close nested geometry")
      }
      schedule(.closeRight)

    case .closeRight:
      guard let window = controller.window, let right else {
        return finish(error: "missing spanning right pane")
      }
      window.makeFirstResponder(right)
      controller.closePane(nil)
      schedule(.verifyPromotion)

    case .verifyPromotion:
      guard let window = controller.window, let top, let bottom, let before else {
        return finish(error: "missing promoted nested panes")
      }
      settle(window)
      let after = Geometry(top: top, bottom: bottom, in: window)
      self.after = after
      guard after.isValid else { return finish(error: "invalid promoted geometry") }
      guard abs(before.heightRatio - after.heightRatio) <= 0.02,
        abs(before.topHeight - after.topHeight) <= 1,
        abs(before.bottomHeight - after.bottomHeight) <= 1
      else { return finish(error: "promotion changed nested split heights") }
      schedule(.resplit)

    case .resplit:
      guard let window = controller.window, let top else {
        return finish(error: "missing top pane for re-split")
      }
      // Match the real driver: it creates a second horizontal split after
      // closing the right-spanning pane, exercising nested height minima.
      window.makeFirstResponder(top)
      controller.splitHorizontal(nil)
      schedule(.verifyResplit)

    case .verifyResplit:
      guard let window = controller.window else { return finish(error: "missing window after re-split") }
      settle(window)
      let panes = controller.panes
      let leafFrames = panes.map { $0.convert($0.bounds, to: window.contentView) }
      let distinctIDs = Set(panes.map(ObjectIdentifier.init)).count == panes.count
      let attached = panes.allSatisfy { $0.window === window && $0.isAccessibilityElement() }
      let visible = leafFrames.allSatisfy { $0.width >= 100 && $0.height >= 60 }
      let nonOverlapping = !leafFrames.enumerated().contains { index, frame in
        leafFrames.dropFirst(index + 1).contains {
          frame.intersection($0).width > 1 && frame.intersection($0).height > 1
        }
      }
      guard panes.count == 3, distinctIDs, attached, visible, nonOverlapping else {
        return finish(error: "re-split did not leave three visible terminal panes",
          extra: ["leaf_frames": leafFrames.map(NSStringFromRect), "distinct_ids": distinctIDs,
            "attached": attached, "visible": visible, "non_overlapping": nonOverlapping])
      }
      schedule(.headersOff)

    case .headersOff:
      guard let window = controller.window else { return finish(error: "window disappeared while hiding pane titles") }
      presentationPreferencesBeforeToggle = TerminalPreferences.load()
      controller.applyPanePresentationPreferences(presentationPreferences(showTitles: false))
      settle(window)
      titlesOffMinimum = window.contentMinSize
      guard paneViewportGeometry(headersVisible: false) else {
        return finish(error: "hiding pane titles did not restore full terminal viewports",
          extra: presentationEvidence(in: window))
      }
      schedule(.headersOn)

    case .headersOn:
      controller.applyPanePresentationPreferences(presentationPreferences(showTitles: true))
      schedule(.verifyHeadersOn)

    case .verifyHeadersOn:
      guard let window = controller.window else { return finish(error: "window disappeared while showing pane titles") }
      settle(window)
      guard window.contentMinSize.height > titlesOffMinimum.height + 0.5,
        paneViewportGeometry(headersVisible: true)
      else {
        return finish(error: "showing pane titles left stale pane minimums or Metal viewports",
          extra: presentationEvidence(in: window))
      }
      if let presentationPreferencesBeforeToggle {
        controller.applyPanePresentationPreferences(presentationPreferencesBeforeToggle)
      }
      schedule(.prepareNarrowLeaf)

    case .prepareNarrowLeaf:
      guard let window = controller.window, let bottom else {
        return finish(error: "missing pane while resetting narrow-leaf fixture")
      }
      // Reuse the same benign session, retaining the bottom leaf while closing
      // the other two from the first scenario.  One close per turn preserves
      // the real structural code path rather than swapping in a test double.
      if controller.panes.count > 1,
        let other = controller.panes.first(where: { $0 !== bottom })
      {
        window.makeFirstResponder(other)
        controller.closePane(nil)
        return schedule(.prepareNarrowLeaf)
      }
      guard controller.panes.count == 1, controller.panes.first === bottom else {
        return finish(error: "could not retain narrow-leaf fixture pane")
      }
      narrowLeaf = bottom
      window.makeFirstResponder(bottom)
      controller.splitHorizontal(nil)
      schedule(.positionNarrowLeaf)

    case .positionNarrowLeaf:
      guard let window = controller.window, let narrowLeaf,
        let narrowPresentation = panePresentation(narrowLeaf),
        let outer = narrowPresentation.superview as? NSSplitView
      else { return finish(error: "missing outer split for narrow leaf") }
      settle(window)
      let minimumLeafHeight = narrowPresentation.minimumSize.height
      outer.setPosition(minimumLeafHeight, ofDividerAt: 0)
      outer.adjustSubviews()
      settle(window)
      guard abs(narrowPresentation.frame.height - minimumLeafHeight) <= 1,
        abs(narrowLeaf.frame.height - TerminalPanePresentationView.terminalMinimum.height) <= 1
      else {
        return finish(error: "could not create minimum-height leaf",
          extra: ["narrow_leaf_height": narrowLeaf.frame.height,
            "presentation_height": narrowPresentation.frame.height])
      }
      schedule(.splitNarrowLeaf)

    case .splitNarrowLeaf:
      guard let window = controller.window, let narrowLeaf else {
        return finish(error: "missing narrow leaf before split")
      }
      window.makeFirstResponder(narrowLeaf)
      controller.splitHorizontal(nil)
      schedule(.verifyNarrowLeaf)

    case .verifyNarrowLeaf:
      guard let window = controller.window, let narrowLeaf,
        let inner = panePresentation(narrowLeaf)?.superview as? NSSplitView,
        inner.arrangedSubviews.count == 2
      else { return finish(error: "narrow leaf did not split") }
      settle(window)
      let leafFrames = inner.arrangedSubviews.map { $0.convert($0.bounds, to: window.contentView) }
      let expectedMinimum = inner.arrangedSubviews.reduce(CGFloat(0)) {
        $0 + (($1 as? TerminalPanePresentationView)?.minimumSize.height ?? 120)
      } + inner.dividerThickness
      let enoughRoom = (window.contentView?.bounds.height ?? 0) >= expectedMinimum + 120
      let leavesVisible = zip(inner.arrangedSubviews, leafFrames).allSatisfy { view, frame in
        let minimum = (view as? TerminalPanePresentationView)?.minimumSize ?? NSSize(width: 200, height: 120)
        return frame.height >= minimum.height && frame.width >= minimum.width
      }
      guard enoughRoom, inner.frame.height >= expectedMinimum, leavesVisible else {
        return finish(error: "ancestor did not redistribute room for nested leaf minimum",
          extra: ["nested_height": inner.frame.height, "nested_minimum": expectedMinimum,
            "window_height": window.contentView?.bounds.height ?? 0,
            "leaf_frames": leafFrames.map(NSStringFromRect), "leaves_visible": leavesVisible])
      }
      nestedLeaves = inner.arrangedSubviews
      resizeBaseline = window.contentView?.bounds.size
      schedule(.resizeNarrowSmaller)

    case .resizeNarrowSmaller:
      guard let window = controller.window, let baseline = resizeBaseline else {
        return finish(error: "missing window resize baseline")
      }
      // Both dimensions remain above the recursively computed 200×362 root
      // minimum. A real corner resize used to leave a nested leaf at 110pt.
      window.setContentSize(NSSize(
        width: max(600, baseline.width * 0.72), height: max(420, baseline.height * 0.64)))
      schedule(.verifyNarrowSmaller)

    case .verifyNarrowSmaller:
      guard let window = controller.window else { return finish(error: "window disappeared after shrink") }
      settle(window)
      guard verifyResizedLeaves(in: window) else {
        return finish(error: "window shrink violated nested leaf minimum", extra: resizeEvidence(in: window))
      }
      schedule(.resizeNarrowLarger)

    case .resizeNarrowLarger:
      guard let window = controller.window, let baseline = resizeBaseline else {
        return finish(error: "missing window resize baseline before grow")
      }
      window.setContentSize(baseline)
      schedule(.verifyNarrowLarger)

    case .verifyNarrowLarger:
      guard let window = controller.window else { return finish(error: "window disappeared after grow") }
      settle(window)
      guard verifyResizedLeaves(in: window) else {
        return finish(error: "window grow violated nested leaf minimum", extra: resizeEvidence(in: window))
      }
      finish(error: nil, extra: resizeEvidence(in: window))
    }
  }

  private func settle(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func panePresentation(_ pane: TerminalCanvasView) -> TerminalPanePresentationView? {
    pane.superview as? TerminalPanePresentationView
  }

  private func presentationPreferences(showTitles: Bool) -> TerminalPreferences {
    let current = presentationPreferencesBeforeToggle ?? TerminalPreferences.load()
    return TerminalPreferences(fontSize: current.fontSize, historyRows: current.historyRows,
      optionSendsEscape: current.optionSendsEscape, followTailOnInput: current.followTailOnInput,
      startingDirectory: current.startingDirectory, selectionWordProfile: current.selectionWordProfile,
      showPaneTitles: showTitles, inactivePaneDim: current.inactivePaneDim,
      defaultPaneColor: current.defaultPaneColor, sidePulseEnabled: current.sidePulseEnabled)
  }

  /// Assert that the canvas—the CAMetalLayer owner—received the reduced frame,
  /// rather than merely being covered by a header. This catches stretching when
  /// a split is resized while pane chrome changes.
  private func paneViewportGeometry(headersVisible: Bool) -> Bool {
    controller.panes.allSatisfy { pane in
      guard let presentation = panePresentation(pane), let layer = pane.layer as? CAMetalLayer,
        let window = pane.window
      else { return false }
      let expectedHeader = headersVisible ? TerminalPanePresentationView.headerHeight : 0
      let scale = window.backingScaleFactor
      return abs(pane.frame.minY - expectedHeader) <= 1
        && abs(pane.frame.height - (presentation.bounds.height - expectedHeader)) <= 1
        && pane.bounds.height >= TerminalPanePresentationView.terminalMinimum.height
        && abs(layer.drawableSize.width - pane.bounds.width * scale) <= 1
        && abs(layer.drawableSize.height - pane.bounds.height * scale) <= 1
    }
  }

  private func presentationEvidence(in window: NSWindow) -> [String: Any] {
    ["content_minimum": NSStringFromSize(window.contentMinSize),
      "panes": controller.panes.map { pane in
        ["canvas_frame": NSStringFromRect(pane.frame), "canvas_bounds": NSStringFromRect(pane.bounds),
          "presentation_frame": NSStringFromRect(panePresentation(pane)?.frame ?? .zero),
          "drawable_size": NSStringFromSize((pane.layer as? CAMetalLayer)?.drawableSize ?? .zero)]
      }]
  }

  private func observeTitle(_ pane: TerminalCanvasView) {
    let original = pane.onTitle
    let identifier = ObjectIdentifier(pane)
    pane.onTitle = { [weak self] title in
      original?(title)
      self?.observedTitles[identifier] = title
    }
  }

  private func emitTitle(_ title: String, to pane: TerminalCanvasView) {
    pane.session.rawInput(Data("\u{1B}]2;\(title)\u{07}".utf8))
  }

  private func waitFor(_ step: Step, attempts: Int = 0, _ condition: @escaping () -> Bool) {
    if condition() { return schedule(step) }
    guard attempts < 100 else { return finish(error: "timed out waiting for \(step.rawValue)") }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
      self?.waitFor(step, attempts: attempts + 1, condition)
    }
  }

  private func breadcrumb(_ step: Step) {
    write(["passed": false, "phase": step.rawValue, "before": before?.dictionary ?? NSNull(),
      "after": after?.dictionary ?? NSNull()])
  }

  private func finish(error: String?, extra: [String: Any] = [:]) {
    guard !finished else { return }
    finished = true
    var report: [String: Any] = [
      "passed": error == nil, "phase": "finished", "error": error ?? NSNull(),
      "before": before?.dictionary ?? NSNull(), "after": after?.dictionary ?? NSNull(),
    ]
    for (key, value) in extra { report[key] = value }
    write(report)
    controller.close()
    NSApp.terminate(nil)
  }

  private func write(_ report: [String: Any]) {
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
      NSLog("Pane lifecycle diagnostic write failed: %@", String(describing: error))
    }
  }

  private func verifyResizedLeaves(in window: NSWindow) -> Bool {
    let panes = controller.panes
    let contentBounds = window.contentView?.bounds ?? .zero
    let frames = panes.map { $0.convert($0.bounds, to: window.contentView) }
    let nonOverlapping = !frames.enumerated().contains { index, frame in
      frames.dropFirst(index + 1).contains {
        frame.intersection($0).width > 1 && frame.intersection($0).height > 1
      }
    }
    return nestedLeaves.count == 2
      && nestedLeaves.allSatisfy { view in
        let minimum = (view as? TerminalPanePresentationView)?.minimumSize ?? NSSize(width: 200, height: 120)
        return view.window === window && view.convert(view.bounds, to: window.contentView).height >= minimum.height
      }
      && panes.count == 3
      && panes.allSatisfy { $0.window === window }
      && frames.allSatisfy { $0.width >= 200 && $0.height >= 120 && contentBounds.contains($0) }
      && nonOverlapping
  }

  private func resizeEvidence(in window: NSWindow) -> [String: Any] {
    [
      "resized_leaf_frames": nestedLeaves.map {
        NSStringFromRect($0.convert($0.bounds, to: window.contentView))
      },
      "all_pane_frames": controller.panes.map {
        NSStringFromRect($0.convert($0.bounds, to: window.contentView))
      },
      "content_size": NSStringFromSize(window.contentView?.bounds.size ?? .zero),
    ]
  }

  @MainActor private struct Geometry {
    let top: NSRect
    let bottom: NSRect

    init(top: TerminalCanvasView, bottom: TerminalCanvasView, in window: NSWindow) {
      self.top = top.convert(top.bounds, to: window.contentView)
      self.bottom = bottom.convert(bottom.bounds, to: window.contentView)
    }

    var topHeight: CGFloat { top.height }
    var bottomHeight: CGFloat { bottom.height }
    var heightRatio: CGFloat { top.height / (top.height + bottom.height) }
    var isValid: Bool {
      top.width >= 100 && bottom.width >= 100 && top.height >= 60 && bottom.height >= 60
        && top.intersection(bottom).isEmpty
    }
    var dictionary: [String: Any] {
      ["top": NSStringFromRect(top), "bottom": NSStringFromRect(bottom),
        "top_height": topHeight, "bottom_height": bottomHeight, "height_ratio": heightRatio]
    }
  }
}

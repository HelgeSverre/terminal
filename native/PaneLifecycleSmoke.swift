import AppKit

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
  private var before: Geometry?
  private var after: Geometry?
  private var finished = false

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
    case initial, nest, position, closeRight, verifyPromotion, resplit, verifyResplit
    case prepareNarrowLeaf, positionNarrowLeaf, splitNarrowLeaf, verifyNarrowLeaf
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
        let inner = top.superview as? NSSplitView,
        let outer = inner.superview as? NSSplitView,
        outer.arrangedSubviews.contains(where: { $0 === right })
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
        let outer = narrowLeaf.superview as? NSSplitView
      else { return finish(error: "missing outer split for narrow leaf") }
      settle(window)
      let minimumLeafHeight: CGFloat = 120
      outer.setPosition(minimumLeafHeight, ofDividerAt: 0)
      outer.adjustSubviews()
      settle(window)
      guard abs(narrowLeaf.frame.height - minimumLeafHeight) <= 1 else {
        return finish(error: "could not create minimum-height leaf",
          extra: ["narrow_leaf_height": narrowLeaf.frame.height])
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
        let inner = narrowLeaf.superview as? NSSplitView,
        inner.arrangedSubviews.count == 2
      else { return finish(error: "narrow leaf did not split") }
      settle(window)
      let leafFrames = inner.arrangedSubviews.map { $0.convert($0.bounds, to: window.contentView) }
      let expectedMinimum = CGFloat(120 * 2) + inner.dividerThickness
      let enoughRoom = (window.contentView?.bounds.height ?? 0) >= expectedMinimum + 120
      let leavesVisible = leafFrames.allSatisfy { $0.height >= 120 && $0.width >= 200 }
      guard enoughRoom, inner.frame.height >= expectedMinimum, leavesVisible else {
        return finish(error: "ancestor did not redistribute room for nested leaf minimum",
          extra: ["nested_height": inner.frame.height, "nested_minimum": expectedMinimum,
            "window_height": window.contentView?.bounds.height ?? 0,
            "leaf_frames": leafFrames.map(NSStringFromRect), "leaves_visible": leavesVisible])
      }
      finish(error: nil, extra: ["leaf_frames": leafFrames.map(NSStringFromRect)])
    }
  }

  private func settle(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
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

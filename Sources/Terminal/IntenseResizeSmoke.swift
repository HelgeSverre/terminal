import AppKit

/// Resizes a window of streaming panes hard, in both directions.
///
/// Every pane runs `SmokeStream`. A seeded schedule then moves dividers of
/// the vertical and the horizontal splits and resizes the window itself,
/// without waiting for any pane to catch up. The schedule is fixed by the
/// seed; how it interleaves with the streams is not.
///
/// Checked on every snapshot a pane presents, during and after the resizes:
/// the numbered lines on screen count up by one. Checked at the end: each
/// pane's grid is the one its view holds, and its stream is still arriving.
@MainActor final class IntenseResizeSmokeTest {
  nonisolated static let flag = "--intense-resize-smoke"

  private static let seed: UInt64 = 0x7E57_2026_1111
  private static let splits = 6
  private static let steps = 320
  private static var active: IntenseResizeSmokeTest?

  private final class PaneState {
    var latest: TerminalSnapshot?
    var snapshotsChecked = 0
    var linesChecked = 0
    var orderViolations = 0
    var firstViolation: String?
    /// The revision when the resizes stopped; a later one shows a live stream.
    var revisionAtSettle: UInt64?
    var arrivedAfterSettle = false
    /// Seconds from the last resize until the pane showed its view's grid.
    var secondsToViewGrid: Double?
  }

  private let controller: TerminalWindow
  private let path: String
  private var random = SmokeRandom(seed: seed)
  private var states: [ObjectIdentifier: PaneState] = [:]
  private var layoutCreated = false
  private var resizing = false
  private var settled = false
  private var finished = false
  private var step = 0
  private var dividerMoves = [0, 0]  // vertical splits, horizontal splits
  private var windowResizes = 0
  private var windowSizes: [NSSize] = []
  private var lastResize = DispatchTime.now()

  private init(window: TerminalWindow, path: String) {
    controller = window
    self.path = path
  }

  static func start(window: TerminalWindow, path: String) {
    let test = IntenseResizeSmokeTest(window: window, path: path)
    active = test
    guard let first = window.panes.first else { return test.finish(["the window opened without a pane"]) }
    test.observe(first)
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { test.finish(["timed out"]) }
  }

  /// The launch for every pane: this executable as a stream.
  static func launch(from shell: LaunchSpec) -> LaunchSpec {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return LaunchSpec(
      executable: executable, arguments: [executable, SmokeStream.flag], cwd: shell.cwd, launcher: shell.launcher)
  }

  /// Names the seed the next pane's stream starts from.
  static func seedNextStream(_ index: Int) {
    setenv(SmokeStream.seedVariable, String(seed &+ UInt64(index)), 1)
  }

  private func observe(_ pane: TerminalCanvasView) {
    let state = PaneState()
    states[ObjectIdentifier(pane)] = state
    pane.onObservedSnapshot = { [weak self, weak pane] snapshot in
      guard let self, let pane, !self.finished else { return }
      state.latest = snapshot
      self.check(snapshot, of: pane, into: state)
      if self.step == Self.steps, state.secondsToViewGrid == nil, self.hasViewGrid(snapshot, pane) {
        state.secondsToViewGrid =
          Double(DispatchTime.now().uptimeNanoseconds - self.lastResize.uptimeNanoseconds) / 1e9
      }
      self.advance()
    }
  }

  private func advance() {
    if !layoutCreated {
      guard states.values.contains(where: { $0.linesChecked > 0 }) else { return }
      layoutCreated = true
      createLayout()
    } else if !resizing {
      guard controller.panes.count == Self.splits + 1,
        controller.panes.allSatisfy({ (states[ObjectIdentifier($0)]?.linesChecked ?? 0) > 0 })
      else { return }
      resizing = true
      resizeAgain()
    } else if settled {
      finishIfSettled()
    }
  }

  /// Splits a seeded choice of pane right or below, alternating, so the
  /// window holds dividers that change widths and dividers that change heights.
  private func createLayout() {
    guard let window = controller.window else { return finish(["the window is gone"]) }
    for index in 0..<Self.splits {
      let panes = controller.panes
      window.makeFirstResponder(panes[random.pick(0...panes.count - 1)])
      Self.seedNextStream(index + 1)
      if index.isMultiple(of: 2) { controller.splitVertical(nil) } else { controller.splitHorizontal(nil) }
    }
    for pane in controller.panes where states[ObjectIdentifier(pane)] == nil { observe(pane) }
    for (pane, choice) in zip(controller.panes, PaneColorChoice.palette.shuffled(using: &random)) {
      TerminalPanePresentationView.enclosing(pane)?.choose(choice.color)
    }
  }

  // MARK: Resizing

  private func resizeAgain() {
    guard !finished else { return }
    guard step < Self.steps else {
      lastResize = .now()
      return settle()
    }
    step += 1
    switch random.pick(0...9) {
    case 0...5: moveDivider()
    case 6...7: resizeWindow()
    default:
      moveDivider()
      moveDivider()
    }
    // Mostly back to back, with a pause now and then for the panes to draw.
    let delay = step.isMultiple(of: 25) ? 150 : random.pick(0...30)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in self?.resizeAgain() }
  }

  private func moveDivider() {
    let splits = splitViews(in: controller.window?.contentView)
    guard !splits.isEmpty else { return }
    let split = splits[random.pick(0...splits.count - 1)]
    let extent = split.isVertical ? split.bounds.width : split.bounds.height
    let position = extent * (0.1 + 0.8 * random.fraction())
    split.setPosition(position, ofDividerAt: 0)
    split.adjustSubviews()
    split.layoutSubtreeIfNeeded()
    dividerMoves[split.isVertical ? 0 : 1] += 1
  }

  private func resizeWindow() {
    guard let window = controller.window, let visible = window.screen?.visibleFrame else { return }
    let size = NSSize(
      width: min(visible.width, CGFloat(random.pick(720...1500))),
      height: min(visible.height, CGFloat(random.pick(460...980))))
    // Keep the top left corner where it is, as a drag of the bottom right would.
    let origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - size.height)
    window.setFrame(NSRect(origin: origin, size: size), display: true)
    windowResizes += 1
    windowSizes.append(window.frame.size)
  }

  private func splitViews(in view: NSView?) -> [NSSplitView] {
    guard let view else { return [] }
    let own = (view as? NSSplitView).map { [$0] } ?? []
    return own + view.subviews.flatMap { splitViews(in: $0) }
  }

  // MARK: Checking

  /// The lines on screen must be consecutive. The first may be the tail of a
  /// line whose start has scrolled away, so it is read only when it carries
  /// its number.
  private func check(_ snapshot: TerminalSnapshot, of pane: TerminalCanvasView, into state: PaneState) {
    state.snapshotsChecked += 1
    var previous: Int?
    let lines = logicalLines(snapshot).map { $0.trimmingCharacters(in: .whitespaces) }
    let last = lines.lastIndex { !$0.isEmpty }
    for (index, line) in lines.enumerated() where !line.isEmpty {
      // The newest line may still be arriving, its number not yet whole.
      if index == last, line.count <= SmokeStream.numberWidth, line.allSatisfy(\.isNumber) { continue }
      guard let number = Self.number(of: line) else {
        if index > 0 {
          violation(
            "after line \(previous.map(String.init) ?? "none") at \(snapshot.cols)x\(snapshot.rows.count), "
              + "no number in: \(line.prefix(40))", state)
        }
        continue
      }
      if let previous, number != previous + 1 {
        violation("line \(number) follows line \(previous) at \(snapshot.cols)x\(snapshot.rows.count)", state)
      }
      previous = number
      state.linesChecked += 1
    }
  }

  private func violation(_ detail: String, _ state: PaneState) {
    state.orderViolations += 1
    if state.firstViolation == nil { state.firstViolation = detail }
  }

  private static func number(of line: String) -> Int? {
    let digits = line.prefix(SmokeStream.numberWidth)
    guard digits.count == SmokeStream.numberWidth, digits.allSatisfy(\.isNumber) else { return nil }
    // A line with an empty payload is its number alone.
    guard line.count == SmokeStream.numberWidth || line.dropFirst(SmokeStream.numberWidth).first == " " else {
      return nil
    }
    return Int(digits)
  }

  private func logicalLines(_ snapshot: TerminalSnapshot) -> [String] {
    var lines: [String] = []
    var line = ""
    for row in snapshot.rows {
      line += row.cells.map(\.text).joined()
      guard !row.soft_wrapped else { continue }
      lines.append(line)
      line = ""
    }
    if !line.isEmpty { lines.append(line) }
    return lines
  }

  // MARK: Finishing

  private func settle() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, !self.finished else { return }
      for state in self.states.values { state.revisionAtSettle = state.latest?.revision }
      self.settled = true
      // A pane that never reaches its grid or whose stream has stopped fails here.
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish([]) }
    }
  }

  private func finishIfSettled() {
    for pane in controller.panes {
      guard let state = states[ObjectIdentifier(pane)], let snapshot = state.latest else { return }
      if let revision = state.revisionAtSettle, snapshot.revision > revision { state.arrivedAfterSettle = true }
      guard state.arrivedAfterSettle, hasViewGrid(snapshot, pane) else { return }
    }
    finish([])
  }

  private func hasViewGrid(_ snapshot: TerminalSnapshot, _ pane: TerminalCanvasView) -> Bool {
    guard let grid = pane.gridForBounds else { return false }
    return snapshot.cols == grid.columns && snapshot.rows.count == grid.rows
  }

  private func finish(_ problems: [String]) {
    guard !finished else { return }
    finished = true
    controller.panes.forEach { $0.onObservedSnapshot = nil }
    var failures = problems
    if step < Self.steps { failures.append("stopped after \(step) of \(Self.steps) resize steps") }
    if dividerMoves.contains(0) || windowResizes == 0 {
      failures.append("the schedule did not resize in every direction")
    }
    var panes: [[String: Any]] = []
    for (index, pane) in controller.panes.enumerated() {
      guard let state = states[ObjectIdentifier(pane)], let snapshot = state.latest else {
        failures.append("pane \(index) never presented a snapshot")
        continue
      }
      let grid = pane.gridForBounds
      if !hasViewGrid(snapshot, pane) {
        failures.append(
          "pane \(index) shows \(snapshot.cols)x\(snapshot.rows.count), its view holds "
            + "\(grid?.columns ?? 0)x\(grid?.rows ?? 0)")
      }
      if settled, !state.arrivedAfterSettle { failures.append("pane \(index) stream stopped arriving") }
      if state.linesChecked == 0 { failures.append("pane \(index) showed no numbered line") }
      if let detail = state.firstViolation {
        failures.append("pane \(index): \(state.orderViolations) order violations, first: \(detail)")
      }
      panes.append([
        "columns": snapshot.cols, "rows": snapshot.rows.count,
        "view_columns": grid?.columns ?? 0, "view_rows": grid?.rows ?? 0,
        "history_rows": snapshot.history_rows,
        "snapshots_checked": state.snapshotsChecked, "lines_checked": state.linesChecked,
        "order_violations": state.orderViolations,
        "stream_arriving_after_resizes": state.arrivedAfterSettle,
        "seconds_to_view_grid": state.secondsToViewGrid ?? -1,
      ])
    }
    let report: [String: Any] = [
      "passed": failures.isEmpty,
      "failures": failures,
      "seed": String(Self.seed, radix: 16),
      "pane_count": controller.panes.count,
      "resize_steps": step,
      "vertical_divider_moves": dividerMoves[0],
      "horizontal_divider_moves": dividerMoves[1],
      "window_resizes": windowResizes,
      "window_width_range_points": [windowSizes.map(\.width).min() ?? 0, windowSizes.map(\.width).max() ?? 0],
      "window_height_range_points": [windowSizes.map(\.height).min() ?? 0, windowSizes.map(\.height).max() ?? 0],
      "panes": panes,
      "note": "Seeded synthetic streams only; the report holds counts and geometry.",
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { NSLog("Intense resize smoke report failed: %@", String(describing: error)) }
    Self.active = nil
    NSApp.terminate(nil)
  }
}

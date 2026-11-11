import AppKit

// A private-ZDOTDIR Starship fixture for the prompt reflow regression. Reports
// counts and geometry only; no user configuration, history, or shell output is
// read or persisted.
@MainActor final class ResizeSmokeTest {
  private enum Phase: String, CaseIterable {
    case rapid, reference

    var events: Int { self == .rapid ? 240 : 120 }
    /// Each resize still waits for the core's geometry snapshot. The reference
    /// pass also applies this minimum wall-clock delay; rapid deliberately does
    /// not claim a fixed interval and schedules the next resize on the next
    /// main-loop turn after geometry arrives.
    var minimumDelay: DispatchTimeInterval? {
      self == .reference ? .milliseconds(76) : nil
    }

    var cadence: String {
      switch self {
      case .rapid: "geometry-gated-next-main-loop"
      case .reference: "geometry-gated-minimum-76ms"
      }
    }
  }

  private static var active: ResizeSmokeTest?
  private let controller: TerminalWindow
  private let path: String
  private var latest: [ObjectIdentifier: TerminalSnapshot] = [:]
  private var target: TerminalCanvasView?
  private var layoutCreated = false
  private var baselineCaptured = false
  private var phaseIndex = 0
  private var step = 0
  private var awaitingEpoch: UInt64?
  private var awaitingPromptRedraw: (epoch: UInt64, revision: UInt64)?
  private var resizeEvents = 0
  private var phaseReports: [[String: Any]] = []
  private var finalTargetMetrics: [String: Any]?
  private var dividerRange: [Double] = []
  private var finished = false

  private let promptMarker = "RESIZE_PROMPT"
  private let rightPromptMarker = "RESIZE_RPROMPT"
  private let bufferMarker = "RESIZE_BUFFER"

  init(window: TerminalWindow, path: String) {
    controller = window
    self.path = path
  }

  static func start(window: TerminalWindow, path: String) {
    let test = ResizeSmokeTest(window: window, path: path)
    active = test
    test.installObservers()
    DispatchQueue.main.asyncAfter(deadline: .now() + 75) { test.finish(timedOut: true) }
  }

  private func installObservers() {
    guard let pane = controller.panes.first else { return finish(timedOut: true) }
    observe(pane)
  }

  private func observe(_ pane: TerminalCanvasView) {
    pane.onObservedSnapshot = { [weak self, weak pane] snapshot in
      guard let self, let pane, !self.finished else { return }
      self.latest[ObjectIdentifier(pane)] = snapshot
      self.advance(after: pane, snapshot: snapshot)
    }
  }

  private func advance(after pane: TerminalCanvasView, snapshot: TerminalSnapshot) {
    if pane === target { finalTargetMetrics = targetMetrics(snapshot) }
    if !layoutCreated, controller.panes.count == 1, fixtureReady(snapshot) {
      layoutCreated = true
      createNestedLayout()
      return
    }
    guard let target else {
      if layoutCreated, controller.panes.count == 5,
        controller.panes.allSatisfy({ latest[ObjectIdentifier($0)].map(fixtureReady) == true })
      {
        begin()
      }
      return
    }
    if pane === target, let epoch = awaitingEpoch, snapshot.geometry_epoch > epoch {
      awaitingEpoch = nil
      resizeEvents += 1
      advanceResize()
    }
    if pane === target, let redraw = awaitingPromptRedraw,
      snapshot.geometry_epoch == redraw.epoch, snapshot.revision > redraw.revision,
      fixtureReady(snapshot)
    {
      awaitingPromptRedraw = nil
      completePhase(with: snapshot)
    }
  }

  private func createNestedLayout() {
    guard let window = controller.window, let first = controller.panes.first else {
      return finish(timedOut: true)
    }
    for index in 0..<4 {
      window.makeFirstResponder(first)
      if index.isMultiple(of: 2) { controller.splitVertical(nil) }
      else { controller.splitHorizontal(nil) }
    }
    controller.panes.forEach(observe)
    // A different header color per pane, drawn at random, so the panes are
    // easy to tell apart while the dividers move. Nothing is asserted on it.
    for (pane, choice) in zip(controller.panes, PaneColorChoice.palette.shuffled()) {
      TerminalPanePresentationView.enclosing(pane)?.choose(choice.color)
    }
  }

  /// The split view whose divider sizes `pane`. A pane sits inside its
  /// presentation view, which carries the header, and that view is what the
  /// split arranges.
  private static func split(holding pane: TerminalCanvasView) -> NSSplitView? {
    (TerminalPanePresentationView.enclosing(pane) ?? pane).superview as? NSSplitView
  }

  private func begin() {
    guard !baselineCaptured,
      let pane = controller.panes.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
      let snapshot = latest[ObjectIdentifier(pane)], fixtureReady(snapshot),
      markerOccurrences(promptMarker, in: snapshot) == 1,
      markerOccurrences(rightPromptMarker, in: snapshot) == 1,
      cursorImmediatelyFollowsBuffer(snapshot)
    // The splits have just resized every pane, and zsh may still be
    // redrawing its prompt. A later snapshot tries again; a prompt that
    // never settles runs into the smoke's time limit.
    else { return }
    baselineCaptured = true
    target = pane
    controller.window?.makeFirstResponder(pane)
    guard let split = Self.split(holding: pane) else { return finish(timedOut: true) }
    let extent = split.isVertical ? split.bounds.width : split.bounds.height
    let lower = max(40, min(180, extent * 0.15))
    let upper = max(lower + 20, extent - lower - split.dividerThickness)
    dividerRange = [lower, upper]
    beginPhase()
  }

  private func beginPhase() {
    step = 0
    guard let target, let snapshot = latest[ObjectIdentifier(target)] else { return finish(timedOut: true) }
    recordPhaseBaseline(snapshot)
    moveDivider(for: target, after: snapshot.geometry_epoch)
  }

  private func moveDivider(for target: TerminalCanvasView, after epoch: UInt64) {
    guard let split = Self.split(holding: target), currentPhase != nil else {
      return finish(timedOut: true)
    }
    awaitingEpoch = epoch
    let position = step.isMultiple(of: 2) ? dividerRange[0] : dividerRange[1]
    split.setPosition(position, ofDividerAt: 0)
    split.adjustSubviews()
    split.layoutSubtreeIfNeeded()
  }

  private func advanceResize() {
    guard let phase = currentPhase else { return finish(timedOut: true) }
    step += 1
    guard step < phase.events else {
      guard let target, let snapshot = latest[ObjectIdentifier(target)] else {
        return finish(timedOut: true)
      }
      // A resize acknowledgement only says the terminal accepted geometry. The
      // ZLE redraw arrives on a later PTY snapshot, so wait for that completed
      // redraw rather than starting the next cadence on a guessed timer.
      awaitingPromptRedraw = (snapshot.geometry_epoch, snapshot.revision)
      return
    }
    guard let target, let snapshot = latest[ObjectIdentifier(target)] else { return finish(timedOut: true) }
    if let delay = phase.minimumDelay {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.moveDivider(for: target, after: snapshot.geometry_epoch)
      }
    } else {
      DispatchQueue.main.async { [weak self] in self?.moveDivider(for: target, after: snapshot.geometry_epoch) }
    }
  }

  private func completePhase(with snapshot: TerminalSnapshot) {
    guard let phase = currentPhase else {
      return finish(timedOut: true)
    }
    let metrics = targetMetrics(snapshot)
    let promptCount = metrics["prompt_markers"] as? Int ?? 0
    let bufferPreserved = metrics["buffer_preserved"] as? Bool ?? false
    let cursorAfterBuffer = metrics["cursor_immediately_after_buffer"] as? Bool ?? false
    phaseReports.append([
      "name": phase.rawValue,
      "events": phase.events,
      "cadence": phase.cadence,
      "prompt_markers": promptCount, "right_prompt_markers": metrics["right_prompt_markers"]!,
      "buffer_preserved": metrics["buffer_preserved"]!,
      "cursor_on_buffer_row": metrics["cursor_on_buffer_row"]!,
      "cursor_immediately_after_buffer": metrics["cursor_immediately_after_buffer"]!,
      "target_columns": metrics["target_columns"]!, "target_rows": metrics["target_rows"]!,
      "passed": promptCount == 1 && bufferPreserved && cursorAfterBuffer,
    ])
    phaseIndex += 1
    if phaseIndex == Phase.allCases.count { finish(timedOut: false) }
    else { beginPhase() }
  }

  private var currentPhase: Phase? {
    Phase.allCases.indices.contains(phaseIndex) ? Phase.allCases[phaseIndex] : nil
  }

  private func recordPhaseBaseline(_ snapshot: TerminalSnapshot) {
    if phaseReports.isEmpty {
      phaseReports.append([
        "name": "baseline",
        "prompt_markers": markerOccurrences(promptMarker, in: snapshot),
        "right_prompt_markers": markerOccurrences(rightPromptMarker, in: snapshot),
        "buffer_preserved": contains(bufferMarker, in: snapshot),
        "cursor_on_buffer_row": cursorIsOnBufferRow(snapshot),
        "cursor_immediately_after_buffer": cursorImmediatelyFollowsBuffer(snapshot),
      ])
    }
  }

  private func fixtureReady(_ snapshot: TerminalSnapshot) -> Bool {
    markerOccurrences(promptMarker, in: snapshot) == 1 && contains(bufferMarker, in: snapshot)
  }

  private func markerOccurrences(_ marker: String, in snapshot: TerminalSnapshot) -> Int {
    logicalLines(snapshot).reduce(0) { count, line in
      count + max(0, line.components(separatedBy: marker).count - 1)
    }
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

  private func contains(_ marker: String, in snapshot: TerminalSnapshot) -> Bool {
    logicalLines(snapshot).contains { $0.contains(marker) }
  }

  /// Retained as a diagnostic only. A cursor somewhere on the buffer's physical
  /// row does not prove its column or pending-wrap insertion boundary.
  private func cursorIsOnBufferRow(_ snapshot: TerminalSnapshot) -> Bool {
    snapshot.rows.indices.contains(snapshot.cursor.row)
      && snapshot.rows[snapshot.cursor.row].cells.map(\.text).joined().contains(bufferMarker)
  }

  private struct InsertionBoundary: Equatable {
    let row: Int
    let col: Int
    let pendingWrap: Bool
  }

  /// Locate the unique ASCII fixture buffer at cell precision and calculate the
  /// insertion boundary directly after it. This remains correct if the buffer
  /// crosses soft-wrapped rows or ends at the final column, where terminals keep
  /// the cursor on that cell with pending-wrap set rather than at col == width.
  private func bufferEndBoundary(_ snapshot: TerminalSnapshot) -> InsertionBoundary? {
    let markerCells = bufferMarker.map(String.init)
    var matches: [InsertionBoundary] = []

    for initialRow in snapshot.rows.indices {
      for initialCol in snapshot.rows[initialRow].cells.indices {
        var row = initialRow
        var col = initialCol
        var matched = true

        for (index, expected) in markerCells.enumerated() {
          let cell = snapshot.rows[row].cells[col]
          guard cell.kind == "Lead1", cell.text == expected else {
            matched = false
            break
          }
          guard index + 1 < markerCells.count else { continue }
          if col + 1 < snapshot.rows[row].cells.count {
            col += 1
          } else if snapshot.rows[row].soft_wrapped, row + 1 < snapshot.rows.count {
            row += 1
            col = 0
          } else {
            matched = false
            break
          }
        }

        guard matched else { continue }
        if col + 1 < snapshot.rows[row].cells.count {
          matches.append(InsertionBoundary(row: row, col: col + 1, pendingWrap: false))
        } else {
          matches.append(InsertionBoundary(row: row, col: col, pendingWrap: true))
        }
      }
    }

    return matches.count == 1 ? matches[0] : nil
  }

  private func cursorImmediatelyFollowsBuffer(_ snapshot: TerminalSnapshot) -> Bool {
    guard let expected = bufferEndBoundary(snapshot) else { return false }
    return snapshot.cursor.row == expected.row && snapshot.cursor.col == expected.col
      && snapshot.cursor.pending_wrap == expected.pendingWrap
  }

  private func targetMetrics(_ snapshot: TerminalSnapshot) -> [String: Any] {
    [
      "prompt_markers": markerOccurrences(promptMarker, in: snapshot),
      "right_prompt_markers": markerOccurrences(rightPromptMarker, in: snapshot),
      "buffer_preserved": contains(bufferMarker, in: snapshot),
      "cursor_on_buffer_row": cursorIsOnBufferRow(snapshot),
      "cursor_immediately_after_buffer": cursorImmediatelyFollowsBuffer(snapshot),
      "target_columns": snapshot.cols,
      "target_rows": snapshot.rows.count,
      "geometry_epoch": snapshot.geometry_epoch,
      "revision": snapshot.revision,
    ]
  }

  private func finish(timedOut: Bool) {
    guard !finished else { return }
    finished = true
    controller.panes.forEach { $0.onObservedSnapshot = nil }
    let passed = !timedOut && phaseReports.count == 3
      && phaseReports.dropFirst().allSatisfy { ($0["passed"] as? Bool) == true }
    let report: [String: Any] = [
      "passed": passed,
      "completed_without_timeout": !timedOut,
      "fixture": "private-zdotdir-starship",
      "pane_count": controller.panes.count,
      "layout": "nested-splits",
      "resize_events": resizeEvents,
      "fixture_ready": baselineCaptured,
      "completed_phase_count": max(0, phaseReports.count - 1),
      "active_phase": currentPhase?.rawValue ?? "complete",
      "awaiting_geometry_commit": awaitingEpoch != nil,
      "awaiting_zle_redraw": awaitingPromptRedraw != nil,
      "divider_range_points": dividerRange,
      "phases": phaseReports,
      "final_target": finalTargetMetrics ?? [:],
      "note": "Synthetic Starship fixture only; report contains counts and geometry, never user shell data.",
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { NSLog("Resize smoke report failed: %@", String(describing: error)) }
    Self.active = nil
    NSApp.terminate(nil)
  }
}

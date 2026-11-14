import AppKit
import TerminalEngine
import TerminalUI

/// Real-AppKit selection smoke. It uses only a fixed child fixture, private
/// pasteboard scope, and the same mouse handlers used by the application.
@MainActor final class SelectionSmokeTest {
  private enum Stage: Equatable {
    case awaitingFixture, awaitingWide, awaitingForward, awaitingForwardCopy
    case awaitingReverse, awaitingReverseCopy, awaitingWordFixture, awaitingWord, awaitingCopy, awaitingOutput
    case awaitingReflow, awaitingReflowApplied, awaitingReflowCopy, awaitingLineFixture, awaitingLine
    case awaitingRectangleFixture, awaitingRectangle, awaitingRectangleApplied, awaitingRectangleCopy, awaitingClear
    case awaitingTailFixture, awaitingPlainClick, awaitingPlainClickApplied
    case awaitingMouseMode, awaitingMouseRoute, awaitingCloseSelection, awaitingClose
  }

  private static var active: SelectionSmokeTest?
  private let controller: TerminalWindow
  private let path: String
  private let original: TerminalCanvasView
  private let pasteboard: NSPasteboard
  private var latest: [ObjectIdentifier: TerminalSnapshot] = [:]
  private var stage: Stage = .awaitingFixture
  private var checks = Dictionary(uniqueKeysWithValues: [
    "fixture_ready", "wide_drag", "ordinary_forward_copy", "ordinary_reverse_copy",
    "word_double_click", "private_copy", "output_preserves_selection",
    "reflow_retains_selection", "line_triple_click", "rectangular_option_drag",
    "rectangular_ax_multirange_has_no_union_holes", "plain_click_publishes_caret_without_selection",
    "application_mouse_does_not_select", "original_pane_close_cancels_pending", "private_board_unchanged_after_close",
  ].map { ($0, false) })
  private var measurements: [String: Any] = [:]
  private var selectedIDs: [UInt64] = []
  private var selectedText = ""
  private var selectedRevision: UInt64 = 0
  private var reflowEpoch: UInt64 = 0
  private let reflowColumns = 64
  private let reflowRows = 18
  private var mouseRevision: UInt64 = 0
  private var rawControlReceipts: [[String: Any]] = []
  private var rawControlStatuses: [String] = []
  private var finished = false

  private init(window: TerminalWindow, path: String) {
    controller = window
    self.path = path
    guard let pane = window.panes.first else {
      fatalError("Selection smoke requires its initial pane")
    }
    original = pane
    pasteboard = NSPasteboard(name: selectionSmokePasteboardName(reportPath: path))
  }

  static func start(window: TerminalWindow, path: String) {
    let test = SelectionSmokeTest(window: window, path: path)
    active = test
    test.pasteboard.clearContents()
    test.original.onObservedSnapshot = { [weak test] snapshot in test?.observe(snapshot, pane: test?.original) }
    let priorStatus = test.original.onStatus
    test.original.onStatus = { [weak test] status in
      priorStatus?(status)
      let relevant = ["Input busy", "Input closed", "PTY write closed"]
      if relevant.contains(where: { status.localizedCaseInsensitiveContains($0) }) {
        test?.rawControlStatuses.append(status)
      }
    }
    // `/bin/sh` can print its fixture before an AppKit window has finished
    // wiring observers. The owned child waits for this byte after `stty raw`,
    // making readiness a real PTY/owner handshake rather than a startup race.
    test.original.session.rawInput(Data("R".utf8))
    // This is only an outer liveness bound. Every transition below waits for a
    // concrete fixture marker, selection publication, completion or close.
    DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak test] in test?.finish(timedOut: true) }
  }

  private func observe(_ snapshot: TerminalSnapshot, pane: TerminalCanvasView?) {
    guard !finished, let pane else { return }
    latest[ObjectIdentifier(pane)] = snapshot
    guard pane === original else { return }
    measurements["last_observed_stage"] = String(describing: stage)
    measurements["last_selection_phase"] = String(describing: snapshot.selection.phase)
    measurements["last_selection_revision"] = snapshot.selection.revision
    switch stage {
    case .awaitingFixture where contains("SELECTION_FIXTURE_READY", snapshot):
      checks["fixture_ready"] = true
      measurements["fixture_epoch"] = snapshot.geometry_epoch
      stage = .awaitingWide
      DispatchQueue.main.async { [weak self] in self?.wideDrag() }
    case .awaitingWide where committed(snapshot):
      let text = selectionText(snapshot)
      checks["wide_drag"] = text.contains("猫")
      measurements["wide_selected_text"] = text
      stage = .awaitingForward
      DispatchQueue.main.async { [weak self] in self?.ordinaryForwardDrag() }
    case .awaitingForward where committed(snapshot):
      stage = .awaitingForwardCopy
      copySelection(snapshot, expected: "SEL_WIDE_猫_TOKEN") { [weak self] copied in
        guard let self else { return }
        self.checks["ordinary_forward_copy"] = copied
        self.stage = .awaitingReverse
        DispatchQueue.main.async { self.ordinaryReverseDrag() }
      }
    case .awaitingReverse where committed(snapshot):
      stage = .awaitingReverseCopy
      copySelection(snapshot, expected: "SEL_WIDE_猫_TOKEN") { [weak self] copied in
        guard let self else { return }
        self.checks["ordinary_reverse_copy"] = copied
        self.stage = .awaitingWordFixture
        self.sendRawFixtureCommand("WORD\n")
      }
    case .awaitingWordFixture where contains("WORD_TOKEN", snapshot):
      stage = .awaitingWord
      DispatchQueue.main.async { [weak self] in self?.wordClick() }
    case .awaitingWord where committed(snapshot):
      let text = selectionText(snapshot)
      checks["word_double_click"] = text == "WORD_TOKEN"
      selectedText = text
      selectedRevision = snapshot.selection.revision
      selectedIDs = selectedRowIDs(snapshot)
      measurements["word_selection_revision"] = selectedRevision
      measurements["word_selection_row_ids"] = selectedIDs
      stage = .awaitingCopy
      DispatchQueue.main.async { [weak self] in self?.copyWord() }
    case .awaitingOutput where contains("SELECTION_OUTPUT_AFTER_GESTURE", snapshot):
      let preserved = committed(snapshot) && selectionText(snapshot) == selectedText
        && selectedRowIDs(snapshot) == selectedIDs
      checks["output_preserves_selection"] = preserved
      measurements["post_output_selection_revision"] = snapshot.selection.revision
      measurements["post_output_selection_row_ids"] = selectedRowIDs(snapshot)
      reflowEpoch = snapshot.geometry_epoch
      stage = .awaitingReflow
      controller.window?.setContentSize(original.contentSize(columns: reflowColumns, rows: reflowRows))
    case .awaitingReflow where snapshot.geometry_epoch > reflowEpoch
      && snapshot.cols == reflowColumns && snapshot.rows.count == reflowRows:
      measurements["reflow_epoch_before"] = reflowEpoch
      measurements["reflow_epoch_after"] = snapshot.geometry_epoch
      measurements["reflow_selection_text"] = selectionText(snapshot)
      measurements["reflow_selection_row_ids"] = selectedRowIDs(snapshot)
      measurements["reflow_final_columns"] = snapshot.cols
      measurements["reflow_final_rows"] = snapshot.rows.count
      stage = .awaitingReflowApplied
      // The observer runs before Canvas applies this exact final geometry.
      DispatchQueue.main.async { [weak self] in self?.verifyAppliedReflow(snapshot) }
    case .awaitingLineFixture where contains("LINE_TOKEN", snapshot):
      stage = .awaitingLine
      DispatchQueue.main.async { [weak self] in self?.lineClick() }
    case .awaitingLine where committed(snapshot):
      checks["line_triple_click"] = selectionText(snapshot).contains("LINE_TOKEN")
      stage = .awaitingRectangleFixture
      sendRawFixtureCommand("RECT\n")
    case .awaitingRectangleFixture where contains("abcde", snapshot) && contains("ABCDE", snapshot):
      stage = .awaitingRectangle
      DispatchQueue.main.async { [weak self] in self?.rectangularDrag() }
    case .awaitingRectangle where committed(snapshot):
      stage = .awaitingRectangleApplied
      // Snapshot observers run before Canvas applies the new AX projection.
      DispatchQueue.main.async { [weak self] in self?.verifyAppliedRectangle() }
    case .awaitingClear where snapshot.selection.phase == .none:
      stage = .awaitingTailFixture
      sendRawFixtureCommand("TAIL\n")
    case .awaitingTailFixture where contains("CLICK_TAIL", snapshot):
      stage = .awaitingPlainClick
      DispatchQueue.main.async { [weak self] in self?.plainClickAtTail() }
    case .awaitingPlainClick where snapshot.selection.phase == .none:
      measurements["plain_click_selection_revision"] = snapshot.selection.revision
      stage = .awaitingPlainClickApplied
      // Canvas applies its projection after this observation. The follow-up is
      // an ownership/publication boundary, not a timed wait.
      DispatchQueue.main.async { [weak self] in self?.verifyAppliedPlainClick() }
    case .awaitingMouseMode where contains("MOUSE_MODE_READY", snapshot):
      DispatchQueue.main.async { [weak self] in self?.applicationMouseGesture() }
    case .awaitingMouseRoute where contains("MOUSE_ROUTE_ACK", snapshot) && contains("CLOSE_TOKEN", snapshot):
      checks["application_mouse_does_not_select"] = snapshot.selection.phase == .none
        && snapshot.selection.revision == mouseRevision
      measurements["application_mouse_selection_revision"] = snapshot.selection.revision
      stage = .awaitingCloseSelection
      DispatchQueue.main.async { [weak self] in self?.closeCancellation() }
    case .awaitingClose:
      break
    default:
      break
    }
  }

  private func wideDrag() { drag(token: "猫", modifiers: []) }
  private func ordinaryForwardDrag() { drag(token: "SEL_WIDE_猫_TOKEN", modifiers: []) }
  private func ordinaryReverseDrag() { drag(token: "SEL_WIDE_猫_TOKEN", modifiers: [], reverse: true) }
  private func wordClick() { click(token: "WORD_TOKEN", count: 2, modifiers: []) }
  private func lineClick() { click(token: "LINE_TOKEN", count: 3, modifiers: []) }

  private func rectangularDrag() {
    guard let start = point(for: "abcde", atEnd: false), let end = point(for: "ABCDE", atEnd: true) else {
      return finish(timedOut: true)
    }
    sendMouse(.leftMouseDown, point: start, clicks: 1, modifiers: .option)
    sendMouse(.leftMouseDragged, point: end, clicks: 1, modifiers: .option)
    sendMouse(.leftMouseUp, point: end, clicks: 1, modifiers: .option)
  }

  private func applicationMouseGesture() {
    guard let point = point(for: "LINE_TOKEN", atEnd: false) else { return finish(timedOut: true) }
    stage = .awaitingMouseRoute
    sendMouse(.leftMouseDown, point: point, clicks: 1, modifiers: [])
    sendMouse(.leftMouseUp, point: point, clicks: 1, modifiers: [])
  }

  private func plainClickAtTail() {
    guard let point = point(for: "CLICK_TAIL", atEnd: true) else { return finish(timedOut: true) }
    sendMouse(.leftMouseDown, point: point, clicks: 1, modifiers: [])
    sendMouse(.leftMouseUp, point: point, clicks: 1, modifiers: [])
  }

  private func verifyAppliedPlainClick() {
    guard !finished, stage == .awaitingPlainClickApplied else { return }
    let caret = original.accessibilitySelectedTextRange()
    checks["plain_click_publishes_caret_without_selection"] =
      caret.location != NSNotFound && caret.length == 0
    measurements["plain_click_caret_range"] = ["location": caret.location, "length": caret.length]
    mouseRevision = latest[ObjectIdentifier(original)]?.selection.revision ?? 0
    stage = .awaitingMouseMode
    sendRawFixtureCommand("MOUSE\n")
  }

  private func verifyAppliedReflow(_ snapshot: TerminalSnapshot) {
    guard !finished, stage == .awaitingReflowApplied else { return }
    let projected = AccessibilityProjection(snapshot: snapshot)
    let canvasApplied = original.accessibilitySelectedText() == projected.selectedText()
    let coherent = snapshot.selection.phase == .committed
      && snapshot.selectionPresentation?.geometryEpoch == snapshot.geometry_epoch
      && !snapshot.selection.segments.isEmpty && selectionText(snapshot) == selectedText
      && canvasApplied
    measurements["reflow_selection_geometry_coherent"] = coherent
    measurements["reflow_canvas_applied_selected_text"] = original.accessibilitySelectedText() ?? ""
    measurements["reflow_selection_document_generation"] =
      snapshot.selectionPresentation.map { String(describing: $0.documentGeneration) } ?? ""
    guard coherent else {
      checks["reflow_retains_selection"] = false
      measurements["reflow_copy_result"] = "not-submitted: final selection was not coherent"
      stage = .awaitingLineFixture
      sendRawFixtureCommand("LINE\n")
      return
    }
    stage = .awaitingReflowCopy
    copySelectionResult(snapshot) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let copied):
        self.checks["reflow_retains_selection"] = copied == self.selectedText
        self.measurements["reflow_copy_result"] = copied ?? ""
      case .failure(let error):
        self.checks["reflow_retains_selection"] = false
        self.measurements["reflow_copy_result"] = "rejected: \(error.rawValue)"
      }
      self.stage = .awaitingLineFixture
      self.sendRawFixtureCommand("LINE\n")
    }
  }

  private func verifyAppliedRectangle() {
    guard !finished, stage == .awaitingRectangleApplied,
      let snapshot = latest[ObjectIdentifier(original)]
    else { return }
    let expected = AccessibilityProjection(snapshot: snapshot).selectedRanges()
    let actual = original.accessibilitySelectedTextRanges()?.map(\.rangeValue) ?? []
    let legacy = original.accessibilitySelectedTextRange()
    checks["rectangular_option_drag"] = snapshot.selection.mode == .rectangular
      && snapshot.selection.segments.count >= 2
    // A union would bridge the unselected newline/gap between the two rows.
    // Multiple ranges are therefore the only truthful AX representation.
    checks["rectangular_ax_multirange_has_no_union_holes"] = expected.count > 1
      && actual == expected && legacy.location == NSNotFound && legacy.length == 0
    measurements["rectangular_ax_ranges"] = actual.map { ["location": $0.location, "length": $0.length] }
    measurements["rectangular_legacy_range"] = ["location": legacy.location, "length": legacy.length]
    stage = .awaitingRectangleCopy
    copySelection(snapshot, expected: "abcde\nABCDE") { [weak self] copied in
      guard let self else { return }
      self.checks["rectangular_option_drag"] = self.checks["rectangular_option_drag"] == true && copied
      self.stage = .awaitingClear
      _ = self.original.session.selection(.clear)
    }
  }

  private func closeCancellation() {
    guard let snapshot = latest[ObjectIdentifier(original)],
      let range = textRange("CLOSE_TOKEN", in: snapshot),
      let span = AccessibilityProjection(snapshot: snapshot).spans.first(where: {
        $0.cells > 0 && NSIntersectionRange($0.range, range).length > 0
      }),
      let hit = snapshot.selectionHit(row: span.row, boundary: span.column)
    else { return finish(timedOut: true) }
    measurements["close_token_hit"] = ["row": span.row, "boundary": span.column]
    controller.window?.makeFirstResponder(original)
    controller.splitVertical(nil)
    stage = .awaitingClose
    guard original.session.selection(.begin(hit, granularity: .word), completion: { [weak self] result in
      guard let self, !self.finished else { return }
      if case .failure(.cancelled) = result {
        self.checks["original_pane_close_cancels_pending"] = true
      }
      self.checks["private_board_unchanged_after_close"] =
        self.pasteboard.string(forType: .string) == "WORD_TOKEN"
      self.finish(timedOut: false)
    }) else { return finish(timedOut: true) }
    controller.window?.makeFirstResponder(original)
    controller.closePane(nil)
  }

  private func copyWord() {
    original.copy(nil)
    waitForPrivateCopy()
  }

  private func waitForPrivateCopy() {
    guard !finished else { return }
    if pasteboard.string(forType: .string) == "WORD_TOKEN" {
      checks["private_copy"] = true
      measurements["expected_copied_text"] = "WORD_TOKEN"
      stage = .awaitingOutput
      sendRawFixtureCommand("OUTPUT\n")
      return
    }
    DispatchQueue.main.async { [weak self] in self?.waitForPrivateCopy() }
  }

  private func sendRawFixtureCommand(_ command: String) {
    original.session.rawInput(Data(command.utf8))
    let label = command.trimmingCharacters(in: .whitespacesAndNewlines)
    // A probe is ordered behind the raw event in Session's FIFO. Its callback
    // proves that event was pumped and `flush()` was attempted; it does not
    // claim the child consumed the bytes (a PTY write may still be pending).
    original.session.semanticProbe { [weak self] delay in
      guard let self, !self.finished else { return }
      self.rawControlReceipts.append([
        "command": label, "raw_event_pumped": true, "flush_attempted": true,
        "owner_probe_delay_ms": delay,
      ])
      self.measurements["raw_control_receipts"] = self.rawControlReceipts
      self.measurements["raw_control_statuses"] = self.rawControlStatuses
    }
  }

  private func copySelection(
    _ snapshot: TerminalSnapshot, expected: String, completion: @escaping @MainActor (Bool) -> Void
  ) {
    copySelectionResult(snapshot) { result in
      if case .success(let text) = result { completion(text == expected) }
      else { completion(false) }
    }
  }

  private func copySelectionResult(
    _ snapshot: TerminalSnapshot,
    completion: @escaping @MainActor (Result<String?, TerminalSelectionFailure>) -> Void
  ) {
    guard original.session.selection(.copy(expectedSelectionRevision: snapshot.selection.revision), completion: completion) else {
      completion(.failure(.busy))
      return
    }
  }

  private func drag(token: String, modifiers: NSEvent.ModifierFlags, reverse: Bool = false) {
    guard let leading = point(for: token, atEnd: false), let trailing = point(for: token, atEnd: true) else {
      return finish(timedOut: true)
    }
    let start = reverse ? trailing : leading
    let end = reverse ? leading : trailing
    sendMouse(.leftMouseDown, point: start, clicks: 1, modifiers: modifiers)
    sendMouse(.leftMouseDragged, point: end, clicks: 1, modifiers: modifiers)
    sendMouse(.leftMouseUp, point: end, clicks: 1, modifiers: modifiers)
  }

  private func click(token: String, count: Int, modifiers: NSEvent.ModifierFlags) {
    guard let point = point(for: token, atEnd: false) else { return finish(timedOut: true) }
    sendMouse(.leftMouseDown, point: point, clicks: count, modifiers: modifiers)
    sendMouse(.leftMouseUp, point: point, clicks: count, modifiers: modifiers)
  }

  private func sendMouse(
    _ type: NSEvent.EventType, point: NSPoint, clicks: Int, modifiers: NSEvent.ModifierFlags
  ) {
    guard let window = controller.window,
      let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    else { return }
    NSApp.sendEvent(event)
  }

  private func point(for token: String, atEnd: Bool) -> NSPoint? {
    guard let snapshot = latest[ObjectIdentifier(original)], let range = textRange(token, in: snapshot),
      let window = controller.window
    else { return nil }
    let frame = window.convertFromScreen(original.accessibilityFrame(for: range))
    guard !frame.isEmpty else { return nil }
    let inset: CGFloat = 1
    return NSPoint(x: atEnd ? max(frame.minX + inset, frame.maxX - inset) : frame.minX + inset, y: frame.midY)
  }

  private func textRange(_ token: String, in snapshot: TerminalSnapshot) -> NSRange? {
    let text = AccessibilityProjection(snapshot: snapshot).text as NSString
    let range = text.range(of: token)
    return range.location == NSNotFound ? nil : range
  }

  private func contains(_ token: String, _ snapshot: TerminalSnapshot) -> Bool {
    AccessibilityProjection(snapshot: snapshot).text.contains(token)
  }

  private func selectionText(_ snapshot: TerminalSnapshot) -> String {
    AccessibilityProjection(snapshot: snapshot).selectedText() ?? ""
  }

  private func selectedRowIDs(_ snapshot: TerminalSnapshot) -> [UInt64] {
    guard let rows = snapshot.selectionPresentation?.rows else { return [] }
    return Array(Set(snapshot.selection.segments.compactMap { rows.indices.contains($0.row) ? rows[$0.row].id : nil })).sorted()
  }

  private func committed(_ snapshot: TerminalSnapshot) -> Bool { snapshot.selection.phase == .committed }

  private func finish(timedOut: Bool) {
    guard !finished else { return }
    finished = true
    Self.active = nil
    original.onObservedSnapshot = nil
    checks["completed_without_timeout"] = !timedOut
    measurements["timeout_stage"] = String(describing: stage)
    measurements["raw_control_receipts"] = rawControlReceipts
    measurements["raw_control_statuses"] = rawControlStatuses
    let result: [String: Any] = [
      "passed": !timedOut && checks.values.allSatisfy { $0 },
      "checks": checks, "measurements": measurements,
      "counts": ["required_checks": checks.count, "passed_checks": checks.values.filter { $0 }.count],
      "expected_known_text": [
        "WORD_TOKEN", "猫", "SEL_WIDE_猫_TOKEN", "LINE_TOKEN", "abcde", "ABCDE", "CLICK_TAIL", "CLOSE_TOKEN",
      ],
      "note": "Synthetic NSApp mouse events route through the real pane handlers and private fixture pasteboard. This is not physical HID proof."
    ]
    do {
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { NSLog("Selection smoke report failed: %@", String(describing: error)) }
    if !CommandLine.arguments.contains("--keep-open") { NSApp.terminate(nil) }
  }
}

import AppKit
import TerminalEngine

// Dispatches synthetic AppKit events and checks ZLE's independent editable buffer.
// Existing history suggestions are exercised, but never written to the report.
@MainActor final class EditingSmokeTest {
  private static var active: EditingSmokeTest?
  private let controller: TerminalWindow
  private let path: String
  private var latest: TerminalSnapshot?
  private var stage = 0
  private var round = 0
  private var baseline = (row: 0, col: 0)
  private var checks: [String: Bool] = [:]
  private var measurements: [String: Any] = [:]
  private var startupSnapshots = 0
  private var startupPromptSnapshots = 0
  private var startupReadySnapshots = 0
  private var keyboardMonitor: Any?
  private var syntheticEvent: NSEvent?
  private var suppressedExternalKeys = 0
  init(window: TerminalWindow, path: String) { controller = window; self.path = path }
  static func start(window: TerminalWindow, path: String) {
    let test = EditingSmokeTest(window: window, path: path)
    active = test
    // This fixture tests synthetic input. Physical keys on the shared desktop
    // must not mutate its fresh ZLE buffer before the first snapshot arrives.
    test.keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak test] event in
      guard let test, event.window === test.controller.window else { return event }
      guard event === test.syntheticEvent else {
        test.suppressedExternalKeys += 1
        return nil
      }
      return event
    }
    window.panes.first?.onObservedSnapshot = { [weak test] in test?.observe($0) }
    window.panes.first?.session.semanticProbe { _ in }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
      if active === test { test.checks["completed"] = false; test.finish() }
    }
  }
  private func observe(_ snapshot: TerminalSnapshot) {
    latest = snapshot
    let lines = snapshot.rows.map { $0.cells.map { $0.text }.joined().trimmingCharacters(in: .whitespaces) }
    if stage == 0 {
      startupSnapshots += 1
      if snapshot.at_prompt { startupPromptSnapshots += 1 }
      if snapshot.input_ready == true { startupReadySnapshots += 1 }
    }
    if stage == 0 && snapshot.input_ready == true && snapshot.modes.bracketed_paste
      && promptIsVisible(in: snapshot)
    {
      checks["startup_input_ready"] = true
      stage = -1
      let initial = snapshot.cursor.col
      measurements["fresh_initial_col"] = initial
      if let prompt = snapshot.rows[snapshot.cursor.row].cells.firstIndex(where: { $0.text == "❯" }) {
        measurements["fresh_starship_prompt_col"] = prompt
        measurements["fresh_starship_cursor_offset"] = initial - prompt
        let spanStart = min(prompt + 1, snapshot.cols)
        let spanEnd = max(spanStart, min(initial, snapshot.cols))
        measurements["fresh_starship_cells_after_prompt"] = snapshot.rows[snapshot.cursor.row].cells[spanStart..<spanEnd].count
        checks["fresh_starship_cursor_alignment"] = initial == prompt + 2
      }
      key(8, "c"); key(2, "d")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
        measurements["fresh_typed_col"] = latest?.cursor.col
        checks["fresh_typed_cursor"] = latest?.cursor.col == initial + 2
        key(51, "\u{7f}"); key(51, "\u{7f}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
          measurements["fresh_erased_col"] = latest?.cursor.col
          checks["fresh_erased_cursor"] = latest?.cursor.col == initial
          if let snapshot = latest {
            checks["fresh_no_stuck_cd"] = !snapshot.rows[snapshot.cursor.row].cells.map { $0.text }.joined().contains("cd")
          }
          setupProbe()
        }
      }
    } else if stage == 1 && snapshot.input_ready == true && snapshot.modes.bracketed_paste
      && promptIsVisible(in: snapshot) && lines.contains("HT_EDIT_READY") {
      stage = 2
      DispatchQueue.main.async { [self] in beginRound() }
    } else if stage == 4 {
      let prefix = "HT_EDIT_BUFFER_\(round + 1):"
      if let line = lines.last(where: { $0.hasPrefix(prefix) }) {
        checks["round_\(round)_zsh_buffer_empty"] = line == prefix + "<>:0"
        measurements["round_\(round)_buffer"] = line
        round += 1
        if round == 2 { checks["completed"] = true; finish() }
        else {
          stage = 2
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in beginRound() }
        }
      }
    }
  }
  private func setupProbe() {
      stage = 1
      let setup = #" unset HISTFILE; typeset _ht_probe_number=0; function _ht_edit_probe() { ((_ht_probe_number++)); zle -I; print -r -- "HT_EDIT_BUFFER_${_ht_probe_number}:<${BUFFER}>:${CURSOR}"; zle redisplay; }; zle -N _ht_edit_probe; bindkey '^X^V' _ht_edit_probe; printf 'HT_EDIT_READY\n'"#
      controller.panes.first?.insertText(setup, replacementRange: NSRange(location: NSNotFound, length: 0))
      key(36, "\r")
  }
  private func promptIsVisible(in snapshot: TerminalSnapshot) -> Bool {
    guard snapshot.rows.indices.contains(snapshot.cursor.row) else { return false }
    return snapshot.rows[snapshot.cursor.row].cells.contains { $0.text == "❯" }
  }
  private func beginRound() {
    guard let snapshot = latest else { finish(); return }
    baseline = (snapshot.cursor.row, snapshot.cursor.col)
    measurements["round_\(round)_initial_col"] = baseline.col
    key(8, "c")
    key(2, "d")
    if round == 1 { key(49, " ") }
    stage = 3
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
      guard let snapshot = latest else { finish(); return }
      let count = round == 0 ? 2 : 3
      checks["round_\(round)_typed_cursor"] =
        snapshot.cursor.row == baseline.row && snapshot.cursor.col == baseline.col + count
      measurements["round_\(round)_typed_col"] = snapshot.cursor.col
      for _ in 0..<count { key(51, "\u{7f}") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
        guard let snapshot = latest else { finish(); return }
        checks["round_\(round)_erased_cursor"] =
          snapshot.cursor.row == baseline.row && snapshot.cursor.col == baseline.col
        let line = snapshot.rows[snapshot.cursor.row].cells.map { $0.text }.joined()
        checks["round_\(round)_no_stuck_cd"] = !line.contains("cd")
        measurements["round_\(round)_erased_col"] = snapshot.cursor.col
        stage = 4
        key(7, "x", flags: .control)
        key(9, "v", flags: .control)
      }
    }
  }
  private func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) {
    guard let window = controller.window else { return }
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
      if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
        syntheticEvent = event
        NSApp.sendEvent(event)
        syntheticEvent = nil
      }
    }
  }
  private func finish() {
    guard Self.active === self else { return }
    Self.active = nil
    if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    keyboardMonitor = nil
    measurements["suppressed_external_key_events"] = suppressedExternalKeys
    measurements["startup_snapshot_count"] = startupSnapshots
    measurements["startup_prompt_snapshot_count"] = startupPromptSnapshots
    measurements["startup_input_ready_snapshot_count"] = startupReadySnapshots
    measurements["startup_timeout_phase"] = stage
    controller.panes.first?.onObservedSnapshot = nil
    let result: [String: Any] = ["passed": checks["completed"] == true && checks.values.allSatisfy { $0 },
      "checks": checks, "measurements": measurements,
      "note": "Synthetic AppKit events, current zsh configuration, existing history and ZLE buffer probe. This does not test physical keyboard delivery. No history suggestions recorded."]
    do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path), options: .atomic) }
    catch { NSLog("Editing smoke report failed: %@", String(describing: error)) }
    if !CommandLine.arguments.contains("--keep-open") { NSApp.terminate(nil) }
  }
}

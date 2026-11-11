import AppKit
import Darwin

@MainActor enum CloseSmokeTest {
  static func start(window: TerminalWindow, path: String) {
    var closing = false
    window.panes.first?.onObservedSnapshot = { snapshot in
      guard !closing, snapshot.rows.flatMap({ $0.cells }).map({ $0.text }).joined().contains("CLOSE_SMOKE_READY") else { return }
      closing = true
      window.panes.first?.session.statistics { stats in
        let shortcut = CommandLine.arguments.contains("--quit-shortcut")
        let report: [String: Any] = ["app_pid": ProcessInfo.processInfo.processIdentifier,
          "child_pid": stats["child_pid"] ?? -1, "trigger": shortcut ? "cmd+q" : "last-window-close"]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { NSLog("Close smoke report failed: %@", String(describing: error)) }
        if shortcut, let number = window.window?.windowNumber,
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: number, context: nil, characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: 12) {
          NSApp.sendEvent(event)
        } else { window.window?.performClose(nil) }
      }
    }
  }
}

// Separate test instance; invokes actual input/PTY/render paths without global input.
@MainActor final class NativeSmokeTest {
  private static var active: NativeSmokeTest?
  let controller: TerminalWindow
  let path: String
  let idle = CommandLine.arguments.contains("--idle-test")
  private var keyboardMonitor: Any?
  private var syntheticEvent: NSEvent?
  private var suppressedExternalKeys = 0
  var checks = Dictionary(
    uniqueKeysWithValues: [
      "pty_input_and_output", "unicode_text", "sgr_red", "ime_marked_state", "ime_unmarked_state",
      "ime_commit_once", "resize_epoch", "split_panes", "metal_submitted",
      "split_resize_frames_match_drawables",
      "split_resize_drops_stale_frames",
      "split_resize_layer_placement_configured",
      "completed_without_timeout", "accessibility_text_ranges", "accessibility_attributed_text",
      "startup_input_ready",
      "native_keypad_enter",
      "pane_focus_consistent", "settings_window",
      "preedit_cancelled_on_resize", "preedit_cancelled_on_focus", "cancel_did_not_commit_preedit",
      "search_navigated_and_highlighted",
      "command_left_begins_line", "command_right_route_ready", "command_right_accepts_zsh_suggestion",
      "command_k_shortcut_registered",
      "command_k_clears_history_and_redraws_prompt",
      "modifier_keys_preserve_selection",
      "starting_directory",
    ].map { ($0, false) })
  var measurements: [String: Any] = [:]
  var phase = -1
  var clearHistoryEpoch: UInt64 = 0
  var resizeEpoch: UInt64 = 0
  var oldCols = 0
  var maximumIMEMarkerLines = 0
  var geometryMismatchedPresents: UInt64 = 0
  var geometryMismatchedDrawables: UInt64 = 0
  var geometryDroppedStaleFrames: UInt64 = 0
  var startupSnapshots = 0
  var startupPromptSnapshots = 0
  var startupReadySnapshots = 0
  // Selection now belongs to the terminal owner. Keep the old modifier
  // regression check, but wait until its immutable publication is visible
  // before asking the AppKit surface to receive modifier changes.
  var startupGateReady = false
  var modifierSelection: NSRange?
  var modifierSelectionPending = false
  var modifierSelectionResult: Bool?
  var finalizing = false
  var finalAccessibilityRange: NSRange?
  init(window: TerminalWindow, path: String) {
    controller = window
    self.path = path
    // The idle run closes the pane the accessibility checks read and then
    // only watches the app at rest. Those checks belong to the normal run.
    if idle {
      checks["accessibility_text_ranges"] = nil
      checks["accessibility_attributed_text"] = nil
    }
  }
  static func start(window: TerminalWindow, path: String) {
    let test = NativeSmokeTest(window: window, path: path)
    active = test
    // The smoke's window is key while it runs, so keys typed by whoever is
    // using the machine would land in its shell and fail the input checks.
    // Only the key events the smoke sends itself reach the window.
    test.keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak test] event in
      guard let test, event.window === test.controller.window else { return event }
      guard event === test.syntheticEvent else {
        test.suppressedExternalKeys += 1
        return nil
      }
      return event
    }
    DispatchQueue.main.async { test.run() }
    DispatchQueue.main.asyncAfter(deadline: .now() + (test.idle ? 80 : 12)) {
      if active != nil { test.finish(timedOut: true) }
    }
  }
  func run() {
    guard let pane = controller.panes.first else {
      finish(timedOut: true)
      return
    }
    pane.onObservedSnapshot = { [weak self] snapshot in self?.observe(snapshot) }
    pane.session.semanticProbe { _ in }
  }
  private func beginModifierKeysPreserveSelection(_ pane: TerminalCanvasView) {
    let visible = pane.accessibilityVisibleCharacterRange()
    let text = pane.accessibilityString(for: visible).map { $0 as NSString }
    let firstCharacter = text?.rangeOfCharacter(from: CharacterSet.newlines.inverted).location ?? NSNotFound
    let selection = firstCharacter == NSNotFound ? NSRange(location: NSNotFound, length: 0)
      : pane.accessibilityRange(for: firstCharacter)
    guard selection.location != NSNotFound, selection.length > 0 else {
      modifierSelectionResult = false
      advanceStartupAfterModifierCheck()
      return
    }
    modifierSelection = selection
    modifierSelectionPending = true
    measurements["modifier_requested_range"] = ["location": selection.location, "length": selection.length]
    measurements["modifier_requested_text"] = pane.accessibilityString(for: selection) ?? ""
    pane.setAccessibilitySelectedTextRange(selection)
  }
  private func observeModifierKeysSelection(_ snapshot: TerminalSnapshot) {
    guard startupGateReady, modifierSelectionPending, let expected = modifierSelection,
      snapshot.selection.phase == .committed,
      !AccessibilityProjection(snapshot: snapshot).selectedRanges().isEmpty,
      let pane = controller.panes.first
    else { return }
    modifierSelectionPending = false
    measurements["modifier_requested_range"] = ["location": expected.location, "length": expected.length]
    measurements["modifier_published_ranges"] = AccessibilityProjection(snapshot: snapshot).selectedRanges().map {
      ["location": $0.location, "length": $0.length]
    }
    // Canvas publishes its observation before it updates its AX projection.
    // Let that presentation turn finish; this is a notification ordering
    // boundary, not an arbitrary timing delay.
    DispatchQueue.main.async { [weak self, weak pane] in
      guard let self, let pane, self.phase == -1 else { return }
      self.modifierSelectionResult = self.deliverModifierKeysPreserving(expected, to: pane)
      self.advanceStartupAfterModifierCheck()
    }
  }
  private func deliverModifierKeysPreserving(_ selection: NSRange, to pane: TerminalCanvasView) -> Bool {
    let event = { (flags: NSEvent.ModifierFlags, key: UInt16) in
      NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pane.window?.windowNumber ?? 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)
    }
    guard let shiftDown = event(.shift, 56),
      let commandDown = event([.shift, .command], 55),
      let commandUp = event(.shift, 55),
      let shiftUp = event([], 56)
    else { return false }
    for value in [shiftDown, commandDown, commandUp, shiftUp] {
      pane.flagsChanged(with: value)
      guard pane.accessibilitySelectedTextRange() == selection else { return false }
    }
    return true
  }
  private func advanceStartupAfterModifierCheck() {
    guard phase == -1, startupGateReady, let modifierSelectionResult else { return }
    checks["modifier_keys_preserve_selection"] = modifierSelectionResult
    phase = 0
    guard let window = controller.window, let pane = controller.panes.first else {
      finish(timedOut: true)
      return
    }
    // This fixture writes through the Canvas/Session boundary. Give its owned
    // window the same AppKit focus precondition as an interactive key route;
    // otherwise a direct executable launch can have a first responder while
    // its focus lifecycle remains false.
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(pane)
    controller.panes.forEach { $0.updateFocus() }
    DispatchQueue.main.async { [weak self, weak pane, weak window] in
      guard let self, let pane, let window, self.phase == 0 else { return }
      self.measurements["startup_command_app_active"] = NSApp.isActive
      self.measurements["startup_command_key_window"] = window.isKeyWindow
      self.measurements["startup_command_first_responder"] = window.firstResponder === pane
      self.measurements["startup_command_pane_focused"] = pane.geometryReport()["focused"] as? Bool == true
      self.runCommand()
    }
  }
  private func runCommand() {
    guard let pane = controller.panes.first else { return }
    pane.insertText(
      #"printf '\033[2J\033[H\033[31mRED\033[0m Unicode: 猫 é 👩🏽‍💻 🇳🇴\nSTARTUP_PWD=%s\nSMOKE_SENTINEL\n' "$PWD""#,
      replacementRange: NSRange(location: NSNotFound, length: 0))
    pane.doCommand(by: NSSelectorFromString("insertNewline:"))
  }
  private func startKeypadProbe() {
    guard let pane = controller.panes.first else { return }
    pane.insertText(
      #"printf '\033>\033[=0u'; stty raw -echo min 0 time 10; printf 'KEYPAD_READY\n'; bytes=$(dd bs=1 count=64 2>/dev/null | od -An -tx1 | tr -d ' \n'); stty sane; printf 'KEYPAD_BYTES_%s\n' "$bytes""#,
      replacementRange: NSRange(location: NSNotFound, length: 0))
    pane.doCommand(by: NSSelectorFromString("insertNewline:"))
  }
  private func deliverKeypadEnter() -> Bool {
    guard let pane = controller.panes.first,
      let down = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: pane.window?.windowNumber ?? 0, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 76),
      let up = NSEvent.keyEvent(
        with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: pane.window?.windowNumber ?? 0, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: 76)
    else { return false }
    pane.keyDown(with: down)
    pane.keyUp(with: up)
    return true
  }
  func observe(_ snapshot: TerminalSnapshot) {
    if finalizing {
      observeFinalAccessibilitySelection(snapshot)
      return
    }
    if phase == -1 {
      startupSnapshots += 1
      if snapshot.at_prompt { startupPromptSnapshots += 1 }
      if snapshot.input_ready == true { startupReadySnapshots += 1 }
      guard snapshot.input_ready == true && snapshot.at_prompt && snapshot.modes.bracketed_paste else {
        return
      }
      if !startupGateReady {
        startupGateReady = true
        checks["startup_input_ready"] = true
        measurements["startup_gate_at_prompt"] = snapshot.at_prompt
        measurements["startup_gate_bracketed_paste"] = snapshot.modes.bracketed_paste
        if let pane = controller.panes.first {
          // Canvas invokes observers before installing this immutable
          // projection. AX range conversion must use the next applied view.
          DispatchQueue.main.async { [weak self, weak pane] in
            guard let self, let pane, self.phase == -1, self.modifierSelectionResult == nil else { return }
            self.beginModifierKeysPreserveSelection(pane)
          }
        } else {
          modifierSelectionResult = false
        }
      }
      observeModifierKeysSelection(snapshot)
      advanceStartupAfterModifierCheck()
      return
    }
    let lines = snapshot.rows.map { $0.cells.map { $0.text }.joined() }
    let text = lines.joined(separator: "\n")
    if text.contains("DISCARDED_PREEDIT") { checks["cancel_did_not_commit_preedit"] = false }
    maximumIMEMarkerLines = max(
      maximumIMEMarkerLines,
      lines.filter { $0.trimmingCharacters(in: .whitespaces) == "IME_COMMIT" }.count)
    if phase == 0 && text.contains("SMOKE_SENTINEL")
      && snapshot.rows.first?.cells.prefix(3).map({ $0.text }).joined() == "RED"
    {
      checks["pty_input_and_output"] = true
      let directory = lines.first(where: { $0.hasPrefix("STARTUP_PWD=") })?.dropFirst("STARTUP_PWD=".count)
      checks["starting_directory"] = directory.map(String.init)
        == URL(fileURLWithPath: LaunchSpec.shell.cwd).resolvingSymlinksInPath().path
      measurements["starting_directory"] = directory.map(String.init) ?? ""
      checks["unicode_text"] = text.contains("猫 é 👩🏽‍💻 🇳🇴")
      checks["sgr_red"] = snapshot.rows.flatMap { $0.cells }.contains {
        $0.text == "R" && $0.style.foreground.index == 1
      }
      phase = -3
      startKeypadProbe()
    } else if phase == -3,
      lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "KEYPAD_READY" })
    {
      phase = -2
      measurements["native_keypad_dispatch_accepted"] = deliverKeypadEnter()
    } else if phase == -2,
      let line = lines.first(where: { $0.hasPrefix("KEYPAD_BYTES_") })
    {
      let bytes = String(line.dropFirst("KEYPAD_BYTES_".count))
      measurements["native_keypad_bytes"] = bytes
      measurements["native_keypad_expected_bytes"] = "0d"
      checks["native_keypad_enter"] = bytes == "0d"
      phase = 1
      if let pane = controller.panes.first {
        pane.setMarkedText(
          "printf 'IME_COMMIT\\n';", selectedRange: NSRange(location: 0, length: 0),
          replacementRange: NSRange(location: NSNotFound, length: 0))
        checks["ime_marked_state"] = pane.hasMarkedText()
        pane.unmarkText()
        checks["ime_unmarked_state"] = !pane.hasMarkedText()
        pane.doCommand(by: NSSelectorFromString("insertNewline:"))
      }
    } else if phase == 1 && maximumIMEMarkerLines == 1
      && snapshot.at_prompt && snapshot.input_ready == true && snapshot.modes.bracketed_paste {
      checks["ime_commit_once"] = true
      resizeEpoch = snapshot.geometry_epoch
      oldCols = snapshot.cols
      phase = 2
      controller.panes.first?.setMarkedText(
        "RESIZE_DISCARDED_PREEDIT", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      checks["cancel_did_not_commit_preedit"] = true
      controller.window?.setContentSize(NSSize(width: 850, height: 530))
    } else if phase == 2 && snapshot.geometry_epoch > resizeEpoch && snapshot.cols != oldCols {
      checks["resize_epoch"] = true
      phase = 3
      // The observer runs before the canvas accepts this snapshot; defer until
      // its geometry-epoch cancellation has executed, before testing focus loss.
      DispatchQueue.main.async { [self] in
        checks["preedit_cancelled_on_resize"] = controller.panes.first?.hasMarkedText() == false
        controller.panes.first?.setMarkedText(
          "FOCUS_DISCARDED_PREEDIT", selectedRange: NSRange(location: 0, length: 0),
          replacementRange: NSRange(location: NSNotFound, length: 0))
        geometryMismatchedPresents = RendererMetrics.mismatchedPresentations()
        geometryMismatchedDrawables = RendererMetrics.report()["mismatched_drawables"] as? UInt64 ?? 0
        geometryDroppedStaleFrames = RendererMetrics.staleFrameDropCount()
        controller.splitVertical(nil)
        checks["preedit_cancelled_on_focus"] = controller.panes.first?.hasMarkedText() == false
        checks["split_panes"] =
          controller.panes.count == 2
          && controller.panes.allSatisfy { $0.bounds.width > 100 && $0.bounds.height > 80 }
        checks["pane_focus_consistent"] = controller.panes.allSatisfy { pane in
          let expected =
            controller.window?.isKeyWindow == true && controller.window?.firstResponder === pane
          return pane.geometryReport()["focused"] as? Bool == expected
        }
        checks["split_resize_layer_placement_configured"] = controller.panes.allSatisfy {
          $0.layerContentsPlacement == .topLeft
        }
        exerciseSplitResizeStress { [self] in
          let mismatches = RendererMetrics.report()["mismatched_drawables"] as? UInt64 ?? 0
          let drops = RendererMetrics.staleFrameDropCount()
          checks["split_resize_frames_match_drawables"] =
            RendererMetrics.mismatchedPresentations() == geometryMismatchedPresents
          // A fast or occluded renderer may acquire no stale drawable. Require
          // drops when a mismatch was observed, rather than requiring a race.
          checks["split_resize_drops_stale_frames"] =
            mismatches == geometryMismatchedDrawables || drops > geometryDroppedStaleFrames
          measurements["split_resize_mismatched_drawables"] = mismatches - geometryMismatchedDrawables
          measurements["split_resize_stale_frames_dropped"] = drops - geometryDroppedStaleFrames
          checks["metal_submitted"] = RendererMetrics.submissions() > 0
          phase = 4
          controller.panes.first?.session.find("SMOKE_SENTINEL") { [weak self] outcome in
            if outcome != .found { self?.finish(timedOut: true) }
          }
        }
      }
    } else if phase == 4 && !snapshot.search.isEmpty {
      checks["search_navigated_and_highlighted"] = snapshot.search.contains { hit in
        snapshot.rows[hit.row].cells[hit.start..<hit.end].map { $0.text }.joined() == "SMOKE_SENTINEL"
      }
      phase = 5
    }
    if phase == 5 {
      measurements["navigation_prompt_at_prompt"] = snapshot.at_prompt
      measurements["navigation_prompt_input_ready"] = snapshot.input_ready == true
      measurements["navigation_prompt_bracketed_paste"] = snapshot.modes.bracketed_paste
      guard snapshot.at_prompt && snapshot.input_ready == true && snapshot.modes.bracketed_paste else { return }
      phase = 6
      DispatchQueue.main.async { [self] in testCommandNavigation() }
    } else if phase == 6 && lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "CMD_LEFT_OK" }) {
      checks["command_left_begins_line"] = true
      phase = 7
      if let pane = controller.panes.first {
        pane.insertText(
          #"HISTFILE=/dev/null; print -rs -- "printf 'CMD_SUGGEST_OK\n'"; printf 'SUGGEST_READY\n'"#,
          replacementRange: NSRange(location: NSNotFound, length: 0))
        pane.doCommand(by: NSSelectorFromString("insertNewline:"))
      }
    } else if phase == 7 && lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "SUGGEST_READY" }) {
      measurements["suggestion_prompt_at_prompt"] = snapshot.at_prompt
      measurements["suggestion_prompt_input_ready"] = snapshot.input_ready == true
      measurements["suggestion_prompt_bracketed_paste"] = snapshot.modes.bracketed_paste
      // SUGGEST_READY is printed before zsh necessarily returns to ZLE. Do not
      // type into that gap, because an autosuggestion cannot be accepted yet.
      guard snapshot.at_prompt && snapshot.input_ready == true && snapshot.modes.bracketed_paste else {
        return
      }
      phase = 8
      controller.panes.first?.insertText(
        "printf 'CMD_SUGGEST", replacementRange: NSRange(location: NSNotFound, length: 0))
    } else if phase == 8 && suggestionCandidateVisible(in: snapshot) {
      // The setup command is still visible in scrollback and contains this
      // marker. Only accept it on the active input row, where zsh renders its
      // candidate after the entered prefix.
      measurements["suggestion_candidate_visible"] = true
      phase = 9
      if let pane = controller.panes.first, commandSuggestionRouteReady(pane) {
        deliverCommandArrow(left: false)
        pane.doCommand(by: NSSelectorFromString("insertNewline:"))
      } else {
        finish(timedOut: false)
      }
    } else if phase == 9 && lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "CMD_SUGGEST_OK" }) {
      checks["command_right_accepts_zsh_suggestion"] = true
      phase = 10
    }
    if phase == 10 && snapshot.at_prompt && snapshot.modes.bracketed_paste {
      phase = 11
      clearHistoryEpoch = snapshot.history_epoch
      measurements["clear_key_window"] = controller.window?.isKeyWindow == true
      measurements["clear_app_key_window"] = NSApp.keyWindow === controller.window
      checks["command_k_shortcut_registered"] = hasClearScreenShortcut()
      // NSApp's synthetic key routing needs an active key window. The smoke
      // owns this pane, so exercise the action directly and assert the menu
      // registration separately; the two contracts remain independently testable.
      controller.panes.first?.clearScreen(nil)
    } else if phase == 11 && snapshot.at_prompt && snapshot.modes.bracketed_paste && snapshot.history_epoch > clearHistoryEpoch
      && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      checks["command_k_clears_history_and_redraws_prompt"] = snapshot.history_rows == 0
        && !text.contains("CMD_SUGGEST_OK") && !text.contains("SMOKE_SENTINEL")
      phase = 12
      if let pane = controller.panes.first {
        pane.insertText(
          "printf '\\033[=8uKITTY_SELECTION_%s\\n' READY",
          replacementRange: NSRange(location: NSNotFound, length: 0))
        pane.doCommand(by: NSSelectorFromString("insertNewline:"))
      }
    } else if phase == 12
      && lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "KITTY_SELECTION_READY" })
    {
      phase = 13
      if idle {
        controller.closePane(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in measureIdle() }
      } else { DispatchQueue.main.async { [self] in finish(timedOut: false) } }
    }
    if phase == 11 {
      measurements["clear_epoch_before"] = clearHistoryEpoch
      measurements["clear_epoch_after"] = snapshot.history_epoch
      measurements["clear_at_prompt"] = snapshot.at_prompt
      measurements["clear_bracketed_paste"] = snapshot.modes.bracketed_paste
    }
  }
  private func exerciseSplitResizeStress(completion: @escaping @MainActor @Sendable () -> Void) {
    guard let window = controller.window else {
      completion()
      return
    }
    let sizes = (0..<48).map { index in
      NSSize(
        width: index.isMultiple(of: 2) ? 820 : 1180,
        height: index.isMultiple(of: 3) ? 460 : 760)
    }
    func resize(_ index: Int) {
      guard index < sizes.count else {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { completion() }
        return
      }
      window.setContentSize(sizes[index])
      window.contentView?.layoutSubtreeIfNeeded()
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2)) { resize(index + 1) }
    }
    resize(0)
  }
  private func testCommandNavigation() {
    guard let pane = controller.panes.first, let window = controller.window else { return }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(pane)
    controller.panes.forEach { $0.updateFocus() }
    DispatchQueue.main.async { [self] in
      measurements["navigation_app_active"] = NSApp.isActive
      measurements["navigation_key_window"] = window.isKeyWindow
      measurements["navigation_app_key_window"] = NSApp.keyWindow === window
      measurements["navigation_first_responder"] = window.firstResponder === pane
      // The key goes to this window itself, so the route does not need the
      // app to be the active one: someone may be working in another app.
      let ready = window.firstResponder === pane
      measurements["navigation_route_ready"] = ready
      guard ready else {
        finish(timedOut: true)
        return
      }
      pane.insertText(" : ", replacementRange: NSRange(location: NSNotFound, length: 0))
      deliverCommandArrow(left: true)
      pane.insertText("printf 'CMD_LEFT_OK\\n';", replacementRange: NSRange(location: NSNotFound, length: 0))
      pane.doCommand(by: NSSelectorFromString("insertNewline:"))
    }
  }
  private func commandSuggestionRouteReady(_ pane: TerminalCanvasView) -> Bool {
    guard let window = controller.window else {
      measurements["command_right_route_ready"] = false
      measurements["command_right_focus_interference"] = true
      checks["command_right_route_ready"] = false
      return false
    }
    measurements["command_right_app_active"] = NSApp.isActive
    measurements["command_right_key_window"] = window.isKeyWindow
    measurements["command_right_app_key_window"] = NSApp.keyWindow === window
    measurements["command_right_first_responder"] = window.firstResponder === pane
    let focused = pane.geometryReport()["focused"] as? Bool == true
    measurements["command_right_pane_focused"] = focused
    let ready = window.firstResponder === pane
    measurements["command_right_route_ready"] = ready
    // Recorded, not required: whether another app had the keyboard meanwhile.
    measurements["command_right_focus_interference"] = !(NSApp.isActive && window.isKeyWindow && focused)
    checks["command_right_route_ready"] = ready
    return ready
  }
  private func suggestionCandidateVisible(in snapshot: TerminalSnapshot) -> Bool {
    guard snapshot.rows.indices.contains(snapshot.cursor.row) else { return false }
    let inputRow = snapshot.rows[snapshot.cursor.row].cells.map(\.text).joined()
    return inputRow.contains("CMD_SUGGEST_OK")
  }
  private func hasClearScreenShortcut() -> Bool {
    func containsShortcut(in menu: NSMenu) -> Bool {
      for item in menu.items {
        if item.action == #selector(TerminalCanvasView.clearScreen(_:))
          && item.keyEquivalent == "k" && item.keyEquivalentModifierMask == .command
        { return true }
        if let submenu = item.submenu, containsShortcut(in: submenu) { return true }
      }
      return false
    }
    guard let menu = NSApp.mainMenu else { return false }
    return containsShortcut(in: menu)
  }
  /// Sends a key event the way the application object would send it to its
  /// key window: key equivalents of the window, then of the menu, then the
  /// first responder. Going to the window directly, it also arrives while
  /// another app is active.
  private static func route(_ event: NSEvent, to window: NSWindow) {
    if event.type == .keyDown {
      if window.performKeyEquivalent(with: event) { return }
      if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
    }
    window.sendEvent(event)
  }
  private func deliverCommandArrow(left: Bool) {
    guard let window = controller.window else { return }
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
      if let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: left ? "\u{f702}" : "\u{f703}",
        charactersIgnoringModifiers: left ? "\u{f702}" : "\u{f703}",
        isARepeat: false, keyCode: left ? 123 : 124)
      {
        syntheticEvent = event
        Self.route(event, to: window)
        syntheticEvent = nil
      }
    }
  }
  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
      usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
  private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }
  private func measureIdle() {
    let initial = RendererMetrics.submissions()
    let cpu = cpuSeconds()
    let start = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [self] in
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
      let utilization = (cpuSeconds() - cpu) / elapsed * 100
      let submitted = RendererMetrics.submissions() - initial
      measurements = [
        "idle_seconds": elapsed, "idle_gpu_submissions": submitted,
        "idle_cpu_percent_of_one_core": utilization, "physical_footprint_bytes": footprint(),
        "visible_panes": controller.panes.count, "blink_enabled": false,
      ]
      checks["idle_zero_gpu_submissions"] = submitted == 0
      checks["idle_cpu_below_half_percent"] = utilization < 0.5
      finish(timedOut: false)
    }
  }
  private func observeFinalAccessibilitySelection(_ snapshot: TerminalSnapshot) {
    guard let expected = finalAccessibilityRange,
      AccessibilityProjection(snapshot: snapshot).selectedRanges().contains(expected),
      let pane = controller.panes.first
    else { return }
    finalAccessibilityRange = nil
    // `onObservedSnapshot` deliberately precedes Canvas's projection update.
    // Read AX back on the next main turn, after that exact owner snapshot has
    // become the view's applied projection.
    DispatchQueue.main.async { [weak self, weak pane] in
      guard let self, let pane, self.finalizing else { return }
      self.checkFinalAccessibility(on: pane, expectedSelection: expected)
      self.completeFinish(timedOut: false)
    }
  }
  private func checkFinalAccessibility(on pane: TerminalCanvasView, expectedSelection: NSRange) {
    let visible = pane.accessibilityVisibleCharacterRange()
    let text = pane.accessibilityString(for: visible)
    let frame = pane.accessibilityFrame(for: expectedSelection)
    checks["accessibility_text_ranges"] =
      visible.location == 0 && visible.length == pane.accessibilityNumberOfCharacters()
      && text?.utf16.count == visible.length
      && pane.accessibilityLine(for: 0) == 0
      && pane.accessibilityRange(forLine: 0).location == 0
      && pane.accessibilitySelectedTextRange() == expectedSelection
      && pane.accessibilitySelectedText() == pane.accessibilityString(for: expectedSelection)
      && pane.accessibilityRange(for: NSPoint(x: frame.midX, y: frame.midY)) == expectedSelection
      && !pane.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:"))
      && frame.width > 0 && frame.height > 0
    measurements["accessibility_utf16_count"] = visible.length
    measurements["accessibility_first_range_frame"] = NSStringFromRect(frame)
    if let text {
      let styled = (text as NSString).rangeOfCharacter(from: CharacterSet.newlines.inverted)
      if styled.location != NSNotFound, let attributed = pane.accessibilityAttributedString(for: styled) {
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        let run = pane.accessibilityStyleRange(for: styled.location)
        checks["accessibility_attributed_text"] = attributed.string == pane.accessibilityString(for: styled)
          && attributes[.accessibilityFont] is [String: Any]
          && attributes[.accessibilityForegroundColor].map { CFGetTypeID($0 as CFTypeRef) == CGColor.typeID } == true
          && attributes[.accessibilityBackgroundColor].map { CFGetTypeID($0 as CFTypeRef) == CGColor.typeID } == true
          && run.location != NSNotFound && NSLocationInRange(styled.location, run)
      }
    }
  }
  func finish(timedOut: Bool) {
    guard Self.active != nil else { return }
    if finalizing {
      // The outer smoke liveness bound remains authoritative if an owner
      // request was rejected or never published.
      if timedOut { completeFinish(timedOut: true) }
      return
    }
    checks["completed_without_timeout"] = !timedOut
    // Count output lines, not readline/kernel echo redraws. A duplicate commit
    // executes the semicolon-terminated command twice and must fail this check.
    checks["ime_commit_once"] = maximumIMEMarkerLines == 1
    measurements["maximum_ime_output_marker_lines"] = maximumIMEMarkerLines
    measurements["startup_snapshot_count"] = startupSnapshots
    measurements["startup_prompt_snapshot_count"] = startupPromptSnapshots
    measurements["startup_input_ready_snapshot_count"] = startupReadySnapshots
    measurements["startup_timeout_phase"] = phase
    guard !timedOut, let pane = controller.panes.first else {
      completeFinish(timedOut: timedOut)
      return
    }
    let first = pane.accessibilityRange(for: 0)
    guard first.location != NSNotFound, first.length > 0 else {
      completeFinish(timedOut: false)
      return
    }
    finalizing = true
    finalAccessibilityRange = first
    pane.setAccessibilitySelectedTextRange(first)
  }
  private func completeFinish(timedOut: Bool) {
    guard Self.active != nil else { return }
    Self.active = nil
    if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    keyboardMonitor = nil
    measurements["suppressed_external_keys"] = suppressedExternalKeys
    (NSApp.delegate as? AppDelegate)?.settings(nil)
    if let settings = NSApp.windows.first(where: { $0.title == "Settings" && $0.isVisible }) {
      checks["settings_window"] = true
      settings.close()
    }
    let result: [String: Any] = [
      "checks": checks, "passed": checks.values.allSatisfy { $0 },
      "render": RendererMetrics.report(), "measurements": measurements, "renderer": "Metal",
      "pane_geometry": controller.panes.map { $0.geometryReport() },
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "note":
        "Programmatic native input/PTY/resize/split smoke. Real input methods and VoiceOver require interactive validation. GPU command time is not display latency.",
    ]
    do {
      let data = try JSONSerialization.data(
        withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { NSLog("Smoke report failed: %@", String(describing: error)) }
    controller.panes.forEach { $0.onObservedSnapshot = nil }
    if !CommandLine.arguments.contains("--keep-open") { NSApp.terminate(nil) }
  }
}

@MainActor final class DemoSmokeTest {
  private static var active: DemoSmokeTest?
  let controller: TerminalWindow
  let path: String
  var updates = 0
  var coloredCells = 0
  var imageDimensions: Set<String> = []
  var maxImagePixels = 0
  var statusesSeen: Set<String> = []
  var alternateSeen = false
  var exited = false
  var statuses: [String] = []
  var controls: [String: Bool] = [:]
  let initialSubmissions = RendererMetrics.submissions()
  init(window: TerminalWindow, path: String) {
    controller = window
    self.path = path
  }
  static func start(window: TerminalWindow, path: String) {
    let test = DemoSmokeTest(window: window, path: path)
    active = test
    test.run()
  }
  func run() {
    guard let pane = controller.panes.first else { return }
    pane.onObservedSnapshot = { [weak self] snapshot in
      guard let self else { return }
      updates += 1
      alternateSeen = alternateSeen || snapshot.alternate
      for image in snapshot.images {
        imageDimensions.insert("\(image.width)x\(image.height)")
        maxImagePixels = max(maxImagePixels, image.width * image.height)
      }
      for row in snapshot.rows {
        let text = row.cells.map { $0.text }.joined()
        if text.contains("fps") && text.contains(" ch ") { statusesSeen.insert(text) }
      }
      coloredCells = max(
        coloredCells,
        snapshot.rows.flatMap { $0.cells }.filter {
          $0.style.foreground.rgb != nil || $0.style.background.rgb != nil
        }.count)
    }
    let originalStatus = pane.onStatus
    pane.onStatus = { [weak self] text in
      originalStatus?(text)
      self?.statuses.append(text)
      if text.hasPrefix("Process exited") { self?.exited = true }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
      controls["pause_admitted"] = pane.session.input(" ")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
      controls["resume_admitted"] = pane.session.input(" ")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [self] in
      controls["seek_admitted"] = pane.session.input(key: 12)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [self] in
      controller.window?.setContentSize(NSSize(width: 880, height: 600))
      controls["resize_requested"] = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 11) { [self] in
      controls["speed_admitted"] = pane.session.input(key: 10)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 13) { [self] in
      controls["quit_admitted"] = pane.session.input("q")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in finish() }
  }
  func finish() {
    guard Self.active != nil else { return }
    Self.active = nil
    let render = RendererMetrics.report()
    var checks: [String: Bool] = [
      "multiple_snapshots": updates > 10,
      "graphics_payload": coloredCells > 100 || maxImagePixels > 0,
      "alternate_screen": alternateSeen,
      "gpu_frames": RendererMetrics.submissions() - initialSubmissions > 10,
      "controls_admitted": controls.count == 6 && controls.values.allSatisfy { $0 },
      "child_exited_after_quit": exited, "no_metal_errors": (render["command_errors"] as? Int) == 0,
    ]
    if CommandLine.arguments.contains("kitty") || CommandLine.arguments.contains("auto") {
      checks["kitty_image_received"] = maxImagePixels > 0
    }
    let report: [String: Any] = [
      "checks": checks, "passed": checks.values.allSatisfy { $0 }, "updates": updates,
      "image_dimensions": imageDimensions.sorted(), "max_image_pixels": maxImagePixels,
      "player_status_samples": statusesSeen.sorted(), "max_truecolor_cells": coloredCells,
      "render": render, "controls": controls,
      "statuses": statuses, "pane_geometry": controller.panes.map { $0.geometryReport() },
      "arguments": CommandLine.arguments,
      "note":
        "Real dmscene PTY playback with the graphics mode recorded in arguments and --mute; macOS output muted before launch. Scripted pause/resume/seek/resize/speed/q through the terminal owner; admission is recorded separately from rendered behavior.",
    ]
    do {
      guard JSONSerialization.isValidJSONObject(report) else {
        NSLog("Invalid benchmark report")
        return
      }
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { NSLog("Demo report failed: %@", String(describing: error)) }
    controller.panes.forEach { $0.onObservedSnapshot = nil }
    NSApp.terminate(nil)
  }
}

@MainActor final class CatSmokeTest {
  static private var active: CatSmokeTest?
  let controller: TerminalWindow
  let path: String
  let expected: UInt64
  let started = DispatchTime.now().uptimeNanoseconds
  var uiDelay: [Double] = []
  var ownerDelay: [Double] = []
  var peakFootprint: UInt64 = 0
  var samples = 0
  var updates = 0
  var exitStatus = ""
  var latestViewport: [String: Any] = [:]
  var anchoredSnapshotCount = 0
  var finishing = false
  var latest: [String: Any] = [:]
  let motionStress = CommandLine.arguments.prefix { $0 != "--execute" }.contains("--cat-motion-stress")
  var motion: WindowStressMotion?
  var finalMotionReport: [String: Any]?
  init(window: TerminalWindow, path: String, bytes: UInt64) {
    controller = window
    self.path = path
    expected = bytes
  }
  static func start(window: TerminalWindow, path: String, bytes: UInt64) {
    let test = CatSmokeTest(window: window, path: path, bytes: bytes)
    active = test
    test.run()
  }
  private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }
  func run() {
    guard let pane = controller.panes.first else { return }
    if motionStress, let window = controller.window {
      motion = WindowStressMotion.start(window: window)
    }
    pane.onObservedSnapshot = { [weak self] snapshot in
      guard let self else { return }
      updates += 1
      if !snapshot.following_tail { anchoredSnapshotCount += 1 }
      latestViewport = [
        "columns": snapshot.cols, "rows": snapshot.rows.count,
        "following_tail": snapshot.following_tail, "scroll_offset": snapshot.scroll_offset,
        "history_rows": snapshot.history_rows, "alternate": snapshot.alternate,
        "geometry_epoch": snapshot.geometry_epoch,
        "clamp_revision": snapshot.viewport_clamp_revision,
      ]
    }
    let oldStatus = pane.onStatus
    pane.onStatus = { [weak self] value in
      oldStatus?(value)
      guard let self else { return }
      if value.hasPrefix("Process exited") { exitStatus = value }
      if value == "Session finished" { finish(timeout: false) }
    }
    heartbeat()
    sample()
    if !motionStress {
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
        self?.controller.window?.setContentSize(NSSize(width: 900, height: 620))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
        self?.controller.window?.setContentSize(NSSize(width: 1000, height: 680))
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
      self?.finish(timeout: true)
    }
  }
  func heartbeat() {
    guard !finishing else { return }
    let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
    DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) {
      [weak self] in
      guard let self, !finishing else { return }
      let now = DispatchTime.now().uptimeNanoseconds
      let delay = Double(now >= deadline ? now - deadline : 0) / 1_000_000
      if uiDelay.count == 12_000 { uiDelay.removeFirst() }
      uiDelay.append(delay)
      heartbeat()
    }
  }
  func sample() {
    guard !finishing, let pane = controller.panes.first else { return }
    peakFootprint = max(peakFootprint, footprint())
    samples += 1
    pane.session.semanticProbe { [weak self] delay in self?.ownerDelay.append(delay) }
    pane.session.statistics { [weak self] values in
      guard let self, !finishing else { return }
      latest = values
      write(final: false, timeout: false)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sample() }
  }
  func finish(timeout: Bool) {
    guard !finishing, let pane = controller.panes.first else { return }
    finishing = true
    if let motion {
      finalMotionReport = motion.stop(reason: timeout ? .catTimedOut : .catFinished)
      self.motion = nil
    }
    pane.session.statistics { [self] values in
      latest = values
      peakFootprint = max(peakFootprint, footprint())
      write(final: true, timeout: timeout)
      Self.active = nil
      NSApp.terminate(nil)
    }
  }
  func write(final: Bool, timeout: Bool) {
    let read = (latest["bytes_read"] as? UInt64) ?? 0
    let parsed = (latest["bytes_parsed"] as? UInt64) ?? 0
    let checks: [String: Bool] = [
      "complete_file": final && read >= expected, "all_pty_bytes_parsed": read == parsed,
      "child_exit_success": exitStatus.contains("status 0"),
      "history_within_64_mib": ((latest["history_bytes"] as? UInt64) ?? 0) <= 64 * 1_048_576,
      "not_timed_out": !timeout,
    ]
    var report: [String: Any] = [
      "final": final, "passed": final && checks.values.allSatisfy { $0 }, "checks": checks,
      "source_file_bytes": expected, "session": latest,
      "wall_seconds": Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000,
      "peak_physical_footprint_bytes": peakFootprint,
      "current_physical_footprint_bytes": footprint(), "samples": samples,
      "snapshot_updates": updates, "main_queue_delay": TimingDistribution.report(uiDelay),
      "viewport": latestViewport, "anchored_snapshots": anchoredSnapshotCount,
      "semantic_queue_probe_delay": TimingDistribution.report(ownerDelay),
      "exit_status": exitStatus,
      "renderer": RendererMetrics.report(),
      "note": motionStress
        ? "Actual /bin/cat of a local SQL dump with opt-in smooth programmatic window motion. Report contains no SQL content. PTY wire bytes can exceed file bytes because normal terminal output processing expands LF to CRLF. Timings are a development stress run, not an isolated comparison benchmark."
        : "Actual /bin/cat of a local SQL dump. Report contains no SQL content. PTY wire bytes can exceed file bytes because normal terminal output processing expands LF to CRLF. Includes two live resizes during output; timings are a development stress run, not an isolated comparison benchmark.",
    ]
    if motionStress {
      report["window_motion"] = final ? finalMotionReport ?? motion?.report() ?? [:] : motion?.report() ?? [:]
    }
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { NSLog("Cat report failed: %@", String(describing: error)) }
  }
}

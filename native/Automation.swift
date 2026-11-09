import AppKit

/// The deliberately small AppleScript boundary. It resolves a stable pane
/// identifier to the existing UI/session owner and never treats screen output
/// as editable text.
private enum TerminalAutomation {
  static let panePrefix = "no.helgesverre.terminal.pane."
  static let defaultScreenLimit = 32_768
  static let maximumScreenLimit = 262_144

  static var delegate: AppDelegate? {
    guard let delegate = NSApp.delegate as? AppDelegate, delegate.acceptsAutomation else { return nil }
    return delegate
  }

  static func pane(id: String?) -> TerminalCanvasView? {
    guard let delegate else { return nil }
    if let id {
      guard !id.isEmpty else { return nil }
      let normalized = id.hasPrefix(panePrefix) ? String(id.dropFirst(panePrefix.count)) : id
      return delegate.windows.lazy.flatMap(\.panes).first { $0.automationID == normalized }
    }
    return delegate.intendedPane()
  }

  static func paneID(_ pane: TerminalCanvasView) -> String { panePrefix + pane.automationID }

  static func focus(_ pane: TerminalCanvasView) {
    pane.window?.makeKeyAndOrderFront(nil)
    pane.window?.makeFirstResponder(pane)
    delegate?.rememberFocus(pane)
    pane.updateFocus()
  }

}

class TerminalScriptCommand: NSScriptCommand {
  @discardableResult
  func fail(_ message: String, number: Int = -1728) -> Any? {
    scriptErrorNumber = number
    scriptErrorString = message
    return nil
  }

  func pane() -> TerminalCanvasView? {
    let target = evaluatedArguments?["PaneID"] as? String
    guard let pane = TerminalAutomation.pane(id: target) else {
      fail(
        target == nil
          ? "No terminal pane has focus. Focus a pane or pass its pane id."
          : "The requested terminal pane is closed or does not exist.")
      return nil
    }
    return pane
  }
  func screenLimit() -> Int? {
    guard let value = evaluatedArguments?["MaxCharacters"] else {
      return TerminalAutomation.defaultScreenLimit
    }
    guard let number = value as? NSNumber else {
      fail("max characters must be a whole number.", number: -1700)
      return nil
    }
    let limit = number.intValue
    guard limit > 0, limit <= TerminalAutomation.maximumScreenLimit else {
      fail("max characters must be between 1 and \(TerminalAutomation.maximumScreenLimit).", number: -1700)
      return nil
    }
    return Int(limit)
  }
}

@objc(TerminalSendTextCommand)
final class TerminalSendTextCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let text = directParameter as? String, !text.isEmpty else {
      return fail("send text requires nonempty text.", number: -1700)
    }
    guard let pane = pane() else { return nil }
    guard pane.submitAutomationText(text) else {
      return fail("The terminal pane rejected input because it is busy or closed.", number: -1719)
    }
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalReadScreenCommand)
final class TerminalReadScreenCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let pane = pane(), let limit = screenLimit() else { return nil }
    let screen = pane.accessibilityValue() as? String ?? ""
    return String(screen.suffix(limit))
  }
}

@objc(TerminalClearScreenCommand)
final class TerminalClearScreenCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let pane = pane() else { return nil }
    pane.clearScreen(nil)
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalFocusPaneCommand)
final class TerminalFocusPaneCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let pane = pane() else { return nil }
    TerminalAutomation.focus(pane)
    return TerminalAutomation.paneID(pane)
  }
}

private func split(_ command: TerminalScriptCommand, vertical: Bool) -> Any? {
  guard let pane = command.pane(), let window = pane.window?.windowController as? TerminalWindow else {
    return nil
  }
  TerminalAutomation.focus(pane)
  vertical ? window.splitVertical(nil) : window.splitHorizontal(nil)
  guard let created = window.panes.last else { return command.fail("Could not create a terminal pane.") }
  return TerminalAutomation.paneID(created)
}

@objc(TerminalSplitRightCommand)
final class TerminalSplitRightCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? { split(self, vertical: true) }
}

@objc(TerminalSplitBelowCommand)
final class TerminalSplitBelowCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? { split(self, vertical: false) }
}

@objc(TerminalClosePaneCommand)
final class TerminalClosePaneCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let pane = pane(), let window = pane.window?.windowController as? TerminalWindow else { return nil }
    TerminalAutomation.focus(pane)
    window.closePane(nil)
    return true
  }
}

@objc(TerminalNewWindowCommand)
final class TerminalNewWindowCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    delegate.newWindow(nil)
    guard let pane = delegate.windows.last?.panes.first else { return fail("Could not create a terminal window.") }
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalNewTabCommand)
final class TerminalNewTabCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    delegate.newTab(nil)
    guard let pane = delegate.windows.last?.panes.first else { return fail("Could not create a terminal tab.") }
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalListPanesCommand)
final class TerminalListPanesCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    return delegate.windows.flatMap(\.panes).map(TerminalAutomation.paneID)
  }
}

@objc(TerminalShowSettingsCommand)
final class TerminalShowSettingsCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    delegate.settings(nil)
    return true
  }
}

@objc(TerminalConfigurePreferencesCommand)
final class TerminalConfigurePreferencesCommand: TerminalScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    let current = TerminalPreferences.load()
    let arguments = evaluatedArguments ?? [:]
    func text(_ key: String, fallback: String) -> String? {
      guard let value = arguments[key] else { return fallback }
      if let text = value as? String { return text }
      if let number = value as? NSNumber { return number.stringValue }
      fail("\(key) has an invalid value.", number: -1700)
      return nil
    }
    func boolean(_ key: String, fallback: Bool) -> Bool? {
      guard let value = arguments[key] else { return fallback }
      guard let number = value as? NSNumber else {
        fail("\(key) must be true or false.", number: -1700)
        return nil
      }
      return number.boolValue
    }
    guard
      let fontSize = text("FontSize", fallback: String(format: "%.15g", Double(current.fontSize))),
      let historyRows = text("HistoryRows", fallback: String(current.historyRows)),
      let optionSendsEscape = boolean("OptionSendsEscape", fallback: current.optionSendsEscape),
      let followTailOnInput = boolean("FollowTailOnInput", fallback: current.followTailOnInput),
      let startingDirectory = text("StartingDirectory", fallback: current.startingDirectory),
      let selectionWordCharacters = text(
        "SelectionWordCharacters", fallback: current.selectionWordProfile.punctuation)
    else { return nil }
    do {
      let preferences = try TerminalPreferences.edited(
        fontSize: fontSize, historyRows: historyRows, optionSendsEscape: optionSendsEscape,
        followTailOnInput: followTailOnInput, startingDirectory: startingDirectory,
        selectionWordCharacters: selectionWordCharacters)
      delegate.applyPreferences(preferences)
      return "font size \(String(format: "%.15g", Double(preferences.fontSize))), scrollback rows \(preferences.historyRows), starting directory \(preferences.startingDirectory), word characters \(preferences.selectionWordProfile.punctuation)"
    } catch {
      return fail(error.localizedDescription, number: -1700)
    }
  }
}

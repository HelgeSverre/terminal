import AppKit
import TerminalUI

/// The deliberately small AppleScript boundary. It resolves a stable pane
/// identifier to the existing UI/session owner and never treats screen output
/// as editable text.
@MainActor
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
      return delegate.windows.lazy.flatMap { $0.panes }.first { $0.automationID == normalized }
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
  override func performDefaultImplementation() -> Any? {
    struct Box: @unchecked Sendable { let value: Any? }
    nonisolated(unsafe) let command = self
    return MainActor.assumeIsolated { Box(value: command.run()) }.value
  }

  @MainActor
  func run() -> Any? { nil }

  @MainActor
  @discardableResult
  func fail(_ message: String, number: Int = -1728) -> Any? {
    scriptErrorNumber = number
    scriptErrorString = message
    return nil
  }

  @MainActor
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
  @MainActor
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
  @MainActor
  override func run() -> Any? {
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
  @MainActor
  override func run() -> Any? {
    guard let pane = pane(), let limit = screenLimit() else { return nil }
    let screen = pane.accessibilityValue() as? String ?? ""
    return String(screen.suffix(limit))
  }
}

@objc(TerminalClearScreenCommand)
final class TerminalClearScreenCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let pane = pane() else { return nil }
    pane.clearScreen(nil)
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalFocusPaneCommand)
final class TerminalFocusPaneCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let pane = pane() else { return nil }
    TerminalAutomation.focus(pane)
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalApplyPaneColorCommand)
final class TerminalApplyPaneColorCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let text = directParameter as? String else {
      return fail("apply pane color requires a color.", number: -1700)
    }
    let followsDefault = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default"
    let color = PaneColorChoice.resolve(text)
    guard followsDefault || color != nil else {
      return fail("pane color must be #RRGGBB, a palette color name, or default.", number: -1700)
    }
    guard let pane = pane() else { return nil }
    guard let presentation = TerminalPanePresentationView.enclosing(pane) else {
      return fail("The requested terminal pane is closed or does not exist.")
    }
    if let color { presentation.choose(color) } else { presentation.resetColor() }
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalReadPaneColorCommand)
final class TerminalReadPaneColorCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let pane = pane() else { return nil }
    guard let presentation = TerminalPanePresentationView.enclosing(pane) else {
      return fail("The requested terminal pane is closed or does not exist.")
    }
    return presentation.color.hex
  }
}

@MainActor
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
  @MainActor
  override func run() -> Any? { split(self, vertical: true) }
}

@objc(TerminalSplitBelowCommand)
final class TerminalSplitBelowCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? { split(self, vertical: false) }
}

@objc(TerminalClosePaneCommand)
final class TerminalClosePaneCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let pane = pane(), let window = pane.window?.windowController as? TerminalWindow else { return nil }
    TerminalAutomation.focus(pane)
    window.closePane(nil)
    return true
  }
}

@objc(TerminalNewWindowCommand)
final class TerminalNewWindowCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    delegate.newWindow(nil)
    guard let pane = delegate.windows.last?.panes.first else { return fail("Could not create a terminal window.") }
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalNewTabCommand)
final class TerminalNewTabCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    delegate.newTab(nil)
    guard let pane = delegate.windows.last?.panes.first else { return fail("Could not create a terminal tab.") }
    return TerminalAutomation.paneID(pane)
  }
}

@objc(TerminalListPanesCommand)
final class TerminalListPanesCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    return delegate.windows.flatMap { $0.panes }.map(TerminalAutomation.paneID)
  }
}

@objc(TerminalShowSettingsCommand)
final class TerminalShowSettingsCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let delegate = TerminalAutomation.delegate else { return fail("Terminal is not ready.") }
    delegate.settings(nil)
    return true
  }
}

@objc(TerminalConfigurePreferencesCommand)
final class TerminalConfigurePreferencesCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
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
      let ligatures = boolean("Ligatures", fallback: current.ligatures),
      let graphemeClustering = boolean("GraphemeClustering", fallback: current.graphemeClustering),
      let showPaneTitles = boolean("ShowPaneTitles", fallback: current.showPaneTitles),
      let fontFamily = text("FontFamily", fallback: current.fontFamily ?? ""),
      let startingDirectory = text("StartingDirectory", fallback: current.startingDirectory),
      let selectionWordCharacters = text(
        "SelectionWordCharacters", fallback: current.selectionWordProfile.punctuation)
    else { return nil }
    var defaultPaneColor = current.defaultPaneColor
    if let value = arguments["DefaultPaneColor"] {
      guard let text = value as? String, let color = PaneColorChoice.resolve(text) else {
        return fail("default pane color must be #RRGGBB or a palette color name.", number: -1700)
      }
      defaultPaneColor = color
    }
    do {
      var desktop = current.desktop
      if let configuration = arguments["DesktopConfiguration"] {
        guard let json = configuration as? String else { return fail("desktop configuration must be JSON text.", number: -1700) }
        desktop = try DesktopConfiguration.decode(Data(json.utf8))
      }
      var inactivePaneDim = current.inactivePaneDim
      if let raw = arguments["InactivePaneDim"] {
        guard let value = raw as? NSNumber, let dim = PaneInactiveDim(rawValue: value.intValue),
          value.doubleValue == Double(value.intValue) else { return fail("inactive pane dim must be 0, 5, 10, 20 or 50.", number: -1700) }
        inactivePaneDim = dim
      }
      let preferences = try TerminalPreferences.edited(
        fontSize: fontSize, historyRows: historyRows, optionSendsEscape: optionSendsEscape,
        followTailOnInput: followTailOnInput, startingDirectory: startingDirectory,
        selectionWordCharacters: selectionWordCharacters, showPaneTitles: showPaneTitles,
        inactivePaneDim: inactivePaneDim, defaultPaneColor: defaultPaneColor,
        fontFamily: .some(fontFamily.isEmpty ? nil : fontFamily), ligatures: ligatures,
        graphemeClustering: graphemeClustering, desktop: desktop)
      delegate.applyPreferences(preferences)
      return "font size \(String(format: "%.15g", Double(preferences.fontSize))), scrollback rows \(preferences.historyRows), starting directory \(preferences.startingDirectory), word characters \(preferences.selectionWordProfile.punctuation), default pane color \(preferences.defaultPaneColor.hex)"
    } catch {
      return fail(error.localizedDescription, number: -1700)
    }
  }
}

@objc(TerminalReadPreferencesCommand)
final class TerminalReadPreferencesCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard TerminalAutomation.delegate != nil else { return fail("Terminal is not ready.") }
    let value = TerminalPreferences.load()
    let fields: [String: Any] = ["fontSize": Double(value.fontSize), "fontFamily": value.fontFamily ?? "",
      "ligatures": value.ligatures, "graphemeClustering": value.graphemeClustering,
      "historyRows": value.historyRows, "optionSendsEscape": value.optionSendsEscape,
      "followTailOnInput": value.followTailOnInput, "startingDirectory": value.startingDirectory,
      "selectionWordCharacters": value.selectionWordProfile.punctuation,
      "showPaneTitles": value.showPaneTitles, "inactivePaneDim": value.inactivePaneDim.rawValue,
      "defaultPaneColor": value.defaultPaneColor.hex,
      "desktopConfiguration": (try? value.desktop.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) else {
      return fail("Could not encode preferences.")
    }
    return String(data: data, encoding: .utf8)
  }
}

@objc(TerminalReadDirectoryCommand)
final class TerminalReadDirectoryCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let pane = pane() else { return nil }
    return MainActor.assumeIsolated { pane.session.deliveredDirectory ?? "" }
  }
}

@objc(TerminalReadHistoryCommand)
final class TerminalReadHistoryCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let pane = pane(), let limit = screenLimit() else { return nil }
    suspendExecution()
    pane.session.recoveryHistory(maximumBytes: limit) { [self] text in
      guard let text else {
        fail("The terminal history read was busy or the pane closed.", number: -1719)
        resumeExecution(withResult: nil)
        return
      }
      resumeExecution(withResult: text)
    }
    return nil
  }
}

@objc(TerminalSelectTextCommand)
final class TerminalSelectTextCommand: TerminalScriptCommand {
  @MainActor
  override func run() -> Any? {
    guard let pane = pane() else { return nil }
    func coordinate(_ key: String) -> Int? {
      guard let value = evaluatedArguments?[key] as? NSNumber,
        (1...4097).contains(value.intValue), value.doubleValue == Double(value.intValue) else { return nil }
      return value.intValue - 1
    }
    guard let row = coordinate("FromRow"), let column = coordinate("FromColumn"),
      let endRow = coordinate("ToRow"), let endColumn = coordinate("ToColumn"),
      pane.selectVisibleText(fromRow: row, fromColumn: column, toRow: endRow, toColumn: endColumn) else {
      return fail("Selection coordinates must be whole, one-based visible rows and column boundaries.", number: -1700)
    }
    return TerminalAutomation.paneID(pane)
  }
}

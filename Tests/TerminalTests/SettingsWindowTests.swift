import AppKit
import Testing
@testable import TerminalApp

/// Serialized: the test installs a volatile argument domain in the standard UserDefaults.
@Suite(.serialized) @MainActor struct SettingsWindowTests {
  /// Semantic navigation, raw invalid drafts, hidden validation, nonfinite
  /// recovery, bounds, atomic Apply, Cancel and no persistence.
  @Test func settingsWindowFlow() throws {
    _ = NSApplication.shared
    defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
    UserDefaults.standard.setVolatileDomain([
      "fontSize": 14, "historyRows": 50000, "optionSendsEscape": false,
      "followTailOnInput": true, "startingDirectory": NSHomeDirectory(),
      "selectionWordCharacters": "_-/.:~", "showPaneTitles": true, "inactivePaneDim": 5,
    ], forName: UserDefaults.argumentDomain)
    var applied: [TerminalPreferences] = []
    let settings = TerminalSettingsWindow { applied.append($0) }
    settings.present()
    let content = settings.window!.contentView!
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = descendants(content)
    func find<T: NSView>(_ id: String, as type: T.Type) -> T {
      views.first { $0.accessibilityIdentifier() == "no.helgesverre.terminal.settings." + id } as! T
    }
    func select(_ section: String) {
      let button = find("section." + section, as: NSButton.self)
      #expect(button.accessibilityPerformPress())
      #expect((button.accessibilityValue() as? NSNumber)?.boolValue == true)
    }
    func edit(_ field: NSTextField, _ value: String) -> NSTextView {
      #expect(settings.window!.makeFirstResponder(field))
      let editor = field.currentEditor() as! NSTextView
      editor.selectAll(nil)
      editor.insertText(value, replacementRange: editor.selectedRange())
      #expect(field.stringValue == value && editor.string == value)
      return editor
    }
    let apply = find("apply", as: NSButton.self)
    let directory = find("starting-directory", as: NSTextField.self)
    let font = find("font-size", as: NSTextField.self)
    let history = find("scrollback-rows", as: NSTextField.self)
    _ = edit(directory, "")
    select("text")
    _ = edit(font, "41")
    select("general")
    #expect(font.stringValue == "41" && font.currentEditor() == nil && !apply.isEnabled)
    select("text")
    for value in ["nan", "inf", "-inf"] {
      let editor = edit(font, value)
      #expect(!apply.isEnabled)
      editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
      #expect((8...40).contains(Double(font.stringValue)!))
    }
    var editor = edit(font, "40")
    editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
    #expect(font.stringValue == "40")
    editor = edit(font, "8")
    editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
    #expect(font.stringValue == "8")
    _ = edit(font, "18")
    select("scrollback")
    _ = edit(history, "50001")
    select("panes")
    #expect(history.stringValue == "50001" && history.currentEditor() == nil && !apply.isEnabled)
    select("scrollback")
    _ = edit(history, "0")
    select("text")
    #expect(font.stringValue == "18" && apply.isEnabled)
    // The Panes section offers the pane palette for the default header color.
    select("panes")
    content.layoutSubtreeIfNeeded()
    let palette = find("default-pane-color", as: PaneColorPaletteView.self)
    let paletteFrame = content.convert(palette.bounds, from: palette)
    #expect(!palette.isHiddenOrHasHiddenAncestor && content.bounds.contains(paletteFrame),
      "Default color palette clipped or hidden: \(paletteFrame)")
    #expect(palette.selected == .standard)
    // Tab visits the grid once, on its stop, then the hex field.
    #expect(palette.focusSelection())
    settings.window!.selectNextKeyView(nil)
    let hexEditor = try #require(settings.window!.firstResponder as? NSTextView)
    #expect((hexEditor.delegate as? NSView)?.accessibilityIdentifier() == "no.helgesverre.terminal.pane.color.hex")
    let graphite = descendants(palette).first {
      $0.accessibilityIdentifier() == "no.helgesverre.terminal.pane.color.graphite"
    } as! NSButton
    graphite.performClick(nil)
    #expect(palette.selected?.hex == "#26272B" && apply.isEnabled)
    apply.performClick(nil)
    #expect(applied.count == 1 && applied[0].fontSize == 18 && applied[0].historyRows == 0)
    #expect(applied[0].defaultPaneColor.hex == "#26272B")
    #expect(UserDefaults.standard.string(forKey: "defaultPaneColor") == nil)
    #expect(applied[0].startingDirectory == NSHomeDirectory())
    #expect(UserDefaults.standard.integer(forKey: "fontSize") == 14)
    settings.present()
    select("text")
    _ = edit(font, "41")
    find("cancel", as: NSButton.self).performClick(nil)
    settings.present()
    #expect(font.stringValue == "14" && history.stringValue == "50000" && apply.isEnabled)
    #expect(palette.selected == .standard, "Cancel must discard the unsaved default color")
    settings.close()
  }

  /// Tab and Shift-Tab cycle through the shown section only: its sidebar
  /// entry, its controls in order, Cancel and Apply. Buttons, checkboxes and
  /// the segmented control take part whatever the Keyboard Navigation setting.
  @Test func settingsKeyboardOrder() throws {
    _ = NSApplication.shared
    defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
    UserDefaults.standard.setVolatileDomain([
      "fontSize": 14, "historyRows": 50000, "optionSendsEscape": false,
      "followTailOnInput": true, "startingDirectory": NSHomeDirectory(),
      "selectionWordCharacters": "_-/.:~", "showPaneTitles": true, "inactivePaneDim": 5,
    ], forName: UserDefaults.argumentDomain)
    let settings = TerminalSettingsWindow { _ in }
    settings.present()
    defer { settings.close() }
    let window = try #require(settings.window)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = descendants(window.contentView!)
    let prefix = "no.helgesverre.terminal."
    func view(_ id: String) -> NSView { views.first { $0.accessibilityIdentifier() == prefix + id }! }
    // What has focus, by identifier; a field being edited answers for its field editor.
    func focused() -> String {
      var responder = window.firstResponder as? NSView
      if let editor = responder as? NSTextView, editor.isFieldEditor { responder = editor.delegate as? NSView }
      return responder.map { $0.accessibilityIdentifier().replacingOccurrences(of: prefix, with: "") } ?? "nothing"
    }
    func tab(backward: Bool = false) {
      if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
        backward ? editor.insertBacktab(nil) : editor.insertTab(nil)
      } else {
        backward ? window.selectPreviousKeyView(nil) : window.selectNextKeyView(nil)
      }
    }
    func walk(_ count: Int, backward: Bool = false) -> [String] {
      (0..<count).map { _ in tab(backward: backward); return focused() }
    }
    let orders: [String: [String]] = [
      "general": ["settings.starting-directory", "settings.choose-directory"],
      "text": ["settings.font-size", "settings.word-characters"],
      "scrollback": ["settings.scrollback-rows", "settings.follow-tail-on-input"],
      "panes": ["settings.show-pane-titles", "settings.inactive-pane-dim", "pane.color.onyx", "pane.color.hex"],
      "keyboard": ["settings.option-sends-escape"],
    ]
    for section in ["general", "text", "scrollback", "panes", "keyboard"] {
      let button = view("settings.section." + section)
      #expect((button as! NSButton).accessibilityPerformPress())
      #expect(window.makeFirstResponder(button))
      let loop = ["settings.section." + section] + orders[section]! + ["settings.cancel", "settings.apply"]
      let forward = Array(loop.dropFirst()) + [loop[0]]
      #expect(walk(loop.count) == forward, "Tab order in \(section)")
      #expect(walk(loop.count, backward: true) == Array(loop.reversed()),
        "Shift-Tab order in \(section)")
    }
    // The sidebar is one stop: Up and Down change the section and keep focus there.
    #expect(focused() == "settings.section.keyboard")
    let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 126)!
    window.firstResponder?.keyDown(with: up)
    #expect(focused() == "settings.section.panes")
    #expect(walk(1) == ["settings.show-pane-titles"], "Tab follows the newly selected section")
    // Space toggles a focused checkbox.
    let checkbox = view("settings.show-pane-titles") as! NSButton
    let before = checkbox.state
    let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
      isARepeat: false, keyCode: 49)!
    window.firstResponder?.keyDown(with: space)
    #expect(checkbox.state != before, "Space did not toggle the focused checkbox")
    // Left and Right choose a dimming level on the focused segmented control.
    let dim = view("settings.inactive-pane-dim") as! NSSegmentedControl
    #expect(window.makeFirstResponder(dim))
    func arrow(_ keyCode: UInt16) {
      dim.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: keyCode)!)
    }
    let start = dim.selectedSegment
    arrow(124)
    #expect(dim.selectedSegment == start + 1)
    arrow(123)
    #expect(dim.selectedSegment == start)
    for _ in 0..<dim.segmentCount { arrow(123) }
    #expect(dim.selectedSegment == 0, "Left stops at the first level")
    // Hints are exposed to VoiceOver as help, not only as tooltips.
    #expect(view("settings.font-size").accessibilityHelp() == "8–40 pt. Use Up and Down to adjust by one point.")
  }
}

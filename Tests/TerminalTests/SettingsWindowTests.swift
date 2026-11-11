import AppKit
import Testing
@testable import TerminalApp

/// Serialized: the test installs a volatile argument domain in the standard UserDefaults.
@Suite(.serialized) @MainActor struct SettingsWindowTests {
  /// Semantic navigation, raw invalid drafts, hidden validation, nonfinite
  /// recovery, bounds, atomic Apply, Cancel and no persistence.
  @Test func settingsWindowFlow() {
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
}

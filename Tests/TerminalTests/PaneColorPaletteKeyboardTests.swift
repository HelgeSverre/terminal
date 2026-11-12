import AppKit
import Testing
@testable import TerminalApp

/// Keyboard use of the pane color palette: one Tab stop for the grid, arrows
/// that preview, Return or Space to keep, Escape to cancel.
@Suite(.serialized) @MainActor struct PaneColorPaletteKeyboardTests {
  @MainActor private final class Host {
    let palette = PaneColorPaletteView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    var previews: [String] = []
    var picks: [String] = []
    var cancels = 0

    init() {
      _ = NSApplication.shared
      window.isReleasedWhenClosed = false
      window.contentView = palette
      palette.closeKeyViewLoop()
      palette.layoutSubtreeIfNeeded()
      palette.onPreview = { [unowned self] in previews.append($0.hex) }
      palette.onPick = { [unowned self] in picks.append($0.hex) }
      palette.onCancel = { [unowned self] in cancels += 1 }
    }

    var focused: PaneColorSwatch? { window.firstResponder as? PaneColorSwatch }

    var hexField: NSTextField {
      func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
      return descendants(palette).first {
        $0.accessibilityIdentifier() == "no.helgesverre.terminal.pane.color.hex"
      } as! NSTextField
    }

    func press(_ keyCode: UInt16) {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: keyCode)!
      window.firstResponder?.keyDown(with: event)
    }
  }

  @Test func arrowsWalkTheGridAndPreview() throws {
    let host = Host()
    let palette = host.palette
    palette.selected = PaneColorChoice.palette[1].color
    #expect(palette.focusSelection())
    #expect(host.focused === palette.swatches[1], "focus starts on the selected color")
    host.press(124)  // right
    #expect(host.focused === palette.swatches[2] && palette.selected == PaneColorChoice.palette[2].color)
    host.press(125)  // down: one row further
    let below = 2 + PaneColorPaletteView.columns
    #expect(host.focused === palette.swatches[below])
    host.press(126)  // up
    host.press(123)  // left
    #expect(host.focused === palette.swatches[1])
    host.press(115)  // Home
    host.press(123)  // left at the first swatch stays there
    #expect(host.focused === palette.swatches[0])
    host.press(126)  // up from the top row stays there
    #expect(host.focused === palette.swatches[0])
    host.press(119)  // End
    host.press(125)  // down from the bottom row stays there
    #expect(host.focused === palette.swatches.last)
    let hex = PaneColorChoice.palette.map(\.color.hex)
    #expect(host.previews == [hex[2], hex[below], hex[2], hex[1], hex[0], hex[0], hex[0], hex.last!, hex.last!])
    #expect(host.picks.isEmpty, "moving only previews")
  }

  @Test func returnAndSpaceKeepTheFocusedColor() {
    let host = Host()
    host.palette.focusSelection()
    host.press(124)
    host.press(36)  // Return
    host.press(124)
    host.press(49)  // Space
    let hex = PaneColorChoice.palette.map(\.color.hex)
    #expect(host.picks == [hex[1], hex[2]])
  }

  @Test func escapeCancelsFromTheGridAndTheHexField() throws {
    let host = Host()
    host.palette.focusSelection()
    host.press(53)
    #expect(host.cancels == 1)
    #expect(host.window.makeFirstResponder(host.hexField))
    let editor = try #require(host.hexField.currentEditor() as? NSTextView)
    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(host.cancels == 2)
  }

  @Test func theGridIsOneTabStopBeforeTheHexField() throws {
    let host = Host()
    let palette = host.palette
    // Tab as AppKit delivers it: the field editor inserts a tab, which ends
    // editing and moves on; any other view asks the window.
    func tab(backward: Bool = false) {
      if let editor = host.window.firstResponder as? NSTextView {
        backward ? editor.insertBacktab(nil) : editor.insertTab(nil)
      } else {
        backward ? host.window.selectPreviousKeyView(nil) : host.window.selectNextKeyView(nil)
      }
    }
    var editingHex: Bool { (host.window.firstResponder as? NSTextView)?.delegate === host.hexField }
    palette.selected = PaneColorChoice.palette[4].color
    #expect(palette.swatches.filter(\.canBecomeKeyView) == [palette.swatches[4]])
    palette.focusSelection()
    tab()
    #expect(editingHex, "Tab leaves the grid for the hex field")
    tab()
    #expect(host.focused === palette.swatches[4], "Tab returns to the grid's one stop")
    // Arrows move the stop; Tab then comes back to where focus was left.
    host.press(124)
    tab()
    tab()
    #expect(host.focused === palette.swatches[5], "Tab returns to the moved stop")
    tab(backward: true)
    #expect(editingHex, "Shift-Tab wraps to the hex field")
    tab(backward: true)
    #expect(host.focused === palette.swatches[5], "Shift-Tab returns to the moved stop")
    // A custom color has no swatch; the grid keeps its previous stop.
    palette.selected = PaneChromeColor(hex: "#123456")
    #expect(palette.tabStop === palette.swatches[5])
  }

  @Test func swatchesAreRadioButtonsInARadioGroup() throws {
    let host = Host()
    let palette = host.palette
    palette.selected = PaneColorChoice.palette[3].color
    let swatch = palette.swatches[3]
    #expect(swatch.accessibilityRole() == .radioButton)
    #expect(swatch.accessibilityValue() as? NSNumber == true)
    #expect(palette.swatches[0].accessibilityValue() as? NSNumber == false)
    let group = try #require(swatch.superview?.superview)
    #expect(group.accessibilityRole() == .radioGroup && group.accessibilityLabel() == "Pane color")
  }
}

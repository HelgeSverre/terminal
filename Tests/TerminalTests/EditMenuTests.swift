import AppKit
import Testing
@testable import TerminalApp
@testable import TerminalCore
@testable import TerminalSession
@testable import TerminalView

/// The Edit menu answers through the focused view. A test process cannot make
/// its window key, so nil-targeted dispatch is not exercised here; the menu's
/// shape, the text editor's validation and the terminal's key claim are.
/// Nothing here writes the general pasteboard.
@Suite(.serialized) @MainActor struct EditMenuTests {
  private func event(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
      isARepeat: false, keyCode: 0)!
  }

  @Test func theMenuOffersTextEditingToWhicheverViewHasFocus() throws {
    let menu = TerminalEditMenu.make()
    let items = menu.items.filter { !$0.isSeparatorItem }
    #expect(items.map(\.title) == ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All",
      "Find", "Find Next", "Find Previous", "Cancel Paste"])
    #expect(items.allSatisfy { $0.target == nil }, "an item with a target ignores focus")
    let actions = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.action.map(NSStringFromSelector)) })
    #expect(actions["Undo"] == "undo:" && actions["Redo"] == "redo:" && actions["Cut"] == "cut:"
      && actions["Copy"] == "copy:" && actions["Delete"] == "delete:")
  }

  @Test func theTerminalClaimsExactlyTheTextOnlyKeys() throws {
    // The predicate matches the menu's own Undo, Redo and Cut, and only them.
    let menu = TerminalEditMenu.make()
    for item in menu.items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
      let claimed = TerminalEditMenu.isTextOnlyKey(event(item.keyEquivalent, item.keyEquivalentModifierMask))
      #expect(claimed == ["Undo", "Redo", "Cut"].contains(item.title), "\(item.title)")
    }
    #expect(TerminalEditMenu.isTextOnlyKey(event("Z", [.command, .shift])), "shifted characters still match")
    #expect(!TerminalEditMenu.isTextOnlyKey(event("z", [.command, .option])))
    #expect(!TerminalEditMenu.isTextOnlyKey(event("z", [])))
  }

  @Test func aFieldEditorAnswersCutAndDeleteForASelection() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = NSTextField(string: "")
    field.frame = NSRect(x: 8, y: 8, width: 200, height: 24)
    window.contentView!.addSubview(field)
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("query", replacementRange: editor.selectedRange())
    let menu = TerminalEditMenu.make()
    func enabled(_ title: String) throws -> Bool {
      editor.validateUserInterfaceItem(try #require(menu.item(withTitle: title)))
    }
    editor.setSelectedRange(NSRange(location: 5, length: 0))
    #expect(try !enabled("Cut") && !enabled("Copy"), "nothing selected")
    editor.selectAll(nil)
    #expect(try enabled("Cut") && enabled("Copy") && enabled("Delete"))
    editor.delete(nil)
    #expect(editor.string == "")
  }
}

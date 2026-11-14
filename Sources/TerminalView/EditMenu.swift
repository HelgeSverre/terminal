import AppKit

/// The Edit menu. No item has a target, so the focused view answers: the
/// terminal copies, pastes and selects its own text, and a text field's
/// editor (the find query, Settings, the pane color hex) also cuts, deletes,
/// undoes and redoes.
package enum TerminalEditMenu {
  /// Key equivalents of the text-only items: Undo, Redo and Cut. A menu takes
  /// a key equivalent even while its item is disabled, so the focused
  /// terminal claims these first (`TerminalCanvasView.performKeyEquivalent`)
  /// and sends them to its program, as it did before the items existed.
  static let textOnlyKeys: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
    ("z", [.command]), ("z", [.command, .shift]), ("x", [.command]),
  ]

  /// Whether `event` is one of `textOnlyKeys`, compared the way a menu
  /// matches it: by the key without modifiers and the exact modifier set.
  static func isTextOnlyKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    return textOnlyKeys.contains { $0.key == key && $0.modifiers == modifiers }
  }

  package static func make() -> NSMenu {
    let menu = NSMenu(title: "Edit")
    func add(_ title: String, _ action: Selector, _ key: String,
      _ modifiers: NSEvent.ModifierFlags = [.command]) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      menu.addItem(item)
    }
    add("Undo", Selector(("undo:")), "z")
    add("Redo", Selector(("redo:")), "z", [.command, .shift])
    menu.addItem(.separator())
    add("Cut", #selector(NSText.cut(_:)), "x")
    add("Copy", #selector(TerminalCanvasView.copy(_:)), "c")
    add("Paste", #selector(TerminalCanvasView.paste(_:)), "v")
    add("Delete", #selector(NSText.delete(_:)), "")
    add("Select All", #selector(TerminalCanvasView.selectAll(_:)), "a")
    menu.addItem(.separator())
    add("Find", #selector(TerminalCanvasView.find(_:)), "f")
    add("Find Next", #selector(TerminalCanvasView.findNext(_:)), "g")
    add("Find Previous", #selector(TerminalCanvasView.findPrevious(_:)), "g", [.command, .shift])
    add("Cancel Paste", #selector(TerminalCanvasView.cancelPaste(_:)), ".")
    return menu
  }
}

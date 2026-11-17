import AppKit
import TerminalHost

enum DesktopMenus {
  /// Rebuilding menus makes removing a saved override restore the normal key.
  static func append(shell: NSMenu, view: NSMenu, delegate: AppDelegate) {
    shell.addItem(.separator())
    for (title, selector, key) in [("Focus Pane Left", "focusLeft:", "h"),
      ("Focus Pane Down", "focusDown:", "j"), ("Focus Pane Up", "focusUp:", "k"),
      ("Focus Pane Right", "focusRight:", "l"), ("Zoom Pane", "togglePaneZoom:", "z"),
      ("Move Pane to New Window", "movePaneToWindow:", "n")] {
      let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
      item.keyEquivalentModifierMask = [.command, .control]
      shell.addItem(item)
    }
    let profiles = NSMenuItem(title: "New Window with Profile", action: nil, keyEquivalent: "")
    profiles.submenu = NSMenu()
    for profile in TerminalPreferences.load().desktop.profiles {
      let item = NSMenuItem(title: profile.name, action: #selector(AppDelegate.launchProfile(_:)), keyEquivalent: "")
      item.target = delegate
      item.representedObject = profile.id
      profiles.submenu?.addItem(item)
    }
    shell.addItem(profiles)
    for (title, selector) in [("Previous Command", "previousCommand:"), ("Next Command", "nextCommand:")] {
      view.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: "")
    }
  }
  static func applyShortcuts(to menu: NSMenu, configuration: DesktopConfiguration) {
    for item in menu.items {
      if let action = item.action,
        let shortcut = configuration.shortcuts.first(where: { NSSelectorFromString($0.action.selectorName) == action }) {
        item.keyEquivalent = shortcut.key
        item.keyEquivalentModifierMask = shortcut.flags
      }
      if let child = item.submenu { applyShortcuts(to: child, configuration: configuration) }
    }
  }
}

extension AppDelegate {
  @objc func launchProfile(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String,
      let profile = TerminalPreferences.load().desktop.profiles.first(where: { $0.id == id }) else { return }
    do {
      let prefs = TerminalPreferences.load()
      let launch = try profile.launch(fallbackDirectory: prefs.launchDirectory, launcher: LaunchSpec.shell.launcher)
      let controller = TerminalWindow(launch: launch)
      windows.append(controller)
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
    } catch { NSApp.presentError(error) }
  }
}

import AppKit
import TerminalHost
import TerminalUI

/// The menu bar. Remappable actions take their title, selector and key from
/// `TerminalShortcut.Action`; rebuilding after a settings change is what makes
/// removing a saved override restore the default key.
enum MainMenu {
  static func build(
    delegate: AppDelegate?, tabNavigation: TerminalTabNavigation, configuration: DesktopConfiguration
  ) -> (bar: NSMenu, windows: NSMenu) {
    let bar = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let menu = NSMenu(title: title)
      item.submenu = menu
      bar.addItem(item)
      return menu
    }
    func item(
      _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
      _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil
    ) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target
      menu.addItem(item)
    }
    func remappable(_ menu: NSMenu, _ action: TerminalShortcut.Action, target: AnyObject? = nil) {
      let shortcut = configuration.shortcuts.first { $0.action == action } ?? .standard(action)
      item(menu, action.title, NSSelectorFromString(action.selectorName), shortcut.key, shortcut.flags, target: target)
    }
    let app = submenu("Helge Terminal")
    item(app, "About Helge Terminal", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
    item(app, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), "", target: delegate)
    item(app, "Settings…", #selector(AppDelegate.settings(_:)), ",", target: delegate)
    if delegate?.handoffDirectory != nil {
      item(app, "Relaunch Keeping Sessions", #selector(AppDelegate.relaunchKeepingSessions(_:)), "", target: delegate)
    }
    app.addItem(.separator())
    item(app, "Quit Helge Terminal", #selector(NSApplication.terminate(_:)), "q")

    let shell = submenu("Shell")
    remappable(shell, .newWindow, target: delegate)
    remappable(shell, .newTab, target: delegate)
    item(shell, "Resume All", #selector(AppDelegate.resumeAll(_:)), "", [], target: delegate)
    remappable(shell, .splitRight)
    remappable(shell, .splitBelow)
    item(shell, "Close Pane", #selector(TerminalWindow.closePane(_:)), "w")
    shell.addItem(.separator())
    item(shell, "Pane Color…", #selector(TerminalWindow.choosePaneColor(_:)), "", [])
    shell.addItem(.separator())
    for action in [TerminalShortcut.Action.focusLeft, .focusDown, .focusUp, .focusRight, .zoomPane, .movePaneToWindow] {
      remappable(shell, action)
    }
    let profiles = NSMenuItem(title: "New Window with Profile", action: nil, keyEquivalent: "")
    profiles.submenu = NSMenu()
    for profile in configuration.profiles {
      let entry = NSMenuItem(title: profile.name, action: #selector(AppDelegate.launchProfile(_:)), keyEquivalent: "")
      entry.target = delegate
      entry.representedObject = profile.id
      profiles.submenu?.addItem(entry)
    }
    shell.addItem(profiles)

    let edit = NSMenuItem()
    edit.submenu = TerminalEditMenu.make()
    bar.addItem(edit)

    let view = submenu("View")
    item(view, "Clear Screen", #selector(TerminalCanvasView.clearScreen(_:)), "k")
    item(view, "Increase Font Size", #selector(TerminalCanvasView.increaseFont(_:)), "+")
    item(view, "Decrease Font Size", #selector(TerminalCanvasView.decreaseFont(_:)), "-")
    item(view, "Reset Font Size", #selector(TerminalCanvasView.resetFont(_:)), "0")
    for (title, selector) in [("Previous Command", "previousCommand:"), ("Next Command", "nextCommand:")] {
      view.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: "")
    }

    let window = submenu("Window")
    item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    item(window, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control])
    item(window, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])
    window.addItem(.separator())
    tabNavigation.addMenuItems(to: window)
    return (bar, window)
  }
}

extension AppDelegate {
  @objc func launchProfile(_ sender: NSMenuItem) {
    let prefs = TerminalPreferences.current
    guard let id = sender.representedObject as? String,
      let profile = prefs.desktop.profiles.first(where: { $0.id == id }) else { return }
    do {
      show(TerminalWindow(launch: try profile.launch(
        fallbackDirectory: prefs.launchDirectory, launcher: LaunchSpec.bundledLauncher)))
    } catch { NSApp.presentError(error) }
  }
}

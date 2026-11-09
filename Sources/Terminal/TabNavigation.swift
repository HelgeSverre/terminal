import AppKit

/// AppKit owns the tab order and restores each window's first responder.
/// Keep these actions enabled even for a missing tab: the shortcut is consumed
/// as a no-op instead of falling through to terminal input.
final class TerminalTabNavigation: NSObject {
  enum Selection {
    case numbered(Int)
    case previous
    case next

    func index(count: Int, current: Int) -> Int? {
      guard count > 0 else { return nil }
      switch self {
      case .numbered(let number):
        guard (1...9).contains(number) else { return nil }
        let index = number == 9 ? count - 1 : number - 1
        return index < count ? index : nil
      case .previous:
        guard (0..<count).contains(current) else { return nil }
        return current == 0 ? count - 1 : current - 1
      case .next:
        guard (0..<count).contains(current) else { return nil }
        return current == count - 1 ? 0 : current + 1
      }
    }
  }

  private let intendedWindow: () -> NSWindow?

  init(intendedWindow: @escaping () -> NSWindow?) {
    self.intendedWindow = intendedWindow
    super.init()
  }

  func addMenuItems(to menu: NSMenu) {
    func item(_ title: String, _ action: Selector, _ key: String,
      _ modifiers: NSEvent.ModifierFlags, tag: Int = 0)
    {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      item.keyEquivalentModifierMask = modifiers
      item.tag = tag
      menu.addItem(item)
    }
    item("Select Previous Tab", #selector(previousTab(_:)),
      String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
    item("Select Next Tab", #selector(nextTab(_:)),
      String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
    menu.addItem(.separator())
    for number in 1...9 {
      item(number == 9 ? "Select Last Tab" : "Select Tab \(number)",
        #selector(numberedTab(_:)), String(number), [.command], tag: number)
    }
  }

  @objc private func numberedTab(_ sender: NSMenuItem) { select(.numbered(sender.tag)) }
  @objc private func previousTab(_ sender: Any?) { select(.previous) }
  @objc private func nextTab(_ sender: Any?) { select(.next) }

  private func select(_ selection: Selection) {
    guard let window = intendedWindow() else { return }
    let tabs = window.tabbedWindows ?? [window]
    guard let current = tabs.firstIndex(where: { $0 === window }),
      let index = selection.index(count: tabs.count, current: current)
    else { return }
    guard tabs[index] !== window else { return }
    tabs[index].makeKeyAndOrderFront(nil)
  }
}

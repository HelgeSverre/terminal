import AppKit
import Testing
@testable import TerminalApp
@testable import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

@Suite @MainActor struct TabNavigationTests {
  typealias Selection = TerminalTabNavigation.Selection

  @Test func selectionIndexMath() {
    for count in 0...12 {
      for number in 1...9 {
        let expected: Int? = count == 0 ? nil
          : number == 9 ? count - 1 : number <= count ? number - 1 : nil
        #expect(Selection.numbered(number).index(count: count, current: 0) == expected)
      }
      for current in 0..<count {
        #expect(Selection.next.index(count: count, current: current) == (current + 1) % count)
        #expect(Selection.previous.index(count: count, current: current)
          == (current + count - 1) % count)
      }
    }
    #expect(Selection.numbered(0).index(count: 10, current: 0) == nil)
    #expect(Selection.numbered(10).index(count: 10, current: 0) == nil)
    #expect(Selection.next.index(count: 0, current: 0) == nil)
    #expect(Selection.previous.index(count: 3, current: -1) == nil)
    #expect(Selection.next.index(count: 3, current: 3) == nil)

  }

  @Test func keyEquivalentDispatch() {
    // Exercise actual AppKit key-equivalent dispatch, including no target
    // window. A handled result prevents delivery to the terminal key encoder.
    _ = NSApplication.shared
    var dispatchCount = 0
    let navigation = TerminalTabNavigation {
      dispatchCount += 1
      return nil
    }
    defer { withExtendedLifetime(navigation) {} }
    let menu = NSMenu(title: "Window")
    navigation.addMenuItems(to: menu)
    func dispatch(_ characters: String, _ flags: NSEvent.ModifierFlags,
      code: UInt16 = 18) -> Bool
    {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!
      return menu.performKeyEquivalent(with: event)
    }
    for number in 1...9 {
      let before = dispatchCount
      #expect(dispatch(String(number), [.command]))
      #expect(dispatchCount == before + 1)
    }
    for (key, code) in [(NSLeftArrowFunctionKey, UInt16(123)),
      (NSRightArrowFunctionKey, UInt16(124))]
    {
      let before = dispatchCount
      #expect(dispatch(String(UnicodeScalar(key)!), [.command, .option, .function], code: code))
      #expect(dispatchCount == before + 1)
    }
    let before = dispatchCount
    #expect(!dispatch("1", []))
    #expect(!dispatch("!", [.command, .shift]))
    #expect(!dispatch("0", [.command]))
    #expect(!dispatch("\t", [.control], code: 48))
    #expect(!dispatch(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command], code: 123))
    #expect(dispatchCount == before)
  }

  /// Opens real windows and needs the foreground, so it runs only when
  /// `TERMINAL_TAB_WINDOWS` is set (the old `--windows` flag).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMINAL_TAB_WINDOWS"] != nil))
  func nativeWindowTabs() async {
    final class InputView: NSView {
      var receivedKeys: [NSEvent] = []
      override var acceptsFirstResponder: Bool { true }
      override func keyDown(with event: NSEvent) { receivedKeys.append(event) }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    // The main run loop cannot be spun here, so suspend and let queued work run.
    func settle() async { _ = await TestEnvironment.wait(seconds: 0.5) { false } }
    var windows: [NSWindow] = []
    var inputs: [InputView] = []
    func makeWindow(_ title: String, group: String) -> NSWindow {
      let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 260),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = title
      window.tabbingMode = .disallowed
      window.tabbingIdentifier = group
      let input = InputView(frame: window.contentView!.bounds)
      window.contentView = input
      window.makeFirstResponder(input)
      inputs.append(input)
      windows.append(window)
      return window
    }
    defer { for window in windows { window.close() } }
    let a = makeWindow("Tab A", group: "first")
    let b = makeWindow("Tab B", group: "first")
    let c = makeWindow("Tab C", group: "first")
    a.addTabbedWindow(b, ordered: .above)
    b.addTabbedWindow(c, ordered: .above)
    let d = makeWindow("Tab D", group: "second")
    let e = makeWindow("Tab E", group: "second")
    d.addTabbedWindow(e, ordered: .above)
    let single = makeWindow("Singleton", group: "single")
    var intendedWindow: NSWindow? = a
    let navigation = TerminalTabNavigation { app.keyWindow ?? intendedWindow }
    defer { withExtendedLifetime(navigation) {} }
    let bar = NSMenu()
    let windowItem = NSMenuItem()
    let menu = NSMenu(title: "Window")
    windowItem.submenu = menu
    bar.addItem(windowItem)
    navigation.addMenuItems(to: menu)
    app.mainMenu = bar
    func focus(_ window: NSWindow) async {
      window.makeKeyAndOrderFront(nil)
      app.activate(ignoringOtherApps: true)
      await settle()
      intendedWindow = window
      #expect((window.tabGroup?.selectedWindow ?? window) === window)
    }
    func event(_ characters: String, flags: NSEvent.ModifierFlags = [.command],
      code: UInt16 = 18) -> NSEvent
    {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: intendedWindow!.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!
    }
    func select(_ characters: String, expected: NSWindow,
      flags: NSEvent.ModifierFlags = [.command], code: UInt16 = 18) async
    {
      #expect(menu.performKeyEquivalent(with: event(characters, flags: flags, code: code)))
      await settle()
      intendedWindow = intendedWindow?.tabGroup?.selectedWindow ?? intendedWindow
      #expect(intendedWindow === expected,
        "Wrong selected tab for \(characters.debugDescription): expected=\(expected.title), actual=\(intendedWindow?.title ?? "nil")")
    }
    await focus(a)
    #expect(a.tabbedWindows == [a, b, c])
    await select("2", expected: b)
    await select("9", expected: c)
    await select(String(UnicodeScalar(NSRightArrowFunctionKey)!), expected: a,
      flags: [.command, .option, .function], code: 124)
    await select(String(UnicodeScalar(NSLeftArrowFunctionKey)!), expected: c,
      flags: [.command, .option, .function], code: 123)
    await select("8", expected: c)
    // Reorder through AppKit and resolve the next shortcut from its display order.
    a.addTabbedWindow(c, ordered: .below)
    await focus(c)
    #expect(c.tabbedWindows == [c, a, b])
    await select("2", expected: a)
    await select("9", expected: b)
    await focus(d)
    await select("9", expected: e)
    await select("1", expected: d)
    #expect(a.tabbedWindows == [c, a, b])
    await focus(single)
    await select("8", expected: single)
    await select("9", expected: single)
    await select(String(UnicodeScalar(NSLeftArrowFunctionKey)!), expected: single,
      flags: [.command, .option, .function], code: 123)
    // Native field-editor focus is restored when returning to its tab.
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    a.contentView!.addSubview(field)
    await focus(a)
    #expect(a.makeFirstResponder(field))
    #expect(field.currentEditor() === a.firstResponder)
    await select("9", expected: b)
    await select("2", expected: a)
    #expect(field.currentEditor() === a.firstResponder)
    // Send through NSApplication as well: consumed keys must never reach a
    // terminal-like first responder, even when their target index is missing.
    await focus(single)
    #expect(single.makeFirstResponder(inputs.last!))
    guard app.isActive, app.keyWindow === single else {
      print("SKIP application event routing: test app could not retain foreground focus")
      return
    }
    let shortcuts = ["1", "8", "9"].map { event($0) } + [
      event(String(UnicodeScalar(NSRightArrowFunctionKey)!),
        flags: [.command, .option, .function], code: 124)]
    for shortcut in shortcuts { app.sendEvent(shortcut) }
    #expect(inputs.allSatisfy { input in
      !input.receivedKeys.contains { received in shortcuts.contains { $0 === received } }
    }, "A synthetic tab shortcut reached the input responder")
    // Prove the recorder receives ordinary input through the same route.
    let ordinaryKey = event("x", flags: [], code: 7)
    app.sendEvent(ordinaryKey)
    #expect(inputs.last!.receivedKeys.filter { $0 === ordinaryKey }.count == 1,
      "The ordinary synthetic key did not reach the input responder exactly once")
  }
}

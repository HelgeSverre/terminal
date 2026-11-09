import AppKit

@main struct TabNavigationTests {
  static func main() {
    typealias Selection = TerminalTabNavigation.Selection
    for count in 0...12 {
      for number in 1...9 {
        let expected: Int? = count == 0 ? nil
          : number == 9 ? count - 1 : number <= count ? number - 1 : nil
        precondition(Selection.numbered(number).index(count: count, current: 0) == expected)
      }
      for current in 0..<count {
        precondition(Selection.next.index(count: count, current: current) == (current + 1) % count)
        precondition(Selection.previous.index(count: count, current: current)
          == (current + count - 1) % count)
      }
    }
    precondition(Selection.numbered(0).index(count: 10, current: 0) == nil)
    precondition(Selection.numbered(10).index(count: 10, current: 0) == nil)
    precondition(Selection.next.index(count: 0, current: 0) == nil)
    precondition(Selection.previous.index(count: 3, current: -1) == nil)
    precondition(Selection.next.index(count: 3, current: 3) == nil)

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
      precondition(dispatch(String(number), [.command]))
      precondition(dispatchCount == before + 1)
    }
    for (key, code) in [(NSLeftArrowFunctionKey, UInt16(123)),
      (NSRightArrowFunctionKey, UInt16(124))]
    {
      let before = dispatchCount
      precondition(dispatch(String(UnicodeScalar(key)!), [.command, .option, .function], code: code))
      precondition(dispatchCount == before + 1)
    }
    let before = dispatchCount
    precondition(!dispatch("1", []))
    precondition(!dispatch("!", [.command, .shift]))
    precondition(!dispatch("0", [.command]))
    precondition(!dispatch("\t", [.control], code: 48))
    precondition(!dispatch(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command], code: 123))
    precondition(dispatchCount == before)
    if CommandLine.arguments.contains("--windows") {
      DispatchQueue.main.async {
        windowTests()
        print("Tab navigation tests passed")
        exit(0)
      }
      NSApplication.shared.run()
    }
    print("Tab navigation tests passed")
  }

  private static func windowTests() {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String = "",
      line: UInt = #line)
    {
      guard condition() else {
        FileHandle.standardError.write(Data("FAIL native tab navigation line \(line): \(message)\n".utf8))
        exit(1)
      }
    }
    final class InputView: NSView {
      var receivedKeys: [NSEvent] = []
      override var acceptsFirstResponder: Bool { true }
      override func keyDown(with event: NSEvent) { receivedKeys.append(event) }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    func settle() {
      let deadline = Date(timeIntervalSinceNow: 0.5)
      while let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
        app.sendEvent(event)
        if Date() >= deadline { break }
      }
    }
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
    func focus(_ window: NSWindow) {
      window.makeKeyAndOrderFront(nil)
      app.activate(ignoringOtherApps: true)
      settle()
      intendedWindow = window
      expect((window.tabGroup?.selectedWindow ?? window) === window)
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
      flags: NSEvent.ModifierFlags = [.command], code: UInt16 = 18)
    {
      expect(menu.performKeyEquivalent(with: event(characters, flags: flags, code: code)))
      settle()
      intendedWindow = intendedWindow?.tabGroup?.selectedWindow ?? intendedWindow
      expect(intendedWindow === expected,
        "Wrong selected tab for \(characters.debugDescription): expected=\(expected.title), actual=\(intendedWindow?.title ?? "nil")")
    }
    focus(a)
    expect(a.tabbedWindows == [a, b, c])
    select("2", expected: b)
    select("9", expected: c)
    select(String(UnicodeScalar(NSRightArrowFunctionKey)!), expected: a,
      flags: [.command, .option, .function], code: 124)
    select(String(UnicodeScalar(NSLeftArrowFunctionKey)!), expected: c,
      flags: [.command, .option, .function], code: 123)
    select("8", expected: c)
    // Reorder through AppKit and resolve the next shortcut from its display order.
    a.addTabbedWindow(c, ordered: .below)
    focus(c)
    expect(c.tabbedWindows == [c, a, b])
    select("2", expected: a)
    select("9", expected: b)
    focus(d)
    select("9", expected: e)
    select("1", expected: d)
    expect(a.tabbedWindows == [c, a, b])
    focus(single)
    select("8", expected: single)
    select("9", expected: single)
    select(String(UnicodeScalar(NSLeftArrowFunctionKey)!), expected: single,
      flags: [.command, .option, .function], code: 123)
    // Native field-editor focus is restored when returning to its tab.
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    a.contentView!.addSubview(field)
    focus(a)
    expect(a.makeFirstResponder(field))
    expect(field.currentEditor() === a.firstResponder)
    select("9", expected: b)
    select("2", expected: a)
    expect(field.currentEditor() === a.firstResponder)
    // Send through NSApplication as well: consumed keys must never reach a
    // terminal-like first responder, even when their target index is missing.
    focus(single)
    expect(single.makeFirstResponder(inputs.last!))
    guard app.isActive, app.keyWindow === single else {
      print("Native tab selection and field-editor restoration passed")
      print("SKIP application event routing: test app could not retain foreground focus")
      return
    }
    let shortcuts = ["1", "8", "9"].map { event($0) } + [
      event(String(UnicodeScalar(NSRightArrowFunctionKey)!),
        flags: [.command, .option, .function], code: 124)]
    for shortcut in shortcuts { app.sendEvent(shortcut) }
    expect(inputs.allSatisfy { input in
      !input.receivedKeys.contains { received in shortcuts.contains { $0 === received } }
    }, "A synthetic tab shortcut reached the input responder")
    // Prove the recorder receives ordinary input through the same route.
    let ordinaryKey = event("x", flags: [], code: 7)
    app.sendEvent(ordinaryKey)
    expect(inputs.last!.receivedKeys.filter { $0 === ordinaryKey }.count == 1,
      "The ordinary synthetic key did not reach the input responder exactly once")
    print("Native window tab navigation and responder routing passed")
  }
}

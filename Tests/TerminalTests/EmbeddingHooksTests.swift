import AppKit
import Testing
import TerminalEngine
@testable import TerminalHost
@testable import TerminalUI

/// What a host decides or reads through the view, over a transport so no
/// process is involved.
@Suite(.serialized) @MainActor struct EmbeddingHooksTests {
  private final class Line: TerminalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedConnection: TerminalConnection?
    private var storedSent = Data()
    var connection: TerminalConnection? { lock.lock(); defer { lock.unlock() }; return storedConnection }
    var sent: String { lock.lock(); defer { lock.unlock() }; return String(decoding: storedSent, as: UTF8.self) }
    func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
      lock.lock(); storedConnection = connection; lock.unlock()
    }
    func send(_ bytes: Data) { lock.lock(); storedSent.append(bytes); lock.unlock() }
  }
  private func osc52(_ text: String) -> Data {
    Data("\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}".utf8)
  }

  @Test func theHostDecidesEachClipboardWrite() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("no.helgesverre.terminal.tests.hooks.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    var asked: [String] = []
    let clipboard = ClipboardAccess(writingTo: pasteboard) { text, decide in
      asked.append(text)
      decide(!text.hasPrefix("secret"))
    }
    let line = Line()
    let session = TerminalSession(transport: line)
    defer { session.close() }
    let view = TerminalCanvasView(frame: .zero, session: session, rendering: nil, clipboard: clipboard)
    _ = view
    #expect(await TestEnvironment.wait { line.connection != nil })

    line.connection?.receive(osc52("secret one"))
    #expect(await TestEnvironment.wait { asked == ["secret one"] })
    #expect(pasteboard.string(forType: .string) == nil)
    // A refusal is for that write only.
    line.connection?.receive(osc52("public two"))
    #expect(await TestEnvironment.wait { pasteboard.string(forType: .string) == "public two" }, "\(asked)")
    #expect(asked == ["secret one", "public two"])
  }

  @Test func aPasteIsBracketedWhenTheProgramAsked() async {
    let line = Line()
    let session = TerminalSession(transport: line)
    defer { session.close() }
    #expect(await TestEnvironment.wait { line.connection != nil })
    #expect(session.paste("plain"))
    #expect(await TestEnvironment.wait { line.sent == "plain" }, "\(line.sent.debugDescription)")
    line.connection?.receive(Data("\u{1b}[?2004h".utf8))
    #expect(await TestEnvironment.wait {
      session.paste("x")
      return line.sent.contains("\u{1b}[200~x\u{1b}[201~")
    }, "\(line.sent.debugDescription)")
  }

  @Test func theViewGivesItsSelectionAndItsMenuToTheHost() async {
    let line = Line()
    let session = TerminalSession(transport: line)
    defer { session.close() }
    let view = TerminalCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), session: session,
                                  rendering: nil, clipboard: nil)
    #expect(await TestEnvironment.wait { line.connection != nil })
    line.connection?.receive(Data("first line\r\nsecond".utf8))
    #expect(await TestEnvironment.wait { view.visibleText.contains("second") })
    #expect(!view.hasSelection)
    var nothing: String?? = nil
    view.selectedText { nothing = .some($0) }
    #expect(nothing == .some(nil))

    view.selectAll(nil as Any?)
    #expect(await TestEnvironment.wait { view.hasSelection })
    var text: String?
    view.selectedText { text = $0 }
    #expect(await TestEnvironment.wait { text != nil })
    #expect(text?.hasPrefix("first line\nsecond") == true, "\(text ?? "nil")")
    view.clearSelection()
    #expect(await TestEnvironment.wait { !view.hasSelection })
  }

  @Test func theInsetAndTheChromeFollowTheConfiguration() {
    let session = TerminalSession(transport: Line())
    defer { session.close() }
    let view = TerminalCanvasView(frame: .zero, session: session, rendering: nil, clipboard: nil)
    let standard = view.contentSize(columns: 80, rows: 24)
    var configuration = TerminalViewConfiguration()
    configuration.contentInset = 0
    view.apply(configuration)
    let flush = view.contentSize(columns: 80, rows: 24)
    #expect(standard.width - flush.width == 16 && standard.height - flush.height == 16)

    // The app's scheme keeps the app's chrome; another scheme gets its own.
    #expect(TerminalChromeColors(.standard) == .standard)
    let light = TerminalChromeColors(TerminalColorScheme(foreground: 0x000000, background: 0xffffff, cursor: 0x0000ff))
    #expect(light.background == 0xffffff && light.text == 0x000000 && light.accent == 0x0000ff)
    #expect(light.raised == 0xededed, "a bar slightly darker than a light background")
    #expect(light.muted == 0x666666)
  }
}

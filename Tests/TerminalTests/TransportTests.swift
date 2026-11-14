import Foundation
import Testing
@testable import TerminalHost

/// A far end that records what the session asks of it.
private final class RecordingTransport: TerminalTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var storedConnection: TerminalConnection?
  private var storedSent = Data()
  private var storedSizes: [[Int]] = []
  private var storedCloses = 0
  private var storedStarts = 0
  var connection: TerminalConnection? { lock.lock(); defer { lock.unlock() }; return storedConnection }
  var sent: String { lock.lock(); defer { lock.unlock() }; return String(decoding: storedSent, as: UTF8.self) }
  var sizes: [[Int]] { lock.lock(); defer { lock.unlock() }; return storedSizes }
  var closes: Int { lock.lock(); defer { lock.unlock() }; return storedCloses }
  var starts: Int { lock.lock(); defer { lock.unlock() }; return storedStarts }

  func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
    lock.lock(); storedConnection = connection; storedStarts += 1; storedSizes.append([columns, rows]); lock.unlock()
  }
  func send(_ bytes: Data) { lock.lock(); storedSent.append(bytes); lock.unlock() }
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
    lock.lock(); storedSizes.append([columns, rows, pixelWidth, pixelHeight]); lock.unlock()
  }
  func close() { lock.lock(); storedCloses += 1; storedConnection = nil; lock.unlock() }
}

private struct LinkDown: Error {}

@Suite @MainActor struct TransportTests {
  private func text(of session: TerminalSession) -> () -> String {
    final class Box { var text = "" }
    let box = Box()
    session.onSnapshot = { box.text = $0.rows.map { $0.cells.map(\.text).joined() }.joined(separator: "\n") }
    return { box.text }
  }

  @Test func aSessionShowsATransportsOutputAndSendsItInput() async {
    let transport = RecordingTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    let screen = text(of: session)
    #expect(await TestEnvironment.wait { transport.connection != nil })
    #expect(transport.sizes.first == [80, 24])
    #expect(session.processIdentifier == nil)

    transport.connection?.receive(Data("FROM_FAR_END\r\n".utf8))
    #expect(await TestEnvironment.wait { screen().contains("FROM_FAR_END") })

    session.rawInput(Data("typed".utf8))
    #expect(await TestEnvironment.wait { transport.sent == "typed" }, "\(transport.sent)")

    // The terminal's own replies go to the far end too.
    transport.connection?.receive(Data("\u{1b}[6n".utf8))
    #expect(await TestEnvironment.wait { transport.sent.hasSuffix("\u{1b}[2;1R") }, "\(transport.sent.debugDescription)")
  }

  @Test func aResizeReachesTheTransport() async {
    let transport = RecordingTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    #expect(await TestEnvironment.wait { transport.connection != nil })
    session.resize(cols: 100, rows: 30, cellWidth: 9, cellHeight: 18)
    #expect(await TestEnvironment.wait { transport.sizes.last == [100, 30, 900, 540] }, "\(transport.sizes)")
  }

  @Test func theTransportStartsAtTheFirstGrid() async {
    let transport = RecordingTransport()
    let session = TerminalSession(transport: transport, startsAtFirstGrid: true)
    defer { session.close() }
    session.resize(cols: 120, rows: 40, cellWidth: 8, cellHeight: 16)
    #expect(await TestEnvironment.wait { transport.connection != nil })
    #expect(transport.sizes.first == [120, 40])
  }

  @Test func theSessionEndsWhenTheTransportDoes() async {
    let transport = RecordingTransport()
    let session = TerminalSession(transport: transport)
    let screen = text(of: session)
    var end: SessionEnd?
    var ends = 0
    session.onEnd = { end = $0; ends += 1 }
    #expect(await TestEnvironment.wait { transport.connection != nil })
    let connection = transport.connection
    // Output handed over just before the end is still shown.
    connection?.receive(Data(String(repeating: "x", count: 400_000).utf8))
    connection?.receive(Data("\r\nLAST_WORDS".utf8))
    connection?.end()
    #expect(await TestEnvironment.wait { end != nil })
    // The last frame is published at the frame cadence, the end at once.
    #expect(await TestEnvironment.wait { screen().contains("LAST_WORDS") }, "\(screen().suffix(60))")
    #expect(end?.exitedCleanly == true)
    #expect(end?.exitCode == nil, "there was no process")
    #expect(end?.transportError == nil)
    #expect(await TestEnvironment.wait { transport.closes == 1 })
    session.close()
    _ = await TestEnvironment.wait(seconds: 0.3) { false }
    #expect(ends == 1)
    #expect(transport.closes == 1)
    #expect(transport.starts == 1)
  }

  @Test func aTransportErrorMakesTheEndUnclean() async {
    let transport = RecordingTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    var end: SessionEnd?
    session.onEnd = { end = $0 }
    #expect(await TestEnvironment.wait { transport.connection != nil })
    transport.connection?.end(error: LinkDown())
    #expect(await TestEnvironment.wait { end != nil })
    #expect(end?.exitedCleanly == false)
    #expect(end?.transportError is LinkDown)
  }

  @Test func closingOrReleasingTheSessionClosesTheTransport() async {
    let closed = RecordingTransport()
    let session = TerminalSession(transport: closed)
    #expect(await TestEnvironment.wait { closed.connection != nil })
    session.close()
    #expect(await TestEnvironment.wait { closed.closes == 1 })

    let released = RecordingTransport()
    var owner: TerminalSession? = TerminalSession(transport: released)
    #expect(await TestEnvironment.wait { released.starts == 1 })
    _ = owner
    owner = nil
    #expect(await TestEnvironment.wait { released.closes == 1 })
  }
}

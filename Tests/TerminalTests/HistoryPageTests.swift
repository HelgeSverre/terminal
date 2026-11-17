import Foundation
import Testing
@testable import TerminalEngine
import TerminalInterop
@testable import TerminalHost

final class HistoryPageTransport: TerminalTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var endpoint: TerminalConnection?
  private var output = Data()
  var connection: TerminalConnection? { lock.lock(); defer { lock.unlock() }; return endpoint }
  var sent: String { lock.lock(); defer { lock.unlock() }; return String(decoding: output, as: UTF8.self) }
  func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
    lock.lock(); endpoint = connection; lock.unlock()
  }
  func send(_ bytes: Data) { lock.lock(); output.append(bytes); lock.unlock() }
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {}
  func close() { lock.lock(); endpoint = nil; lock.unlock() }
}

@Suite(.serialized) @MainActor struct HistoryPageTests {
  @Test func pagesAreBoundedOrderedAndRetainedAcrossOutput() throws {
    let core = try #require(helge_terminal_create(20, 3))
    defer { helge_terminal_destroy(core) }
    SnapshotBridgeTests.feed(core, (0..<200).map { "row-\($0)\r\n" }.joined())
    let latest = try #require(swiftTerminalHistoryPage(core, request: .latest))
    #expect(latest.rows.count == 64 && latest.hasOlder && !latest.hasNewer)
    #expect(latest.text.contains("row-199"))
    let first = try #require(latest.rows.first?.cursor)
    let older = try #require(swiftTerminalHistoryPage(core, request: .older(first)))
    #expect(older.rows.count == 64 && older.hasOlder && older.hasNewer)
    #expect(Set(latest.rows.map(\.cursor.row)).isDisjoint(with: older.rows.map(\.cursor.row)))
    let lastOlder = try #require(older.rows.last?.cursor)
    let newer = try #require(swiftTerminalHistoryPage(core, request: .newer(lastOlder)))
    #expect(newer.rows.map(\.cursor) == latest.rows.map(\.cursor))
    SnapshotBridgeTests.feed(core, "new output\r\n")
    #expect(!latest.text.contains("new output"), "Fetched pages own their text")
    SnapshotBridgeTests.feed(core, "\u{1b}[3J")
    #expect(swiftTerminalHistoryPage(core, request: .older(first)) == nil, "Evicted anchors must expire")
  }

  @Test func alternateScreenAndResetCannotReusePrimaryHistoryAnchors() throws {
    let core = try #require(helge_terminal_create(20, 3))
    defer { helge_terminal_destroy(core) }
    SnapshotBridgeTests.feed(core, "primary\r\n")
    let primary = try #require(swiftTerminalHistoryPage(core, request: .latest)?.rows.first?.cursor)
    SnapshotBridgeTests.feed(core, "\u{1b}[?1049halternate")
    #expect(swiftTerminalHistoryPage(core, request: .older(primary)) == nil)
    let alternate = try #require(swiftTerminalHistoryPage(core, request: .latest))
    #expect(alternate.rows.count == 3 && !alternate.hasOlder && !alternate.hasNewer)
    #expect(alternate.text.contains("alternate") && !alternate.text.contains("primary"))
    SnapshotBridgeTests.feed(core, "\u{1b}[?1049l\u{1b}c")
    #expect(swiftTerminalHistoryPage(core, request: .older(primary)) == nil)
  }

  @Test func widePagesRespectCellAndTextBudgets() throws {
    let core = try #require(helge_terminal_create(4096, 3))
    defer { helge_terminal_destroy(core) }
    SnapshotBridgeTests.feed(core, (0..<20).map { _ in String(repeating: "界", count: 2000) + "\r\n" }.joined())
    let page = try #require(swiftTerminalHistoryPage(core, request: .latest))
    #expect(page.rows.count <= 8 && page.hasOlder)
    #expect(page.text.utf16.count <= 65_536)
  }

  @Test func sessionFetchOrdersAfterOutputAndBoundsPendingMainCallbacks() async throws {
    let transport = HistoryPageTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    var observed = false
    session.onSnapshot = { snapshot in
      observed = snapshot.rows.contains { $0.cells.map(\.text).joined().contains("ordered-history-marker") }
    }
    #expect(await TestEnvironment.wait { transport.connection != nil })
    transport.connection?.receive(Data("ordered-history-marker\r\n".utf8))
    #expect(await TestEnvironment.wait { observed })
    var delivered = false
    var page: TerminalHistoryPage?
    #expect(session.accessibilityHistory(.latest) { page = $0; delivered = true })
    #expect(!session.accessibilityHistory(.latest) { _ in Issue.record("Second fetch must be refused") })
    #expect(await TestEnvironment.wait { delivered })
    #expect(try #require(page).text.contains("ordered-history-marker"))
    delivered = false
    #expect(session.accessibilityHistory(.latest) { page = $0; delivered = true })
    session.close()
    #expect(await TestEnvironment.wait { delivered })
    #expect(page == nil, "Close must cancel queued or not-yet-delivered pages")
  }
}

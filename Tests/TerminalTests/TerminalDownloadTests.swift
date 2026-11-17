import Foundation
import Testing
@testable import TerminalEngine
@testable import TerminalHost

@Suite(.serialized) struct TerminalDownloadTests {
  private let esc = "\u{1b}"
  private func file(_ bytes: Data, name: String = "note.txt", arguments: String = "inline=0") -> String {
    "\(esc)]1337;File=name=\(Data(name.utf8).base64EncodedString());\(arguments):\(bytes.base64EncodedString())\u{7}"
  }

  @Test func headlessDownloadsAreDataOnlyAndExplicitlyTaken() throws {
    let terminal = try #require(HeadlessTerminal(columns: 8, rows: 4))
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-output-\(UUID().uuidString).txt")
    let payload = Data([0, 255, 10, 0, 17])
    terminal.feed(file(payload, name: destination.path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(terminal.screen()?.images.isEmpty == true)
    let received = try #require(terminal.takeDownloads().first)
    #expect(received.suggestedFilename == destination.lastPathComponent && received.data == payload)
    #expect(terminal.takeDownloads().isEmpty)
    terminal.feed(file(Data(), arguments: ""))
    #expect(terminal.takeDownloads().first?.data.isEmpty == true, "omitted inline and empty files are valid")
  }

  @Test func multipartDownloadCancellationAndResetReleasePendingFiles() throws {
    let terminal = try #require(HeadlessTerminal(columns: 8, rows: 4))
    let bytes = Data("a multipart file".utf8), encoded = bytes.base64EncodedString()
    let start = "\(esc)]1337;MultipartFile=name=YS50eHQ=;inline=0\u{7}"
    terminal.feed(start + "\(esc)]1337;FilePart=\(encoded.prefix(8))\u{7}")
    #expect(terminal.takeDownloads().isEmpty)
    terminal.feed("\(esc)]1337;FilePart=\(encoded.dropFirst(8))\(esc)\\\(esc)]1337;FileEnd\u{7}")
    let file = try #require(terminal.takeDownloads().first)
    #expect(file.suggestedFilename == "a.txt" && file.data == bytes)
    terminal.feed(start + "\(esc)]1337;FilePart=\(encoded)\u{18}\(esc)]1337;FileEnd\u{7}")
    #expect(terminal.takeDownloads().isEmpty)
    terminal.feed(self.file(bytes) + "\(esc)c")
    #expect(terminal.takeDownloads().isEmpty, "RIS clears completed downloads")
    terminal.feed(self.file(bytes) + "\(esc)]1337;File=inline=0:!!!!\u{7}")
    #expect(terminal.takeDownloads().count == 1, "malformed base64 is never offered")
  }

  @Test func filenameAndQueueBudgetsAreBounded() {
    #expect(TerminalDownloads.filename("../../folder/\u{202e}good\n.txt") == "good.txt")
    #expect(TerminalDownloads.filename("C:\\folder\\a:b.txt") == "a_b.txt")
    for name in ["", "/", ".", "..", "\u{0}"] { #expect(TerminalDownloads.filename(name) == "Unnamed file") }
    #expect(TerminalDownloads.filename(String(repeating: "🦊", count: 100)).utf8.count <= 255)
    let downloads = TerminalDownloads()
    for index in 0..<4 { #expect(downloads.enqueue(name: "\(index)", data: Data([UInt8(index)]))) }
    #expect(!downloads.enqueue(name: "overflow", data: Data()))
    let id = downloads.pending[0].id
    #expect(downloads.resolve(id, take: false) == nil && downloads.pending.count == 3)
    #expect(downloads.enqueue(name: "replacement", data: Data()))
    downloads.clear()
    let half = Data(repeating: 17, count: TerminalDownloads.maximumBytes / 2)
    #expect(downloads.enqueue(name: "one", data: half) && downloads.enqueue(name: "two", data: half))
    #expect(!downloads.enqueue(name: "over-byte-budget", data: Data([1])))
    #expect(downloads.byteCount == TerminalDownloads.maximumBytes)
    #expect(downloads.takeAll().count == 2 && downloads.byteCount == 0 && downloads.pending.isEmpty)
  }

  @Test @MainActor func dismissCancelsATakeBeforeDeliveryAndCompletionIsOnce() async {
    var ownerCompletion: (@MainActor (Data?) -> Void)?
    let request = TerminalDownloadRequest(suggestedFilename: "file", byteCount: 1, live: { true }) { _, completion in
      ownerCompletion = completion
    }
    var deliveries: [Data?] = []
    request.takeData { deliveries.append($0) }
    request.dismiss()
    ownerCompletion?(Data([1]))
    #expect(deliveries.count == 1 && deliveries[0] == nil)
    request.takeData { deliveries.append($0) }
    #expect(await TestEnvironment.wait { deliveries.count == 2 })
    #expect(deliveries[1] == nil && !request.isAvailable)
  }

  private final class Transport: TerminalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TerminalConnection?
    var connection: TerminalConnection? { lock.lock(); defer { lock.unlock() }; return stored }
    func start(_ connection: TerminalConnection, columns: Int, rows: Int) { lock.lock(); stored = connection; lock.unlock() }
    func send(_ bytes: Data) {}
  }

  @Test @MainActor func sessionDeliversMetadataThenExplicitDataAndInvalidatesOnClose() async throws {
    let transport = Transport(), payload = Data("received file".utf8)
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    var offers: [TerminalDownloadRequest] = []
    session.onDownload = { offers.append($0) }
    #expect(await TestEnvironment.wait { transport.connection != nil })
    transport.connection?.receive(Data(file(payload).utf8))
    #expect(await TestEnvironment.wait { offers.count == 1 })
    let first = try #require(offers.first)
    #expect(first.suggestedFilename == "note.txt" && first.byteCount == payload.count && first.isAvailable)
    var received: Data?, completed = false
    first.takeData { received = $0; completed = true }
    #expect(await TestEnvironment.wait { completed })
    #expect(received == payload && !first.isAvailable)
    transport.connection?.receive(Data(file(payload).utf8))
    #expect(await TestEnvironment.wait { offers.count == 2 })
    let pending = offers[1]
    session.close()
    #expect(!pending.isAvailable)
    completed = false; received = payload
    pending.takeData { received = $0; completed = true }
    #expect(await TestEnvironment.wait { completed })
    #expect(received == nil)
  }
}

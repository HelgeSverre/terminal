import Foundation

/// The model provider of a Codex stress run: `dev tui-stress provider`.
///
/// A loopback-only server that answers every Responses request with the same
/// streamed text, so Codex renders real output without reaching a model.
/// Request bodies and headers are discarded and never written to provenance.
enum TUIStressProvider {
  /// The text every response streams. Both accents are a combining mark,
  /// written as an escape because an editor would silently compose them.
  static let response = """
    TUI_STRESS_RESPONSE

    # Streamed resize fixture

    **bold** _italic_ and `inline-code` render while this response streams.

    ```swift
    let path = "/tmp/tui-stress/猫/combining-cafe\u{301}.txt"
    print("TUI_STRESS_RESPONSE")
    ```

    | field | rendered value |
    | --- | --- |
    | path | `/tmp/tui-stress/猫` |
    | link | https://example.test/tui-stress |
    | text | 中 文 · cafe\u{301} · 👩‍💻 |

    URL: https://example.test/tui-stress
    TUI_STRESS_RESPONSE

    """

  static let maxBodyBytes = 1 * 1024 * 1024
  static let maxHeaderBytes = 64 * 1024
  static let maxResponseBytes = 16 * 1024

  static func main(_ arguments: [String]) throws {
    guard arguments.isEmpty else {
      throw Failure.usage(
        "usage: TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE=/absolute/fixture/provider.json dev tui-stress provider")
    }
    let server = try Server(environment: ProcessInfo.processInfo.environment)
    Interruption.takeOver()
    try server.serve()
  }

  /// The response text in pieces of 18 code points. A piece can end inside an
  /// emoji sequence but never inside a code point, so each is valid UTF-8.
  static let chunks: [String] = {
    let scalars = Array(response.unicodeScalars)
    return stride(from: 0, to: scalars.count, by: 18).map { start in
      var piece = String.UnicodeScalarView()
      piece.append(contentsOf: scalars[start..<min(start + 18, scalars.count)])
      return String(piece)
    }
  }()

  /// Every event of one streamed response, in order, as the Responses API sends them.
  static func streamEvents(responseID: String) -> [[String: Any]] {
    let itemID = "msg_" + (responseID.hasPrefix("resp_") ? String(responseID.dropFirst(5)) : responseID)
    let part: [String: Any] = ["type": "output_text", "text": "", "annotations": [Any](), "logprobs": [Any]()]
    let item: [String: Any] = ["id": itemID, "status": "in_progress", "type": "message", "role": "assistant",
                               "content": [Any]()]
    let place: [String: Any] = ["item_id": itemID, "output_index": 0, "content_index": 0]
    func event(_ type: String, _ fields: [String: Any], at place: [String: Any] = [:]) -> [String: Any] {
      fields.merging(place) { field, _ in field }.merging(["type": type]) { field, _ in field }
    }
    let completePart = part.merging(["text": response]) { _, new in new }
    let completeItem = item.merging(["status": "completed", "content": [completePart]]) { _, new in new }
    var events = [
      event("response.created", ["response": responseObject(id: responseID, status: "in_progress", output: [])]),
      event("response.output_item.added", ["output_index": 0, "item": item]),
      event("response.content_part.added", ["part": part], at: place),
    ]
    events += chunks.map { event("response.output_text.delta", ["delta": $0, "logprobs": [Any]()], at: place) }
    events += [
      event("response.output_text.done", ["text": response, "logprobs": [Any]()], at: place),
      event("response.content_part.done", ["part": completePart], at: place),
      event("response.output_item.done", ["output_index": 0, "item": completeItem]),
      event("response.completed",
            ["response": responseObject(id: responseID, status: "completed", output: [completeItem])]),
    ]
    for index in events.indices { events[index]["sequence_number"] = index + 1 }
    return events
  }

  private static func responseObject(id: String, status: String, output: [Any]) -> [String: Any] {
    let null = NSNull()
    return [
      "id": id, "object": "response", "created_at": 1, "status": status,
      "completed_at": status == "completed" ? 1 : null, "error": null, "incomplete_details": null,
      "instructions": null, "max_output_tokens": null, "model": "fixture-model", "output": output,
      "parallel_tool_calls": false, "previous_response_id": null,
      "reasoning": ["effort": null, "summary": null], "store": false, "temperature": 1,
      "text": ["format": ["type": "text"]], "tool_choice": "auto", "tools": [Any](),
      "top_p": 1, "truncation": "disabled", "usage": null, "user": null, "metadata": [String: Any](),
    ]
  }

  /// Why a request was answered with an error.
  enum RequestError: Error {
    case invalid(String)
    case timedOut
    case system(Int32)

    /// The name recorded in provenance. These are the names the Ruby provider
    /// recorded, kept so that provenance files from both stay comparable.
    var name: String {
      switch self {
      case .invalid: return "RuntimeError"
      case .timedOut: return "Timeout::Error"
      case .system(EPIPE): return "Errno::EPIPE"
      case .system(ECONNRESET): return "Errno::ECONNRESET"
      case .system: return "SystemCallError"
      }
    }
  }

  /// One accepted connection, read through a buffer so that a line and the body after it can share a read.
  struct Connection {
    let descriptor: Int32
    private var buffer = Data()

    init(_ descriptor: Int32) { self.descriptor = descriptor }

    /// Reads more into the buffer. Returns false at the end of the stream.
    private mutating func fill(until deadline: Double?) throws -> Bool {
      if let deadline {
        let remaining = deadline - monotonic()
        guard remaining > 0, !readable([descriptor], milliseconds: Int32(remaining * 1000) + 1).isEmpty else {
          throw RequestError.timedOut
        }
      }
      var bytes = [UInt8](repeating: 0, count: 16_384)
      let count = recv(descriptor, &bytes, bytes.count, 0)
      if count < 0 {
        if errno == EINTR { return true }
        throw RequestError.system(errno)
      }
      buffer.append(contentsOf: bytes[..<count])
      return count > 0
    }

    /// The next line with its line ending, an unterminated last line, or nil at the end of the stream.
    private mutating func line(until deadline: Double) throws -> String? {
      let ending = Data("\r\n".utf8)
      while true {
        if let range = buffer.range(of: ending) {
          let line = buffer.subdata(in: buffer.startIndex..<range.upperBound)
          buffer = buffer.subdata(in: range.upperBound..<buffer.endIndex)
          return String(decoding: line, as: UTF8.self)
        }
        if try !fill(until: deadline) {
          defer { buffer = Data() }
          return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
      }
    }

    /// The request line and the headers, with lower-case names.
    mutating func readHeaders(until deadline: Double) throws -> (request: String, headers: [String: String]) {
      let request = try line(until: deadline)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !request.isEmpty else { throw RequestError.invalid("missing request line") }
      var headers: [String: String] = [:]
      var total = 0
      while true {
        guard let line = try line(until: deadline) else { throw RequestError.invalid("truncated request headers") }
        if line == "\r\n" { return (request, headers) }
        total += line.utf8.count
        guard total <= maxHeaderBytes else { throw RequestError.invalid("request headers exceed fixture bound") }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RequestError.invalid("malformed request header") }
        headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    /// Reads the request body and throws it away. Returns its length.
    mutating func discardBody(_ headers: [String: String]) throws -> Int {
      guard headers["transfer-encoding"] == nil else {
        throw RequestError.invalid("chunked request bodies are not accepted by this fixture")
      }
      guard let length = Int(headers["content-length"] ?? "0") else {
        throw RequestError.invalid("invalid request content length")
      }
      guard (0...maxBodyBytes).contains(length) else { throw RequestError.invalid("request body exceeds fixture bound") }
      while buffer.count < length {
        guard try fill(until: nil) else { throw RequestError.invalid("truncated request body") }
      }
      buffer = Data()
      return length
    }

    func send(_ text: String) throws {
      do { try writeAll(descriptor, Data(text.utf8)) }
      catch let error as SystemFailure { throw RequestError.system(error.code) }
    }

    func sendJSON(status: Int, _ body: [String: Any]) throws {
      let payload = String(decoding: try compactJSON(body), as: UTF8.self)
      // Every status but 200 is sent with the reason "Not Found", as the Ruby provider did.
      try send("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: application/json\r\n"
        + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)")
    }
  }

  /// The listening server. It ends after its lifetime, when one request more
  /// than its limit arrives, or when it is signalled, so that it cannot outlive a run by long.
  final class Server {
    private let portFile: String
    private let slowMilliseconds: Int
    private let maxRequests: Int
    private let lifetimeSeconds: Int
    private let listener: Int32
    let port: Int
    private let started = monotonic()
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var requests: [[String: Any]] = []
    private var accepted = 0
    private var closing = false

    init(environment: [String: String]) throws {
      guard let file = environment["TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE"] else {
        throw Failure("missing environment variable TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE")
      }
      func integer(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
        let bounds = "\(range.lowerBound)..\(range.upperBound)"
        guard let value = Int(environment[key] ?? String(fallback)) else {
          throw Failure("\(key) must be an integer within \(bounds)")
        }
        guard range.contains(value) else { throw Failure("\(key) must be within \(bounds)") }
        return value
      }
      portFile = absolutePath(file)
      slowMilliseconds = try integer("TERMINAL_TUI_STRESS_PROVIDER_SLOW_MS", 12, 0...1000)
      maxRequests = try integer("TERMINAL_TUI_STRESS_PROVIDER_MAX_REQUESTS", 8, 1...32)
      lifetimeSeconds = try integer("TERMINAL_TUI_STRESS_PROVIDER_LIFETIME_SECONDS", 90, 1...300)
      guard !FileManager.default.fileExists(atPath: portFile) else {
        throw Failure("provider port file already exists; use a unique fixture path")
      }
      guard isDirectory(URL(fileURLWithPath: portFile).deletingLastPathComponent().path) else {
        throw Failure("provider port-file parent directory is missing")
      }
      (listener, port) = try Self.listen()
    }

    /// Listens on a free loopback port. Nothing outside this machine can connect.
    private static func listen() throws -> (descriptor: Int32, port: Int) {
      let descriptor = socket(AF_INET, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw Failure(SystemFailure("socket").message) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, length) == 0 && Darwin.listen(descriptor, 16) == 0 && getsockname(descriptor, $0, &length) == 0
        }
      }
      // A connection that goes away between the poll and the accept must not block the loop.
      guard bound, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
        close(descriptor)
        throw Failure(SystemFailure("listen on 127.0.0.1").message)
      }
      return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    private var isStopping: Bool {
      if Interruption.stopRequested { return true }
      lock.lock()
      defer { lock.unlock() }
      return closing
    }

    /// Serves until the server ends, then waits for requests in progress and writes the final provenance.
    func serve() throws {
      try writeProvenance("listening")
      let deadline = monotonic() + Double(lifetimeSeconds)
      while !isStopping, monotonic() < deadline {
        let wait = min(max(deadline - monotonic(), 0), 0.25)
        guard !readable([listener], milliseconds: Int32(wait * 1000)).isEmpty else { continue }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { continue }
        guard let slot = reserveRequest() else {
          close(client)
          break
        }
        workers.enter()
        Thread.detachNewThread {
          self.handle(client, slot: slot)
          self.workers.leave()
        }
      }
      let status = Interruption.stopRequested ? "stopped" : "complete"
      lock.lock(); closing = true; lock.unlock()
      close(listener)
      workers.wait()
      lock.lock()
      defer { lock.unlock() }
      try writeProvenance(status)
    }

    private func reserveRequest() -> Int? {
      lock.lock()
      defer { lock.unlock() }
      guard accepted < maxRequests else { return nil }
      accepted += 1
      return accepted
    }

    private func handle(_ client: Int32, slot: Int) {
      let began = monotonic()
      // An accepted socket inherits the listener's non-blocking mode. A
      // client that hangs up mid-stream must produce an error, not SIGPIPE.
      _ = fcntl(client, F_SETFL, 0)
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      defer { close(client) }
      var connection = Connection(client)
      do {
        let (request, headers) = try connection.readHeaders(until: began + 3)
        let parts = request.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2] == "HTTP/1.1" else { throw RequestError.invalid("invalid HTTP version") }
        let bodyBytes = try connection.discardBody(headers)
        switch (parts[0], parts[1]) {
        case ("POST", "/v1/responses"):
          let responseID = String(format: "resp_tui_stress_%03d", slot)
          try stream(connection, responseID: responseID)
          record(parts[0], parts[1], bodyBytes, responseID: responseID, status: 200, began: began)
        case ("GET", "/v1/models"):
          let model: [String: Any] = ["id": "fixture-model", "object": "model", "created": 1, "owned_by": "tui-stress"]
          try connection.sendJSON(status: 200, ["object": "list", "data": [model]])
          record(parts[0], parts[1], bodyBytes, status: 200, began: began)
        default:
          try connection.sendJSON(status: 404, ["error": ["message": "local fixture route not found",
                                                          "type": "invalid_request_error"]])
          record(parts[0], parts[1], bodyBytes, status: 404, began: began)
        }
      } catch {
        try? connection.sendJSON(status: 400, ["error": ["message": "local fixture rejected malformed request",
                                                         "type": "invalid_request_error"]])
        let name = (error as? RequestError)?.name ?? "RuntimeError"
        record("invalid", "invalid", 0, status: 400, began: began, error: name)
      }
    }

    /// Sends the response as server-sent events, pausing between pieces of
    /// text so that Codex is still streaming while the driver resizes the window.
    private func stream(_ connection: Connection, responseID: String) throws {
      try connection.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
        + "Connection: close\r\nX-Accel-Buffering: no\r\n\r\n")
      for event in streamEvents(responseID: responseID) {
        let type = event["type"] as? String ?? ""
        try connection.send("event: \(type)\ndata: \(String(decoding: try compactJSON(event), as: UTF8.self))\n\n")
        if type == "response.output_text.delta", slowMilliseconds > 0, !isStopping {
          usleep(useconds_t(slowMilliseconds * 1000))
        }
      }
    }

    private func record(_ method: String, _ path: String, _ bodyBytes: Int, responseID: String? = nil,
                        status: Int, began: Double, error: String? = nil) {
      lock.lock()
      defer { lock.unlock() }
      var request: [String: Any] = ["method": method, "path": path, "body_bytes": bodyBytes, "status": status,
                                    "duration_ms": ((monotonic() - began) * 1_000_000).rounded() / 1000]
      request["response_id"] = responseID
      request["error"] = error
      requests.append(request)
      try? writeProvenance("listening")
    }

    /// Rewrites the port file. The runner reads the port from it, and later
    /// which requests were answered. Callers other than `serve`'s first write hold the lock.
    private func writeProvenance(_ status: String) throws {
      let payload: [String: Any] = [
        "protocol": "responses-sse-fixture-v1", "status": status, "pid": Int(getpid()), "host": "127.0.0.1",
        "port": port, "response_identity": "TUI_STRESS_RESPONSE",
        "response_sha256": sha256(of: Data(response.utf8)), "response_bytes": response.utf8.count,
        "event_count": streamEvents(responseID: "resp_tui_stress_001").count, "slow_ms": slowMilliseconds,
        "max_requests": maxRequests, "lifetime_seconds": lifetimeSeconds, "request_count": requests.count,
        "requests": requests, "started_monotonic": started, "updated_monotonic": monotonic(),
      ]
      let exists = FileManager.default.fileExists(atPath: portFile)
      let descriptor = open(portFile, exists ? O_RDWR : O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard descriptor >= 0 else { throw Failure(SystemFailure("open \(portFile)").message) }
      defer { close(descriptor) }
      do {
        guard ftruncate(descriptor, 0) == 0 else { throw SystemFailure("truncate \(portFile)") }
        try writeAll(descriptor, try compactJSON(payload))
      } catch { throw Failure(wrapping: error) }
    }
  }

  private static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }

  static let tests = [
    SelfTest.Case(name: "tui-stress provider: deterministic Responses SSE event lifecycle and Unicode-safe chunks") {
      let events = streamEvents(responseID: "resp_tui_stress_001")
      let expected = ["response.created", "response.output_item.added", "response.content_part.added"]
        + Array(repeating: "response.output_text.delta", count: chunks.count)
        + ["response.output_text.done", "response.content_part.done", "response.output_item.done", "response.completed"]
      try expect(events.map { $0["type"] as? String ?? "" } == expected, "the response lifecycle is complete")
      try expect(events.map { $0["sequence_number"] as? Int ?? 0 } == Array(1...events.count),
                 "sequence numbers rise by one")
      let text = events.filter { $0["type"] as? String == "response.output_text.delta" }
        .map { $0["delta"] as? String ?? "" }.joined()
      try expect(text == response, "the pieces join to the response text")
      try expect(response.utf8.count <= maxResponseBytes, "the response is within the fixture bound")
    },
    SelfTest.Case(name: "tui-stress provider: the response text is the Ruby provider's, byte for byte") {
      try expect(response.utf8.count == 437, "437 bytes, got \(response.utf8.count)")
      try expect(chunks.count == 24, "24 pieces, got \(chunks.count)")
      try expect(sha256(of: Data(response.utf8)) == "0d483012cc211418402e9a4150739add2a98b93f1eb64e462b46c3cd0cae8852",
                 "the hash recorded in earlier provenance files")
    },
    SelfTest.Case(name: "tui-stress provider: serves the stream over loopback and records each request") {
      try withTemporaryDirectory("dev-tui-stress-provider-") { directory in
        let portFile = directory + "/provider.json"
        let server = try Server(environment: [
          "TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE": portFile, "TERMINAL_TUI_STRESS_PROVIDER_SLOW_MS": "0",
          "TERMINAL_TUI_STRESS_PROVIDER_MAX_REQUESTS": "3", "TERMINAL_TUI_STRESS_PROVIDER_LIFETIME_SECONDS": "5",
        ])
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
          try? server.serve()
          done.signal()
        }
        let stream = try exchange(port: server.port,
                                  "POST /v1/responses HTTP/1.1\r\nContent-Length: 4\r\nAuthorization: x\r\n\r\nbody")
        try expect(stream.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream"),
                   "the stream starts: \(stream.prefix(80))")
        try expect(stream.contains("event: response.completed\n"), "the stream completes")
        try expect(stream.contains("resp_tui_stress_001"), "the first response is numbered 001")
        try expect(try exchange(port: server.port, "GET /v1/models HTTP/1.1\r\n\r\n").contains("fixture-model"),
                   "the model list names the fixture model")
        try expect(try exchange(port: server.port, "GET / HTTP/1.0\r\n\r\n").hasPrefix("HTTP/1.1 400"),
                   "another HTTP version is rejected")
        // One connection more than the limit ends the server.
        _ = try exchange(port: server.port, "GET /v1/models HTTP/1.1\r\n\r\n")
        try expect(done.wait(timeout: .now() + 3) == .success, "the server ends at its request limit")
        let provenance = try readJSONObject(portFile)
        let requests = provenance["requests"] as? [[String: Any]] ?? []
        try expect(provenance["status"] as? String == "complete", "the final status is complete")
        try expect(provenance["port"] as? Int == server.port, "the port is recorded")
        try expect(requests.map { $0["status"] as? Int ?? 0 } == [200, 200, 400], "each request is recorded: \(requests)")
        let first = requests.first
        try expect(first?["body_bytes"] as? Int == 4 && first?["response_id"] as? String == "resp_tui_stress_001",
                   "the stream request records its body length and response")
        try expect(requests.last?["error"] as? String == "RuntimeError", "the rejection names its error")
        let written = String(decoding: FileManager.default.contents(atPath: portFile) ?? Data(), as: UTF8.self)
        try expect(!written.contains("Authorization"), "no header reaches provenance")
      }
    },
  ]

  /// Sends one request to the loopback server and returns everything it answers.
  private static func exchange(port: Int, _ request: String) throws -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Failure(SystemFailure("socket").message) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    guard connected else { throw Failure(SystemFailure("connect to the provider").message) }
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    try? writeAll(descriptor, Data(request.utf8))
    var answer = Data()
    while !readable([descriptor], milliseconds: 3000).isEmpty,
          case .bytes(let bytes)? = try? readAvailable(descriptor, limit: 65_536) {
      answer += bytes
    }
    return String(decoding: answer, as: UTF8.self)
  }
}

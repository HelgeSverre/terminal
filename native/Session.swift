import Foundation

struct CellSnapshot: Decodable, Equatable {
  let text: String
  let kind: String
  let style: CellStyle
  let link: String?
  let flags: Int
}
struct TerminalColor: Decodable, Equatable {
  let index: Int?
  let rgb: [Int]?
  init(packed: UInt32) {
    index = packed >> 24 == 1 ? Int(packed & 255) : nil
    rgb =
      packed >> 24 == 2
      ? [Int((packed >> 16) & 255), Int((packed >> 8) & 255), Int(packed & 255)] : nil
  }
  init(from decoder: Decoder) throws {
    if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self),
      s == "Default"
    {
      index = nil
      rgb = nil
      return
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    index = try c.decodeIfPresent(Int.self, forKey: .Indexed)
    rgb = try c.decodeIfPresent([Int].self, forKey: .Rgb)
  }
  enum CodingKeys: String, CodingKey { case Indexed, Rgb }
}
struct CellStyle: Decodable, Equatable {
  let foreground: TerminalColor
  let background: TerminalColor
  let underline_color: TerminalColor
  let underline: Int
  let bold: Bool
  let faint: Bool
  let italic: Bool
  let inverse: Bool
  let conceal: Bool
  let strike: Bool
  let overline: Bool
  let blink: Bool
}
struct RowSnapshot: Decodable, Equatable {
  let cells: [CellSnapshot]
  let soft_wrapped: Bool
}
struct CursorSnapshot: Decodable, Equatable {
  let row: Int
  let col: Int
  let pending_wrap: Bool
  let visible: Bool
  let shape: Int
}
struct ModesSnapshot: Decodable, Equatable {
  let application_cursor: Bool
  let bracketed_paste: Bool
  let focus: Bool
  let mouse: Int
  let sgr_mouse: Bool
  let reverse_video: Bool
}
struct ImageKey: Hashable {
  let id: UInt32
  let generation: UInt64
}
struct ImagePlacementSnapshot: Decodable, Equatable {
  let image: UInt32
  let generation: UInt64
  let width: Int
  let height: Int
  let source: [Int]
  let row: Int
  let col: Int
  let columns: Int
  let rows: Int
  let offset: [Int]
  let natural: Bool
  let z: Int
  let placement: UInt64
  var key: ImageKey { ImageKey(id: image, generation: generation) }
}
final class ImagePixels: @unchecked Sendable {
  let data: Data
  init(_ data: Data) { self.data = data }
}
private final class ImageCapture { var data: Data? }
struct TerminalSnapshot: Decodable {
  let at_prompt: Bool
  let search: [SearchHighlight]
  let images: [ImagePlacementSnapshot]
  var imagePixels: [ImageKey: ImagePixels] = [:]
  enum CodingKeys: String, CodingKey {
    case at_prompt, search, images, revision, geometry_epoch, document_epoch, history_epoch, screen_epoch,
      scroll_offset, following_tail, viewport_clamp_revision, cols, rows, cursor, modes, alternate, title,
      history_rows, palette, default_fg, default_bg
  }
  let revision: UInt64
  let geometry_epoch: UInt64
  let document_epoch: UInt64
  let history_epoch: UInt64
  let screen_epoch: UInt64
  let scroll_offset: Int
  let following_tail: Bool
  let viewport_clamp_revision: UInt64
  let cols: Int
  let rows: [RowSnapshot]
  let cursor: CursorSnapshot
  let modes: ModesSnapshot
  let alternate: Bool
  let title: String
  let history_rows: Int
  let palette: [[Int]]
  let default_fg: [Int]
  let default_bg: [Int]
}
struct SearchHighlight: Decodable, Equatable {
  let row: Int
  let start: Int
  let end: Int
}
enum HistorySearchOutcome: Equatable {
  case found, missing, changed, cancelled, invalidQuery, resourceLimit
  var message: String {
    switch self {
    case .found: return "Match found"
    case .missing: return "No match"
    case .changed: return "Output changed during search; try again"
    case .cancelled: return "Search cancelled"
    case .invalidQuery: return "Search must contain 1–4096 UTF-8 bytes"
    case .resourceLimit: return "A terminal row exceeds the search memory limit"
    }
  }
}

struct LaunchSpec {
  let executable: String
  let arguments: [String]
  let cwd: String
  let launcher: String
  static var shell: LaunchSpec {
    let executable = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    return LaunchSpec(
      executable: executable, arguments: [executable, "-l"],
      cwd: TerminalPreferences.load().launchDirectory,
      launcher: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalLauncher").path)
  }
}
final class ClipboardWriteRequest {
  let sessionID: UUID
  let data: Data
  private let complete: (Bool, @escaping @MainActor (Bool) -> Void) -> Void
  private let live: () -> Bool
  private var resolved = false
  init(
    sessionID: UUID, data: Data,
    live: @escaping () -> Bool,
    complete: @escaping (Bool, @escaping @MainActor (Bool) -> Void) -> Void
  ) {
    self.sessionID = sessionID
    self.data = data
    self.live = live
    self.complete = complete
  }
  var isLive: Bool { live() }
  func resolve(_ allowed: Bool, completion: @escaping @MainActor (Bool) -> Void) {
    guard !resolved else { return }
    resolved = true
    complete(allowed, completion)
  }
}

// Complete physical-key facts are admitted as one object. Text commits, paste
// and focus use Session's legacy raw-input API and cannot accidentally claim a
// keyboard-layout identity they do not have.
struct TerminalKeyEvent {
  let text: String
  let logical: String
  let shifted: String
  let baseLayout: String
  let legacyText: String
  let key: UInt32
  let modifiers: UInt32
  let event: UInt32
  private var isModifierOnly: Bool { (400...412).contains(key) }
  // Presentation policy belongs to the immutable input fact, not to mutable
  // terminal modes queried from the main thread. A modifier can encode to an
  // empty legacy write or a Kitty sequence, but it never changes user intent.
  var isKeyAction: Bool { event != 2 && !isModifierOnly }
}
// The PTY and Rust handle are confined to this queue. Main receives immutable decoded values.
final class Session: @unchecked Sendable {
  let queue = DispatchQueue(label: "no.helgesverre.terminal.owner", qos: .userInteractive)
  private enum Event {
    case output(Data, Int)
    case input(String, UInt32, UInt32, UInt32, Int)
    case keyInput(TerminalKeyEvent, Int)
    case raw(Data, Int)
    case shortcut(Data, Int)
    case resize(Int, Int, Int, Int)
    case configure(TerminalSessionConfiguration)
    case scroll(Int)
    case find(String, @MainActor (HistorySearchOutcome) -> Void)
    case searchAdvance
    case clearDisplay
    case probe(UInt64, @MainActor (Double) -> Void)
    case clipboardDecision(UInt64, Bool, @MainActor (Bool) -> Void)
    case eof, idle
  }
  private let launchSpec: LaunchSpec?
  private var events: [Event] = []
  private var head = 0
  private var queuedOutput = 0
  private var bytesRead: UInt64 = 0
  private var bytesParsed: UInt64 = 0
  private var firstReadNs: UInt64 = 0
  private var lastParseNs: UInt64 = 0
  private var parserEnded = false
  private var ownerScheduled = false
  private var core: OpaquePointer?
  private var master: Int32 = -1
  private var pid: Int32 = -1
  private var reaped = false
  private var readEnded = false
  private var writeEnded = false
  private var closed = false
  private var readSuspended = false
  private var writeSuspended = false
  private var clipboardClosedNotified = false
  private var clipboardCloseDelivered = false
  private var reader: DispatchSourceRead?
  private var writer: DispatchSourceWrite?
  private var statusReader: DispatchSourceRead?
  private var process: DispatchSourceProcess?
  private var writes: [WriteTransaction] = []
  private var writeID: UInt64 = 0
  private var collectingPaste = false
  private var columns = 80
  private var rowCount = 24
  private var cellWidthPx = 8
  private var cellHeightPx = 16
  private var configuration = TerminalSessionConfiguration()
  private var imageCache: [ImageKey: ImagePixels] = [:]
  private var publishScheduled = false
  private let admission = NSLock()
  private var admittedBytes = 0
  private var accepting = true
  private let publication = NSLock()
  private var latest: TerminalSnapshot?
  private var deliveryScheduled = false
  private lazy var historySearch = HistorySearch(session: self)
  var onSnapshot: (@MainActor (TerminalSnapshot) -> Void)?
  var onStatus: (@MainActor (String) -> Void)?
  var onClipboardWrite: (@MainActor (ClipboardWriteRequest) -> Void)?
  private var onClipboardClosed: (@MainActor (UUID) -> Void)?
  private let clipboardSessionID = UUID()
  init(launch: LaunchSpec? = nil) {
    launchSpec = launch
    queue.async { [self] in start() }
  }
  deinit { if let core { terminal_destroy(core) } }
  private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
  private var writeBytes: Int { writes.reduce(0) { $0 + $1.remaining } }
  // This module owns worker scheduling, latest-query replacement, bounded work,
  // retries, lifetime and source validation. Canvas only submits a query and
  // receives an outcome; it never reconstructs history positions or epochs.
  private final class HistorySearch {
    private static let worker = DispatchQueue(label: "no.helgesverre.terminal.search", qos: .utility)
    private final class Job {
      let handle: OpaquePointer
      let generation: UInt64
      init(_ handle: OpaquePointer, generation: UInt64) {
        self.handle = handle
        self.generation = generation
      }
      deinit { terminal_search_destroy(handle) }
    }
    private struct Request {
      let query: String
      let completion: @MainActor (HistorySearchOutcome) -> Void
      var retries = 0
    }
    private weak var session: Session?
    private var generation: UInt64 = 0
    private var request: Request?
    private var job: Job?
    private var working = false
    private var scheduled = false
    init(session: Session) { self.session = session }
    func start(_ query: String, completion: @escaping @MainActor (HistorySearchOutcome) -> Void) {
      cancel()
      request = Request(query: query, completion: completion)
      schedule()
    }
    func cancel() {
      generation &+= 1
      if let request { DispatchQueue.main.async { request.completion(.cancelled) } }
      request = nil
      job = nil
    }
    private func schedule() {
      guard !working, !scheduled, request != nil, let session, !session.closed else { return }
      scheduled = true
      session.enqueue(.searchAdvance)
    }
    func advance() {
      scheduled = false
      guard !working, let request, let session, !session.closed, let core = session.core else { return }
      if job == nil {
        guard !request.query.isEmpty, request.query.utf8.count <= 4096 else {
          finish(.invalidQuery)
          return
        }
        let bytes = Array(request.query.utf8)
        let handle = bytes.withUnsafeBufferPointer {
          terminal_search_create(core, $0.baseAddress, $0.count)
        }
        guard let handle else { finish(.invalidQuery); return }
        job = Job(handle, generation: generation)
      }
      guard let job else { return }
      let status = terminal_search_fill(core, job.handle)
      if status == 0 {
        working = true
        let owner = session.queue
        Self.worker.async { [weak self, job] in
          _ = terminal_search_step(job.handle)
          owner.async { [weak self, job] in
            guard let self else { return }
            working = false
            if job.generation != generation { self.job = nil }
            schedule()
          }
        }
      } else if status == 2 {
        let accepted = terminal_search_accept(core, job.handle)
        if accepted == 3 { retryOrFinish() }
        else { finish(accepted == 5 ? .found : .missing) }
      } else if status == 3 { retryOrFinish() }
      else { finish(.resourceLimit) }
    }
    private func retryOrFinish() {
      guard var current = request else { return }
      guard current.retries < 2 else { finish(.changed); return }
      current.retries += 1
      request = current
      job = nil
      schedule()
    }
    private func finish(_ outcome: HistorySearchOutcome) {
      guard let request else { return }
      self.request = nil
      job = nil
      DispatchQueue.main.async { request.completion(outcome) }
    }
  }
  private func report(_ text: String) {
    DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
  }
  private enum Admission {
    case accepted, busy, closed
    var message: String { self == .busy ? "Input busy" : "Input closed" }
  }
  private func reserve(_ cost: Int, control: Bool = false) -> Admission {
    admission.lock()
    defer { admission.unlock() }
    let limit = 2 * 1024 * 1024 - (control ? 0 : 65_536)
    guard accepting else { return .closed }
    guard cost <= limit, admittedBytes + cost <= limit else { return .busy }
    admittedBytes += cost
    return .accepted
  }
  private func release(_ cost: Int) {
    admission.lock()
    admittedBytes -= cost
    admission.unlock()
  }
  private func stopAcceptingInput() {
    admission.lock()
    accepting = false
    admission.unlock()
  }
  private func notifyClipboardClosed() {
    guard !clipboardClosedNotified else { return }
    clipboardClosedNotified = true
    deliverClipboardCloseIfPossible()
  }
  private func deliverClipboardCloseIfPossible() {
    guard clipboardClosedNotified, !clipboardCloseDelivered, let handler = onClipboardClosed else {
      return
    }
    clipboardCloseDelivered = true
    let sessionID = clipboardSessionID
    DispatchQueue.main.async { handler(sessionID) }
  }
  private var acceptingClipboardRequests: Bool {
    admission.lock()
    defer { admission.unlock() }
    return accepting
  }
  func setClipboardClosedHandler(_ handler: @escaping @MainActor (UUID) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      onClipboardClosed = handler
      deliverClipboardCloseIfPossible()
    }
  }
  private func start() {
    guard terminal_abi_version() == 1, let handle = terminal_create(80, 24) else {
      stopAcceptingInput()
      report("Core initialization failed")
      return
    }
    core = handle
    let spec = launchSpec ?? .shell
    guard !spec.arguments.isEmpty, spec.arguments.count <= 256,
      spec.arguments.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576
    else {
      stopAcceptingInput()
      report("Invalid launch arguments")
      return
    }
    var argv = spec.arguments.map { strdup($0) } + [nil]
    defer { for value in argv { free(value) } }
    let child = argv.withUnsafeMutableBufferPointer {
      terminal_spawn_args(spec.launcher, spec.executable, spec.cwd, 80, 24, $0.baseAddress)
    }
    guard child.error == 0 else {
      stopAcceptingInput()
      report("Launch failed: \(String(cString:strerror(child.error)))")
      return
    }
    master = child.master
    pid = child.pid
    let r = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
    let w = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
    reader = r
    writer = w
    r.setEventHandler { [weak self] in self?.readAvailable() }
    w.setEventHandler { [weak self] in self?.flush() }
    let retire = DescriptorRetirement(fd: master, count: 2)
    r.setCancelHandler { retire.complete() }
    w.setCancelHandler { retire.complete() }
    r.resume()
    w.resume()
    w.suspend()
    writeSuspended = true
    let fd = child.status
    let status = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    var failure = Data()
    status.setEventHandler { [weak self, weak status] in
      var bytes = [UInt8](repeating: 0, count: 64)
      let count = Darwin.read(fd, &bytes, bytes.count)
      if count > 0 {
        failure.append(contentsOf: bytes.prefix(count))
        if failure.count >= 8 {
          let stage = failure.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
          let error = failure.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: Int32.self)
          }
          self?.report("Launch stage \(stage) failed: \(String(cString:strerror(error)))")
          status?.cancel()
        }
      } else if count == 0 {
        status?.cancel()
      } else if errno != EAGAIN && errno != EINTR {
        self?.report("Launch handshake failed")
        status?.cancel()
      }
    }
    status.setCancelHandler { Darwin.close(fd) }
    statusReader = status
    status.resume()
    let p = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    p.setEventHandler { [self] in reap() }
    process = p
    p.resume()
    reap()
    publish()
  }
  private func reap() {
    guard !reaped, pid > 0 else { return }
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result == pid {
      reaped = true
      process?.cancel()
      process = nil
      report("Process exited (status \(status)); draining output")
      if parserEnded { report("Session finished") }
    }
  }
  private func enqueue(_ event: Event) {
    events.append(event)
    scheduleOwner()
  }
  private func scheduleOwner() {
    guard !closed, !ownerScheduled, head < events.count else { return }
    ownerScheduled = true
    queue.async { [self] in
      ownerScheduled = false
      pump()
    }
  }
  private func pump() {
    guard !closed, head < events.count else { return }
    let event = events[head]
    var complete = true
    switch event {
    case .output(let bytes, let offset):
      guard writeBytes < 3 * 1024 * 1024 else {
        updateReadInterest()
        return
      }
      let used = bytes.withUnsafeBytes {
        terminal_feed(
          core, $0.bindMemory(to: UInt8.self).baseAddress! + offset, bytes.count - offset, Self.now)
      }
      queuedOutput -= used
      bytesParsed += UInt64(used)
      if used > 0 { lastParseNs = DispatchTime.now().uptimeNanoseconds }
      drainReplies()
      drainClipboardWrites()
      if offset + used < bytes.count || terminal_has_work(core) {
        events[head] = .output(bytes, offset + used)
        complete = false
      }
    case .input(let text, let key, let modifiers, let event, let cost):
      if writeEnded {
        release(cost)
        report("Input closed before delivery")
        break
      }
      // An admitted event waits for write capacity; it is never silently rejected.
      guard writeBytes + text.utf8.count + 256 <= 3 * 1024 * 1024 else { return }
      collectingPaste = key == 1
      let accepted = terminal_input(
        core, text, key, modifiers, event,
        Unmanaged.passUnretained(self).toOpaque(), Self.collect)
      collectingPaste = false
      release(cost)
      if !accepted { report("Input rejected by encoding policy") }
      if accepted && key != 2 && event != 2 && configuration.followTailOnInput { terminal_view_follow_tail(core) }
    case .keyInput(let input, let cost):
      if writeEnded {
        release(cost)
        report("Input closed before delivery")
        break
      }
      guard writeBytes + input.text.utf8.count + 256 <= 3 * 1024 * 1024 else { return }
      let accepted = terminal_input_key(
        core, input.text, input.logical, input.shifted, input.baseLayout, input.legacyText, input.key,
        input.modifiers, input.event, Unmanaged.passUnretained(self).toOpaque(), Self.collect)
      release(cost)
      if !accepted { report("Input rejected by encoding policy") }
      if accepted && input.isKeyAction && configuration.followTailOnInput {
        terminal_view_follow_tail(core)
      }
    case .raw(let bytes, let cost), .shortcut(let bytes, let cost):
      guard writeBytes + bytes.count <= 3 * 1024 * 1024 else { return }
      writeID += 1
      if !writeEnded { writes.append(WriteTransaction(id: writeID, data: bytes, kind: .ordinary)) }
      if case .shortcut = event, configuration.followTailOnInput { terminal_view_follow_tail(core) }
      release(cost)
    case .resize(let cols, let rows, let cw, let ch):
      if terminal_resize_pixels(core, UInt32(cols), UInt32(rows), UInt32(cw), UInt32(ch)) {
        columns = cols
        rowCount = rows
        cellWidthPx = cw
        cellHeightPx = ch
        var size = winsize(
          ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: UInt16(clamping: cols * cw),
          ws_ypixel: UInt16(clamping: rows * ch))
        if master >= 0 && ioctl(master, TIOCSWINSZ, &size) < 0 { report("PTY resize failed") }
      } else {
        report("Resize rejected")
      }
    case .configure(let value):
      configuration = value
      terminal_set_history_limit(core, UInt32(value.historyRows))
    case .scroll(let delta): terminal_view_scroll(core, Int64(delta))
    case .find(let query, let completion): historySearch.start(query, completion: completion)
    case .searchAdvance: historySearch.advance()
    case .clearDisplay:
      let action = terminal_clear_display(core)
      if action != 0 { historySearch.cancel() }
      if action == 2 && !writeEnded {
        writeID += 1
        writes.append(WriteTransaction(id: writeID, data: Data([12]), kind: .ordinary))
      }
    case .probe(let accepted, let completion):
      let delay = Double(DispatchTime.now().uptimeNanoseconds - accepted) / 1_000_000
      DispatchQueue.main.async { completion(delay) }
    case .clipboardDecision(let requestID, let allowed, let completion):
      let accepted = acceptingClipboardRequests && terminal_complete_clipboard_request(core, requestID)
      DispatchQueue.main.async { completion(accepted && allowed) }
    case .eof:
      parserEnded = true
      terminal_finish(core)
      report(reaped ? "Session finished" : "PTY ended; waiting for process exit")
    case .idle: break
    }
    if complete {
      events[head] = .idle
      head += 1
    }
    if head == events.count {
      events.removeAll(keepingCapacity: true)
      head = 0
    } else if head >= 32 {
      events.removeFirst(head)
      head = 0
    }
    flush()
    updateReadInterest()
    schedulePublish()
    scheduleOwner()
  }
  private func readAvailable() {
    guard !closed, !readEnded else { return }
    var slab = [UInt8](repeating: 0, count: 16_384)
    var total = 0
    while total < 65_536 && queuedOutput < 2 * 1024 * 1024 {
      let count = Darwin.read(master, &slab, slab.count)
      if count > 0 {
        enqueue(.output(Data(slab.prefix(count)), 0))
        queuedOutput += count
        bytesRead += UInt64(count)
        if firstReadNs == 0 { firstReadNs = DispatchTime.now().uptimeNanoseconds }
        total += count
      } else if count == 0 || (count < 0 && errno == EIO) {
        endRead()
        enqueue(.eof)
        break
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN {
        break
      } else {
        report("PTY read failed: \(String(cString:strerror(errno)))")
        endRead()
        enqueue(.eof)
        break
      }
    }
    updateReadInterest()
  }
  private func updateReadInterest() {
    guard !closed, !readEnded else { return }
    if queuedOutput >= 2 * 1024 * 1024 || writeBytes >= 3 * 1024 * 1024 {
      if !readSuspended {
        reader?.suspend()
        readSuspended = true
      }
    } else if readSuspended && queuedOutput < 1024 * 1024 && writeBytes < 1536 * 1024 {
      reader?.resume()
      readSuspended = false
      queue.async { [weak self] in self?.readAvailable() }
    }
  }
  private func endRead() {
    readEnded = true
    if readSuspended {
      reader?.resume()
      readSuspended = false
    }
    reader?.cancel()
    endWrite()
    master = -1
    reap()
  }
  private func endWrite() {
    stopAcceptingInput()
    notifyClipboardClosed()
    writeEnded = true
    if writeSuspended {
      writer?.resume()
      writeSuspended = false
    }
    writer?.cancel()
    writes.removeAll()
  }
  private static let collect:
    @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = {
      context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      let owner = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
      guard !owner.writeEnded else { return }
      owner.writeID += 1
      let data = Data(bytes: bytes, count: count)
      owner.writes.append(
        WriteTransaction(
          id: owner.writeID, data: data,
          kind: owner.collectingPaste
            ? .paste(bracketed: data.starts(with: Data("\u{1b}[200~".utf8))) : .ordinary))
    }
  private func drainReplies() {
    terminal_replies(core, Unmanaged.passUnretained(self).toOpaque(), Self.collect)
  }
  private static let collectClipboard:
    @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<UInt8>?, Int) -> Void = {
      context, requestID, bytes, count in
      guard let context, let bytes, count >= 0 else { return }
      let owner = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
      let data = Data(bytes: bytes, count: count)
      let request = ClipboardWriteRequest(
        sessionID: owner.clipboardSessionID, data: data,
        live: { [weak owner] in owner?.acceptingClipboardRequests == true },
        complete: { [weak owner] allowed, completion in
          guard let owner else {
            DispatchQueue.main.async { completion(false) }
            return
          }
          owner.queue.async {
            guard !owner.closed else {
              DispatchQueue.main.async { completion(false) }
              return
            }
            owner.enqueue(.clipboardDecision(requestID, allowed, completion))
          }
        })
      DispatchQueue.main.async { [weak owner, request] in
        guard let owner, owner.acceptingClipboardRequests else {
          request.resolve(false) { _ in }
          return
        }
        if let handler = owner.onClipboardWrite {
          handler(request)
        } else {
          request.resolve(false) { _ in }
        }
      }
    }
  private func drainClipboardWrites() {
    terminal_take_clipboard_requests(
      core, Unmanaged.passUnretained(self).toOpaque(), Self.collectClipboard)
  }
  private func flush() {
    guard !closed, !writeEnded else { return }
    var turn = 0
    while !writes.isEmpty && turn < 65_536 {
      if writes[0].remaining == 0 {
        writes.removeFirst()
        continue
      }
      let first = writes[0]
      let count = first.data.withUnsafeBytes {
        Darwin.write(master, $0.baseAddress! + first.offset, min(first.remaining, 65_536 - turn))
      }
      if count > 0 {
        writes[0].offset += count
        turn += count
      } else if count < 0 && errno == EINTR {
        continue
      } else if count < 0 && errno == EAGAIN {
        if writeSuspended {
          writer?.resume()
          writeSuspended = false
        }
        updateReadInterest()
        return
      } else {
        report("PTY write closed")
        endWrite()
        scheduleOwner()
        return
      }
    }
    if writes.isEmpty {
      if !writeSuspended {
        writer?.suspend()
        writeSuspended = true
      }
    } else if writeSuspended {
      writer?.resume()
      writeSuspended = false
    }
    updateReadInterest()
    scheduleOwner()
  }
  @discardableResult func input(
    _ text: String = "", key: UInt32 = 0, modifiers: UInt32 = 0, event: UInt32 = 0
  ) -> Bool {
    if key == 1 && text.utf8.count > 1_048_576 {
      report("Paste limit is 1 MiB")
      return false
    }
    let cost = text.utf8.count + 128
    let lifecycle = key == 2 || event == 2
    let control = cost <= 256 && ((event == 2 && key >= 10) || key == 2)
    let admission = reserve(cost, control: control)
    guard admission == .accepted else {
      if admission != .closed || !lifecycle { report(admission.message) }
      return false
    }
    queue.async { [self] in
      guard !closed, !writeEnded else {
        release(cost)
        if !lifecycle { report("Input closed") }
        return
      }
      enqueue(.input(text, key, modifiers, event, cost))
    }
    return true
  }
  @discardableResult func input(_ input: TerminalKeyEvent) -> Bool {
    let cost = input.text.utf8.count + 128
    let lifecycle = input.event == 2
    let control = cost <= 256 && input.event == 2
    let admission = reserve(cost, control: control)
    guard admission == .accepted else {
      if admission != .closed || !lifecycle { report(admission.message) }
      return false
    }
    queue.async { [self] in
      guard !closed, !writeEnded else {
        release(cost)
        if !lifecycle { report("Input closed") }
        return
      }
      enqueue(.keyInput(input, cost))
    }
    return true
  }
  func rawInput(_ bytes: Data) {
    _ = submitRaw(bytes, event: Event.raw)
  }
  @discardableResult func shortcut(_ text: String) -> Bool {
    submitRaw(Data(text.utf8), event: Event.shortcut)
  }
  private func submitRaw(_ bytes: Data, event: @escaping (Data, Int) -> Event) -> Bool {
    let cost = bytes.count + 128
    let admission = reserve(cost)
    guard admission == .accepted else {
      report(admission.message)
      return false
    }
    queue.async { [self] in
      guard !closed, !writeEnded else {
        release(cost)
        report("Input closed")
        return
      }
      enqueue(event(bytes, cost))
    }
    return true
  }
  func semanticProbe(_ completion: @escaping @MainActor (Double) -> Void) {
    let time = DispatchTime.now().uptimeNanoseconds
    queue.async { [self] in
      guard !closed else { return }
      enqueue(.probe(time, completion))
    }
  }
  func statistics(_ completion: @escaping @MainActor ([String: Any]) -> Void) {
    queue.async { [self] in
      let elapsed =
        lastParseNs > firstReadNs && firstReadNs > 0
        ? Double(lastParseNs - firstReadNs) / 1_000_000_000 : 0
      let stats: [String: Any] = [
        "bytes_read": bytesRead, "bytes_parsed": bytesParsed, "queued_output_bytes": queuedOutput,
        "history_bytes": terminal_history_bytes(core), "stream_seconds": elapsed,
        "parsed_mib_per_second": elapsed > 0 ? Double(bytesParsed) / 1_048_576 / elapsed : 0,
        "child_reaped": reaped, "read_ended": readEnded, "parser_ended": parserEnded,
        "child_pid": pid,
      ]
      DispatchQueue.main.async { completion(stats) }
    }
  }
  func configure(_ value: TerminalSessionConfiguration) {
    queue.async { [self] in
      guard !closed else { return }
      enqueue(.configure(value))
    }
  }
  func resize(cols: Int, rows: Int, cellWidth: Int = 8, cellHeight: Int = 16) {
    queue.async { [self] in
      guard !closed, cols >= 1, rows >= 1, cols <= 4096, rows <= 4096 else { return }
      if cols != columns || rows != rowCount || cellWidth != cellWidthPx
        || cellHeight != cellHeightPx
      {
        enqueue(.resize(cols, rows, cellWidth, cellHeight))
      }
    }
  }
  func scroll(_ amount: Int) {
    queue.async { [self] in
      guard !closed else { return }
      enqueue(.scroll(amount))
    }
  }
  func clearDisplay() {
    queue.async { [self] in
      guard !closed else { return }
      enqueue(.clearDisplay)
    }
  }
  func find(_ query: String, completion: @escaping @MainActor (HistorySearchOutcome) -> Void) {
    queue.async { [self] in
      guard !closed else {
        DispatchQueue.main.async { completion(.cancelled) }
        return
      }
      enqueue(.find(query, completion))
    }
  }
  // Urgent transport control: no semantic event or stalled write can trap it.
  func cancelPaste() {
    queue.async { [self] in
      guard !closed else { return }
      for index in head..<events.count {
        if case .input(_, let key, _, _, let cost) = events[index], key == 1 {
          release(cost)
          events[index] = .idle
        }
      }
      for index in writes.indices { _ = writes[index].cancelPaste() }
      report("Paste cancelled")
      flush()
      scheduleOwner()
    }
  }
  private func schedulePublish() {
    guard !publishScheduled else { return }
    publishScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(8)) { [self] in
      publishScheduled = false
      publish()
    }
  }
  private static let copyImage:
    @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = {
      context, bytes, count in
      guard let context, let bytes else { return }
      Unmanaged<ImageCapture>.fromOpaque(context).takeUnretainedValue().data = Data(
        bytes: bytes, count: count)
    }
  private func publish() {
    guard !closed else { return }
    let result = SnapshotBridge.readView(core, now: Self.now)
    guard var snapshot = result.snapshot else {
      if let error = result.error { report(error) }
      queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in self?.publish() }
      return
    }
    let visibleKeys = Set(snapshot.images.map { $0.key })
    imageCache = imageCache.filter { visibleKeys.contains($0.key) }
    for image in snapshot.images where imageCache[image.key] == nil {
      let capture = ImageCapture()
      let success = terminal_image_rgba(
        core, image.image, image.generation, Unmanaged.passUnretained(capture).toOpaque(),
        Self.copyImage)
      if success, let data = capture.data { imageCache[image.key] = ImagePixels(data) }
    }
    snapshot.imagePixels = imageCache
    publication.lock()
    latest = snapshot
    if deliveryScheduled {
      publication.unlock()
      return
    }
    deliveryScheduled = true
    publication.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      publication.lock()
      let snapshot = latest
      latest = nil
      deliveryScheduled = false
      publication.unlock()
      if let snapshot { onSnapshot?(snapshot) }
    }
  }
  func close() {
    stopAcceptingInput()
    queue.async { [self] in
      guard !closed else { return }
      notifyClipboardClosed()
      closed = true
      historySearch.cancel()
      for index in head..<events.count {
        switch events[index] {
        case .input(_, _, _, _, let cost), .keyInput(_, let cost), .raw(_, let cost), .shortcut(_, let cost):
          release(cost)
        case .find(_, let completion): DispatchQueue.main.async { completion(.cancelled) }
        default: break
        }
      }
      events.removeAll()
      head = 0
      if readSuspended {
        reader?.resume()
        readSuspended = false
      }
      reader?.cancel()
      endWrite()
      statusReader?.cancel()
      if let core {
        terminal_destroy(core)
        self.core = nil
      }
      reap()
      if !reaped && pid > 0 {
        kill(pid, SIGHUP)
        queue.asyncAfter(deadline: .now() + .seconds(2)) { [self] in
          reap()
          if !reaped { kill(pid, SIGKILL) }
        }
      }
    }
  }
}
private final class DescriptorRetirement: @unchecked Sendable {
  let fd: Int32
  var remaining: Int
  init(fd: Int32, count: Int) {
    self.fd = fd
    remaining = count
  }
  func complete() {
    remaining -= 1
    if remaining == 0 { Darwin.close(fd) }
  }
}

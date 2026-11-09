import Foundation

private final class ImageCapture { var data: Data? }
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
  func inheritingDirectory(_ location: String?) -> Self {
    Self(executable: executable, arguments: arguments,
         cwd: TerminalPreferences.load().launchDirectory(inheriting: location), launcher: launcher)
  }
}
final class ClipboardWriteRequest {
  let sessionID: UUID
  let data: Data
  private let live: () -> Bool
  private let completion: (Bool, @escaping @MainActor (Bool) -> Void) -> Void
  private var resolved = false
  init(sessionID: UUID, data: Data, live: @escaping () -> Bool,
       completion: @escaping (Bool, @escaping @MainActor (Bool) -> Void) -> Void) {
    self.sessionID = sessionID; self.data = data; self.live = live; self.completion = completion
  }
  var isLive: Bool { live() }
  func resolve(_ allowed: Bool, _ result: @escaping @MainActor (Bool) -> Void) {
    guard !resolved else { return }
    resolved = true
    completion(allowed, result)
  }
}

/// Immutable physical-key facts that survive queueing until the SwiftCore
/// adapter emits the negotiated terminal sequence.
struct TerminalKeyEvent {
  private static let retainedOverhead = 128
  private static let wireOverhead = 256
  let text: String
  let logical: String
  let shifted: String
  let baseLayout: String
  let legacyText: String
  let key: UInt32
  let modifiers: UInt32
  let event: UInt32
  private var isModifierOnly: Bool { (400...412).contains(key) }
  var isKeyAction: Bool { event != 2 && !isModifierOnly }
  var retainedCost: Int? {
    var total = Self.retainedOverhead
    for value in [text, logical, shifted, baseLayout, legacyText] {
      let bytes = value.utf8.count
      guard bytes <= Int.max - total else { return nil }
      total += bytes
    }
    return total
  }
  var maximumWireBytes: Int? {
    let (expandedText, overflow) = text.utf8.count.multipliedReportingOverflow(by: 4)
    guard !overflow else { return nil }
    let payload = max(expandedText, legacyText.utf8.count)
    let (total, overheadOverflow) = payload.addingReportingOverflow(Self.wireOverhead)
    return overheadOverflow ? nil : total
  }
  /// Numeric keypad legacy input is AppKit's committed text. Other keys use
  /// their unmodified current-layout key as the negotiated primary value.
  var adapterText: String { (300...317).contains(key) ? text : logical }
  var shiftedScalar: UInt32 {
    shifted.unicodeScalars.count == 1 ? shifted.unicodeScalars.first!.value : 0
  }
  var baseLayoutScalar: UInt32 {
    baseLayout.unicodeScalars.count == 1 ? baseLayout.unicodeScalars.first!.value : 0
  }
}
// The PTY and Rust handle are confined to this queue. Main receives immutable decoded values.
final class Session: @unchecked Sendable {
  typealias SelectionCompletion = @MainActor (Result<String?, TerminalSelectionFailure>) -> Void
  typealias LinkCompletion = @MainActor (Result<URL, TerminalSelectionFailure>) -> Void
  private final class SelectionDelivery {
    let completion: SelectionCompletion
    let cost: Int
    let retainsCopyResult: Bool
    private let lock = NSLock()
    private var result: Result<String?, TerminalSelectionFailure>
    private var delivering = false
    init(completion: @escaping SelectionCompletion, cost: Int, retainsCopyResult: Bool,
         result: Result<String?, TerminalSelectionFailure>) {
      self.completion = completion; self.cost = cost; self.retainsCopyResult = retainsCopyResult
      self.result = result
    }
    func cancel() {
      lock.lock()
      if !delivering { result = .failure(.cancelled) }
      lock.unlock()
    }
    func takeForDelivery() -> Result<String?, TerminalSelectionFailure> {
      lock.lock()
      delivering = true
      let resolved = result
      lock.unlock()
      return resolved
    }
  }
  private final class LinkDelivery {
    let completion: LinkCompletion
    let cost: Int
    private let lock = NSLock()
    private var result: Result<URL, TerminalSelectionFailure>
    private var delivering = false
    init(completion: @escaping LinkCompletion, cost: Int,
         result: Result<URL, TerminalSelectionFailure>) {
      self.completion = completion; self.cost = cost; self.result = result
    }
    func cancel() {
      lock.lock()
      if !delivering { result = .failure(.cancelled) }
      lock.unlock()
    }
    func takeForDelivery() -> Result<URL, TerminalSelectionFailure> {
      lock.lock()
      delivering = true
      let resolved = result
      lock.unlock()
      return resolved
    }
  }
  private struct StreamStatistics {
    var readCallbacks = 0, readCalls = 0, outputEvents = 0, pumpSchedules = 0, pumpTurns = 0, feedCalls = 0, queueHighWater = 0, suspends = 0, resumes = 0, publishCalls = 0
    var feedBytes: UInt64 = 0, readNanoseconds: UInt64 = 0, feedNanoseconds: UInt64 = 0, snapshotNanoseconds: UInt64 = 0, pumpNanoseconds: UInt64 = 0
    var queuedBytesHighWater = 0
    mutating func observeEventQueue(_ count: Int) { queueHighWater = max(queueHighWater, count) }
    mutating func observeQueuedBytes(_ count: Int) { queuedBytesHighWater = max(queuedBytesHighWater, count) }
  }
  let queue = DispatchQueue(label: "no.helgesverre.terminal.owner", qos: .userInteractive)
  private enum Event {
    case output(Data, Int)
    case input(String, UInt32, UInt32, UInt32, Int)
    case keyInput(TerminalKeyEvent, Int)
    case raw(Data, Int)
    case shortcut(Data, Int)
    case resize(Int, Int, Int, Int, Bool)
    // A selection operation remains at the FIFO head until the core's bounded
    // builder resolves it. `began` prevents a resumed owner turn from
    // reinterpreting a hit against a newer document.
    case selection(TerminalSelectionAction, SelectionCompletion?, Int, Bool, Bool)
    // A link validator owns only immutable displayed-row proof plus the
    // already-recognized URL. It remains FIFO head until Core accepts or
    // rejects the proof; Session never reparses policy or terminal text.
    case link(TerminalPresentedContent, URL, LinkCompletion, Int, Bool)
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
  // Owner-queue scratch; output events always receive their own immutable copy.
  private var readSlab = [UInt8](repeating: 0, count: 16_384)
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
  private var resizePending = false
  private var queuedResizeCount = 0
  private var selectionPending = false
  private var linkPending = false
  private var configuration = TerminalSessionConfiguration()
  private var imageCache: [ImageKey: ImagePixels] = [:]
  private var publishScheduled = false
  private var streamStatistics: StreamStatistics?
  private let admission = NSLock()
  private var admittedBytes = 0
  // A copied String can be 16 MiB. One result may wait for the main actor;
  // further copy requests receive bounded backpressure instead of retaining
  // an unbounded set of immutable completion payloads.
  private var outstandingSelectionCopyCompletions = 0
  private var selectionDeliveries: [SelectionDelivery] = []
  private var linkDeliveries: [LinkDelivery] = []
  // EOF closes the PTY writer but leaves the retained terminal screen
  // owner-validatable. Only explicit Session.close shuts that read-only
  // interaction surface and cancels already-computed Main callbacks.
  private var accepting = true
  private var interactionClosed = false
  private let publication = NSLock()
  private var latest: TerminalSnapshot?
  private var deliveryScheduled = false
  @MainActor private var deliveredDirectory: String?
  @MainActor var siblingLaunch: LaunchSpec { .shell.inheritingDirectory(deliveredDirectory) }
  private lazy var historySearch = HistorySearch(session: self)
  private let clipboardSessionID = UUID()
  var onSnapshot: (@MainActor (TerminalSnapshot) -> Void)?
  var onStatus: (@MainActor (String) -> Void)?
  var onClipboardWrite: (@MainActor (ClipboardWriteRequest) -> Void)?
  private var onClipboardClosed: (@MainActor (UUID) -> Void)?
  init(launch: LaunchSpec? = nil) {
    launchSpec = launch
    if CommandLine.arguments.prefix(while: { $0 != "--execute" }).contains("--session-statistics-file") {
      streamStatistics = StreamStatistics()
    }
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
  private static let selectionBaseCost = 256
  private static let selectionPresentationCost = 128
  private static let selectionProofRowCost = MemoryLayout<TerminalSelectionPresentation.Row>.stride
  private static let linkBaseCost = 256
  private static func selectionCost(_ action: TerminalSelectionAction) -> Int? {
    func hitCost(_ hit: TerminalSelectionHit) -> Int? {
      let (proofBytes, proofOverflow) = hit.presentation.rows.count.multipliedReportingOverflow(
        by: selectionProofRowCost)
      guard !proofOverflow else { return nil }
      let (presentationBytes, presentationOverflow) = proofBytes.addingReportingOverflow(
        selectionPresentationCost)
      return presentationOverflow ? nil : presentationBytes
    }
    let hits: [TerminalSelectionHit]
    switch action {
    case .begin(let hit, _), .extend(let hit): hits = [hit]
    case .range(let start, let end, _): hits = [start, end]
    case .commit, .clear, .copy, .wordProfile: hits = []
    }
    var cost = selectionBaseCost
    for hit in hits {
      guard let costForHit = hitCost(hit) else { return nil }
      let (next, overflow) = cost.addingReportingOverflow(costForHit)
      guard !overflow else { return nil }
      cost = next
    }
    return cost
  }
  private static func linkCost(content: TerminalPresentedContent, target: URL) -> Int? {
    guard let proofBytes = content.retainedByteCount else { return nil }
    let (withProof, proofOverflow) = linkBaseCost.addingReportingOverflow(proofBytes)
    let (cost, urlOverflow) = withProof.addingReportingOverflow(target.absoluteString.utf8.count)
    return proofOverflow || urlOverflow ? nil : cost
  }
  private static func selectionIsControl(_ action: TerminalSelectionAction) -> Bool {
    if case .clear = action { return true }
    if case .commit = action { return true }
    if case .wordProfile = action { return true }
    return false
  }
  private func reserve(_ cost: Int, control: Bool = false) -> Admission {
    admission.lock()
    defer { admission.unlock() }
    let limit = 2 * 1024 * 1024 - (control ? 0 : 65_536)
    guard accepting, !interactionClosed else { return .closed }
    guard cost <= limit, admittedBytes + cost <= limit else { return .busy }
    admittedBytes += cost
    return .accepted
  }
  private func reserveInteraction(_ cost: Int, control: Bool = false) -> Admission {
    admission.lock()
    defer { admission.unlock() }
    let limit = 2 * 1024 * 1024 - (control ? 0 : 65_536)
    guard !interactionClosed else { return .closed }
    guard cost <= limit, admittedBytes + cost <= limit else { return .busy }
    admittedBytes += cost
    return .accepted
  }
  private func reserveSelection(_ cost: Int, control: Bool, retainsCopyResult: Bool) -> Admission {
    admission.lock()
    defer { admission.unlock() }
    let limit = 2 * 1024 * 1024 - (control ? 0 : 65_536)
    guard !interactionClosed else { return .closed }
    guard !retainsCopyResult || outstandingSelectionCopyCompletions == 0 else { return .busy }
    guard cost <= limit, admittedBytes + cost <= limit else { return .busy }
    admittedBytes += cost
    if retainsCopyResult { outstandingSelectionCopyCompletions += 1 }
    return .accepted
  }
  private func release(_ cost: Int) {
    admission.lock()
    admittedBytes -= cost
    admission.unlock()
  }
  private func stopAcceptingInput() {
    admission.lock(); accepting = false; admission.unlock()
  }
  private func closeInteractions() {
    admission.lock()
    accepting = false
    interactionClosed = true
    admission.unlock()
  }
  private func finishSelection(cost: Int, completion: SelectionCompletion?, retainsCopyResult: Bool,
                               result: Result<String?, TerminalSelectionFailure>) {
    selectionPending = false
    guard let completion else {
      precondition(!retainsCopyResult)
      release(cost)
      return
    }
    let delivery = SelectionDelivery(completion: completion, cost: cost,
                                     retainsCopyResult: retainsCopyResult, result: result)
    selectionDeliveries.append(delivery)
    DispatchQueue.main.async { [self, delivery] in
      admission.lock()
      let cancelled = interactionClosed
      admission.unlock()
      if cancelled { delivery.cancel() }
      delivery.completion(delivery.takeForDelivery())
      release(delivery.cost)
      if delivery.retainsCopyResult {
        admission.lock()
        outstandingSelectionCopyCompletions -= 1
        admission.unlock()
      }
      queue.async { [self, delivery] in
        selectionDeliveries.removeAll { $0 === delivery }
      }
    }
  }
  private func finishLink(cost: Int, completion: @escaping LinkCompletion,
                          result: Result<URL, TerminalSelectionFailure>) {
    linkPending = false
    let delivery = LinkDelivery(completion: completion, cost: cost, result: result)
    linkDeliveries.append(delivery)
    DispatchQueue.main.async { [self, delivery] in
      admission.lock()
      let cancelled = interactionClosed
      admission.unlock()
      if cancelled { delivery.cancel() }
      delivery.completion(delivery.takeForDelivery())
      release(delivery.cost)
      queue.async { [self, delivery] in
        linkDeliveries.removeAll { $0 === delivery }
      }
    }
  }
  private func clearSelectionForAcceptedInput(_ core: OpaquePointer) {
    // Input has reached the core only after every earlier selection event has
    // settled. Clear is an immediate owner-side action; it must never begin a
    // second resumable operation without a matching FIFO event to advance it.
    if case .completed = TerminalSelectionBridge.begin(core: core, action: .clear) {}
  }
  private func notifyClipboardClosed() {
    guard !clipboardClosedNotified else { return }
    clipboardClosedNotified = true
    deliverClipboardCloseIfPossible()
  }
  private func deliverClipboardCloseIfPossible() {
    guard clipboardClosedNotified, !clipboardCloseDelivered, let handler = onClipboardClosed else { return }
    clipboardCloseDelivered = true
    let id = clipboardSessionID
    DispatchQueue.main.async { handler(id) }
  }
  private var acceptingClipboardRequests: Bool {
    admission.lock(); defer { admission.unlock() }
    return accepting && !interactionClosed
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
    if case .output = event { streamStatistics?.outputEvents += 1 }
    events.append(event)
    streamStatistics?.observeEventQueue(events.count - head)
    scheduleOwner()
  }
  private func scheduleOwner() {
    guard !closed, !ownerScheduled, head < events.count else { return }
    ownerScheduled = true
    streamStatistics?.pumpSchedules += 1
    queue.async { [self] in
      ownerScheduled = false
      pump()
    }
  }
  private func pump() {
    guard !closed, head < events.count else { return }
    let started = streamStatistics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
    defer {
      if streamStatistics != nil { streamStatistics!.pumpNanoseconds &+= DispatchTime.now().uptimeNanoseconds - started }
    }
    let event = events[head]
    streamStatistics?.pumpTurns += 1
    var complete = true
    var publishNeeded = true
    switch event {
    case .output(let bytes, let offset):
      guard writeBytes < 3 * 1024 * 1024 else {
        updateReadInterest()
        return
      }
      let feedStarted = streamStatistics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
      let used = bytes.withUnsafeBytes {
        terminal_feed(
          core, $0.bindMemory(to: UInt8.self).baseAddress! + offset, bytes.count - offset, Self.now)
      }
      if streamStatistics != nil {
        streamStatistics!.feedCalls += 1
        streamStatistics!.feedBytes &+= UInt64(used)
        streamStatistics!.feedNanoseconds &+= DispatchTime.now().uptimeNanoseconds - feedStarted
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
      let writesBefore = writeID
      let accepted = terminal_input(
        core, text, key, modifiers, event, Unmanaged.passUnretained(self).toOpaque(), Self.collect)
      collectingPaste = false
      release(cost)
      if !accepted { report("Input rejected by encoding policy") }
      // The C ABI returns true when an input request was understood even if no
      // bytes were encoded (disabled focus reporting, a modifier, or an
      // unknown physical key). Only bytes accepted for PTY delivery are a
      // semantic edit that retires the owner-held selection.
      if accepted && writeID != writesBefore && key != 2 && event != 2, let core {
        clearSelectionForAcceptedInput(core)
      }
      if accepted && key != 2 && event != 2 && configuration.followTailOnInput { terminal_view_follow_tail(core) }
    case .keyInput(let input, let cost):
      if writeEnded {
        release(cost)
        report("Input closed before delivery")
        break
      }
      guard let wireBytes = input.maximumWireBytes, wireBytes <= 3 * 1024 * 1024 else {
        release(cost)
        report("Key input exceeds write limit")
        break
      }
      guard writeBytes <= 3 * 1024 * 1024 - wireBytes else { return }
      let writesBefore = writeID
      let accepted = terminal_input_with_metadata(
        core, input.adapterText, input.key, input.modifiers, input.event,
        input.text, input.legacyText, input.shiftedScalar, input.baseLayoutScalar,
        Unmanaged.passUnretained(self).toOpaque(), Self.collect)
      release(cost)
      if !accepted { report("Input rejected by encoding policy") }
      if accepted && writeID != writesBefore && input.isKeyAction, let core {
        clearSelectionForAcceptedInput(core)
      }
      if accepted && input.isKeyAction && configuration.followTailOnInput {
        terminal_view_follow_tail(core)
      }
    case .clipboardDecision(let requestID, let allowed, let completion):
      let accepted = acceptingClipboardRequests && terminal_complete_clipboard_request(core, requestID)
      DispatchQueue.main.async { completion(accepted && allowed) }
    case .raw(let bytes, let cost):
      guard writeBytes + bytes.count <= 3 * 1024 * 1024 else { return }
      writeID += 1
      if !writeEnded { writes.append(WriteTransaction(id: writeID, data: bytes, kind: .ordinary)) }
      release(cost)
    case .shortcut(let bytes, let cost):
      guard writeBytes + bytes.count <= 3 * 1024 * 1024 else { return }
      writeID += 1
      if !writeEnded { writes.append(WriteTransaction(id: writeID, data: bytes, kind: .ordinary)) }
      if !bytes.isEmpty, let core { clearSelectionForAcceptedInput(core) }
      if configuration.followTailOnInput { terminal_view_follow_tail(core) }
      release(cost)
    case .resize(let cols, let rows, let cw, let ch, let began):
      if !began && cols == columns && rows == rowCount && cw == cellWidthPx && ch == cellHeightPx {
        precondition(queuedResizeCount > 0)
        queuedResizeCount -= 1
        publishNeeded = false
        break
      }
      guard let core else {
        precondition(queuedResizeCount > 0)
        queuedResizeCount -= 1
        report("Resize rejected: terminal is unavailable")
        break
      }
      let progress = began
        ? TerminalResizeBridge.advance(core: core)
        : TerminalResizeBridge.begin(core: core, columns: cols, rows: rows, cellWidth: cw, cellHeight: ch)
      switch progress {
      case .pending:
        resizePending = true
        events[head] = .resize(cols, rows, cw, ch, true)
        complete = false
        // A builder step leaves the published terminal untouched. Do not make
        // frame cadence depend on how many bounded steps a reflow needs.
        publishNeeded = false
      case .committed(let geometry):
        resizePending = false
        precondition(queuedResizeCount > 0)
        queuedResizeCount -= 1
        columns = geometry.columns
        rowCount = geometry.rows
        cellWidthPx = geometry.cellWidth
        cellHeightPx = geometry.cellHeight
        var size = winsize(
          ws_row: UInt16(geometry.rows), ws_col: UInt16(geometry.columns),
          ws_xpixel: UInt16(clamping: geometry.columns * geometry.cellWidth),
          ws_ypixel: UInt16(clamping: geometry.rows * geometry.cellHeight))
        if master >= 0 && ioctl(master, TIOCSWINSZ, &size) < 0 { report("PTY resize failed") }
      case .rejected(let reason, _):
        resizePending = false
        precondition(queuedResizeCount > 0)
        queuedResizeCount -= 1
        report("Resize rejected: \(reason)")
      }
    case .selection(let action, let completion, let cost, let began, let retainsCopyResult):
      guard let core else {
        finishSelection(cost: cost, completion: completion, retainsCopyResult: retainsCopyResult,
                        result: .failure(.cancelled))
        break
      }
      let progress = began
        ? TerminalSelectionBridge.advance(core: core)
        : TerminalSelectionBridge.begin(core: core, action: action)
      switch progress {
      case .pending:
        selectionPending = true
        events[head] = .selection(action, completion, cost, true, retainsCopyResult)
        complete = false
        // The snapshot remains the last coherent selection while the bridge
        // captures rows or assembles a copy in bounded owner turns.
        publishNeeded = false
      case .completed(let copiedText):
        finishSelection(cost: cost, completion: completion, retainsCopyResult: retainsCopyResult,
                        result: .success(copiedText))
      case .rejected(let failure):
        finishSelection(cost: cost, completion: completion, retainsCopyResult: retainsCopyResult,
                        result: .failure(failure))
      }
    case .link(let content, let target, let completion, let cost, let began):
      guard let core else {
        finishLink(cost: cost, completion: completion, result: .failure(.cancelled))
        break
      }
      let progress = began
        ? TerminalPresentedContentBridge.advance(core: core)
        : TerminalPresentedContentBridge.begin(core: core, content: content)
      switch progress {
      case .pending:
        linkPending = true
        events[head] = .link(content, target, completion, cost, true)
        complete = false
        // Validation is metadata-only but may span bounded owner turns. The
        // previously coherent snapshot remains the only published view.
        publishNeeded = false
      case .accepted:
        finishLink(cost: cost, completion: completion, result: .success(target))
      case .rejected(let failure):
        finishLink(cost: cost, completion: completion, result: .failure(failure))
      }
    case .configure(let value):
      configuration = value
      terminal_set_history_limit(core, UInt32(value.historyRows))
      // Configuration is semantic FIFO state: a later word gesture observes
      // this profile, while an already captured gesture keeps its own value.
      if let core {
        _ = TerminalSelectionBridge.begin(core: core, action: .wordProfile(value.selectionWordProfile))
      }
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
    if publishNeeded { schedulePublish() }
    scheduleOwner()
  }
  private func readAvailable() {
    guard !closed, !readEnded else { return }
    streamStatistics?.readCallbacks += 1
    let started = streamStatistics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
    var total = 0
    while total < 65_536 && queuedOutput < 2 * 1024 * 1024 {
      streamStatistics?.readCalls += 1
      let (count, output) = readSlab.withUnsafeMutableBytes { buffer -> (Int, Data?) in
        let count = Darwin.read(master, buffer.baseAddress!, buffer.count)
        return (count, count > 0 ? Data(bytes: buffer.baseAddress!, count: count) : nil)
      }
      if let output {
        enqueue(.output(output, 0))
        queuedOutput += count
        streamStatistics?.observeQueuedBytes(queuedOutput)
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
    if streamStatistics != nil { streamStatistics!.readNanoseconds &+= DispatchTime.now().uptimeNanoseconds - started }
    updateReadInterest()
  }
  private func updateReadInterest() {
    guard !closed, !readEnded else { return }
    if queuedOutput >= 2 * 1024 * 1024 || writeBytes >= 3 * 1024 * 1024 {
      if !readSuspended {
        reader?.suspend()
        readSuspended = true
        streamStatistics?.suspends += 1
      }
    } else if readSuspended && queuedOutput < 1024 * 1024 && writeBytes < 1536 * 1024 {
      reader?.resume()
      readSuspended = false
      streamStatistics?.resumes += 1
      queue.async { [weak self] in self?.readAvailable() }
    }
  }
  private func endRead() {
    readEnded = true
    if readSuspended {
      reader?.resume()
      readSuspended = false
      streamStatistics?.resumes += 1
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
  private static let collectClipboard: ClipboardCallback = { context, requestID, bytes, count in
    guard let context, let bytes, count >= 0 else { return }
    let owner = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
    let request = ClipboardWriteRequest(
      sessionID: owner.clipboardSessionID, data: Data(bytes: bytes, count: count),
      live: { [weak owner] in owner?.acceptingClipboardRequests == true },
      completion: { [weak owner] allowed, completion in
        guard let owner else { DispatchQueue.main.async { completion(false) }; return }
        owner.queue.async {
          guard !owner.closed else { DispatchQueue.main.async { completion(false) }; return }
          owner.enqueue(.clipboardDecision(requestID, allowed, completion))
        }
      })
    DispatchQueue.main.async { [weak owner, request] in
      guard let owner, owner.acceptingClipboardRequests else { request.resolve(false) { _ in }; return }
      if let handler = owner.onClipboardWrite { handler(request) }
      else { request.resolve(false) { _ in } }
    }
  }
  private func drainClipboardWrites() { terminal_take_clipboard_requests(core, Unmanaged.passUnretained(self).toOpaque(), Self.collectClipboard) }
  func setClipboardClosedHandler(_ handler: @escaping @MainActor (UUID) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      onClipboardClosed = handler
      deliverClipboardCloseIfPossible()
    }
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
    guard let cost = input.retainedCost else {
      report("Key input metadata is too large")
      return false
    }
    guard let wireBytes = input.maximumWireBytes, wireBytes <= 3 * 1024 * 1024 else {
      report("Key input exceeds write limit")
      return false
    }
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
      var stats: [String: Any] = [
        "bytes_read": bytesRead, "bytes_parsed": bytesParsed, "queued_output_bytes": queuedOutput,
        "history_bytes": terminal_history_bytes(core), "stream_seconds": elapsed,
        "parsed_mib_per_second": elapsed > 0 ? Double(bytesParsed) / 1_048_576 / elapsed : 0,
        "child_reaped": reaped, "read_ended": readEnded, "parser_ended": parserEnded,
        "child_pid": pid,
      ]
      if let stream = streamStatistics {
        stats["stream_diagnostic"] = [
          "read_callbacks": stream.readCallbacks, "read_calls": stream.readCalls,
          "output_events": stream.outputEvents, "pump_schedules": stream.pumpSchedules,
          "pump_turns": stream.pumpTurns, "feed_calls": stream.feedCalls,
          "feed_bytes": stream.feedBytes, "event_queue_high_water": stream.queueHighWater,
          "queued_output_bytes_high_water": stream.queuedBytesHighWater,
          "read_suspends": stream.suspends, "read_resumes": stream.resumes,
          "publish_calls": stream.publishCalls,
          "read_nanoseconds": stream.readNanoseconds, "feed_nanoseconds": stream.feedNanoseconds,
          "snapshot_nanoseconds": stream.snapshotNanoseconds, "pump_nanoseconds": stream.pumpNanoseconds,
        ] as [String: Any]
      }
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
        || cellHeight != cellHeightPx || queuedResizeCount > 0
      {
        queuedResizeCount += 1
        enqueue(.resize(cols, rows, cellWidth, cellHeight, false))
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
  /// Submits an immutable, presentation-proven selection gesture. The host
  /// never reads cells or derives copied text; success carries the core-built
  /// copy (where `nil` means a non-copy selection action).
  @discardableResult func selection(
    _ action: TerminalSelectionAction,
    completion: (@MainActor (Result<String?, TerminalSelectionFailure>) -> Void)? = nil
  ) -> Bool {
    guard let cost = Self.selectionCost(action) else {
      report("Selection request exceeds queue limit")
      return false
    }
    let retainsCopyResult: Bool = {
      if case .copy = action { return completion != nil }
      return false
    }()
    let admission = reserveSelection(cost, control: Self.selectionIsControl(action),
                                     retainsCopyResult: retainsCopyResult)
    guard admission == .accepted else {
      report(admission.message)
      return false
    }
    queue.async { [self] in
      guard !closed else {
        finishSelection(cost: cost, completion: completion, retainsCopyResult: retainsCopyResult,
                        result: .failure(.cancelled))
        return
      }
      enqueue(.selection(action, completion, cost, false, retainsCopyResult))
    }
    return true
  }
  /// Validates a recognized URL against the immutable rows that were actually
  /// presented to the user. URL parsing and policy stay in the projection;
  /// this boundary only proves that those rows still describe the same content
  /// before returning the exact captured URL to Canvas.
  @discardableResult func activateLink(
    _ activation: VisibleLinkProjection.Activation,
    completion: @escaping LinkCompletion
  ) -> Bool {
    guard let cost = Self.linkCost(content: activation.content, target: activation.target) else {
      report("Link activation exceeds queue limit")
      return false
    }
    let admission = reserveInteraction(cost)
    guard admission == .accepted else {
      report(admission.message)
      return false
    }
    queue.async { [self] in
      guard !closed else {
        finishLink(cost: cost, completion: completion, result: .failure(.cancelled))
        return
      }
      enqueue(.link(activation.content, activation.target, completion, cost, false))
    }
    return true
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
    streamStatistics?.publishCalls += 1
    let snapshotStarted = streamStatistics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
    let result = SnapshotBridge.readView(core, now: Self.now)
    if streamStatistics != nil { streamStatistics!.snapshotNanoseconds &+= DispatchTime.now().uptimeNanoseconds - snapshotStarted }
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
      if let snapshot {
        deliveredDirectory = snapshot.cwd
        onSnapshot?(snapshot)
      }
    }
  }
  func close() {
    closeInteractions()
    queue.async { [self] in
      guard !closed else { return }
      notifyClipboardClosed()
      closed = true
      historySearch.cancel()
      // A completed copy can still be awaiting its main-actor callback. Close
      // changes every not-yet-delivered result to cancellation before teardown.
      for delivery in selectionDeliveries { delivery.cancel() }
      for delivery in linkDeliveries { delivery.cancel() }
      if resizePending, let core {
        TerminalResizeBridge.cancel(core: core)
        resizePending = false
      }
      if selectionPending, let core {
        TerminalSelectionBridge.cancel(core: core)
        selectionPending = false
      }
      if linkPending, let core {
        TerminalPresentedContentBridge.cancel(core: core)
        linkPending = false
      }
      for index in head..<events.count {
        switch events[index] {
        case .input(_, _, _, _, let cost), .keyInput(_, let cost), .raw(_, let cost), .shortcut(_, let cost): release(cost)
        case .find(_, let completion): DispatchQueue.main.async { completion(.cancelled) }
        case .clipboardDecision(_, _, let completion): DispatchQueue.main.async { completion(false) }
        case .selection(_, let completion, let cost, _, let retainsCopyResult):
          finishSelection(cost: cost, completion: completion, retainsCopyResult: retainsCopyResult,
                          result: .failure(.cancelled))
        case .link(_, _, let completion, let cost, _):
          finishLink(cost: cost, completion: completion, result: .failure(.cancelled))
        default: break
        }
      }
      events.removeAll()
      head = 0
      queuedResizeCount = 0
      if readSuspended {
        reader?.resume()
        readSuspended = false
        streamStatistics?.resumes += 1
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

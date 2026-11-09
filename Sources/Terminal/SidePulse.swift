import Darwin
import Foundation

/// All device I/O and state are confined to SidePulse's utility queue.
/// Fixed programs only: child output can report activity but cannot supply DSL or paths.
final class SidePulseEngine {
  struct Entry {
    let activity: TerminalActivity
    let expires: TimeInterval?
    let running: Bool
  }
  static let programs: [TerminalActivity: String] = [
    .idle: "off\n",
    .working:
      "brightness 64\noff\n#00e5ff #004050 #001015 #000000 #000000 #000000 #000000 #000000\nroll 1.6s linear\nrepeat\n",
    .succeeded: "brightness 64\n#30d158 320ms cosine\n",
    .failed: "brightness 64\noff\n#ff453a 1.6s pulse\nrepeat\n",
    .attention: "brightness 64\noff\n#ff9f0a 1.6s pulse\nrepeat\n",
  ]
  private(set) var enabled = false
  private(set) var status = "Disabled"
  private var entries: [UUID: Entry] = [:]
  private var lastTarget: URL?
  private var lastProgram: String?
  private var lastWrite: TimeInterval = 0
  private var testUntil: TimeInterval = 0
  private let discover: () -> [URL]
  private let write: (URL, String) throws -> Void

  init(
    discover: @escaping () -> [URL] = SidePulseDevice.discover,
    write: @escaping (URL, String) throws -> Void = SidePulseDevice.write
  ) {
    self.discover = discover
    self.write = write
  }
  func configure(enabled: Bool, now: TimeInterval) {
    guard self.enabled != enabled else { return }
    if !enabled {
      // Release only a still-mounted, unambiguous device we actually controlled.
      if let lastTarget, discover() == [lastTarget] {
        do { try write(lastTarget, "off\n") } catch {
          NSLog("SidePulse release failed: %@", error.localizedDescription)
        }
      }
      lastTarget = nil
      lastProgram = nil
      testUntil = 0
      status = "Disabled"
    }
    self.enabled = enabled
    if enabled { tick(now: now) }
  }
  func record(_ activity: TerminalActivity, session: UUID, now: TimeInterval, running: Bool = false)
  {
    // Keep logical state while disabled, so enabling mid-command is accurate.
    entries[session] = Entry(
      activity: activity,
      expires: activity == .working || activity == .idle ? nil : now + 6,
      running: running || activity == .working)
  }
  func remove(session: UUID) { entries.removeValue(forKey: session) }
  func test(now: TimeInterval) {
    guard enabled else { return }
    testUntil = now + 3
    tick(now: now)
  }
  func tick(now: TimeInterval) {
    guard enabled else { return }
    entries = entries.mapValues { entry in
      guard let expires = entry.expires, expires <= now else { return entry }
      return Entry(activity: entry.running ? .working : .idle, expires: nil, running: entry.running)
    }
    let targets = discover()
    guard targets.count == 1, let target = targets.first else {
      status =
        targets.isEmpty
        ? "SidePulse Pro not connected"
        : "Multiple SidePulse Pro devices connected; connect only one."
      lastTarget = nil
      lastProgram = nil
      return
    }
    let priority: [TerminalActivity] = [.failed, .attention, .working, .succeeded]
    let activity =
      priority.first { state in entries.values.contains { $0.activity == state } } ?? .idle
    let program =
      testUntil > now
      ? "brightness 64\n#30d158 800ms pulse\noff\nrepeat\n"
      : Self.programs[activity]!
    // A real I/O write once a minute also keeps older Pro SD readers active.
    // Never reset the animation for every output chunk or display frame.
    if lastTarget == target, lastProgram == program, now - lastWrite < 60 { return }
    do {
      try write(target, program)
      lastTarget = target
      lastProgram = program
      lastWrite = now
      status = "Connected: \(target.deletingLastPathComponent().lastPathComponent)"
    } catch {
      lastProgram = nil  // Retry at the next bounded refresh, including read-only errors.
      status = "SidePulse Pro write failed: \(error.localizedDescription)"
    }
  }
}

// Mounted volumes only. Never recurse, create a mount directory/file, replace a
// file by rename, or access raw disks. Reject symlinks and ambiguous discovery.
enum SidePulseDevice {
  static func isProName(_ name: String) -> Bool {
    let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")
    return normalized.range(of: "^sidepulse(pro)?[0-9]*$", options: .regularExpression) != nil
  }
  static func discover() -> [URL] {
    let volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: nil,
        options: [.skipHiddenVolumes]) ?? []
    return volumes.filter {
      $0.deletingLastPathComponent().path == "/Volumes" && isProName($0.lastPathComponent)
    }
    .map { $0.appendingPathComponent("LEDS.LED") }.sorted { $0.path < $1.path }
  }
  static func write(_ target: URL, program: String) throws {
    let data = Data(program.utf8)
    guard !data.isEmpty, data.count <= 512,
      program.split(separator: "\n", omittingEmptySubsequences: false).count <= 20
    else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    // No O_CREAT: a disappearing drive must never create a file on the host.
    let fd = open(target.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw POSIXError(.EINVAL)
    }
    guard ftruncate(fd, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += count
      }
    }
    _ = fsync(fd)  // Best effort, matching the vendor writer.
  }
}

final class SidePulse {
  static let shared = SidePulse()
  private let queue = DispatchQueue(label: "no.helgesverre.terminal.sidepulse", qos: .utility)
  private let engine = SidePulseEngine()
  private var timer: DispatchSourceTimer?
  private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
  func configure(enabled: Bool) {
    queue.async { [self] in
      engine.configure(enabled: enabled, now: Self.now)
      timer?.cancel()
      timer = nil
      guard enabled else { return }
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
      source.setEventHandler { [weak self] in self?.engine.tick(now: Self.now) }
      timer = source
      source.resume()
    }
  }
  func record(_ activity: TerminalActivity, session: UUID, running: Bool) {
    queue.async { [self] in
      engine.record(activity, session: session, now: Self.now, running: running)
    }
  }
  func remove(session: UUID) { queue.async { [self] in engine.remove(session: session) } }
  func status(_ completion: @escaping @MainActor (String) -> Void) {
    queue.async { [self] in
      let value = engine.status
      DispatchQueue.main.async { completion(value) }
    }
  }
  func test() { queue.async { [self] in engine.test(now: Self.now) } }
}

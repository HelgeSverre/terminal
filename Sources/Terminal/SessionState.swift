import Foundation
import CryptoKit
import Darwin

enum StateLocation {
  static func directory(arguments: [String], bundle: URL, home: URL) -> URL? {
    let args = Array(arguments.dropFirst().prefix { $0 != "--execute" })
    if let index = args.firstIndex(of: "--state-directory") {
      guard args.indices.contains(index + 1), !args[index + 1].isEmpty,
        !args[index + 1].hasPrefix("--") else { return nil }
      return URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }
    guard arguments.dropFirst().isEmpty else { return nil }
    let path = bundle.standardizedFileURL.path
    let roots = ["/Applications/", home.appendingPathComponent("Applications").path + "/"]
    guard roots.contains(where: { path.hasPrefix($0) }) else { return nil }
    return home.appendingPathComponent("Library/Application Support/no.helgesverre.terminal/Sessions", isDirectory: true)
  }
}

/// One run owns the descriptor for its entire lifetime. All file mutations
/// after launch run on `queue`; clean termination drains that queue first.
final class SessionStateStore: @unchecked Sendable {
  struct Running: Codable { var pid: Int32; var started: Date; var restoring: Bool }
  struct ScrollbackHeader: Codable {
    var version = 1
    var rows: Int
    var bytes: Int
    var capturedAt: Date
    var checksum: String
  }
  struct Scrollback {
    var text: String
    var capturedAt: Date
    var unavailable: Bool
  }
  let directory: URL
  let restored: SessionLayout?
  private let descriptor: Int32
  private let queue = DispatchQueue(label: "terminal.recovery.files", qos: .utility)
  private let stopLock = NSLock()
  private var stopping = false
  private var isStopping: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopping }
  private var lastGoodLayout: Data?
  private let runStarted = Date()
  private var wroteRunMetadata = false
  private static let maximumTextBytes = 16 * 1024 * 1024

  static func open(directory: URL?) -> SessionStateStore? {
    guard let directory else { return nil }
    do { return try SessionStateStore(directory: directory) }
    catch { NSLog("Session recovery disabled: %@", String(describing: error)); return nil }
  }

  private init(directory: URL) throws {
    self.directory = directory
    try Self.makeDirectory(directory)
    let runningURL = directory.appendingPathComponent("running")
    let existed = FileManager.default.fileExists(atPath: runningURL.path)
    descriptor = Darwin.open(runningURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EACCES) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(.EWOULDBLOCK)
    }
    do {
      var info = stat()
      guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        fchmod(descriptor, 0o600) == 0 else { throw POSIXError(.EACCES) }
      let old = try? Self.read(runningURL, limit: 4096)
      let previousRestoring: Bool?
      if old?.first == 82 { previousRestoring = true }
      else if old?.first == 78 { previousRestoring = false }
      else { previousRestoring = old.flatMap { try? JSONDecoder().decode(Running.self, from: $0).restoring } }
      var layout: SessionLayout?
      if existed {
        if previousRestoring == nil || previousRestoring == true { try Self.quarantine(directory) }
        else {
          let current = try? Self.read(directory.appendingPathComponent("layout.json"), limit: Self.maximumTextBytes)
          let previous = try? Self.read(directory.appendingPathComponent("layout.previous.json"), limit: Self.maximumTextBytes)
          // A newer writer's state is preserved rather than silently downgraded.
          if let current, let object = try? JSONSerialization.jsonObject(with: current) as? [String: Any],
            let version = object["version"] as? Int, version > 1 {
            try Self.quarantine(directory)
          } else {
            for data in [current, previous].compactMap({ $0 }) {
              if let decoded = try? JSONDecoder().decode(SessionLayout.self, from: data), decoded.isValid {
                layout = decoded; lastGoodLayout = data; break
              }
            }
            if layout == nil { try Self.quarantine(directory) }
          }
        }
      } else { try Self.removeSavedFiles(directory) }
      restored = layout
      try Self.makeDirectory(directory.appendingPathComponent("panes", isDirectory: true))
      try writeRunning(restoring: layout != nil)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  deinit { Darwin.close(descriptor) }

  func save(_ layout: SessionLayout, restoring: Bool = false, completion: (() -> Void)? = nil) {
    queue.async { [self] in
      guard !isStopping else { return }
      do {
        let data = try JSONEncoder().encode(layout)
        if let lastGoodLayout {
          try Self.atomicWrite(lastGoodLayout, to: directory.appendingPathComponent("layout.previous.json"))
        }
        try Self.atomicWrite(data, to: directory.appendingPathComponent("layout.json"))
        lastGoodLayout = data
        let retained = Set(layout.windows.flatMap(\.panes).map { $0.id.string })
        let panes = directory.appendingPathComponent("panes")
        try Self.checkDirectory(panes)
        for file in try FileManager.default.contentsOfDirectory(at: panes, includingPropertiesForKeys: nil) {
          // `<pane>.txt`, `<pane>.resume` and a hook's `<pane>.resume.tmp` all belong to the pane.
          let owner = file.lastPathComponent.prefix { $0 != "." }
          if !retained.contains(String(owner)) { try? FileManager.default.removeItem(at: file) }
        }
        try writeRunning(restoring: restoring)
        if let completion { DispatchQueue.main.async(execute: completion) }
      } catch { NSLog("Session recovery save failed: %@", String(describing: error)) }
    }
  }

  func saveScrollback(_ text: String, rows: Int, pane: PaneID) {
    queue.async { [self] in
      guard !isStopping, text.utf8.count <= Self.maximumTextBytes else { return }
      do {
        let body = Data(text.utf8)
        let header = ScrollbackHeader(rows: rows, bytes: body.count, capturedAt: Date(), checksum: Self.checksum(body))
        var data = try JSONEncoder().encode(header)
        data.append(10); data.append(body)
        try Self.atomicWrite(data, to: scrollbackURL(pane))
      } catch { NSLog("Scrollback checkpoint failed: %@", String(describing: error)) }
    }
  }

  func scrollback(_ pane: PaneID) -> Scrollback {
    do {
      try Self.checkDirectory(directory.appendingPathComponent("panes"))
      let data = try Self.read(scrollbackURL(pane), limit: Self.maximumTextBytes + 4096)
      guard let newline = data.firstIndex(of: 10), newline < 4096 else { throw POSIXError(.EINVAL) }
      let header = try JSONDecoder().decode(ScrollbackHeader.self, from: data[..<newline])
      let body = Data(data[(newline + 1)...])
      guard header.version == 1, header.bytes == body.count, header.rows >= 0, header.rows <= 50_000,
        header.checksum == Self.checksum(body), let text = String(data: body, encoding: .utf8)
      else { throw POSIXError(.EINVAL) }
      return Scrollback(text: text, capturedAt: header.capturedAt, unavailable: false)
    } catch { return Scrollback(text: "", capturedAt: restored?.savedAt ?? Date(), unavailable: true) }
  }

  func cleanExit(completion: @escaping @Sendable () -> Void = {}) {
    stopLock.lock(); stopping = true; stopLock.unlock()
    queue.async { [self] in
      defer { completion() }
      do {
        try Self.removeSavedFiles(directory)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("running").path) {
          try FileManager.default.removeItem(at: directory.appendingPathComponent("running"))
        }
        Self.syncDirectory(directory)
      } catch { NSLog("Session recovery cleanup failed: %@", String(describing: error)) }
    }
  }

  private func scrollbackURL(_ pane: PaneID) -> URL {
    directory.appendingPathComponent("panes/\(pane.string).scrollback")
  }
  func resumeFile(_ pane: PaneID) -> URL {
    directory.appendingPathComponent("panes/\(pane.string).resume")
  }
  private func writeRunning(restoring: Bool) throws {
    // Keep the flock inode stable. A single N/R byte is the authoritative
    // restore-loop marker; normal saves never truncate or replace it. Even a
    // partial metadata write on launch leaves the decision readable.
    var status: UInt8 = restoring ? 82 : 78
    guard pwrite(descriptor, &status, 1, 0) == 1, fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    if !wroteRunMetadata {
      let data = try JSONEncoder().encode(Running(pid: getpid(), started: runStarted, restoring: restoring))
      guard lseek(descriptor, 1, SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
      try Self.write(data, descriptor: descriptor)
      guard ftruncate(descriptor, off_t(data.count + 1)) == 0 else { throw POSIXError(.EIO) }
      wroteRunMetadata = true
    }
    guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
  }
  private static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func makeDirectory(_ url: URL) throws {
    // Reject redirected ancestors before creation or destructive cleanup.
    // This includes a replaced panes/ directory in otherwise valid state.
    let parent = url.deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: parent.path) { try checkDirectory(parent) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try checkDirectory(url)
    guard chmod(url.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
  }
  private static func checkDirectory(_ url: URL) throws {
    guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw POSIXError(.ELOOP) }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isSymbolicLink != true, values.isDirectory == true else { throw POSIXError(.ENOTDIR) }
  }
  private static func read(_ url: URL, limit: Int) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw POSIXError(.ENOENT) }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size >= 0, info.st_size <= limit else { throw POSIXError(.EFBIG) }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
      if count == 0 { return result }
      if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= limit else { throw POSIXError(.EFBIG) }
    }
  }
  private static func write(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw POSIXError(.EIO) }
        offset += count
      }
    }
  }
  private static func atomicWrite(_ data: Data, to url: URL) throws {
    try checkDirectory(url.deletingLastPathComponent())
    let temporary = url.appendingPathExtension("tmp")
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError(.EACCES) }
    defer { Darwin.close(fd) }
    guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EACCES) }
    try write(data, descriptor: fd)
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    syncDirectory(url.deletingLastPathComponent())
  }
  private static func syncDirectory(_ directory: URL) {
    let fd = Darwin.open(directory.path, O_RDONLY)
    if fd >= 0 { _ = fsync(fd); Darwin.close(fd) }
  }
  private static func removeSavedFiles(_ directory: URL) throws {
    try checkDirectory(directory)
    for name in ["layout.json", "layout.previous.json", "layout.json.tmp", "layout.previous.json.tmp", "panes"] {
      let url = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
  }
  private static func quarantine(_ directory: URL) throws {
    let destination = directory.appendingPathComponent("quarantine")
    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    try makeDirectory(destination)
    for name in ["layout.json", "layout.previous.json", "panes"] {
      let source = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.moveItem(at: source, to: destination.appendingPathComponent(name))
      }
    }
    NSLog("Session recovery quarantined unusable state")
  }
}

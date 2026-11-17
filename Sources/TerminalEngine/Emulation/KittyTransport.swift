import Foundation
import TerminalInterop

/// Where a Kitty graphics transmission keeps its data: in the escape code
/// itself (`t=d`), in a file (`t=f`), in a temporary file the terminal
/// deletes after reading (`t=t`), or in POSIX shared memory (`t=s`). For the
/// last three the payload is the name, and `S` and `O` give the size and
/// offset to read.
enum KittyTransport {
  /// Admission is process-wide: even an uninterruptible filesystem can hold
  /// at most two workers and their bounded payloads. Timeout releases the
  /// terminal owner, not the descriptor still used by the worker.
  final class Read: @unchecked Sendable {
    private static let slots = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var result: Result<Data, KittyGraphicsError>?
    private var callback: (() -> Void)?
    init(fields: [Character: String], payload: Data, limit: Int,
         timeout: DispatchTimeInterval = .seconds(2),
         operation: @escaping () throws -> Data) {
      guard Self.slots.wait(timeout: .now()) == .success else { result = .failure(.noSpace); return }
      DispatchQueue.global(qos: .utility).async { [self] in
        defer { Self.slots.signal() }
        let value: Result<Data, KittyGraphicsError>
        do { value = .success(try operation()) }
        catch let error as KittyGraphicsError { value = .failure(error) }
        catch { value = .failure(.invalid) }
        complete(value)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
        self?.complete(.failure(.notFound))
      }
    }
    private func complete(_ value: Result<Data, KittyGraphicsError>) {
      lock.lock()
      guard result == nil else { lock.unlock(); return }
      result = value; let ready = callback; callback = nil
      lock.unlock(); ready?()
    }
    func take() -> Result<Data, KittyGraphicsError>? { lock.lock(); defer { lock.unlock() }; return result }
    func whenReady(_ ready: @escaping () -> Void) {
      lock.lock()
      if result != nil { lock.unlock(); ready() }
      else { callback = ready; lock.unlock() }
    }
    func cancel() { complete(.failure(.invalid)); lock.lock(); callback = nil; lock.unlock() }
  }
  static func read(_ fields: [Character: String], payload: Data, limit: Int) throws -> Data {
    let type = fields["t"] ?? "d"
    guard type != "d" else { return payload }
    guard let name = String(data: payload, encoding: .utf8), !name.isEmpty, !name.contains("\0"),
      name.utf8.count <= 4096 else { throw KittyGraphicsError.invalid }
    let size = try value(fields["S"]), offset = try value(fields["O"])
    guard size <= limit else { throw KittyGraphicsError.tooLarge }
    if type == "s" { return try sharedMemory(name, size: size, offset: offset, limit: limit) }

    // A path resolved, with no link left in it, to a regular file.
    guard let resolved = realpath(name, nil) else { throw KittyGraphicsError.notFound }
    let path = String(cString: resolved)
    free(resolved)
    // Device and kernel pseudo-files are never read.
    for refused in ["/dev/", "/proc/", "/sys/"] where path.hasPrefix(refused) { throw KittyGraphicsError.invalid }
    if type == "t" {
      // A temporary file must be in a temporary directory and say what it
      // is in its name, so a program cannot have the terminal delete
      // anything else.
      guard path.contains("tty-graphics-protocol"), temporaryDirectories.contains(where: { path.hasPrefix($0) })
      else { throw KittyGraphicsError.invalid }
    }
    defer { if type == "t" { unlink(path) } }
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw KittyGraphicsError.notFound }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw KittyGraphicsError.invalid }
    let available = Int(status.st_size) - offset
    guard offset >= 0, available > 0 else { throw KittyGraphicsError.invalid }
    let count = size > 0 ? min(size, available) : available
    guard count <= limit else { throw KittyGraphicsError.tooLarge }
    var data = Data(count: count)
    let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
    guard read == count else { throw KittyGraphicsError.invalid }
    return data
  }

  private static func value(_ text: String?) throws -> Int {
    guard let text else { return 0 }
    guard let value = UInt32(text) else { throw KittyGraphicsError.invalid }
    return Int(value)
  }

  /// The temporary directories, resolved, each ending in a slash.
  private static let temporaryDirectories: [String] = {
    var found: [String] = []
    for directory in [NSTemporaryDirectory(), "/tmp", "/var/tmp", ProcessInfo.processInfo.environment["TMPDIR"] ?? ""]
    where !directory.isEmpty {
      guard let resolved = realpath(directory, nil) else { continue }
      var path = String(cString: resolved)
      free(resolved)
      if !path.hasSuffix("/") { path += "/" }
      found.append(path)
    }
    return found
  }()

  /// C owns the variadic call; casting it to a fixed-argument function is
  /// not ABI-compatible on Darwin arm64 when a creation mode is supplied.
  private static func openSharedMemory(_ name: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    #if os(macOS)
    return helge_terminal_graphics_shm_open(name, flags, 0)
    #else
    errno = ENOTSUP; return -1
    #endif
  }

  /// Reads and removes a shared memory object, as kitty does.
  private static func sharedMemory(_ name: String, size: Int, offset: Int, limit: Int) throws -> Data {
    let descriptor = name.withCString { openSharedMemory($0, O_RDONLY) }
    guard descriptor >= 0 else { throw KittyGraphicsError.notFound }
    defer { close(descriptor); _ = shm_unlink(name) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw KittyGraphicsError.invalid }
    // macOS rounds shared memory up to whole pages, so `S` says how much is data.
    let total = Int(status.st_size)
    let count = size > 0 ? size : total - offset
    guard offset >= 0, count > 0, offset + count <= total, count <= limit else { throw KittyGraphicsError.invalid }
    let pageSize = Int(getpagesize())
    let alignedOffset = offset / pageSize * pageSize
    let prefix = offset - alignedOffset
    let mappedCount = prefix + count
    guard let mapped = mmap(nil, mappedCount, PROT_READ, MAP_SHARED, descriptor, off_t(alignedOffset)), mapped != MAP_FAILED else {
      throw KittyGraphicsError.invalid
    }
    defer { munmap(mapped, mappedCount) }
    return Data(bytes: mapped.advanced(by: prefix), count: count)
  }
}

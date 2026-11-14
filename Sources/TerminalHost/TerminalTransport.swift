import Foundation

/// The far end of a session that is not a local process: an SSH channel, a
/// serial line, a recording being replayed. The session gives it what the
/// user types and the terminal answers, and takes its output through the
/// `TerminalConnection` handed to `start`.
///
/// Every method is called on one private serial queue, never on the main
/// thread, and never two at a time.
public protocol TerminalTransport: AnyObject {
  /// Called once, when the terminal has its first size. Keep `connection`
  /// and give it the far end's output.
  func start(_ connection: TerminalConnection, columns: Int, rows: Int)
  /// Bytes for the far end: keystrokes, pastes and the terminal's replies.
  func send(_ bytes: Data)
  /// The terminal's size changed. The pixel sizes are zero when unknown.
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
  /// The session is done with the transport: it was closed or released, or
  /// the transport ended it. Called once, and only after `start`.
  func close()
}

extension TerminalTransport {
  public func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {}
  public func close() {}
}

/// A transport's line into its session. Safe to use from any thread.
public final class TerminalConnection: @unchecked Sendable {
  private let descriptor: Int32
  /// Outbound queue only once started; dropped when the transport is closed,
  /// so a transport may keep its connection without a cycle.
  private var transport: TerminalTransport?
  /// Carries output toward the session, in order. A write waits here when
  /// the terminal is behind, so `receive` itself never blocks.
  private let inbound = DispatchQueue(label: "no.helgesverre.terminal.transport.in", qos: .userInitiated)
  /// Calls the transport.
  private let outbound = DispatchQueue(label: "no.helgesverre.terminal.transport.out", qos: .userInitiated)
  private let lock = NSLock()
  private var ended = false
  private var storedFailure: Error?
  private var pending = 0
  /// Inbound queue only.
  private var descriptorClosed = false
  private var reader: DispatchSourceRead?

  /// The error the transport ended with, if any.
  var failure: Error? {
    lock.lock(); defer { lock.unlock() }
    return storedFailure
  }
  /// Bytes received and not yet handed to the terminal. A transport that can
  /// outrun the terminal (a file, a fast link) waits while this is large.
  public var bufferedByteCount: Int {
    lock.lock(); defer { lock.unlock() }
    return pending
  }

  /// Takes ownership of `descriptor`, the transport's end of a socket pair.
  init(descriptor: Int32, transport: TerminalTransport) {
    self.descriptor = descriptor
    self.transport = transport
  }
  func start(columns: Int, rows: Int) {
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: outbound)
    reader = source
    let descriptor = descriptor
    guard let transport else { return }
    source.setEventHandler { [weak source] in
      var buffer = [UInt8](repeating: 0, count: 65_536)
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        transport.send(Data(buffer.prefix(count)))
      } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
        // The session closed its end.
        source?.cancel()
      }
    }
    source.setCancelHandler { [self] in
      transport.close()
      self.transport = nil
      lock.lock(); ended = true; lock.unlock()
      inbound.async { [self] in
        Darwin.close(descriptor)
        descriptorClosed = true
      }
    }
    outbound.async {
      transport.start(self, columns: columns, rows: rows)
      source.resume()
    }
  }
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
    outbound.async { [self] in
      lock.lock(); let over = ended; lock.unlock()
      if !over { transport?.resize(columns: columns, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
    }
  }

  /// Output from the far end, for the terminal to show. Returns at once;
  /// the bytes are shown in the order they were received.
  public func receive(_ bytes: Data) {
    guard !bytes.isEmpty else { return }
    lock.lock()
    guard !ended else { lock.unlock(); return }
    pending += bytes.count
    lock.unlock()
    inbound.async { [self] in
      write(bytes)
      lock.lock(); pending -= bytes.count; lock.unlock()
    }
  }
  /// The far end is gone. What was received before is still shown, then the
  /// session reports its end; `error` makes that end an unclean one.
  public func end(error: Error? = nil) {
    lock.lock()
    guard !ended else { lock.unlock(); return }
    ended = true
    storedFailure = error
    lock.unlock()
    inbound.async { [self] in
      if !descriptorClosed { shutdown(descriptor, SHUT_WR) }
    }
  }
  /// Inbound queue only. Waits for room; gives up when the session is gone.
  private func write(_ bytes: Data) {
    guard !descriptorClosed else { return }
    bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if count > 0 { offset += count; continue }
        if count < 0 && errno == EINTR { continue }
        guard count < 0, errno == EAGAIN else { return }
        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        // Bounded, so a session that has stopped reading is noticed.
        _ = poll(&waiting, 1, 250)
        lock.lock(); let over = reader?.isCancelled ?? true; lock.unlock()
        if over { return }
      }
    }
  }

  /// A connected pair of nonblocking stream sockets, or the error.
  static func socketPair() -> Result<(session: Int32, transport: Int32), POSIXError> {
    var ends: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
      return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }
    for end in ends {
      _ = fcntl(end, F_SETFD, FD_CLOEXEC)
      _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
      var on: Int32 = 1
      setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      var size: Int32 = 262_144
      setsockopt(end, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(end, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
    return .success((ends[0], ends[1]))
  }
}

import Foundation

private nonisolated(unsafe) var stopSignalled: sig_atomic_t = 0
private nonisolated(unsafe) var resizeSignalled: sig_atomic_t = 0

/// What SIGINT and SIGTERM do to the tool. There are three ways, and this
/// file owns all of them:
///
/// - `endRun()` is the default, set by `main.swift`: every launched process
///   tree is ended and the tool exits with status 130. No report is written.
/// - `observe()` is for a runner that promises a report for an interrupted
///   run. The signal becomes a request, which `check()` turns into an
///   ordinary failure wherever the runner waits.
/// - `takeOver()` is for the tool running as a helper inside a terminal, such
///   as the TUI stress fixture. Plain handlers set flags that the helper's
///   own loop reads, and nothing ends the process but the helper itself.
enum Interruption {
  nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
  private static let lock = NSLock()
  nonisolated(unsafe) private static var count = 0

  /// Ends every launched process and the tool on the first signal.
  static func endRun() {
    lock.lock(); count = 0; lock.unlock()
    watch { end() }
  }

  /// Turns the first signal into a request that `requested` and `check()`
  /// report. A second signal ends everything at once, so a runner that has
  /// stopped checking can still be stopped.
  static func observe() {
    watch {
      lock.lock(); count += 1; let repeated = count > 1; lock.unlock()
      if repeated { end() }
    }
  }

  /// Whether a signal has arrived since `observe()`.
  static var requested: Bool {
    lock.lock(); defer { lock.unlock() }
    return count > 0
  }

  /// Fails with "interrupted" once a signal has arrived.
  static func check() throws {
    if requested { throw Failure("interrupted") }
  }

  /// Leaves SIGINT, SIGTERM and SIGHUP, and SIGWINCH with `resize`, to
  /// handlers that only set a flag. A helper has a child to reap and a
  /// receipt to write before it ends, and neither is safe inside a handler.
  /// A handler also interrupts a blocking call, so the helper's loop sees
  /// the flag at once.
  static func takeOver(resize: Bool = false) {
    sources.forEach { $0.cancel() }
    sources = []
    stopSignalled = 0
    resizeSignalled = 0
    for number in [SIGTERM, SIGHUP, SIGINT] { signal(number) { _ in stopSignalled = 1 } }
    if resize { signal(SIGWINCH) { _ in resizeSignalled = 1 } }
  }

  /// Whether a helper that took over has been asked to stop.
  static var stopRequested: Bool { stopSignalled != 0 }

  /// Whether the terminal was resized since the last call.
  static func takeResize() -> Bool {
    guard resizeSignalled != 0 else { return false }
    resizeSignalled = 0
    return true
  }

  /// Replaces what the two signals do. They get an empty handler rather than
  /// being ignored: an ignored signal stays ignored in every process this
  /// tool launches, a handled one does not.
  private static func watch(_ handler: @escaping () -> Void) {
    sources.forEach { $0.cancel() }
    sources = [SIGINT, SIGTERM].map { number in
      signal(number) { _ in }
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler(handler: handler)
      source.resume()
      return source
    }
  }

  // An interrupted run still ends the processes it launched.
  private static func end() -> Never {
    ProcessTree.cleanupAll()
    exit(130)
  }

  static let tests = [
    SelfTest.Case(name: "interruption: an observing runner is told once, and the default is restored") {
      observe()
      defer { endRun() }
      try check()
      kill(getpid(), SIGTERM)
      let deadline = Clock.now + 2_000_000_000
      while !requested, Clock.now < deadline { usleep(5_000) }
      try expect(requested, "the signal is recorded as a request")
      try expect(try expectFailure("an interrupted wait") { try check() }.message == "interrupted", "check fails")
      let tree = try ProcessTree(["/bin/sleep", "30"])
      defer { tree.cleanup() }
      try expect(try expectFailure("an interrupted wait") { _ = try tree.waitInterruptibly(seconds: 5) }
        .message == "interrupted", "a wait ends early")
      endRun()
      try expect(!requested, "a new run starts without a request")
    },
  ]
}

extension ProcessTree {
  /// Waits like `wait(seconds:)`, and fails early when the run is interrupted.
  func waitInterruptibly(seconds: Double) throws -> Exit? {
    let deadline = Clock.now + UInt64(seconds * 1_000_000_000)
    while true {
      let now = Clock.now
      if let exit = wait(seconds: now < deadline ? min(0.2, Double(deadline - now) / 1_000_000_000) : 0) { return exit }
      try Interruption.check()
      if Clock.now >= deadline { return nil }
    }
  }
}

import Darwin
import Foundation
import TerminalInterop

/// Holds the PTYs of running programs while the app that showed them is
/// replaced. The app starts one keeper as it leaves; the keeper does nothing
/// but keep the descriptors open, so no program is hung up, and gives them
/// to the next app that asks. It never reads a PTY: a program that writes
/// meanwhile waits, as it would behind a slow terminal.
///
/// The keeper is this executable in another role, so there is no second
/// binary to ship. It runs before AppKit is touched and has no window.
enum SessionKeeper {
  static let flag = "--session-keeper"
  /// The first inherited descriptor; the rest follow it.
  private static let firstDescriptor: Int32 = 3
  /// `sockaddr_un.sun_path` holds 104 bytes with its terminator.
  static let maximumSocketPath = 103

  /// Becomes the keeper when the arguments ask for it, and never returns.
  /// Arguments: the flag, the socket path, seconds to wait, descriptor count.
  static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
    guard arguments.count == 5, arguments[1] == flag, let seconds = Int(arguments[3]), seconds > 0,
      let count = Int32(arguments[4]), count > 0, count <= 1024 else { return }
    exit(keep(socketPath: arguments[2], seconds: seconds, descriptors: (0..<count).map { firstDescriptor + $0 }))
  }

  private static func keep(socketPath: String, seconds: Int, descriptors: [Int32]) -> Int32 {
    // The app that started the keeper is leaving; nothing of its ending may
    // end the keeper too.
    signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN); signal(SIGINT, SIG_IGN)
    guard let listener = listen(socketPath) else { return 1 }
    defer { unlink(socketPath) }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      // Unclaimed: closing the descriptors, by exiting, hangs the programs up
      // as closing their windows would have.
      guard now < deadline else { return 2 }
      var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      guard poll(&waiting, 1, Int32(min(1000, (deadline - now) / 1_000_000 + 1))) > 0 else { continue }
      let client = accept(listener, nil, nil)
      guard client >= 0 else { continue }
      defer { close(client) }
      var user: uid_t = 0, group: gid_t = 0
      guard getpeereid(client, &user, &group) == 0, user == getuid() else { continue }
      guard descriptors.allSatisfy({ helge_descriptor_send(client, $0) }) else { continue }
      // The descriptors are let go only when the receiver says it has them.
      var acknowledged: UInt8 = 0
      var reply = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
      if poll(&reply, 1, 10_000) > 0, read(client, &acknowledged, 1) == 1, acknowledged == 0x6b { return 0 }
    }
  }

  private static func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count <= maximumSocketPath else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
  }
  private static func listen(_ path: String) -> Int32? {
    guard var address = address(path) else { return nil }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    unlink(path)
    let previous = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(previous)
    guard bound == 0, Darwin.listen(descriptor, 4) == 0 else { close(descriptor); return nil }
    return descriptor
  }

  /// Starts a keeper holding `descriptors` and returns its process, once it
  /// is listening. The caller still owns its own copies.
  static func start(executable: String, socketPath: String, seconds: Int, descriptors: [Int32]) -> pid_t? {
    guard !descriptors.isEmpty, address(socketPath) != nil else { return nil }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attributes) }
    // Copies above the target range first, so that placing one descriptor
    // cannot overwrite another that is still to be placed.
    let base = firstDescriptor + Int32(descriptors.count)
    var copies: [Int32] = []
    defer { copies.forEach { close($0) } }
    for descriptor in descriptors {
      let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, base)
      guard copy >= 0 else { return nil }
      copies.append(copy)
    }
    let null = open("/dev/null", O_RDWR | O_CLOEXEC)
    guard null >= 0 else { return nil }
    defer { close(null) }
    for target in 0..<firstDescriptor { posix_spawn_file_actions_adddup2(&actions, null, target) }
    for (index, copy) in copies.enumerated() {
      posix_spawn_file_actions_adddup2(&actions, copy, firstDescriptor + Int32(index))
    }
    // Its own session: the keeper belongs to no terminal and no job.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    let arguments = [executable, flag, socketPath, String(seconds), String(descriptors.count)]
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, executable, &actions, &attributes, &argv, environ) == 0 else { return nil }
    // Listening is the keeper's word that it holds the descriptors.
    for _ in 0..<200 {
      if let probe = connect(socketPath) { close(probe); return pid }
      var status: Int32 = 0
      if waitpid(pid, &status, WNOHANG) == pid { return nil }
      usleep(10_000)
    }
    kill(pid, SIGKILL)
    return nil
  }

  private static func connect(_ path: String) -> Int32? {
    guard var address = address(path) else { return nil }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { close(descriptor); return nil }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    return descriptor
  }

  /// Takes `count` descriptors from the keeper at `socketPath`, which then
  /// exits. Nil when no keeper answers or it holds something else.
  static func claim(socketPath: String, count: Int) -> [Int32]? {
    guard count > 0, let client = connect(socketPath) else { return nil }
    defer { close(client) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var descriptors: [Int32] = []
    for _ in 0..<count {
      let descriptor = helge_descriptor_receive(client)
      guard descriptor >= 0 else { descriptors.forEach { close($0) }; return nil }
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      descriptors.append(descriptor)
    }
    var acknowledgement: UInt8 = 0x6b
    guard write(client, &acknowledgement, 1) == 1 else { descriptors.forEach { close($0) }; return nil }
    return descriptors
  }
}

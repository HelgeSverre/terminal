import Foundation
import TerminalEngine

/// A running child and its terminal, given up by one session so that another
/// process can adopt them: the app is replaced while its programs keep
/// running. The descriptor is the PTY's controlling end and is the receiver's
/// to close; while any copy stays open the child is not hung up.
package struct SessionHandoff: Sendable {
  package let descriptor: Int32
  package let processIdentifier: Int32
  /// When the child started (`ProcessIdentity.start`). The receiver is not
  /// its parent, so the number alone may name another process by then.
  package let processStart: UInt64
  package let terminal: TerminalHandoff
  package init(descriptor: Int32, processIdentifier: Int32, processStart: UInt64, terminal: TerminalHandoff) {
    self.descriptor = descriptor; self.processIdentifier = processIdentifier
    self.processStart = processStart; self.terminal = terminal
  }
}

/// Tells a process from a later one that was given the same number. A parent
/// needs none of this: its child keeps its number until it is waited for.
package enum ProcessIdentity {
  /// When the process started, in microseconds since 1970; nil when there
  /// is no such process or it cannot be asked.
  package static func start(of pid: Int32) -> UInt64? {
    guard pid > 0 else { return nil }
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let started = info.kp_proc.p_un.__p_starttime
    return UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec)
  }
  /// Whether `pid` is still the process that started at `start`.
  package static func holds(_ pid: Int32, startedAt start: UInt64) -> Bool { self.start(of: pid) == start }
}

import Foundation
import TerminalInterop

/// The first window's child, started at process launch so that its startup
/// (a login shell reading its configuration, usually) overlaps the app's own.
/// The first session adopts it when it asks for the same launch; any other
/// first launch ends it.
package enum EarlyChild {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var pending: (spec: LaunchSpec, process: TerminalProcess)?
  nonisolated(unsafe) private static var settleGrid: (@Sendable (Int, Int, Int, Int) -> Void)?

  /// Spawns `spec` now. With no explicit grid, the PTY starts at `savedGrid`
  /// when provided, so the child usually never sees it change.
  package static func start(
    _ spec: LaunchSpec,
    grid: (columns: Int, rows: Int)?,
    savedGrid: (rows: Int, columns: Int, pixelWidth: Int, pixelHeight: Int)? = nil,
    onSettleGrid: (@Sendable (Int, Int, Int, Int) -> Void)? = nil
  ) {
    guard spec.isValid else { return }
    var size = winsize(ws_row: UInt16(grid?.rows ?? 24), ws_col: UInt16(grid?.columns ?? 80),
                       ws_xpixel: 0, ws_ypixel: 0)
    if grid == nil, let saved = savedGrid,
       [saved.rows, saved.columns, saved.pixelWidth, saved.pixelHeight].allSatisfy({ (1...Int(UInt16.max)).contains($0) }) {
      size = winsize(ws_row: UInt16(saved.rows), ws_col: UInt16(saved.columns),
                     ws_xpixel: UInt16(saved.pixelWidth), ws_ypixel: UInt16(saved.pixelHeight))
    }
    let process = spec.spawn(columns: Int(size.ws_col), rows: Int(size.ws_row))
    guard process.error == 0 else { return }
    // The pixel size too, before the child can have asked for it.
    if size.ws_xpixel > 0 { _ = ioctl(process.master, TIOCSWINSZ, &size) }
    lock.lock(); defer { lock.unlock() }
    pending = (spec, process)
    settleGrid = grid == nil ? onSettleGrid : nil
  }

  /// The early child, when it was started for `spec`. The first call settles
  /// it either way.
  static func adopt(_ spec: LaunchSpec) -> TerminalProcess? {
    lock.lock()
    let early = pending
    pending = nil
    lock.unlock()
    guard let early else { return nil }
    if early.spec == spec { return early.process }
    // Closing the PTY hangs the unwanted child up.
    close(early.process.master)
    close(early.process.status)
    TerminalSession.endAbandonedChild(early.process.pid, counted: false)
    return nil
  }

  /// Records the first size a pane settles on, for the next launch.
  static func noteGrid(_ size: winsize) {
    lock.lock()
    let callback = settleGrid
    settleGrid = nil
    lock.unlock()
    callback?(Int(size.ws_row), Int(size.ws_col), Int(size.ws_xpixel), Int(size.ws_ypixel))
  }
}

/// Measurement switches the app turns on from its command line. A session
/// never reads the host's arguments itself.
package enum SessionDiagnostics {
  /// Whether sessions count their stream events. Set before the first
  /// session is created.
  nonisolated(unsafe) package static var collectsStreamStatistics = false
}

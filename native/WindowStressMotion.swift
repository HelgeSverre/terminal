import AppKit

/// The deterministic geometry behind the optional Cat-window motion stress run.
///
/// This is intentionally independent of TerminalWindow so its bounds and continuity
/// properties can be exercised without creating an AppKit window.
enum WindowStressTrajectory {
  static let targetHz = 60.0
  static let motionPeriod = 7.0

  static func frame(
    elapsed: TimeInterval, originalFrame: CGRect, visibleFrame: CGRect, minimumSize: CGSize
  ) -> CGRect {
    guard visibleFrame.width > 0, visibleFrame.height > 0 else { return originalFrame }

    let minimumWidth = min(max(1, minimumSize.width), visibleFrame.width)
    let minimumHeight = min(max(1, minimumSize.height), visibleFrame.height)
    let baseWidth = clamp(originalFrame.width, minimumWidth, visibleFrame.width)
    let baseHeight = clamp(originalFrame.height, minimumHeight, visibleFrame.height)
    let widthAmplitude = min((visibleFrame.width - minimumWidth) * 0.22, baseWidth * 0.18)
    let heightAmplitude = min((visibleFrame.height - minimumHeight) * 0.20, baseHeight * 0.16)
    let phase = elapsed * (2 * .pi / motionPeriod)
    let width = clamp(baseWidth + sin(phase * 0.73) * widthAmplitude, minimumWidth, visibleFrame.width)
    let height = clamp(baseHeight + sin(phase * 0.31) * heightAmplitude, minimumHeight, visibleFrame.height)

    let centeredX = clamp(originalFrame.midX, visibleFrame.minX + width / 2, visibleFrame.maxX - width / 2)
    let centeredY = clamp(originalFrame.midY, visibleFrame.minY + height / 2, visibleFrame.maxY - height / 2)
    let travelX = max(0, (visibleFrame.width - width) * 0.43)
    let travelY = max(0, (visibleFrame.height - height) * 0.43)
    // x = sin(t), y = sin(2t) is a figure-eight, rather than a circular drag path.
    let originX = clamp(centeredX + sin(phase) * travelX - width / 2, visibleFrame.minX, visibleFrame.maxX - width)
    let originY = clamp(centeredY + sin(phase * 2) * travelY - height / 2, visibleFrame.minY, visibleFrame.maxY - height)
    return CGRect(x: originX, y: originY, width: width, height: height)
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}

@MainActor final class WindowStressMotion {
  enum StopReason: String {
    case catFinished = "cat_finished"
    case catTimedOut = "cat_timed_out"
    case windowClosed = "window_closed"
    case screenTooSmall = "screen_too_small"
  }

  private struct FrameBounds {
    var minX: CGFloat?
    var maxX: CGFloat?
    var minY: CGFloat?
    var maxY: CGFloat?
    var minWidth: CGFloat?
    var maxWidth: CGFloat?
    var minHeight: CGFloat?
    var maxHeight: CGFloat?

    mutating func include(_ frame: CGRect) {
      minX = Swift.min(minX ?? frame.minX, frame.minX)
      maxX = Swift.max(maxX ?? frame.minX, frame.minX)
      minY = Swift.min(minY ?? frame.minY, frame.minY)
      maxY = Swift.max(maxY ?? frame.minY, frame.minY)
      minWidth = Swift.min(minWidth ?? frame.width, frame.width)
      maxWidth = Swift.max(maxWidth ?? frame.width, frame.width)
      minHeight = Swift.min(minHeight ?? frame.height, frame.height)
      maxHeight = Swift.max(maxHeight ?? frame.height, frame.height)
    }

    func report() -> [String: Double] {
      var result: [String: Double] = [:]
      if let minX { result["min_x"] = minX }
      if let maxX { result["max_x"] = maxX }
      if let minY { result["min_y"] = minY }
      if let maxY { result["max_y"] = maxY }
      if let minWidth { result["min_width"] = minWidth }
      if let maxWidth { result["max_width"] = maxWidth }
      if let minHeight { result["min_height"] = minHeight }
      if let maxHeight { result["max_height"] = maxHeight }
      return result
    }

    static func dictionary(_ frame: CGRect?) -> [String: Double] {
      guard let frame else { return [:] }
      return [
        "x": frame.origin.x, "y": frame.origin.y,
        "width": frame.width, "height": frame.height,
      ]
    }
  }

  private weak var window: NSWindow?
  private let originalFrame: CGRect
  private let startedAt: UInt64
  private let intervalNanoseconds: UInt64
  private var nextDeadline: UInt64
  private var timer: DispatchSourceTimer?
  private var stopped = false
  private var stoppedAt: UInt64?
  private var stopReason: StopReason?
  private var requestedBounds = FrameBounds()
  private var appliedBounds = FrameBounds()
  private var lastObservedFrame: CGRect?
  private var latenessMilliseconds: [Double] = []
  private var tickCount = 0

  private init(window: NSWindow) {
    self.window = window
    originalFrame = window.frame
    startedAt = DispatchTime.now().uptimeNanoseconds
    intervalNanoseconds = UInt64(1_000_000_000 / WindowStressTrajectory.targetHz)
    nextDeadline = startedAt
  }

  static func start(window: NSWindow) -> WindowStressMotion {
    let motion = WindowStressMotion(window: window)
    motion.begin()
    return motion
  }

  private func begin() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNanoseconds)), leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in self?.tick() }
    self.timer = timer
    timer.resume()
  }

  private func tick() {
    guard !stopped else { return }
    guard let window, window.isVisible else {
      _ = stop(reason: .windowClosed)
      return
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let late = Double(now >= nextDeadline ? now - nextDeadline : 0) / 1_000_000
    if latenessMilliseconds.count == 12_000 { latenessMilliseconds.removeFirst() }
    latenessMilliseconds.append(late)
    while nextDeadline <= now { nextDeadline += intervalNanoseconds }

    guard let visibleFrame = window.screen?.visibleFrame else { return }
    let configuredMinimum = CGSize(
      width: max(window.minSize.width, window.contentMinSize.width),
      height: max(window.minSize.height, window.contentMinSize.height))
    guard configuredMinimum.width <= visibleFrame.width,
      configuredMinimum.height <= visibleFrame.height
    else {
      _ = stop(reason: .screenTooSmall)
      return
    }
    let elapsed = Double(now - startedAt) / 1_000_000_000
    let requested = WindowStressTrajectory.frame(
      elapsed: elapsed, originalFrame: originalFrame, visibleFrame: visibleFrame,
      minimumSize: configuredMinimum)
    requestedBounds.include(requested)
    window.setFrame(requested, display: true, animate: false)
    lastObservedFrame = window.frame
    appliedBounds.include(window.frame)
    tickCount += 1
  }

  @discardableResult func stop(reason: StopReason) -> [String: Any] {
    if !stopped {
      stopped = true
      stoppedAt = DispatchTime.now().uptimeNanoseconds
      stopReason = reason
      timer?.setEventHandler {}
      timer?.cancel()
      timer = nil
      if let window, window.isVisible {
        window.setFrame(originalFrame, display: true, animate: false)
      }
    }
    return report()
  }

  func report() -> [String: Any] {
    let now = stoppedAt ?? DispatchTime.now().uptimeNanoseconds
    let observed = lastObservedFrame ?? window?.frame
    return [
      "target_hz": WindowStressTrajectory.targetHz,
      "tick_count": tickCount,
      "duration_seconds": Double(now - startedAt) / 1_000_000_000,
      "tick_lateness_milliseconds": distribution(latenessMilliseconds),
      "requested_frame_bounds": requestedBounds.report(),
      "applied_frame_bounds": appliedBounds.report(),
      "observed_window_frame": FrameBounds.dictionary(observed),
      "restored_window_frame": FrameBounds.dictionary(stopped ? window?.frame : nil),
      "stopped_reason": stopReason?.rawValue ?? "running",
      "note": "Programmatic NSWindow.setFrame trajectory only. This report does not demonstrate physical pointer dragging or compositor presentation.",
    ]
  }

  private func distribution(_ samples: [Double]) -> [String: Double] {
    guard !samples.isEmpty else { return ["count": 0, "maximum": 0, "average": 0] }
    return [
      "count": Double(samples.count),
      "maximum": samples.max() ?? 0,
      "average": samples.reduce(0, +) / Double(samples.count),
    ]
  }
}

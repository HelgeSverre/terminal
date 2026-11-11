import CoreMedia
import Foundation
import ScreenCaptureKit

/// Watches one display and reports when a window becomes visible on it and
/// when a block of marker colour first appears inside that window.
///
/// The display is captured at half its point size, which is enough to tell
/// text from background and keeps a short history cheap. Frames carry the
/// time they were shown, on the clock `Clock.now` reads. Needs Screen
/// Recording permission for the app that hosts the tool.
final class ScreenWatch: NSObject, SCStreamOutput, SCStreamDelegate {
  /// One captured frame: BGRA pixels, rows of `bytesPerRow`.
  private struct Frame {
    let shownAt: UInt64
    let pixels: Data
    let bytesPerRow: Int
  }

  /// A window is visible once this share of its area differs from the screen
  /// as it was just before. Half, so that output scrolling in a window
  /// underneath is not taken for it.
  static let visibleShare = 0.5
  /// The marker is a block of pure magenta, a colour no terminal theme or
  /// shell banner uses. It is present once this many captured pixels have it.
  static let markerPixels = 300
  /// What a program prints to paint the marker: six rows of sixty magenta cells.
  static let markerText = String(repeating: "\u{1b}[48;2;255;0;255m" + String(repeating: " ", count: 60) + "\u{1b}[0m\r\n", count: 6)
  /// How far ahead of its listing a window may already be on screen. Apple
  /// Terminal's is drawn several frames before the window list reports it.
  static let listingLag: UInt64 = 150_000_000

  private let display: SCDisplay
  private let scale = 0.5
  private var stream: SCStream?
  private let queue = DispatchQueue(label: "dev.screen-watch")
  private let lock = NSLock()
  private var reference: Frame?
  private var waiting: [Frame] = []
  private var region: (x: Int, y: Int, width: Int, height: Int)?
  private var firstVisible: UInt64?
  private var firstMarker: UInt64?
  /// When the window was first seen on screen.
  var windowVisibleAt: UInt64? { lock.lock(); defer { lock.unlock() }; return firstVisible }
  /// When the marker was first seen inside the window.
  var markerVisibleAt: UInt64? { lock.lock(); defer { lock.unlock() }; return firstMarker }

  /// The displays that can be watched.
  static func displays() throws -> [SCDisplay] {
    let done = DispatchSemaphore(value: 0)
    var found: [SCDisplay] = []
    var problem: Error?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
      found = content?.displays ?? []
      problem = error
      done.signal()
    }
    done.wait()
    if let problem { throw Failure("cannot list displays (Screen Recording permission?): \(problem.localizedDescription)") }
    return found
  }

  init(display: SCDisplay) { self.display = display }

  /// Starts capturing. The first frame becomes the picture of the screen
  /// before the launch.
  func start() throws {
    let configuration = SCStreamConfiguration()
    configuration.width = Int(Double(display.width) * scale)
    configuration.height = Int(Double(display.height) * scale)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    configuration.showsCursor = false
    configuration.queueDepth = 8
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                          configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    let done = DispatchSemaphore(value: 0)
    var problem: Error?
    stream.startCapture { error in problem = error; done.signal() }
    done.wait()
    if let problem { throw Failure("cannot capture the screen: \(problem.localizedDescription)") }
    self.stream = stream
    // Wait for the reference frame, so that it shows the screen before the launch.
    let deadline = Clock.now + 2_000_000_000
    while Clock.now < deadline {
      lock.lock(); let ready = reference != nil; lock.unlock()
      if ready { return }
      usleep(2_000)
    }
    throw Failure("the screen capture delivered no frame")
  }

  func stop() {
    let done = DispatchSemaphore(value: 0)
    stream?.stopCapture { _ in done.signal() }
    _ = done.wait(timeout: .now() + 2)
    stream = nil
  }

  /// Names the window, in global display points, and when it was first
  /// listed. The last frame shown before then becomes the picture to compare
  /// with, so that whatever else changed on screen since the launch is not
  /// taken for the window. Frames captured since are examined first, then
  /// every new one.
  func watch(window frame: CGRect, listedAt: UInt64) {
    lock.lock(); defer { lock.unlock() }
    let origin = display.frame.origin
    region = (Int((frame.minX - origin.x) * scale), Int((frame.minY - origin.y) * scale),
              Int(frame.width * scale), Int(frame.height * scale))
    // A window can reach the screen a frame before the list reports it.
    let earliest = listedAt - min(listedAt, Self.listingLag)
    if let before = waiting.last(where: { $0.shownAt < earliest }) { reference = before }
    for frame in waiting where frame.shownAt >= earliest { examine(frame) }
    waiting = []
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, let image = buffer.imageBuffer,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
          status == .complete else { return }
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(image) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
    let frame = Frame(shownAt: UInt64(buffer.presentationTimeStamp.seconds * 1_000_000_000),
                      pixels: Data(bytes: base, count: bytesPerRow * CVPixelBufferGetHeight(image)),
                      bytesPerRow: bytesPerRow)
    lock.lock(); defer { lock.unlock() }
    if reference == nil { reference = frame; return }
    if region == nil {
      // A second of history, until the window's place is known.
      waiting.append(frame)
      if waiting.count > 60 { waiting.removeFirst() }
    } else {
      examine(frame)
    }
  }

  /// Looks at one frame for the window, then for the marker in it. Called
  /// with the lock held.
  private func examine(_ frame: Frame) {
    guard let region, let reference, firstMarker == nil else { return }
    let rows = frame.pixels.count / frame.bytesPerRow, columns = frame.bytesPerRow / 4
    let left = max(0, region.x), top = max(0, region.y)
    let right = min(columns, region.x + region.width), bottom = min(rows, region.y + region.height)
    guard right > left, bottom > top else { return }
    let stride = frame.bytesPerRow / 4
    frame.pixels.withUnsafeBytes { now in
      let current = now.bindMemory(to: UInt32.self)
      if firstVisible == nil {
        let changed = reference.pixels.withUnsafeBytes { before -> Int in
          let earlier = before.bindMemory(to: UInt32.self)
          var changed = 0
          for y in top..<bottom {
            for x in left..<right where current[y * stride + x] != earlier[y * stride + x] { changed += 1 }
          }
          return changed
        }
        if Double(changed) >= Self.visibleShare * Double((right - left) * (bottom - top)) { firstVisible = frame.shownAt }
      }
      guard firstVisible != nil else { return }
      var marker = 0
      for y in top..<bottom {
        for x in left..<right where Self.isMarker(current[y * stride + x]) { marker += 1 }
      }
      if marker >= Self.markerPixels { firstMarker = frame.shownAt }
    }
  }

  /// Whether a BGRA pixel is the marker's magenta, allowing for the display's
  /// colour conversion.
  static func isMarker(_ pixel: UInt32) -> Bool {
    let blue = pixel & 0xff, green = (pixel >> 8) & 0xff, red = (pixel >> 16) & 0xff
    return red > 200 && blue > 200 && green < 90
  }
}

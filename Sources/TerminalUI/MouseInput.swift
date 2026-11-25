import Foundation

enum NativeMouseCoordinates {
  /// PTY window-size reports use backing pixels for the content grid, not
  /// points or the surrounding view inset. Clamp gestures to that grid.
  static func position(_ point: CGPoint, scale: CGFloat, inset: Int,
                       width: Int, height: Int, yOffset: CGFloat = 0) -> (x: Int, y: Int) {
    func coordinate(_ value: CGFloat, offset: CGFloat, extent: Int) -> Int {
      let pixel = value * scale - CGFloat(inset) - offset
      guard pixel.isFinite, extent > 0 else { return 1 }
      return Int(max(0, min(CGFloat(extent - 1), floor(pixel)))) + 1
    }
    return (
      coordinate(point.x, offset: 0, extent: width),
      coordinate(point.y, offset: yOffset, extent: height)
    )
  }
}

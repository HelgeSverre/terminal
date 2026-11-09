import AppKit

@main struct WindowStressMotionTests {
  static func main() {
    let visible = CGRect(x: 40, y: 80, width: 1_440, height: 900)
    let original = CGRect(x: 280, y: 230, width: 1_000, height: 680)
    let minimum = CGSize(width: 320, height: 180)
    var previous: CGRect?
    var widthRange = (minimum: CGFloat.greatestFiniteMagnitude, maximum: CGFloat.leastNormalMagnitude)
    var heightRange = (minimum: CGFloat.greatestFiniteMagnitude, maximum: CGFloat.leastNormalMagnitude)

    for sample in 0...1_680 {
      let frame = WindowStressTrajectory.frame(
        elapsed: Double(sample) / WindowStressTrajectory.targetHz,
        originalFrame: original, visibleFrame: visible, minimumSize: minimum)
      precondition(frame.minX >= visible.minX - 0.001)
      precondition(frame.maxX <= visible.maxX + 0.001)
      precondition(frame.minY >= visible.minY - 0.001)
      precondition(frame.maxY <= visible.maxY + 0.001)
      precondition(frame.width >= minimum.width - 0.001)
      precondition(frame.height >= minimum.height - 0.001)
      if let previous {
        // At 60 Hz, every trajectory component advances continuously rather than jumping.
        precondition(abs(frame.minX - previous.minX) < 40)
        precondition(abs(frame.minY - previous.minY) < 40)
        precondition(abs(frame.width - previous.width) < 20)
        precondition(abs(frame.height - previous.height) < 20)
      }
      previous = frame
      widthRange.minimum = min(widthRange.minimum, frame.width)
      widthRange.maximum = max(widthRange.maximum, frame.width)
      heightRange.minimum = min(heightRange.minimum, frame.height)
      heightRange.maximum = max(heightRange.maximum, frame.height)
    }
    precondition(widthRange.maximum - widthRange.minimum > 10)
    precondition(heightRange.maximum - heightRange.minimum > 10)
    print("WindowStressMotionTests passed")
  }
}

#if os(macOS)
import AppKit

/// A passive destination label. It never takes a click from the terminal.
final class LinkTargetPreview: NSView {
  private let label = NSTextField(labelWithString: "")
  private var chrome = TerminalChromeColors.standard

  override init(frame: NSRect) {
    super.init(frame: frame)
    label.font = .systemFont(ofSize: 11)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.baseWritingDirection = .leftToRight
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("Link destination")
    setAccessibilityIdentifier("no.helgesverre.terminal.link-destination")
    label.setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ target: URL, colors: TerminalChromeColors) {
    chrome = colors
    // Keep the address escaped and the real host at the front even when a
    // link has user-info. Never change the URL used for activation.
    var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
    components?.user = nil
    components?.password = nil
    let address = components?.url?.absoluteString ?? target.absoluteString
    label.stringValue = address
    label.textColor = TerminalTheme.color(colors.text)
    setAccessibilityValue(target.absoluteString)
    needsDisplay = true
  }

  func position(in bounds: NSRect, pointer: NSPoint) {
    let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [
      .font: label.font ?? NSFont.systemFont(ofSize: 11)
    ]).width)
    let width = min(textWidth + 24, max(0, bounds.width - 16))
    let height: CGFloat = 26
    let bottom = NSRect(x: bounds.minX + 8, y: bounds.maxY - height - 8, width: width, height: height)
    frame = bottom.contains(pointer)
      ? NSRect(x: bottom.minX, y: bounds.minY + 8, width: width, height: height) : bottom
    label.frame = NSRect(x: 10, y: 6, width: max(0, width - 20), height: 14)
  }

  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    TerminalTheme.color(chrome.raised).setFill()
    shape.fill()
    TerminalTheme.color(chrome.border).setStroke()
    shape.lineWidth = 1
    shape.stroke()
  }
}
#endif

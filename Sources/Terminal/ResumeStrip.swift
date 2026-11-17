import AppKit

/// A restored agent is an offer. Only either button action can invoke its
/// callback; configuring or laying out the strip never sends terminal input.
final class TerminalResumeStrip: NSView {
  static let height: CGFloat = 28
  private let label = NSTextField(labelWithString: "")
  private let resume = NSButton(title: "Resume", target: nil, action: nil)
  private let dismiss = NSButton(title: "Dismiss", target: nil, action: nil)
  private var action: (() -> Bool)?
  var isOffered: Bool { action != nil && !isHidden }
  var onDismiss: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    isHidden = true
    label.font = NSFont.systemFont(ofSize: 11)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for button in [resume, dismiss] {
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.font = NSFont.systemFont(ofSize: 11)
      button.target = self
    }
    resume.action = #selector(resumeClicked(_:))
    dismiss.action = #selector(dismissClicked(_:))
    let stack = NSStackView(views: [label, resume, dismiss])
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    setAccessibilityRole(.group)
    setAccessibilityLabel("Recovered program")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  func offer(label name: String, exact: Bool, warned: Bool, action: @escaping () -> Bool) {
    let guess = exact ? "" : " · most recent in this directory"
    let warning = warned ? " · previously requested broad permissions" : ""
    label.stringValue = "Was running: \(name)\(guess)\(warning)"
    label.toolTip = label.stringValue
    resume.setAccessibilityLabel(exact ? "Resume \(name)" : "Resume most recent \(name) in this directory")
    self.action = action
    isHidden = false
  }
  @discardableResult func resumeIfOffered() -> Bool {
    guard isOffered, let action, action() else { return false }
    clear()
    return true
  }
  private func clear() { action = nil; isHidden = true; onDismiss?() }
  @objc private func resumeClicked(_ sender: Any?) { resumeIfOffered() }
  @objc private func dismissClicked(_ sender: Any?) { clear() }
}

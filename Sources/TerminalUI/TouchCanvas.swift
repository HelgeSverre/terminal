#if os(iOS)
import TerminalEngine
import TerminalHost
import UIKit

/// The terminal view on iOS: a session drawn with Metal, typed into with
/// the on-screen or a hardware keyboard, scrolled with a finger.
///
/// iOS starts no processes, so its session runs over a `TerminalTransport`
/// (an SSH channel, say). Tap the view to bring up the keyboard.
public final class TerminalCanvasView: UIView, UIKeyInput {
  public let session: TerminalSession
  private let rendering: TerminalRendering?
  private var surface: TerminalRendering.SurfaceLease?
  private var configuration: TerminalViewConfiguration
  private var snapshot: TerminalSnapshot?
  private var cellWidth = 1, cellHeight = 1
  private var scrollRemainder: CGFloat = 0
  /// Called with the title the program set.
  public var onTitle: ((String) -> Void)?

  public override class var layerClass: AnyClass { CAMetalLayer.self }

  /// Without `rendering` the view draws nothing.
  public init(frame: CGRect, session: TerminalSession, rendering: TerminalRendering?,
              configuration: TerminalViewConfiguration = TerminalViewConfiguration()) {
    self.session = session
    self.rendering = rendering
    self.configuration = configuration
    super.init(frame: frame)
    session.attachView()
    session.configure(configuration.session)
    isOpaque = true
    backgroundColor = .black
    if let layer = layer as? CAMetalLayer, let rendering { surface = rendering.attach(layer) }
    session.onSnapshot = { [weak self] value in
      guard let self else { return }
      self.snapshot = value
      self.onTitle?(value.title)
      self.redraw()
    }
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    pan.maximumNumberOfTouches = 1
    addGestureRecognizer(pan)
    isAccessibilityElement = true
    accessibilityLabel = "Terminal"
    accessibilityTraits = .allowsDirectInteraction
  }
  public required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  deinit {
    if let surface { rendering?.detach(surface) }
    let session = session
    MainActor.assumeIsolated { session.detachView() }
  }

  /// Changes the configuration of a running view.
  public func apply(_ configuration: TerminalViewConfiguration) {
    self.configuration = configuration
    session.configure(configuration.session)
    updateGeometry()
  }

  // MARK: Geometry and drawing

  private var scale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
  private var insetPixels: Int { Int((min(200, max(0, configuration.contentInset)) * scale).rounded()) }
  private func updateMetrics() {
    let font = TerminalFont.core(size: configuration.fontSize, family: configuration.fontFamily)
    var glyph = CGGlyph(0)
    var character = UniChar(77)   // M
    CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    cellWidth = max(1, Int(ceil(advance.width * scale)))
    cellHeight = max(1, Int(ceil((CTFontGetAscent(font) + CTFontGetDescent(font) + 3) * scale)))
  }
  /// The grid the view's bounds hold, or nil while it is too small.
  public var gridSize: (columns: Int, rows: Int)? {
    guard bounds.width > 16, bounds.height > 16 else { return nil }
    return (max(1, min(4096, Int((bounds.width * scale - CGFloat(2 * insetPixels)) / CGFloat(cellWidth)))),
            max(1, min(4096, Int((bounds.height * scale - CGFloat(2 * insetPixels)) / CGFloat(cellHeight)))))
  }
  /// The view size, in points, that holds `columns` by `rows` cells.
  public func contentSize(columns: Int, rows: Int) -> CGSize {
    updateMetrics()
    return CGSize(width: CGFloat(columns * cellWidth + 2 * insetPixels) / scale,
                  height: CGFloat(rows * cellHeight + 2 * insetPixels) / scale)
  }
  /// The text on screen, one line per row, without trailing spaces.
  public var visibleText: String {
    guard let snapshot else { return "" }
    return snapshot.rows.map { row in
      var line = row.cells.map { $0.kind == "Continuation" ? "" : ($0.text.isEmpty ? " " : $0.text) }.joined()
      while line.hasSuffix(" ") { line.removeLast() }
      return line
    }.joined(separator: "\n")
  }
  public override func layoutSubviews() {
    super.layoutSubviews()
    updateGeometry()
  }
  public override func didMoveToWindow() {
    super.didMoveToWindow()
    updateGeometry()
  }
  private func updateGeometry() {
    guard bounds.width > 16, bounds.height > 16 else { return }
    updateMetrics()
    if let layer = layer as? CAMetalLayer {
      layer.contentsScale = scale
      layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    guard let (columns, rows) = gridSize else { return }
    rendering?.prewarm(cellWidth: cellWidth, cellHeight: cellHeight, fontSize: configuration.fontSize * scale,
                       family: configuration.fontFamily)
    session.resize(cols: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    redraw()
  }
  private func redraw() {
    guard let snapshot, let surface, window != nil, !isHidden else { return }
    rendering?.request(surface, latest: RenderRequest(
      snapshot: snapshot, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
      inset: insetPixels, cellWidth: cellWidth, cellHeight: cellHeight, fontSize: configuration.fontSize * scale,
      focused: isFirstResponder, marked: "", linkUnderline: [], colors: configuration.session.colors,
      fontFamily: configuration.fontFamily, ligatures: configuration.ligatures))
  }

  // MARK: Touch

  @objc private func tapped() { _ = becomeFirstResponder() }
  @objc private func panned(_ gesture: UIPanGestureRecognizer) {
    let lineHeight = CGFloat(cellHeight) / scale
    scrollRemainder += gesture.translation(in: self).y
    gesture.setTranslation(.zero, in: self)
    let lines = Int(scrollRemainder / lineHeight)
    guard lines != 0 else { return }
    scrollRemainder -= CGFloat(lines) * lineHeight
    // A finger moving down shows older output.
    session.scroll(lines)
  }

  // MARK: Keyboard

  public override var canBecomeFirstResponder: Bool { true }
  public override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    redraw()
    return accepted
  }
  public override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    redraw()
    return accepted
  }
  public var hasText: Bool { true }
  public func insertText(_ text: String) {
    if text == "\n" { session.send(.enter) } else { session.send(text: text) }
  }
  public func deleteBackward() { session.send(.backspace) }
  public var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
  public var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
  public var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
  public var smartDashesType: UITextSmartDashesType { get { .no } set {} }
  public var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
  public var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }

  /// A hardware keyboard's keys that type no text, and Control or Option
  /// with a letter, go to the program encoded; everything else arrives as
  /// text through `insertText`.
  public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var unhandled = Set<UIPress>()
    for press in presses {
      guard let key = press.key, send(key) else { unhandled.insert(press); continue }
    }
    if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
  }
  private func send(_ key: UIKey) -> Bool {
    var modifiers: TerminalKeyModifiers = []
    if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
    if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
    if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
    let named: [UIKeyboardHIDUsage: TerminalKey] = [
      .keyboardUpArrow: .up, .keyboardDownArrow: .down, .keyboardLeftArrow: .left, .keyboardRightArrow: .right,
      .keyboardHome: .home, .keyboardEnd: .end, .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown,
      .keyboardDeleteForward: .forwardDelete, .keyboardEscape: .escape, .keyboardTab: .tab,
      .keyboardF1: .function(1), .keyboardF2: .function(2), .keyboardF3: .function(3), .keyboardF4: .function(4),
      .keyboardF5: .function(5), .keyboardF6: .function(6), .keyboardF7: .function(7), .keyboardF8: .function(8),
      .keyboardF9: .function(9), .keyboardF10: .function(10), .keyboardF11: .function(11), .keyboardF12: .function(12),
    ]
    if let terminalKey = named[key.keyCode] { return session.send(terminalKey, modifiers: modifiers) }
    if modifiers.contains(.control) || modifiers.contains(.option),
       let character = key.charactersIgnoringModifiers.lowercased().first {
      return session.send(.character(character), modifiers: modifiers)
    }
    return false
  }
}
#endif

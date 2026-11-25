#if os(iOS)
import TerminalEngine
import TerminalHost
import UIKit

/// The terminal view on iOS: a session drawn with Metal, typed into with
/// the on-screen or a hardware keyboard, scrolled with a finger.
///
/// iOS starts no processes, so its session runs over a `TerminalTransport`
/// (an SSH channel, say). Tap the view to bring up the keyboard.
public final class TerminalCanvasView: UIView, UITextInput {
  public let session: TerminalSession
  private let rendering: TerminalRendering?
  private var surface: TerminalRendering.SurfaceLease?
  private var configuration: TerminalViewConfiguration
  var snapshot: TerminalSnapshot?
  var cellWidth = 1, cellHeight = 1
  let composition = TouchComposition()
  public weak var inputDelegate: UITextInputDelegate?
  public var markedTextStyle: [NSAttributedString.Key: Any]?
  public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
  var heldKeys: [UIKeyboardHIDUsage: TerminalKeyEvent] = [:]
  var interpretingKey: UIKey?
  var selecting = false
  var findController: TouchFindController?
  var clipboardRevision: UInt64 = 0
  private var scrollRemainder: CGFloat = 0
  private let blinkWake = BlinkWake()
  private var accessibilityDirty = true
  private var cachedAccessibilityElements: [UIAccessibilityElement]?
  /// Called with the title the program set.
  public var onTitle: ((String) -> Void)?
  /// Return true when the host opened the validated link.
  public var onOpenLink: ((URL) -> Bool)?

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
      if let previous = self.snapshot,
        previous.selectionPresentation?.documentGeneration != value.selectionPresentation?.documentGeneration
          || previous.alternate != value.alternate || previous.geometry_epoch != value.geometry_epoch
      {
        // Output revisions are expected during composition. Only replacing
        // its document, active screen or geometry invalidates the preedit.
        if !self.composition.text.isEmpty { self.cancelComposition() }
      }
      self.snapshot = value
      self.accessibilityDirty = true
      self.onTitle?(value.title)
      self.redraw()
    }
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(selected(_:))))
    let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    pan.maximumNumberOfTouches = 1
    addGestureRecognizer(pan)
    isAccessibilityElement = false
    accessibilityLabel = "Terminal"
    NotificationCenter.default.addObserver(self, selector: #selector(suspendInput), name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(resumeDrawing), name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  public required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  deinit {
    NotificationCenter.default.removeObserver(self)
    blinkWake.cancel()
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

  var scale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
  var insetPixels: Int { Int((min(200, max(0, configuration.contentInset)) * scale).rounded()) }
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
    accessibilityDirty = true
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
  func redraw() {
    guard let snapshot, let surface, window != nil, window?.isHidden == false, !isHidden,
          (window?.windowScene?.activationState ?? .foregroundActive) == .foregroundActive else { scheduleBlink(nil); return }
    let blink = TerminalBlinkPresentation(now: CACurrentMediaTime(), cursorShape: snapshot.cursor.shape,
      cursor: snapshot.cursor.visible && snapshot.following_tail && isFirstResponder, text: snapshot.hasBlinkingText)
    scheduleBlink(blink.nextDeadline)
    rendering?.request(surface, latest: RenderRequest(
      snapshot: snapshot, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
      inset: insetPixels, cellWidth: cellWidth, cellHeight: cellHeight, fontSize: configuration.fontSize * scale,
      focused: isFirstResponder, marked: composition.text, linkUnderline: [], colors: configuration.session.colors,
      fontFamily: configuration.fontFamily, ligatures: configuration.ligatures,
      backingScale: max(1, Int(scale.rounded())), cursorVisible: blink.cursorVisible,
      textVisible: blink.textVisible, preedit: preeditPresentation))
  }
  private func scheduleBlink(_ deadline: TimeInterval?) {
    blinkWake.schedule(deadline, now: CACurrentMediaTime()) { [weak self] in self?.redraw() }
  }

  // MARK: Touch

  @objc private func tapped(_ gesture: UITapGestureRecognizer) {
    _ = becomeFirstResponder()
    if let index = gridIndex(at: gesture.location(in: self)),
       let activation = snapshot.flatMap({ VisibleLinkProjection(snapshot: $0).occurrence(atGrid: index)?.activation }) {
      activateLink(activation)
    }
  }
  @objc private func panned(_ gesture: UIPanGestureRecognizer) {
    guard !selecting else { gesture.setTranslation(.zero, in: self); return }
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
    if accepted {
      suspendInput()
    }
    redraw()
    return accepted
  }
  @objc private func suspendInput() {
    cancelComposition()
    for event in heldKeys.values { _ = session.input(event.released) }
    heldKeys.removeAll()
    scheduleBlink(nil)
  }
  @objc private func resumeDrawing() { redraw() }
  public var hasText: Bool { true }
  public func insertText(_ text: String) {
    let wasComposing = !composition.text.isEmpty
    cancelComposition()
    if let key = interpretingKey, !wasComposing {
      let event = TouchHardwareInput.mapped(key, text: text, event: heldKeys[key.keyCode] == nil ? 0 : 1)
      if session.input(event) { heldKeys[key.keyCode] = event }
    } else if text == "\n" { session.send(.enter) } else { session.send(text: text) }
  }
  public func deleteBackward() {
    if !composition.text.isEmpty { changeComposition { composition.deleteBackward() } }
    else { session.send(.backspace) }
  }
  public var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
  public var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
  public var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
  public var smartDashesType: UITextSmartDashesType { get { .no } set {} }
  public var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
  public var keyboardType: UIKeyboardType { get { .default } set {} }

  /// A hardware keyboard's keys that type no text, and Control or Option
  /// with a letter, go to the program encoded; everything else arrives as
  /// text through `insertText`.
  public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses {
      guard let key = press.key else { super.pressesBegan([press], with: event); continue }
      if composition.text.isEmpty, TouchHardwareInput.handles(key, optionSendsEscape: configuration.optionSendsEscape) {
        let mapped = TouchHardwareInput.mapped(key, event: heldKeys[key.keyCode] == nil ? 0 : 1)
        if session.input(mapped) { heldKeys[key.keyCode] = mapped }
      } else {
        interpretingKey = key
        super.pressesBegan([press], with: event)
        interpretingKey = nil
      }
    }
  }
  public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses {
      if let key = press.key, let held = heldKeys.removeValue(forKey: key.keyCode) {
        let release = TouchHardwareInput.mapped(key, text: "", event: 2)
        _ = session.input(TerminalKeyEvent(text: "", logical: held.logical, shifted: held.shifted,
          baseLayout: held.baseLayout, legacyText: held.legacyText, key: held.key,
          modifiers: release.modifiers, event: 2))
      } else { super.pressesEnded([press], with: event) }
    }
  }
  public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { pressesEnded(presses, with: event) }

  public override var accessibilityElements: [Any]? {
    get {
      if accessibilityDirty || cachedAccessibilityElements == nil {
        cachedAccessibilityElements = buildAccessibilityElements()
        accessibilityDirty = false
      }
      return cachedAccessibilityElements
    }
    set {
      cachedAccessibilityElements = newValue as? [UIAccessibilityElement]
      accessibilityDirty = false
    }
  }
}
#endif

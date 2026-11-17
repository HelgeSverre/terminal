#if os(iOS)
import TerminalEngine
import TerminalHost
import UIKit

extension TerminalCanvasView {
  public override var keyCommands: [UIKeyCommand]? {
    [UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:))),
     UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))),
     UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:))),
     UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findFromKeyboard))]
  }
  @objc private func findFromKeyboard() { showFind() }
  func gridIndex(at point: CGPoint) -> Int? {
    guard let snapshot else { return nil }
    let x = point.x * scale - CGFloat(insetPixels), y = point.y * scale - CGFloat(insetPixels)
    guard x >= 0, y >= 0 else { return nil }
    let column = Int(x / CGFloat(cellWidth)), row = Int(y / CGFloat(cellHeight))
    guard row < snapshot.rows.count, column < snapshot.cols else { return nil }
    return row * snapshot.cols + column
  }
  @objc func selected(_ gesture: UILongPressGestureRecognizer) {
    if gesture.state == .ended || gesture.state == .cancelled {
      guard selecting else { return }
      _ = session.selection(.commit); selecting = false
      let menu = UIEditMenuInteraction(delegate: self)
      addInteraction(menu)
      menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: gesture.location(in: self)))
      return
    }
    guard let snapshot, let grid = gridIndex(at: gesture.location(in: self)),
          let hit = snapshot.selectionHit(row: grid / snapshot.cols, boundary: grid % snapshot.cols) else { return }
    switch gesture.state {
    case .began:
      _ = becomeFirstResponder()
      selecting = session.selection(.begin(hit, granularity: .word))
    case .changed: if selecting { _ = session.selection(.extend(hit)) }
    default: break
    }
  }
  public var hasSelection: Bool { snapshot.map { $0.selection.phase != .none } ?? false }
  public func selectedText(_ completion: @escaping @MainActor (String?) -> Void) {
    guard let snapshot, hasSelection else { completion(nil); return }
    let admitted = session.selection(.copy(expectedSelectionRevision: snapshot.selection.revision)) { result in
      if case .success(let text) = result { completion(text) } else { completion(nil) }
    }
    if !admitted { completion(nil) }
  }
  public func clearSelection() { _ = session.selection(.clear) }
  public override func copy(_ sender: Any?) {
    clipboardRevision &+= 1
    let revision = clipboardRevision, changeCount = UIPasteboard.general.changeCount
    selectedText { [weak self] text in
      guard let self, clipboardRevision == revision, UIPasteboard.general.changeCount == changeCount,
            let text else { return }
      UIPasteboard.general.string = text
    }
  }
  public override func paste(_ sender: Any?) {
    if let text = UIPasteboard.general.string { _ = session.paste(text) }
  }
  public override func selectAll(_ sender: Any?) {
    guard let snapshot, let first = snapshot.selectionHit(row: 0, boundary: 0),
          let last = snapshot.selectionHit(row: snapshot.rows.count - 1, boundary: snapshot.cols) else { return }
    _ = session.selection(.range(start: first, end: last, mode: .linear))
  }
  public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(findFromKeyboard) { return true }
    if action == #selector(copy(_:)) { return hasSelection }
    if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
    if action == #selector(selectAll(_:)) { return snapshot != nil }
    return super.canPerformAction(action, withSender: sender)
  }
  func activateLink(_ activation: VisibleLinkProjection.Activation) {
    _ = session.activateLink(activation) { [weak self] result in
      guard let self, case .success(let target) = result else { return }
      if onOpenLink?(target) != true { UIApplication.shared.open(target) }
    }
  }
  /// Shows an inline search bar. Search covers retained history as well as the screen.
  public func showFind() {
    if findController == nil {
      let find = TouchFindController(canvas: self)
      findController = find
      addSubview(find)
      find.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        find.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
        find.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        find.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      ])
    }
    findController?.field.becomeFirstResponder()
  }
  public func hideFind() {
    session.searchClear()
    findController?.removeFromSuperview()
    findController = nil
    _ = becomeFirstResponder()
  }
}

extension TerminalCanvasView: UIEditMenuInteractionDelegate {
  public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                  suggestedActions: [UIMenuElement]) -> UIMenu? {
    var actions: [UIMenuElement] = [
      UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(nil) },
      UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste(nil) },
      UIAction(title: "Select All") { [weak self] _ in self?.selectAll(nil) },
    ]
    actions.append(UIAction(title: "Find", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.showFind() })
    if let index = gridIndex(at: configuration.sourcePoint),
       let link = snapshot.flatMap({ VisibleLinkProjection(snapshot: $0).occurrence(atGrid: index) }),
       let activation = link.activation {
      actions.append(UIAction(title: "Open \(link.target.absoluteString)") { [weak self] _ in self?.activateLink(activation) })
    }
    return UIMenu(children: actions)
  }
  public func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                                  animator: UIEditMenuInteractionAnimating) { removeInteraction(interaction) }
}

final class TouchFindController: UIStackView, UITextFieldDelegate {
  weak var canvas: TerminalCanvasView?
  let field = UITextField()
  let result = UILabel()
  init(canvas: TerminalCanvasView) {
    self.canvas = canvas
    super.init(frame: .zero)
    axis = .horizontal; spacing = 6; alignment = .center
    isLayoutMarginsRelativeArrangement = true
    directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    backgroundColor = .secondarySystemBackground
    field.placeholder = "Find in terminal"; field.borderStyle = .roundedRect
    field.delegate = self; field.returnKeyType = .search
    field.autocorrectionType = .no; field.autocapitalizationType = .none
    field.addTarget(self, action: #selector(search), for: .editingChanged)
    addArrangedSubview(field); addArrangedSubview(result)
    for (title, action) in [("Previous", #selector(previous)), ("Next", #selector(next)), ("Done", #selector(done))] {
      let button = UIButton(type: .system)
      button.setTitle(title, for: .normal); button.addTarget(self, action: action, for: .touchUpInside)
      addArrangedSubview(button)
    }
  }
  required init(coder: NSCoder) { fatalError("init(coder:) unsupported") }
  @objc func search() {
    canvas?.session.search(field.text ?? "") { [weak self] _, position in
      self?.result.text = position.map { "\($0.index)/\($0.total)" } ?? "0"
    }
  }
  @objc func previous() { navigate(older: true) }
  @objc func next() { navigate(older: false) }
  func navigate(older: Bool) {
    canvas?.session.searchNavigate(older: older) { [weak self] position in
      self?.result.text = position.map { "\($0.index)/\($0.total)" } ?? "0"
    }
  }
  @objc func done() { canvas?.hideFind() }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool { search(); return true }
}
#endif

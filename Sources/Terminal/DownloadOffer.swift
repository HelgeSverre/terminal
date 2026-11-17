import AppKit
import TerminalHost

/// The app retains metadata until a person chooses a destination. The host
/// owns the bounded payload, and invalidates it when the session closes.
@MainActor protocol PaneDownloadRequest: AnyObject {
  var id: UUID { get }
  var suggestedFilename: String { get }
  var byteCount: Int { get }
  var isAvailable: Bool { get }
  func takeData(_ completion: @escaping @MainActor (Data?) -> Void)
  func dismiss()
}

extension TerminalDownloadRequest: PaneDownloadRequest {}

enum DownloadFilename {
  /// A suggestion is a basename, never an output-supplied destination. Remove
  /// path syntax, hidden-file prefixes and text controls before showing it.
  static func sanitized(_ suggested: String) -> String {
    let basename = suggested.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
    var result = ""
    var bytes = 0
    for scalar in basename.precomposedStringWithCanonicalMapping.unicodeScalars {
      guard scalar.value >= 32, scalar.value != 127, scalar != ":",
        scalar.properties.generalCategory != .control,
        scalar.properties.generalCategory != .format,
        scalar.properties.generalCategory != .lineSeparator,
        scalar.properties.generalCategory != .paragraphSeparator,
        !(0x202a...0x202e).contains(scalar.value), !(0x2066...0x2069).contains(scalar.value) else { continue }
      let character = String(scalar)
      guard bytes + character.utf8.count <= 180 else { break }
      result.append(character)
      bytes += character.utf8.count
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    while result.first == "." { result.removeFirst() }
    return result.isEmpty ? "Download" : result
  }
}

@MainActor protocol DownloadSavePresenting: AnyObject {
  func present(in window: NSWindow?, suggestedName: String, completion: @escaping @MainActor (URL?) -> Void)
  func cancel()
}

@MainActor final class NativeDownloadSavePanel: DownloadSavePresenting {
  private var panel: NSSavePanel?
  func present(in window: NSWindow?, suggestedName: String, completion: @escaping @MainActor (URL?) -> Void) {
    guard let window else { completion(nil); return }
    let panel = NSSavePanel()
    self.panel = panel
    panel.title = "Save Download"
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: window) { [weak self, weak panel] response in
      self?.panel = nil
      completion(response == .OK ? panel?.url : nil)
    }
  }
  func cancel() { panel?.cancel(nil); panel = nil }
}

/// One offer across the app, so output from many panes cannot accumulate a
/// pending user action per session. Only an identifier lives in this gate.
@MainActor final class DownloadOfferAdmission {
  static let shared = DownloadOfferAdmission()
  private var holder: UUID?
  private var lastOffer: TimeInterval?
  func admit(_ id: UUID, now: TimeInterval) -> Bool {
    guard holder == nil, now.isFinite, lastOffer.map({ now - $0 >= 1 }) ?? true else { return false }
    holder = id
    lastOffer = now
    return true
  }
  func release(_ id: UUID) { if holder == id { holder = nil } }
}

@MainActor final class DownloadOfferController {
  static let maximumBytes = 32 * 1024 * 1024
  enum Presentation: Equatable {
    case offered(name: String, bytes: Int, saving: Bool)
    case failed
  }
  typealias Writer = (Data, URL, @escaping @MainActor (Error?) -> Void) -> Void
  private let presenter: DownloadSavePresenting
  private let admission: DownloadOfferAdmission
  private let writer: Writer
  private var request: PaneDownloadRequest?
  private var operation: UUID?
  private(set) var presentation: Presentation? { didSet { onChange?(presentation) } }
  var onChange: ((Presentation?) -> Void)?

  init(admission: DownloadOfferAdmission? = nil, presenter: DownloadSavePresenting? = nil, writer: Writer? = nil) {
    self.admission = admission ?? .shared
    self.presenter = presenter ?? NativeDownloadSavePanel()
    self.writer = writer ?? Self.write
  }

  @discardableResult func offer(_ candidate: PaneDownloadRequest, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    guard request == nil, operation == nil,
      candidate.isAvailable, (0...Self.maximumBytes).contains(candidate.byteCount),
      admission.admit(candidate.id, now: now) else {
      candidate.dismiss()
      return false
    }
    request = candidate
    presentation = .offered(name: DownloadFilename.sanitized(candidate.suggestedFilename), bytes: candidate.byteCount, saving: false)
    return true
  }

  /// Only the Save button calls this. Opening the panel does not copy payload
  /// bytes out of the host, and its cancellation releases the request.
  func save(in window: NSWindow?) {
    guard let request, operation == nil else { return }
    guard request.isAvailable else { dismiss(); return }
    let token = UUID()
    operation = token
    let name = DownloadFilename.sanitized(request.suggestedFilename)
    presentation = .offered(name: name, bytes: request.byteCount, saving: true)
    presenter.present(in: window, suggestedName: name) { [weak self] destination in
      guard let self, operation == token, let request = self.request else { return }
      guard let destination else { dismiss(); return }
      request.takeData { [weak self] data in
        guard let self, operation == token else { return }
        guard let data, data.count == request.byteCount, data.count <= Self.maximumBytes else {
          finish(token: token, failed: true)
          return
        }
        writer(data, destination) { [weak self] error in self?.finish(token: token, failed: error != nil) }
      }
    }
  }

  func dismiss() {
    operation = nil
    let previous = request
    request = nil
    presentation = nil
    if let previous { admission.release(previous.id) }
    previous?.dismiss()
    presenter.cancel()
  }

  private func finish(token: UUID, failed: Bool) {
    guard operation == token else { return }
    operation = nil
    if let request { admission.release(request.id) }
    request?.dismiss()
    request = nil
    presentation = failed ? .failed : nil
  }

  private static func write(_ data: Data, to destination: URL, completion: @escaping @MainActor (Error?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let failure: Error?
      do { try data.write(to: destination, options: .atomic); failure = nil }
      catch { failure = error }
      DispatchQueue.main.async { completion(failure) }
    }
  }
}

/// A compact bottom overlay leaves the grid and existing find/Resume bars
/// unchanged. It never takes focus merely because output offered a file.
@MainActor final class TerminalDownloadOfferView: NSView {
  static let height: CGFloat = 38
  private let controller = DownloadOfferController()
  private let saveButton = NSButton(title: "Save Download…", target: nil, action: nil)
  private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    isHidden = true
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.lineBreakMode = .byTruncatingMiddle
    saveButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    saveButton.setAccessibilityIdentifier("no.helgesverre.terminal.download.save")
    dismissButton.target = self
    dismissButton.action = #selector(dismiss)
    dismissButton.setAccessibilityIdentifier("no.helgesverre.terminal.download.dismiss")
    let row = NSStackView(views: [saveButton, dismissButton])
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    controller.onChange = { [weak self] state in self?.update(state) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

  @discardableResult func offer(_ request: PaneDownloadRequest) -> Bool { controller.offer(request) }
  @objc func dismiss() { controller.dismiss() }
  @objc private func save() { controller.save(in: window) }
  private func update(_ state: DownloadOfferController.Presentation?) {
    isHidden = state == nil
    switch state {
    case let .offered(name, bytes, saving):
      saveButton.title = saving ? "Saving…" : "Save \(name)…"
      saveButton.toolTip = "\(name) · \(bytes.formatted()) bytes"
      saveButton.isEnabled = !saving
    case .failed:
      saveButton.title = "Could not save download"
      saveButton.isEnabled = false
    case nil: break
    }
  }
}

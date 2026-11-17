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

/// One pane's offers. A file that arrives while another is offered waits its
/// turn. Saving a file, or cancelling its Save panel, moves on to the next;
/// Dismiss refuses everything that is waiting. The engine holds the payloads
/// and admits at most four files and 32 MiB a terminal, which bounds this.
@MainActor final class DownloadOfferController {
  static let maximumBytes = 32 * 1024 * 1024
  static let maximumWaiting = 8
  enum Presentation: Equatable {
    case offered(name: String, bytes: Int, saving: Bool)
    case failed
  }
  typealias Writer = (Data, URL, @escaping @MainActor (Error?) -> Void) -> Void
  private let presenter: DownloadSavePresenting
  private let writer: Writer
  private var request: PaneDownloadRequest?
  private var waiting: [PaneDownloadRequest] = []
  private var operation: UUID?
  private(set) var presentation: Presentation? { didSet { onChange?(presentation) } }
  /// Offers behind the one shown.
  var waitingCount: Int { waiting.count }
  var onChange: ((Presentation?) -> Void)?

  init(presenter: DownloadSavePresenting? = nil, writer: Writer? = nil) {
    self.presenter = presenter ?? NativeDownloadSavePanel()
    self.writer = writer ?? Self.write
  }

  /// False when the offer is refused: it is unavailable, too large, or the
  /// queue is full.
  @discardableResult func offer(_ candidate: PaneDownloadRequest) -> Bool {
    guard candidate.isAvailable, (0...Self.maximumBytes).contains(candidate.byteCount),
      waiting.count < Self.maximumWaiting else {
      candidate.dismiss()
      return false
    }
    waiting.append(candidate)
    // A failure notice stays until it is acknowledged or nothing else waits.
    if request == nil, presentation == nil || waiting.count == 1 { showNext() } else { onChange?(presentation) }
    return true
  }

  /// The Dismiss button: acknowledges a failure notice, otherwise refuses
  /// the offered file and every file waiting behind it.
  func acknowledge() {
    if presentation == .failed, request == nil { showNext() } else { dismiss() }
  }

  private func showNext() {
    while !waiting.isEmpty {
      let next = waiting.removeFirst()
      guard next.isAvailable else { next.dismiss(); continue }
      request = next
      presentation = .offered(name: DownloadFilename.sanitized(next.suggestedFilename), bytes: next.byteCount, saving: false)
      return
    }
    presentation = nil
  }

  /// Only the Save button calls this. Opening the panel does not copy payload
  /// bytes out of the host, and its cancellation releases the request.
  func save(in window: NSWindow?) {
    guard let request, operation == nil else { return }
    guard request.isAvailable else { release(); showNext(); return }
    let token = UUID()
    operation = token
    let name = DownloadFilename.sanitized(request.suggestedFilename)
    presentation = .offered(name: name, bytes: request.byteCount, saving: true)
    presenter.present(in: window, suggestedName: name) { [weak self] destination in
      guard let self, operation == token, let request = self.request else { return }
      guard let destination else { release(); showNext(); return }
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

  /// Refuses the offered file and everything waiting. Closing a pane calls
  /// this too.
  func dismiss() {
    let refused = waiting
    waiting = []
    release()
    presentation = nil
    for request in refused { request.dismiss() }
    presenter.cancel()
  }

  private func release() {
    operation = nil
    let previous = request
    request = nil
    previous?.dismiss()
  }

  private func finish(token: UUID, failed: Bool) {
    guard operation == token else { return }
    release()
    if failed { presentation = .failed } else { showNext() }
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
    dismissButton.action = #selector(acknowledge)
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
  func dismiss() { controller.dismiss() }
  @objc private func acknowledge() { controller.acknowledge() }
  @objc private func save() { controller.save(in: window) }
  private func update(_ state: DownloadOfferController.Presentation?) {
    isHidden = state == nil
    let waiting = controller.waitingCount
    switch state {
    case let .offered(name, bytes, saving):
      saveButton.title = saving ? "Saving…" : "Save \(name)…"
      saveButton.toolTip = "\(name) · \(bytes.formatted()) bytes" + (waiting > 0 ? " · \(waiting) more waiting" : "")
      saveButton.isEnabled = !saving
      dismissButton.title = waiting > 0 ? "Dismiss All (\(waiting + 1))" : "Dismiss"
    case .failed:
      saveButton.title = "Could not save download"
      saveButton.toolTip = nil
      saveButton.isEnabled = false
      dismissButton.title = waiting > 0 ? "Continue (\(waiting))" : "Dismiss"
    case nil: break
    }
  }
}

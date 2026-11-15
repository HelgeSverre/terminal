#if canImport(SwiftUI)
import SwiftUI
import TerminalHost

/// A terminal for SwiftUI, on macOS and iOS: the session drawn and typed
/// into. Give each `TerminalView` its own session; one renderer serves them all.
///
/// ```swift
/// TerminalView(session: session, rendering: rendering)
///   .onTerminalTitle { title in self.title = title }
/// ```
public struct TerminalView {
  let session: TerminalSession
  let rendering: TerminalRendering?
  let configuration: TerminalViewConfiguration
  var onTitle: ((String) -> Void)?
  #if os(macOS)
  let clipboard: ClipboardAccess?
  public init(session: TerminalSession, rendering: TerminalRendering?, clipboard: ClipboardAccess? = nil,
              configuration: TerminalViewConfiguration = TerminalViewConfiguration()) {
    self.session = session; self.rendering = rendering; self.clipboard = clipboard; self.configuration = configuration
  }
  #else
  public init(session: TerminalSession, rendering: TerminalRendering?,
              configuration: TerminalViewConfiguration = TerminalViewConfiguration()) {
    self.session = session; self.rendering = rendering; self.configuration = configuration
  }
  #endif
  /// Called with the title the program sets.
  public func onTerminalTitle(_ handler: @escaping (String) -> Void) -> TerminalView {
    var copy = self
    copy.onTitle = handler
    return copy
  }
  @MainActor fileprivate func make() -> TerminalCanvasView {
    #if os(macOS)
    let view = TerminalCanvasView(frame: .zero, session: session, rendering: rendering, clipboard: clipboard,
                                  configuration: configuration)
    #else
    let view = TerminalCanvasView(frame: .zero, session: session, rendering: rendering, configuration: configuration)
    #endif
    view.onTitle = onTitle
    return view
  }
  @MainActor fileprivate func update(_ view: TerminalCanvasView) {
    view.onTitle = onTitle
    view.apply(configuration)
  }
}

#if os(macOS)
extension TerminalView: NSViewRepresentable {
  public func makeNSView(context: Context) -> TerminalCanvasView { make() }
  public func updateNSView(_ view: TerminalCanvasView, context: Context) { update(view) }
}
#else
extension TerminalView: UIViewRepresentable {
  public func makeUIView(context: Context) -> TerminalCanvasView { make() }
  public func updateUIView(_ view: TerminalCanvasView, context: Context) { update(view) }
}
#endif
#endif

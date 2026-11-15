#if os(iOS)
import Testing
import UIKit
import SwiftUI
import iOSCheck
import TerminalHost
import TerminalUI
import Metal
import QuartzCore
import ObjectiveC

/// The last drawable the renderer drew into, kept by swizzling the display
/// link's drawable getter, so a test can read the frame back.
nonisolated(unsafe) private var lastDrawable: MTLTexture?
private let hookDrawables: Void = {
  typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
  guard let type = NSClassFromString("CAMetalDisplayLinkUpdate"),
    let method = class_getInstanceMethod(type, NSSelectorFromString("drawable")) else { return }
  let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
  let selector = NSSelectorFromString("drawable")
  let block: @convention(block) (AnyObject) -> AnyObject? = { update in
    let drawable = original(update, selector)?.takeUnretainedValue()
    if let drawable = drawable as? CAMetalDrawable { lastDrawable = drawable.texture }
    return drawable
  }
  method_setImplementation(method, imp_implementationWithBlock(block))
}()

@MainActor struct ViewTests {
  private func wait(_ seconds: Double = 5, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    return condition()
  }
  private func window(_ view: UIView) -> UIWindow {
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
    window.rootViewController = UIViewController()
    window.rootViewController!.view.addSubview(view)
    view.frame = window.bounds
    window.makeKeyAndVisible()
    return window
  }

  @Test func theViewShowsATransportsOutputAndDrawsIt() async throws {
    _ = hookDrawables
    let rendering = try TerminalRendering()
    let replay = Replay("\u{1b}[1;31mRED\u{1b}[0m on iOS\r\n\u{1b}[42m          \u{1b}[0m\r\n$ ")
    let session = TerminalSession(transport: replay, startsAtFirstGrid: true)
    defer { session.close() }
    let view = TerminalCanvasView(frame: .zero, session: session, rendering: rendering)
    (view.layer as? CAMetalLayer)?.framebufferOnly = false
    let host = window(view)
    defer { host.isHidden = true }
    #expect(await wait { view.visibleText.contains("RED on iOS") }, "\(view.visibleText)")
    let grid = try #require(view.gridSize)
    #expect(grid.columns > 20 && grid.rows > 10, "\(grid)")

    // Typing reaches the far end, encoded.
    #expect(view.becomeFirstResponder())
    view.insertText("ls")
    view.insertText("\n")
    view.deleteBackward()
    #expect(await wait { replay.sent == "ls\r\u{7f}" }, "\(replay.sent.debugDescription)")

    // The frame on screen has the green row.
    try? await Task.sleep(for: .milliseconds(500))
    let texture = try #require(lastDrawable)
    let width = texture.width, height = min(texture.height, 400)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    // The green background of the second row, in BGRA.
    let greenPixels = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 1] > 150 && bytes[$0 + 2] < 120 && bytes[$0] < 120 }.count
    #expect(greenPixels > 1000, "\(greenPixels) green pixels")
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let frame = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let image = UIImage(cgImage: frame)
    let attachment = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TERMINAL_IOS_FRAME"]
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("terminal-ios.png").path)
    try image.pngData()?.write(to: attachment)
    print("FRAME \(attachment.path)")
  }

  @Test func swiftUIHostsTheView() async throws {
    let session = TerminalSession(transport: Replay("from SwiftUI"))
    defer { session.close() }
    var title = ""
    let controller = UIHostingController(rootView: TerminalView(session: session, rendering: try TerminalRendering())
      .onTerminalTitle { title = $0 })
    let host = window(controller.view)
    defer { host.isHidden = true }
    _ = title
    #expect(await wait { controller.view.layoutIfNeeded(); return firstTerminal(in: controller.view) != nil })
    let terminal = try #require(firstTerminal(in: controller.view))
    #expect(await wait { terminal.visibleText.contains("from SwiftUI") }, "\(terminal.visibleText)")
  }
  private func firstTerminal(in view: UIView) -> TerminalCanvasView? {
    if let terminal = view as? TerminalCanvasView { return terminal }
    for child in view.subviews { if let found = firstTerminal(in: child) { return found } }
    return nil
  }
}
#endif

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureFailure: Error { case invalid(String) }

@main struct Main {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 4, let windowID = UInt32(CommandLine.arguments[1]), let pid = Int32(CommandLine.arguments[2]) else {
      throw CaptureFailure.invalid("Usage: Capture windowID ownedPID output.png")
    }
    guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.invalid("Screen Recording unavailable") }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == pid }) else {
      throw CaptureFailure.invalid("owned window unavailable")
    }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width); configuration.height = Int(window.frame.height)
    configuration.scalesToFit = false; configuration.preservesAspectRatio = true; configuration.showsCursor = false
    configuration.capturesAudio = false; configuration.captureMicrophone = false; configuration.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw CaptureFailure.invalid("cannot encode PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.invalid("PNG write failed") }
  }
}

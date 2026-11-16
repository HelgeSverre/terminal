import AppKit
import Testing
@testable import TerminalUI

@Suite @MainActor enum LinkTargetPreviewTests {
  @Test static func showsDestinationWithoutMisleadingUserInfo() throws {
    let preview = LinkTargetPreview(frame: .zero)
    let target = try #require(URL(string: "https://github.com@actual.example/login?q=test"))
    preview.show(target, colors: .standard)
    let label = try #require(preview.subviews.first as? NSTextField)
    #expect(label.stringValue == "https://actual.example/login?q=test")
    #expect(preview.accessibilityValue() as? String == target.absoluteString)
    #expect(preview.hitTest(.zero) == nil)
  }

  @Test static func staysInsideNarrowPanesAndMovesAwayFromThePointer() throws {
    let preview = LinkTargetPreview(frame: .zero)
    preview.show(try #require(URL(string: "https://example.com/" + String(repeating: "long-path/", count: 30))),
      colors: .standard)
    let bounds = NSRect(x: 0, y: 0, width: 180, height: 120)
    preview.position(in: bounds, pointer: .zero)
    #expect(bounds.contains(preview.frame))
    #expect(preview.frame.maxY == bounds.maxY - 8)
    let pointer = NSPoint(x: preview.frame.midX, y: preview.frame.midY)
    preview.position(in: bounds, pointer: pointer)
    #expect(preview.frame.minY == 8)
    #expect(!preview.frame.contains(pointer))
  }
}

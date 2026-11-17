import AppKit
import TerminalUI

enum PaneDirection { case left, right, up, down }

struct PaneZoomState {
  let pane: TerminalCanvasView
  let presentation: TerminalPanePresentationView
  let placeholder: NSView
  let tree: PaneLayout
}

enum PaneNavigation {
  /// Edges choose the directional half-plane; edge separation favors the
  /// adjacent row/column in uneven nested splits over a distant diagonal.
  static func neighbor(from source: CGRect, candidates: [CGRect], direction: PaneDirection) -> Int? {
    let vertical = direction == .up || direction == .down
    let positive = direction == .up || direction == .right
    var best: (index: Int, score: CGFloat)?
    for (index, candidate) in candidates.enumerated() {
      let advance = vertical ? candidate.midY - source.midY : candidate.midX - source.midX
      let isForward: Bool
      if vertical {
        isForward = positive ? candidate.minY >= source.maxY - 0.5 : candidate.maxY <= source.minY + 0.5
      } else {
        isForward = positive ? candidate.minX >= source.maxX - 0.5 : candidate.maxX <= source.minX + 0.5
      }
      guard isForward else { continue }
      let separation = vertical
        ? max(0, max(source.minY - candidate.maxY, candidate.minY - source.maxY))
        : max(0, max(source.minX - candidate.maxX, candidate.minX - source.maxX))
      let crossGap = vertical
        ? max(0, max(source.minX - candidate.maxX, candidate.minX - source.maxX))
        : max(0, max(source.minY - candidate.maxY, candidate.minY - source.maxY))
      let crossCenter = vertical ? abs(source.midX - candidate.midX) : abs(source.midY - candidate.midY)
      let score = separation + crossGap * 4 + abs(advance) * 0.05 + crossCenter * 0.01
      if best == nil || score < best!.score { best = (index, score) }
    }
    return best?.index
  }
}

extension TerminalWindow {
  @objc func focusLeft(_ sender: Any?) { focusPane(direction: .left) }
  @objc func focusRight(_ sender: Any?) { focusPane(direction: .right) }
  @objc func focusUp(_ sender: Any?) { focusPane(direction: .up) }
  @objc func focusDown(_ sender: Any?) { focusPane(direction: .down) }
  private func focusPane(direction: PaneDirection) {
    endPaneZoom()
    guard let source = focusedPane, let sourceView = panePresentation(for: source), let window else { return }
    let candidates = panes.filter { $0 !== source }
    let views = candidates.compactMap { panePresentation(for: $0) }
    guard views.count == candidates.count else { return }
    let frames = views.map { $0.convert($0.bounds, to: nil) }
    guard let index = PaneNavigation.neighbor(from: sourceView.convert(sourceView.bounds, to: nil),
      candidates: frames, direction: direction) else { return }
    window.makeFirstResponder(candidates[index])
    paneDidBecomeActive(candidates[index])
    panes.forEach { $0.updateFocus() }
  }
}

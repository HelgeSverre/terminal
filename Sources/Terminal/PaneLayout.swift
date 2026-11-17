import Foundation

struct PaneID: Hashable, Codable {
  let rawValue: UUID
  init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
  var string: String { rawValue.uuidString }
}

indirect enum PaneLayout: Equatable, Codable {
  case pane(PaneID)
  case split(vertical: Bool, ratio: Double, first: PaneLayout, second: PaneLayout)

  var panes: [PaneID] {
    switch self {
    case .pane(let id): return [id]
    case .split(_, _, let first, let second): return first.panes + second.panes
    }
  }
  static func boundedRatio(_ ratio: Double) -> Double {
    ratio.isFinite ? min(1, max(0, ratio)) : 0.5
  }
}

struct PaneState: Equatable, Codable {
  var id: PaneID
  var directory: String
  var title: String
  var color: String?
}

struct WindowLayout: Equatable, Codable {
  var id: UUID
  var frame: CGRect
  var root: PaneLayout
  var activePane: PaneID
  var panes: [PaneState]
  var tabGroup: UUID
  var tabIndex: Int
  var selectedTab: Bool
  var zoomed: Bool
  var fullScreen: Bool

  static func clampedFrame(_ frame: CGRect, to screens: [CGRect]) -> CGRect {
    guard frame.origin.x.isFinite, frame.origin.y.isFinite,
      frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
      let screen = screens.max(by: { $0.intersection(frame).area < $1.intersection(frame).area })
    else { return screens.first ?? CGRect(x: 0, y: 0, width: 1000, height: 680) }
    let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
    return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
      y: min(max(frame.minY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
  }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

struct SessionLayout: Equatable, Codable {
  var version = 1
  var savedAt = Date()
  var appBuild: String
  var windows: [WindowLayout]
  var keyWindow: UUID?

  var isValid: Bool {
    guard version == 1, !windows.isEmpty, Set(windows.map(\.id)).count == windows.count else { return false }
    let ids = windows.flatMap { $0.root.panes }
    guard Set(ids).count == ids.count else { return false }
    return windows.allSatisfy { window in
      let leaves = window.root.panes
      return leaves.contains(window.activePane) && Set(leaves) == Set(window.panes.map(\.id))
        && leaves.count == window.panes.count
        && window.panes.allSatisfy { $0.directory.utf8.count <= 8192 && !$0.directory.contains("\0") }
    }
  }
}

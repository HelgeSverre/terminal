import Foundation
import TerminalInterop

// MARK: C ABI bridge. The app imports Bridge.h, so native call sites keep one
// stable C-shaped surface.

private func core(_ pointer: OpaquePointer?) -> TerminalEmulator? {
  pointer.map { Unmanaged<TerminalEmulator>.fromOpaque(UnsafeMutableRawPointer($0)).takeUnretainedValue() }
}

/// Host-only asynchronous transport. The C/headless API retains synchronous
/// completion; live sessions suspend the ordered ingress lease while I/O runs.
package enum TerminalGraphicsTransportBridge {
  package static func enable(core pointer: OpaquePointer) { core(pointer)?.enableAsynchronousGraphics() }
  package static func whenReady(core pointer: OpaquePointer, _ callback: @escaping () -> Void) -> Bool {
    core(pointer)?.whenGraphicsReady(callback) ?? false
  }
}

package enum TerminalDownloadBridge {
  package static func pending(core pointer: OpaquePointer) -> [TerminalPendingDownload] { core(pointer)?.pendingDownloads ?? [] }
  package static func resolve(core pointer: OpaquePointer, id: UInt64, take: Bool) -> TerminalDownload? {
    core(pointer)?.resolveDownload(id, take: take)
  }
  package static func takeAll(core pointer: OpaquePointer) -> [TerminalDownload] { core(pointer)?.takeDownloads() ?? [] }
}

final class TerminalSearchToken {
  // The task contains only immutable page snapshots while it is with the
  // worker. The core is consulted exclusively by fill/accept on its owner.
  @exclusivity(unchecked) var task: TerminalSearchTask
  init(_ task: TerminalSearchTask) { self.task = task }
}

package enum TerminalRecoveryBridge {
  package static func capture(core pointer: OpaquePointer, maximumBytes: Int = 16 * 1024 * 1024) -> TerminalRecoveryCapture {
    core(pointer)!.recoveryCapture(maximumBytes: maximumBytes)
  }
  package static func seed(core pointer: OpaquePointer, text: String) {
    core(pointer)!.seedRecovery(text)
  }
}

package enum TerminalHandoffBridge {
  /// False while an escape sequence, a UTF-8 character or a repeat is only
  /// partly read. A capture taken then would lose the part already read.
  package static func isAtBoundary(core pointer: OpaquePointer) -> Bool { core(pointer)!.handoffBoundary }
  package static func capture(core pointer: OpaquePointer) -> TerminalHandoff { core(pointer)!.captureHandoff() }
  /// Restores into a terminal that has read nothing yet and has the
  /// handoff's size. False when the state cannot be read; the rows are
  /// restored either way.
  @discardableResult
  package static func restore(core pointer: OpaquePointer, _ handoff: TerminalHandoff, now: UInt64) -> Bool {
    core(pointer)!.restoreHandoff(handoff, now: now)
  }
}

package func swiftTerminalCommands(_ pointer: OpaquePointer?) -> [TerminalCommandRecord] { core(pointer)?.commands() ?? [] }
package func swiftTerminalNavigateCommand(_ pointer: OpaquePointer?, older: Bool) { core(pointer)?.navigateCommand(older: older) }
// Internal Swift adapter: same owner-confined handle, no C callback or borrowed
// row/cell storage. The returned value survives later mutation and destruction.
package func swiftTerminalSnapshot(_ pointer: OpaquePointer?, scroll: Int?, now: UInt64) -> (snapshot: TerminalSnapshot?, error: String?) {
  core(pointer)?.snapshotValue(scroll: scroll, now: now) ?? (nil, nil)
}
package func swiftTerminalHistoryPage(_ pointer: OpaquePointer?, request: TerminalHistoryPageRequest) -> TerminalHistoryPage? {
  core(pointer)?.accessibilityHistoryPage(request)
}

package enum TerminalSelectionBridge {
  package static func begin(core pointer: OpaquePointer, action: TerminalSelectionAction) -> TerminalSelectionProgress {
    core(pointer)!.beginSelection(action)
  }
  package static func advance(core pointer: OpaquePointer) -> TerminalSelectionProgress { core(pointer)!.advanceSelection() }
  package static func cancel(core pointer: OpaquePointer) { core(pointer)!.cancelSelection() }
}

package enum TerminalPresentedContentBridge {
  package static func begin(core pointer: OpaquePointer, content: TerminalPresentedContent) -> TerminalPresentedContentProgress {
    core(pointer)!.beginPresentedContent(content)
  }
  package static func advance(core pointer: OpaquePointer) -> TerminalPresentedContentProgress { core(pointer)!.advancePresentedContent() }
  package static func cancel(core pointer: OpaquePointer) { core(pointer)!.cancelPresentedContent() }
}

package enum TerminalResizeBridge {
  package static func begin(core pointer: OpaquePointer, columns: Int, rows: Int,
                    cellWidth: Int, cellHeight: Int) -> TerminalResizeProgress {
    core(pointer)!.beginResize(TerminalResizeGeometry(columns: columns, rows: rows,
      cellWidth: cellWidth, cellHeight: cellHeight))
  }
  package static func advance(core pointer: OpaquePointer) -> TerminalResizeProgress { core(pointer)!.advanceResize() }
  package static func cancel(core pointer: OpaquePointer) { core(pointer)!.cancelResize() }
}

private func inputCharacter(_ scalar: UInt32) -> Character? {
  guard scalar != 0, let value = UnicodeScalar(scalar) else { return nil }
  return Character(String(value))
}

typealias BytesCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
package typealias ClipboardCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<UInt8>?, Int) -> Void
typealias SnapshotCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<TerminalCellView>?, Int, UnsafePointer<UInt8>?, Int) -> Void

@_cdecl("helge_terminal_abi_version") func swift_terminal_abi_version() -> UInt32 { 1 }
@_cdecl("helge_terminal_create") func swift_terminal_create(_ cols: UInt32, _ rows: UInt32) -> OpaquePointer? {
  guard (1...4096).contains(cols), (1...4096).contains(rows), cols <= 1_048_576 / rows else { return nil }
  return OpaquePointer(Unmanaged.passRetained(TerminalEmulator(columns: Int(cols), rows: Int(rows))).toOpaque())
}
/// Swift host configuration includes cursor/selection colors without changing
/// the layout of the version-1 C snapshot ABI.
package func swiftTerminalSetColorScheme(_ pointer: OpaquePointer?, colors: TerminalColorScheme) { core(pointer)?.setColorScheme(colors) }
package func swiftTerminalSetIdentity(_ pointer: OpaquePointer?, identity: TerminalIdentity) { core(pointer)?.setIdentity(identity) }
@_cdecl("helge_terminal_set_identity") func swift_terminal_set_identity(_ pointer: OpaquePointer?, _ name: UnsafePointer<CChar>?, _ version: UnsafePointer<CChar>?) {
  func bounded(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    var bytes: [UInt8] = []
    for index in 0..<128 {
      let byte = UInt8(bitPattern: pointer[index])
      if byte == 0 { break }
      bytes.append(byte)
    }
    return String(decoding: bytes, as: UTF8.self)
  }
  core(pointer)?.setIdentity(TerminalIdentity(name: bounded(name) ?? "HelgeTerminal", version: bounded(version)))
}
@_cdecl("helge_terminal_destroy") func swift_terminal_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<TerminalEmulator>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("helge_terminal_feed") func swift_terminal_feed(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ now: UInt64) -> Int { core(pointer)?.feed(bytes, count: count, now: now) ?? 0 }
@_cdecl("helge_terminal_resize") func swift_terminal_resize(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows)) ?? false }
@_cdecl("helge_terminal_resize_pixels") func swift_terminal_resize_pixels(_ pointer: OpaquePointer?, _ cols: UInt32, _ rows: UInt32, _ width: UInt32, _ height: UInt32) -> Bool { core(pointer)?.resize(columns: Int(cols), rows: Int(rows), cellWidth: Int(width), cellHeight: Int(height)) ?? false }
@_cdecl("helge_terminal_search_position") func swift_terminal_search_position(_ pointer: OpaquePointer?, _ position: UnsafeMutablePointer<UInt32>?, _ total: UnsafeMutablePointer<UInt32>?, _ capped: UnsafeMutablePointer<Bool>?) -> Bool {
  guard let value = core(pointer)?.searchPosition() else { return false }
  position?.pointee = UInt32(value.position); total?.pointee = UInt32(value.total); capped?.pointee = value.capped
  return true
}
@_cdecl("helge_terminal_search_navigate") func swift_terminal_search_navigate(_ pointer: OpaquePointer?, _ older: Bool, _ position: UnsafeMutablePointer<UInt32>?, _ total: UnsafeMutablePointer<UInt32>?, _ capped: UnsafeMutablePointer<Bool>?) -> Bool {
  guard let value = core(pointer)?.navigateSearch(older: older) else { return false }
  position?.pointee = UInt32(value.position); total?.pointee = UInt32(value.total); capped?.pointee = value.capped
  return true
}
@_cdecl("helge_terminal_search_clear") func swift_terminal_search_clear(_ pointer: OpaquePointer?) { core(pointer)?.clearSearch() }
@_cdecl("helge_terminal_finish") func swift_terminal_finish(_ pointer: OpaquePointer?) { core(pointer)?.finish() }
@_cdecl("helge_terminal_validate") func swift_terminal_validate(_ pointer: OpaquePointer?) -> Bool { core(pointer)?.isValid() ?? false }
@_cdecl("helge_terminal_has_work") func swift_terminal_has_work(_ pointer: OpaquePointer?) -> Bool { core(pointer)?.hasPendingWork ?? false }
@_cdecl("helge_terminal_set_colors") func swift_terminal_set_colors(_ pointer: OpaquePointer?, _ foreground: UInt32, _ background: UInt32, _ ansi: UnsafePointer<UInt32>?) {
  guard let ansi else { return }
  core(pointer)?.setColorScheme(TerminalColorScheme(foreground: foreground, background: background, ansi: Array(UnsafeBufferPointer(start: ansi, count: 16))))
}
@_cdecl("helge_terminal_set_grapheme_clustering") func swift_terminal_set_grapheme_clustering(_ pointer: OpaquePointer?, _ enabled: Bool) { core(pointer)?.setGraphemeClusteringDefault(enabled) }
@_cdecl("helge_terminal_next_frame_delay") func swift_terminal_next_frame_delay(_ pointer: OpaquePointer?, _ now: UInt64) -> Int64 {
  guard let due = core(pointer)?.nextFrameTime(now: now) else { return -1 }
  return Int64(due > now ? due - now : 0)
}
@_cdecl("helge_terminal_take_bells") func swift_terminal_take_bells(_ pointer: OpaquePointer?) -> UInt32 { core(pointer)?.takeBells() ?? 0 }
@_cdecl("helge_terminal_set_history_limit") func swift_terminal_set_history_limit(_ pointer: OpaquePointer?, _ limit: UInt32) { core(pointer)?.setHistoryLimit(Int(limit)) }
@_cdecl("helge_terminal_set_history_byte_limit") func swift_terminal_set_history_byte_limit(_ pointer: OpaquePointer?, _ limit: UInt64) { core(pointer)?.setHistoryByteLimit(limit > UInt64(Int.max) ? Int.max : Int(limit)) }
@_cdecl("helge_terminal_history_bytes") func swift_terminal_history_bytes(_ pointer: OpaquePointer?) -> UInt64 { core(pointer)?.historyBytes() ?? 0 }
@_cdecl("helge_terminal_snapshot") func swift_terminal_snapshot(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64) -> UnsafeMutablePointer<CChar>? { guard let snapshot = core(pointer)?.snapshot(scroll: scroll, now: now) else { return nil }; return strdup(String(data: snapshot, encoding: .utf8) ?? "{}") }
@_cdecl("helge_terminal_string_free") func swift_terminal_string_free(_ value: UnsafeMutablePointer<CChar>?) { if let value { free(value) } }
@_cdecl("helge_terminal_snapshot_binary") func swift_terminal_snapshot_binary(_ pointer: OpaquePointer?, _ scroll: Int, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(scroll: scroll, now: now, context: context, callback: callback) ?? false }
@_cdecl("helge_terminal_view_snapshot_binary") func swift_terminal_view_snapshot_binary(_ pointer: OpaquePointer?, _ now: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: SnapshotCallback?) -> Bool { core(pointer)?.publishBinary(scroll: nil, now: now, context: context, callback: callback) ?? false }
@_cdecl("helge_terminal_view_scroll") func swift_terminal_view_scroll(_ pointer: OpaquePointer?, _ amount: Int64) { core(pointer)?.scroll(Int(amount)) }
@_cdecl("helge_terminal_view_follow_tail") func swift_terminal_view_follow_tail(_ pointer: OpaquePointer?) { core(pointer)?.followTail() }
@_cdecl("helge_terminal_clear_display") func swift_terminal_clear_display(_ pointer: OpaquePointer?) -> UInt32 { core(pointer)?.clearDisplay() ?? 0 }
@_cdecl("helge_terminal_replies") func swift_terminal_replies(_ pointer: OpaquePointer?, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) { guard let callback, let data = core(pointer)?.takeReplies(), !data.isEmpty else { return }; data.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, data.count) } }
@_cdecl("helge_terminal_take_clipboard_requests") func swift_terminal_take_clipboard_requests(_ pointer: OpaquePointer?, _ context: UnsafeMutableRawPointer?, _ callback: ClipboardCallback?) {
  guard let callback else { return }
  for (requestID, data) in core(pointer)?.takeClipboardRequests() ?? [] {
    if data.isEmpty {
      // An empty write still passes a non-null pointer, for hosts whose callback validates the pointer before
      // observing the zero length.
      var sentinel: UInt8 = 0
      withUnsafePointer(to: &sentinel) { callback(context, requestID, $0, 0) }
    } else {
      data.withUnsafeBytes { callback(context, requestID, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    }
  }
}
@_cdecl("helge_terminal_complete_clipboard_request") func swift_terminal_complete_clipboard_request(_ pointer: OpaquePointer?, _ requestID: UInt64) -> Bool { core(pointer)?.completeClipboardRequest(requestID) ?? false }
@_cdecl("helge_terminal_input") func swift_terminal_input(_ pointer: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ key: UInt32, _ modifiers: UInt32, _ event: UInt32, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { guard let value = core(pointer)?.input(text.map { String(cString: $0) } ?? "", key: key, modifiers: modifiers, event: event) else { return false }; if let callback, !value.isEmpty { value.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, value.count) } }; return true }
@_cdecl("helge_terminal_input_with_metadata") func swift_terminal_input_with_metadata(_ pointer: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ key: UInt32, _ modifiers: UInt32, _ event: UInt32, _ associated: UnsafePointer<CChar>?, _ legacy: UnsafePointer<CChar>?, _ shifted: UInt32, _ baseLayout: UInt32, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool {
  func optionalText(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer, pointer.pointee != 0 else { return nil }
    return String(cString: pointer)
  }
  let metadata = TerminalInputEncoder.KeyMetadata(
    shifted: inputCharacter(shifted), baseLayout: inputCharacter(baseLayout),
    associatedText: optionalText(associated), legacyText: optionalText(legacy))
  guard let value = core(pointer)?.input(text.map { String(cString: $0) } ?? "", key: key,
                                         modifiers: modifiers, event: event, metadata: metadata) else { return false }
  if let callback, !value.isEmpty { value.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, value.count) } }
  return true
}
@_cdecl("helge_terminal_image_rgba") func swift_terminal_image_rgba(_ pointer: OpaquePointer?, _ image: UInt32, _ generation: UInt64, _ context: UnsafeMutableRawPointer?, _ callback: BytesCallback?) -> Bool { guard let callback, let pixels = core(pointer)?.imageRGBA(id: image, generation: generation) else { return false }; pixels.withUnsafeBytes { callback(context, $0.bindMemory(to: UInt8.self).baseAddress, pixels.count) }; return true }
@_cdecl("helge_terminal_search_create") func swift_terminal_search_create(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) -> OpaquePointer? {
  guard let bytes, count > 0, count <= 4_096,
        let query = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8),
        let token = core(pointer)?.createSearch(query)
  else { return nil }
  return OpaquePointer(Unmanaged.passRetained(token).toOpaque())
}
@_cdecl("helge_terminal_search_create_options") func swift_terminal_search_create_options(_ pointer: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ flags: UInt32) -> OpaquePointer? {
  guard flags & ~UInt32(7) == 0, let bytes, count > 0, count <= 4_096,
        let query = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8),
        let token = core(pointer)?.createSearch(query, options: TerminalSearchOptions(flags: flags))
  else { return nil }
  return OpaquePointer(Unmanaged.passRetained(token).toOpaque())
}
@_cdecl("helge_terminal_search_destroy") func swift_terminal_search_destroy(_ pointer: OpaquePointer?) { if let pointer { Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).release() } }
@_cdecl("helge_terminal_search_fill") func swift_terminal_search_fill(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 {
  guard let terminal = core(pointer), let task else { return 3 }
  return terminal.fillSearch(Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue())
}
@_cdecl("helge_terminal_search_step") func swift_terminal_search_step(_ pointer: OpaquePointer?) -> UInt32 {
  guard let pointer else { return 3 }
  return TerminalEmulator.stepSearch(Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(pointer)).takeUnretainedValue())
}
@_cdecl("helge_terminal_search_accept") func swift_terminal_search_accept(_ pointer: OpaquePointer?, _ task: OpaquePointer?) -> UInt32 {
  guard let terminal = core(pointer), let task else { return 3 }
  return terminal.acceptSearch(Unmanaged<TerminalSearchToken>.fromOpaque(UnsafeMutableRawPointer(task)).takeUnretainedValue())
}

import Foundation
import TerminalEngine

/// Immutable physical-key facts that survive queueing until the SwiftCore
/// adapter emits the negotiated terminal sequence.
package struct TerminalKeyEvent {
  private static let retainedOverhead = 128
  private static let wireOverhead = 256
  package let text: String
  package let logical: String
  package let shifted: String
  package let baseLayout: String
  package let legacyText: String
  package let key: UInt32
  package let modifiers: UInt32
  package let event: UInt32
  package init(text: String, logical: String, shifted: String, baseLayout: String, legacyText: String,
               key: UInt32, modifiers: UInt32, event: UInt32) {
    self.text = text
    self.logical = logical
    self.shifted = shifted
    self.baseLayout = baseLayout
    self.legacyText = legacyText
    self.key = key
    self.modifiers = modifiers
    self.event = event
  }
  private var isModifierOnly: Bool { (400...412).contains(key) }
  package var isKeyAction: Bool { event != 2 && !isModifierOnly }
  package var retainedCost: Int? {
    var total = Self.retainedOverhead
    for value in [text, logical, shifted, baseLayout, legacyText] {
      let bytes = value.utf8.count
      guard bytes <= Int.max - total else { return nil }
      total += bytes
    }
    return total
  }
  package var maximumWireBytes: Int? {
    let (expandedText, overflow) = text.utf8.count.multipliedReportingOverflow(by: 4)
    guard !overflow else { return nil }
    let payload = max(expandedText, legacyText.utf8.count)
    let (total, overheadOverflow) = payload.addingReportingOverflow(Self.wireOverhead)
    return overheadOverflow ? nil : total
  }
  /// Numeric keypad legacy input is AppKit's committed text. Other keys use
  /// their unmodified current-layout key as the negotiated primary value.
  package var adapterText: String { (300...317).contains(key) ? text : logical }
  package var shiftedScalar: UInt32 {
    shifted.unicodeScalars.count == 1 ? shifted.unicodeScalars.first!.value : 0
  }
  package var baseLayoutScalar: UInt32 {
    baseLayout.unicodeScalars.count == 1 ? baseLayout.unicodeScalars.first!.value : 0
  }
}

extension TerminalSession {
  @discardableResult package func input(
    _ text: String = "", key: UInt32 = 0, modifiers: UInt32 = 0, event: UInt32 = 0
  ) -> Bool {
    if key == 1 && text.utf8.count > 1_048_576 {
      report("Paste limit is 1 MiB")
      return false
    }
    let cost = text.utf8.count + 128
    let lifecycle = key == 2 || event == 2
    let control = cost <= 256 && ((event == 2 && key >= 10) || key == 2)
    let admission = reserve(cost, control: control)
    guard admission == .accepted else {
      if admission != .closed || !lifecycle { report(admission.message) }
      return false
    }
    readBroker.submit { [self] in
      guard !closed, !writeEnded else {
        release(cost)
        if !lifecycle { report("Input closed") }
        return
      }
      enqueue(.input(text, key, modifiers, event, cost))
    }
    return true
  }

  @discardableResult package func input(_ input: TerminalKeyEvent) -> Bool {
    guard let cost = input.retainedCost else {
      report("Key input metadata is too large")
      return false
    }
    guard let wireBytes = input.maximumWireBytes, wireBytes <= 3 * 1024 * 1024 else {
      report("Key input exceeds write limit")
      return false
    }
    let lifecycle = input.event == 2
    let control = cost <= 256 && input.event == 2
    let admission = reserve(cost, control: control)
    guard admission == .accepted else {
      if admission != .closed || !lifecycle { report(admission.message) }
      return false
    }
    readBroker.submit { [self] in
      guard !closed, !writeEnded else {
        release(cost)
        if !lifecycle { report("Input closed") }
        return
      }
      enqueue(.keyInput(input, cost))
    }
    return true
  }

  /// Presses `key` with `modifiers`, encoded for the program's current
  /// modes. Returns false for a key the terminal does not know (F13 and
  /// up) or when input is closed or busy.
  @discardableResult public func send(_ key: TerminalKey, modifiers: TerminalKeyModifiers = []) -> Bool {
    guard let code = key.code else { return false }
    let character = key.character
    let shifted = modifiers.contains(.shift) ? character.uppercased() : ""
    return input(TerminalKeyEvent(
      text: modifiers.contains(.shift) ? character.uppercased() : character, logical: character,
      shifted: shifted, baseLayout: character, legacyText: modifiers.contains(.shift) ? shifted : character,
      key: code, modifiers: modifiers.rawValue, event: 0))
  }

  /// Types `text`, as the keyboard would.
  @discardableResult public func send(text: String) -> Bool { input(text) }

  /// Sends text as a paste: bracketed when the program asked for that, and
  /// with line ends as a paste has them. At most 1 MiB; returns false when
  /// the text was not accepted.
  @discardableResult public func paste(_ text: String) -> Bool { input(text, key: 1) }

  public func rawInput(_ bytes: Data) {
    _ = submitRaw(bytes, event: Event.raw)
  }

  @discardableResult package func shortcut(_ text: String) -> Bool {
    submitRaw(Data(text.utf8), event: Event.shortcut)
  }

  private func submitRaw(_ bytes: Data, event: @escaping @Sendable (Data, Int) -> Event) -> Bool {
    let cost = bytes.count + 128
    let admission = reserve(cost)
    guard admission == .accepted else {
      report(admission.message)
      return false
    }
    readBroker.submit { [self] in
      guard !closed, !writeEnded else {
        release(cost)
        report("Input closed")
        return
      }
      enqueue(event(bytes, cost))
    }
    return true
  }

  // Urgent transport control: no semantic event or stalled write can trap it.
  package func cancelPaste() {
    readBroker.submit { [self] in
      guard !closed else { return }
      ingress.transformEvents { event in
        if case .input(_, let key, _, _, let cost) = event, key == 1 {
          release(cost)
          return .idle
        }
        return event
      }
      for index in writes.indices { _ = writes[index].cancelPaste() }
      report("Paste cancelled")
      flush()
      scheduleOwner()
    }
  }
}

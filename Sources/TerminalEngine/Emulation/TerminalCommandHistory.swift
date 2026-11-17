import Foundation

/// Shell-reported command boundaries. Output is untrusted: these describe
/// protocol markers, not verified process execution or commands to rerun.
public struct TerminalCommandRecord: Equatable, Sendable {
  public var promptRowID: UInt64
  public var commandRowID: UInt64?
  public var endRowID: UInt64?
  public var exitStatus: Int?
  /// The OSC 7 URI reported when the prompt began.
  public let directory: String?
  public var completed: Bool
}

/// Fixed metadata budget independent of the terminal's scrollback budget.
package struct TerminalCommandHistory {
  package static let limit = 512
  package private(set) var records: [TerminalCommandRecord] = []
  private var pendingPrompt: (row: UInt64, directory: String?)?
  private var running = false

  /// Every row a record or the pending prompt names.
  package var rowIDs: Set<UInt64> {
    var ids = Set(records.flatMap { [$0.promptRowID, $0.commandRowID, $0.endRowID].compactMap { $0 } })
    if let pendingPrompt { ids.insert(pendingPrompt.row) }
    return ids
  }
  /// A width change gives reflowed rows new identities. A row that is not in
  /// the map was evicted; its record keeps the old identity and is skipped.
  package mutating func remap(_ rows: [UInt64: UInt64]) {
    guard !rows.isEmpty else { return }
    for index in records.indices {
      records[index].promptRowID = rows[records[index].promptRowID] ?? records[index].promptRowID
      records[index].commandRowID = records[index].commandRowID.map { rows[$0] ?? $0 }
      records[index].endRowID = records[index].endRowID.map { rows[$0] ?? $0 }
    }
    if let prompt = pendingPrompt { pendingPrompt = (rows[prompt.row] ?? prompt.row, prompt.directory) }
  }

  package mutating func marker(_ value: String, row: UInt64, directory: String?) {
    let fields = value.split(separator: ";", omittingEmptySubsequences: false)
    switch fields.first {
    case "A": pendingPrompt = (row, directory); running = false
    case "B": break
    case "C":
      guard !running else { return }
      let prompt = pendingPrompt ?? (row, directory)
      records.append(TerminalCommandRecord(promptRowID: prompt.0, commandRowID: row,
        endRowID: nil, exitStatus: nil, directory: prompt.1, completed: false))
      if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
      running = true; pendingPrompt = nil
    case "D":
      guard running, !records.isEmpty else { return }
      records[records.count - 1].endRowID = row
      if fields.count > 1, let status = Int(fields[1]), (0...255).contains(status) {
        records[records.count - 1].exitStatus = status
      }
      records[records.count - 1].completed = true
      running = false
    default: break
    }
  }
}

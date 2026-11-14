import Darwin
import Foundation
import Testing
@testable import TerminalApp
@testable import TerminalCore
import TerminalInterop
@testable import TerminalSession

/// Reflow semantics of the document and the resize bridge. Serialized: several
/// tests fill or inspect the process-wide reflow reservation ledger.
@Suite(.serialized) enum TerminalReflowSemanticTests {
  static func feed(_ t: OpaquePointer, _ text: String) { let d = Data(text.utf8); _ = d.withUnsafeBytes { terminal_feed(t, $0.bindMemory(to: UInt8.self).baseAddress, d.count, 0) } }
  static func snapshot(_ t: OpaquePointer) -> [String: Any] { TerminalSnapshotTestSupport.ownerSnapshot(t)! }
  static func text(_ s: [String: Any]) -> String { (s["rows"] as! [[String: Any]]).map { ($0["cells"] as! [[String: Any]]).map { $0["text"] as! String }.joined() }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
  @Test static func inactivePrimaryAndRichRoundtrip() {
    let inactive = terminal_create(8, 3)!; defer { terminal_destroy(inactive) }
    feed(inactive, "abcdef\u{1b}7\u{1b}[?1049h猫猫"); #expect(terminal_resize(inactive, 4, 4)); feed(inactive, "\u{1b}[?1049l")
    let cursor = snapshot(inactive)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 2)
    let roundtrip = terminal_create(8, 4)!; defer { terminal_destroy(roundtrip) }
    feed(roundtrip, "abcd猫efghij   "); let before = text(snapshot(roundtrip)); #expect(terminal_resize(roundtrip, 4, 8)); #expect(terminal_resize(roundtrip, 8, 4)); let after = text(snapshot(roundtrip))
    #expect(after == before, "reflow roundtrip mismatch: before=\(before.debugDescription) after=\(after.debugDescription)")
  }

  @Test static func reservationLifetime() {
    let mib: UInt64 = 1024 * 1024
    let ledger = ReflowReservationLedger()
    #expect(ledger.reserve(96 * mib + 1) == nil)
    var first = ledger.reserve(80 * mib)
    var second = ledger.reserve(48 * mib)
    #expect(first != nil && second != nil && ledger.reservedBytes == 128 * mib)
    #expect(!first!.grow(to: 81 * mib))
    #expect(!first!.grow(to: 97 * mib))
    first = nil
    #expect(ledger.reservedBytes == 48 * mib)
    #expect(second!.grow(to: 96 * mib))
    second = nil
    #expect(ledger.reservedBytes == 0)
  }

  static func fixture() -> TerminalDocument {
    var source = TerminalDocument(columns: 80, rows: 24)
    for index in 0..<2_000 {
      var row = source.blankRow()
      row.setCell(TerminalCell(text: "猫", kind: 2, style: TerminalStyle(foreground: 0x01000002), link: "https://example.test/\(index)"), at: 0)
      row.setCell(TerminalCell(text: "", kind: 3), at: 1)
      row.setCell(TerminalCell(text: " ", kind: 1), at: 79)
      source.history.append(row)
    }
    return source
  }

  @Test static func boundedAssemblyAndCancellation() {
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
    let source = fixture()
    let retainedHistory = source.history
    let transaction = DocumentReflowTransaction(source: source,
      geometry: TerminalResizeGeometry(columns: 40, rows: 24, cellWidth: 8, cellHeight: 16),
      anchor: source.history[10].id, promptEraseStyle: nil, historyRows: 50_000, historyBytes: 64 * 1024 * 1024)
    var pendingTurns = 0
    var replacement: DocumentReflowTransaction.Replacement?
    for _ in 0..<10_000 {
      let progress = transaction.advance()
      // The owner admits 32768 work units, plus at most one atomic row operation
      // of twice the maximum 4096-column grid width.
      #expect(transaction.lastWorkUnits <= 40_960)
      switch progress {
      case .pending:
        pendingTurns += 1
        #expect(source.columns == 80 && source.history.count == 2_000)
        #expect(source.history[10].id == retainedHistory[10].id)
      case .pressure: Issue.record("unexpected pressure in small direct fixture"); return
      case .ready(let value): replacement = value
      case .rejected(let reason): Issue.record("unexpected reflow rejection: \(reason)"); return
      }
      if replacement != nil { break }
    }
    #expect(pendingTurns > 1 && replacement != nil)
    #expect(replacement!.document.columns == 40)
    #expect(replacement!.document.history[0].cell(0).link == "https://example.test/0")
    #expect(source.history == retainedHistory)
    transaction.retire()
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
    #expect(replacement!.document.history[0].cell(0).text == "猫")

    let cancelled = DocumentReflowTransaction(source: source,
      geometry: TerminalResizeGeometry(columns: 39, rows: 24, cellWidth: 8, cellHeight: 16),
      anchor: nil, promptEraseStyle: nil, historyRows: 50_000, historyBytes: 64 * 1024 * 1024)
    for _ in 0..<10 {
      guard case .pending = cancelled.advance() else { Issue.record("fixture must yield"); return }
      if ReflowReservationLedger.shared.reservedBytes > 0 { break }
    }
    #expect(ReflowReservationLedger.shared.reservedBytes > 0)
    cancelled.retire(); cancelled.retire()
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
    guard case .rejected(.noOperation) = cancelled.advance() else { Issue.record("unexpected result"); return }
    #expect(source.history == retainedHistory)
  }

  @Test static func bridgeCoherence() {
    let core = terminal_create(80, 24)!; defer { terminal_destroy(core) }
    feed(core, String(repeating: "abcdefghij\r\n", count: 500))
    let before = snapshot(core)
    guard case .pending = TerminalResizeBridge.begin(core: core, columns: 40, rows: 30, cellWidth: 9, cellHeight: 17) else { Issue.record("unexpected result"); return }
    #expect(snapshot(core)["cols"] as? Int == before["cols"] as? Int)
    TerminalResizeBridge.cancel(core: core)
    #expect(snapshot(core)["cols"] as? Int == 80)
    guard case .committed(let geometry) = TerminalResizeBridge.begin(core: core, columns: 80, rows: 24, cellWidth: 9, cellHeight: 17) else { Issue.record("unexpected result"); return }
    #expect(geometry.cellWidth == 9 && geometry.cellHeight == 17)
    guard case .pending = TerminalResizeBridge.begin(core: core, columns: 40, rows: 30, cellWidth: 9, cellHeight: 17) else { Issue.record("unexpected result"); return }
    feed(core, "x")
    guard case .rejected(.staleInput, let retained) = TerminalResizeBridge.advance(core: core) else { Issue.record("unexpected result"); return }
    #expect(retained.columns == 80 && retained.rows == 24)
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
  }

  @Test static func cursorWindowAndAlternateCoordinates() {
    let core = terminal_create(4, 3)!; defer { terminal_destroy(core) }
    feed(core, "1111\u{1b}[2;1H2222\u{1b}[3;1H3333\u{1b}[1;2H")
    #expect(terminal_resize(core, 2, 2))
    #expect(text(snapshot(core)) == "11\n11", "width reflow must choose the old screen-start window containing the cursor, cropping excess rows below it")
    feed(core, "\u{1b}[?1049h\u{1b}[1;1HA\u{1b}[2;1HB")
    #expect(terminal_resize(core, 3, 1))
    #expect(text(snapshot(core)) == "A", "alternate resize must preserve top-left coordinates")

    let saved = terminal_create(4, 3)!; defer { terminal_destroy(saved) }
    feed(saved, "abcd\u{1b}7\u{1b}[2;1H")
    #expect(terminal_resize(saved, 2, 4))
    feed(saved, "\u{1b}8")
    let cursor = snapshot(saved)["cursor"] as! [String: Any]
    #expect(cursor["row"] as? Int == 1 && cursor["col"] as? Int == 1 && cursor["pending_wrap"] as? Bool == true,
                 "saved cursor must retain its after-cell pending-wrap insertion boundary")
    feed(saved, "Z")
    #expect(text(snapshot(saved)) == "ab\ncd\nZ")
  }

  @Test static func pressureEvictsBeforeReplanning() {
    DocumentReflowTransaction.drainRetirementForTesting()
    let core = terminal_create(1_024, 2)!; defer { terminal_destroy(core) }
    // A single shared link keeps this fixture physically small, while the
    // conservative per-cell resource charge exercises real admission pressure.
    let link = "https://example.test/" + String(repeating: "a", count: 8_000)
    feed(core, "\u{1b}]8;;\(link)\u{1b}\\" + String(repeating: String(repeating: "x", count: 1_000) + "\r\n", count: 9))
    let retained = swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot!
    let beforeBytes = terminal_history_bytes(core)
    #expect(beforeBytes > 50 * 1024 * 1024 && retained.history_rows > 1)
    var progress = TerminalResizeBridge.begin(core: core, columns: 1_000, rows: 2, cellWidth: 8, cellHeight: 16)
    var turns = 0
    while case .pending = progress {
      #expect(turns < 100_000, "pressure replan must make finite progress")
      progress = TerminalResizeBridge.advance(core: core); turns += 1
      if turns.isMultiple(of: 100) { Thread.sleep(forTimeInterval: 0.001) }
    }
    guard case .committed(let geometry) = progress else { Issue.record("history pressure should replan a feasible active grid: \(progress)"); return }
    #expect(geometry.columns == 1_000 && terminal_history_bytes(core) < beforeBytes)
    #expect(retained.cols == 1_024 && retained.rows.count == 2)
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
  }

  @Test static func processRejectionAndDestruction() {
    DocumentReflowTransaction.drainRetirementForTesting()
    var first = ReflowReservationLedger.shared.reserve(96 * 1024 * 1024)
    var second = ReflowReservationLedger.shared.reserve(32 * 1024 * 1024)
    #expect(first != nil && second != nil)
    let core = terminal_create(80, 24)!
    var progress = TerminalResizeBridge.begin(core: core, columns: 40, rows: 24, cellWidth: 8, cellHeight: 16)
    for _ in 0..<100 {
      guard case .pending = progress else { break }
      progress = TerminalResizeBridge.advance(core: core)
    }
    guard case .rejected(.processBudget, let retained) = progress else { Issue.record("full process reservation must reject without waiting"); return }
    #expect(retained.columns == 80)
    first = nil; second = nil
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
    let snapshot = swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot!
    feed(core, String(repeating: "abcdefghij\r\n", count: 1_000))
    _ = TerminalResizeBridge.begin(core: core, columns: 40, rows: 24, cellWidth: 8, cellHeight: 16)
    for _ in 0..<10 {
      _ = TerminalResizeBridge.advance(core: core)
      if ReflowReservationLedger.shared.reservedBytes > 0 { break }
    }
    terminal_destroy(core)
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
    #expect(snapshot.cols == 80 && snapshot.rows.count == 24)
  }

  /// Not a check: prints timings for a large reflow when asked to.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMINAL_MEASURE"] != nil))
  static func measureLargeReflow() {
    func cpu() -> UInt64 {
      var value = timespec(); #expect(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0)
      return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
    var source = TerminalDocument(columns: 160, rows: 40)
    for _ in 0..<10_000 {
      var row = source.blankRow()
      for column in 0..<160 { row.setCell(TerminalCell(text: "x", kind: 1), at: column) }
      source.history.append(row)
    }
    var samples: [[String: Any]] = []
    for _ in 0..<5 {
      DocumentReflowTransaction.drainRetirementForTesting()
      let transaction = DocumentReflowTransaction(source: source,
        geometry: TerminalResizeGeometry(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16),
        anchor: source.history[5_000].id, promptEraseStyle: nil, historyRows: 50_000, historyBytes: 64 * 1024 * 1024)
      let started = DispatchTime.now().uptimeNanoseconds
      let startedCPU = cpu()
      var maximumTurn: UInt64 = 0
      var maximumTurnCPU: UInt64 = 0
      var finished = false
      while !finished {
        let turn = DispatchTime.now().uptimeNanoseconds
        let turnCPU = cpu()
        let result = transaction.advance()
        maximumTurn = max(maximumTurn, DispatchTime.now().uptimeNanoseconds - turn)
        maximumTurnCPU = max(maximumTurnCPU, cpu() - turnCPU)
        switch result {
        case .pending: break
        case .ready(let replacement):
          #expect(replacement.document.columns == 120)
          finished = true
        case .pressure: Issue.record("10k x 160 fixture should fit the operation allowance"); return
        case .rejected(let reason): Issue.record("measurement rejected: \(reason)"); return
        }
      }
      samples.append(["total_ms": Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                      "thread_cpu_ms": Double(cpu() - startedCPU) / 1_000_000,
                      "maximum_owner_turn_ms": Double(maximumTurn) / 1_000_000,
                      "maximum_owner_turn_cpu_ms": Double(maximumTurnCPU) / 1_000_000,
                      "turns": transaction.turnCount,
                      "reserved_bytes": ReflowReservationLedger.shared.reservedBytes])
      transaction.retire()
    }
    DocumentReflowTransaction.drainRetirementForTesting()
    let report: [String: Any] = ["history_rows": 10_000, "old_columns": 160, "new_columns": 120,
                               "includes_snapshot_projection": false, "samples": samples]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data); print("")
  }

  @Test static func retentionIsPlannedBeforePacking() {
    DocumentReflowTransaction.drainRetirementForTesting()
    var source = TerminalDocument(columns: 4_096, rows: 2)
    for _ in 0..<100 {
      var row = source.blankRow()
      row.setCell(TerminalCell(text: " ", kind: 1), at: 4_095)
      source.history.append(row)
    }
    // 409,600 physical output rows exist logically, but only 32 history rows
    // and the active window can survive ordinary retention. Allocating all
    // output would exceed 96 MiB and wrongly pressure-evict the input first.
    let transaction = DocumentReflowTransaction(source: source,
      geometry: TerminalResizeGeometry(columns: 1, rows: 2, cellWidth: 8, cellHeight: 16),
      anchor: nil, promptEraseStyle: nil, historyRows: 32, historyBytes: 4_096)
    var finished = false
    while !finished {
      switch transaction.advance() {
      case .pending: break
      case .pressure: Issue.record("discarded output must not cause input pressure eviction"); return
      case .rejected(let reason): Issue.record("retained output fits: \(reason)"); return
      case .ready(let replacement):
        #expect(replacement.document.history.count == 32)
        #expect(replacement.document.history.byteCount <= 4_096)
        #expect(ReflowReservationLedger.shared.reservedBytes < 20 * 1024 * 1024)
        finished = true
      }
    }
    transaction.retire()
    DocumentReflowTransaction.drainRetirementForTesting()
  }

  @Test static func storedRunsPreserveRichCells() {
    var source = TerminalDocument(columns: 6, rows: 3)
    let style = TerminalStyle(foreground: 0x02010203, background: 0x01000004, flags: 5, underlineKind: 2)
    let cells = [
      TerminalCell(text: "A", kind: 1, style: style, link: "https://a.test", protected: true),
      TerminalCell(text: "e\u{301}", kind: 1, style: style, link: "https://b.test", flags: 2),
      TerminalCell(text: "Z", kind: 1, style: TerminalStyle(foreground: 9)),
      TerminalCell(text: " ", kind: 1, style: style, link: ""),
      TerminalCell(text: "猫", kind: 2, style: style, link: "https://c.test", protected: true),
      TerminalCell(text: "", kind: 3, style: style, link: "https://c.test", protected: true)
    ]
    for index in cells.indices { source.primary.rows[0].setCell(cells[index], at: index) }
    source.primary.cursorRow = 1
    let retained = source.primary
    let transaction = DocumentReflowTransaction(source: source,
      geometry: TerminalResizeGeometry(columns: 4, rows: 4, cellWidth: 8, cellHeight: 16),
      anchor: nil, promptEraseStyle: nil, historyRows: 50_000, historyBytes: 64 * 1024 * 1024)
    var result: DocumentReflowTransaction.Replacement?
    while result == nil {
      switch transaction.advance() {
      case .pending: break
      case .ready(let value): result = value
      case .pressure: Issue.record("small rich fixture must fit"); return
      case .rejected(let reason): Issue.record("\(reason)"); return
      }
    }
    #expect(Array(result!.document.primary.rows[0].cells) == Array(cells.prefix(4)))
    #expect(Array(result!.document.primary.rows[1].cells.prefix(2)) == Array(cells.suffix(2)))
    let outputSnapshot = result!.document.primary
    result!.document.primary.rows[0].setCell(TerminalCell(text: "Q", kind: 1), at: 0)
    #expect(outputSnapshot.rows[0].cell(0) == cells[0])
    #expect(retained == source.primary)
    transaction.retire(); DocumentReflowTransaction.drainRetirementForTesting()
  }

  @Test static func payloadChargeFollowsAllEdits() {
    func check(_ row: TerminalRow) {
      var resources: UInt64 = 0, logical: UInt64 = row.retainedBaseCost
      for cell in row.cells {
        let text = UInt64(cell.text.utf8.count), link = UInt64(cell.link?.utf8.count ?? 0)
        logical += text + link
        resources += link
        if cell.text.unicodeScalars.count != 1 { resources += text }
      }
      #expect(row.reflowAllocationBytes == row.allocationBaseCost + 2 * resources)
      #expect(row.retainedStorageCost == logical, "legacy history byte contract must stay unchanged")
    }
    var row = TerminalRow(columns: 8)
    row.setCell(TerminalCell(text: "e\u{301}", kind: 1, link: "https://é.test"), at: 0)
    row.setCell(TerminalCell(text: "猫", kind: 1, link: ""), at: 1)
    check(row)
    let retained = row
    row.copyCells(from: retained, range: 0..<2, to: 4); check(row); check(retained)
    row.copyCell(from: retained, at: 0, to: 2); check(row)
    row.setScalar("x", at: 0, kind: 1, style: TerminalStyle(), link: nil, flags: 0, protected: false); check(row)
    row.clearText(at: 2); check(row)
    row.erase(at: 4); check(row)
    row.shiftCells(column: 0, right: 7, amount: 1, inserting: true); check(row)
    row.truncate(to: 4); check(row)
    row.appendBlanks(4); check(row)
    row.replaceASCII(at: 0, scalars: Array("abcd".unicodeScalars), style: TerminalStyle(), link: nil, protected: false); check(row)
    let beforeReuse = row
    row.resetForReuse(columns: 8, logicalCellCapacity: TerminalRow.blankLogicalCapacity(columns: 8), style: TerminalStyle(), id: 42)
    check(row); check(beforeReuse); check(retained)
    row.setCell(TerminalCell(text: "a\u{301}", kind: 1, link: "last"), at: 7); check(row)
    row.erase(at: 7); check(row)
    row.setCell(TerminalCell(text: "a\u{301}", kind: 1, link: "last"), at: 7)
    row.resetForReuse(columns: 8, logicalCellCapacity: TerminalRow.blankLogicalCapacity(columns: 8), style: TerminalStyle(), id: 43)
    check(row)
  }

  @Test static func reservationPrecedesCaptureAndSurvivesCancellation() {
    DocumentReflowTransaction.drainRetirementForTesting()
    DocumentReflowTransaction.withRetirementPausedForTesting {
      let core = terminal_create(80, 24)!
      guard case .pending = TerminalResizeBridge.begin(core: core, columns: 40, rows: 24, cellWidth: 8, cellHeight: 16) else { Issue.record("unexpected result"); return }
      let reserved = ReflowReservationLedger.shared.reservedBytes
      #expect(reserved > 0, "input must be charged before the first advance")
      terminal_destroy(core)
      #expect(ReflowReservationLedger.shared.reservedBytes == reserved,
                   "destroy may not credit captured input while retirement is blocked")
    }
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)

    let core = terminal_create(1_024, 2)!; defer { terminal_destroy(core) }
    let link = "https://example.test/" + String(repeating: "a", count: 8_000)
    feed(core, "\u{1b}]8;;\(link)\u{1b}\\" + String(repeating: String(repeating: "x", count: 1_000) + "\r\n", count: 9))
    let before = terminal_history_bytes(core)
    DocumentReflowTransaction.withRetirementPausedForTesting {
      _ = TerminalResizeBridge.begin(core: core, columns: 1_000, rows: 2, cellWidth: 8, cellHeight: 16)
      _ = TerminalResizeBridge.advance(core: core) // initial pressure, without capturing input
      _ = TerminalResizeBridge.advance(core: core) // a bounded eviction packet
      #expect(terminal_history_bytes(core) < before)
      let reserved = ReflowReservationLedger.shared.reservedBytes
      #expect(reserved > 0)
      TerminalResizeBridge.cancel(core: core)
      #expect(ReflowReservationLedger.shared.reservedBytes == reserved,
                   "pressure cancellation may not credit queued retired rows")
      #expect(swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot!.cols == 1_024)
    }
    DocumentReflowTransaction.drainRetirementForTesting()
    #expect(ReflowReservationLedger.shared.reservedBytes == 0)
  }

  @Test static func rejectedAndCancelledResizePreserveSemanticState() {
    DocumentReflowTransaction.drainRetirementForTesting()
    let cancelled = terminal_create(80, 24)!; defer { terminal_destroy(cancelled) }
    feed(cancelled, "e")
    _ = TerminalResizeBridge.begin(core: cancelled, columns: 40, rows: 24, cellWidth: 8, cellHeight: 16)
    TerminalResizeBridge.cancel(core: cancelled)
    feed(cancelled, "\u{301}")
    #expect(swiftTerminalSnapshot(cancelled, scroll: nil, now: 0).snapshot!.rows[0].cells[0].text == "e\u{301}",
                 "cancelled resize must not break an adjacent grapheme")
    DocumentReflowTransaction.drainRetirementForTesting()
    let rejected = terminal_create(80, 24)!; defer { terminal_destroy(rejected) }
    feed(rejected, "e")
    var first = ReflowReservationLedger.shared.reserve(96 * 1024 * 1024)
    var second = ReflowReservationLedger.shared.reserve(32 * 1024 * 1024)
    #expect(first != nil && second != nil)
    _ = TerminalResizeBridge.begin(core: rejected, columns: 40, rows: 24, cellWidth: 8, cellHeight: 16)
    guard case .rejected(.processBudget, _) = TerminalResizeBridge.advance(core: rejected) else { Issue.record("unexpected result"); return }
    first = nil; second = nil
    feed(rejected, "\u{301}")
    #expect(swiftTerminalSnapshot(rejected, scroll: nil, now: 0).snapshot!.rows[0].cells[0].text == "e\u{301}",
                 "rejected resize must not break an adjacent grapheme")

    let gated = terminal_create(80, 24)!; defer { terminal_destroy(gated) }
    feed(gated, "\u{1b}[?2026hX")
    _ = TerminalResizeBridge.begin(core: gated, columns: 40, rows: 24, cellWidth: 8, cellHeight: 16)
    TerminalResizeBridge.cancel(core: gated)
    #expect(swiftTerminalSnapshot(gated, scroll: nil, now: 0).snapshot == nil,
                 "cancellation must preserve synchronized-output publication gating")
    var progress = TerminalResizeBridge.begin(core: gated, columns: 40, rows: 24, cellWidth: 8, cellHeight: 16)
    #expect(swiftTerminalSnapshot(gated, scroll: nil, now: 151).snapshot?.cols == 80)
    while case .pending = progress { progress = TerminalResizeBridge.advance(core: gated) }
    guard case .committed(let geometry) = progress else { Issue.record("publication-only watchdog expiry must not stale the resize"); return }
    #expect(geometry.columns == 40)
    feed(gated, "\u{1b}[?2026h")
    _ = TerminalResizeBridge.begin(core: gated, columns: 20, rows: 24, cellWidth: 8, cellHeight: 16)
    feed(gated, "Y")
    _ = swiftTerminalSnapshot(gated, scroll: nil, now: 302)
    guard case .rejected(.staleInput, _) = TerminalResizeBridge.advance(core: gated) else {
      Issue.record("watchdog bookkeeping must not conceal a real intervening mutation"); return
    }
    DocumentReflowTransaction.drainRetirementForTesting()
  }

  @Test static func insertionBoundaryAffinity() {
    for text in ["ABCDEFGH", "ABCD", "abc猫"] {
      let core = terminal_create(8, 3)!
      feed(core, text + "\u{1b}[1;\(text == "abc猫" ? 4 : 5)H")
      #expect(terminal_resize(core, 4, 4))
      let cursor = swiftTerminalSnapshot(core, scroll: nil, now: 0).snapshot!.cursor
      #expect(cursor.row == 1 && cursor.col == 0 && !cursor.pending_wrap,
                   "ordinary before-atom boundary must map after a wrap: \(text)")
      terminal_destroy(core)
    }
  }

  @Test static func clippedWidePlanningBound() {
    DocumentReflowTransaction.drainRetirementForTesting()
    var source = TerminalDocument(columns: 512, rows: 1)
    for _ in 0..<3 {
      var row = source.blankRow()
      for column in 0..<512 { row.setCell(TerminalCell(text: "猫", kind: 1, flags: 1), at: column) }
      source.history.append(row)
    }
    let transaction = DocumentReflowTransaction(source: source,
      geometry: TerminalResizeGeometry(columns: 2, rows: 1, cellWidth: 8, cellHeight: 16),
      anchor: nil, promptEraseStyle: nil, historyRows: 5_000, historyBytes: 1024 * 1024)
    var finished = false
    while !finished {
      switch transaction.advance() {
      case .pending: break
      case .pressure: Issue.record("small clipped-wide input must fit"); return
      case .rejected(let reason): Issue.record("\(reason)"); return
      case .ready(let value):
        #expect(value.document.history.count == 1_536)
        #expect(value.document.history.allSatisfy { $0.kind(at: 0) == 2 && $0.kind(at: 1) == 3 && $0.flags(at: 0) & 1 == 0 })
        finished = true
      }
    }
    transaction.retire(); DocumentReflowTransaction.drainRetirementForTesting()
  }
}

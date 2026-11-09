import Foundation

struct TerminalResizeGeometry: Equatable {
  let columns: Int
  let rows: Int
  let cellWidth: Int
  let cellHeight: Int
  var isValid: Bool {
    (1...4096).contains(columns) && (1...4096).contains(rows) && columns <= 1_048_576 / rows
      && (1...1024).contains(cellWidth) && (1...1024).contains(cellHeight)
  }
}

enum TerminalResizeRejection: String, CustomStringConvertible {
  case invalidGeometry, operationBudget, processBudget, staleInput, noOperation, resizeInProgress
  var description: String { rawValue }
}

enum TerminalResizeProgress {
  case pending
  case committed(TerminalResizeGeometry)
  case rejected(TerminalResizeRejection, retained: TerminalResizeGeometry)
}

// Reservations include packed slot/dictionary capacities, retained input,
// conservative payload ownership and builder containers. They are not RSS.
final class ReflowReservationLedger {
  static let shared = ReflowReservationLedger()
  static let operationLimit: UInt64 = 96 * 1024 * 1024
  private let lock = NSLock()
  private let limit: UInt64
  private var reserved: UInt64 = 0
  init(limit: UInt64 = 128 * 1024 * 1024) { self.limit = limit }
  var reservedBytes: UInt64 { lock.lock(); defer { lock.unlock() }; return reserved }
  func reserve(_ bytes: UInt64) -> Lease? {
    guard bytes <= Self.operationLimit, take(bytes) else { return nil }
    return Lease(ledger: self, bytes: bytes)
  }
  private func take(_ bytes: UInt64) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard bytes <= limit - reserved else { return false }
    reserved += bytes; return true
  }
  private func release(_ bytes: UInt64) {
    lock.lock(); defer { lock.unlock() }
    precondition(bytes <= reserved); reserved -= bytes
  }
  final class Lease {
    private let ledger: ReflowReservationLedger
    private(set) var bytes: UInt64
    fileprivate init(ledger: ReflowReservationLedger, bytes: UInt64) { self.ledger = ledger; self.bytes = bytes }
    func grow(to next: UInt64) -> Bool {
      guard next <= ReflowReservationLedger.operationLimit else { return false }
      guard next > bytes else { return true }
      guard ledger.take(next - bytes) else { return false }
      bytes = next; return true
    }
    deinit { ledger.release(bytes) }
  }
}

final class DocumentReflowTransaction {
  struct Replacement {
    var document: TerminalDocument
    let mapping: TerminalDocument.ReflowMapping
    let evictedHistory: Bool
    let retainedRowIDs: Set<UInt64>
  }
  enum Progress { case pending, ready(Replacement), pressure, rejected(TerminalResizeRejection) }
  enum PressureProgress { case pending, evicted, ready, rejected(TerminalResizeRejection) }
  // The hot step result must not carry a whole document: even the nil/pending
  // case of such an enum copies a document-sized return buffer per atom.
  private enum Step { case ready, pressure, rejected(TerminalResizeRejection) }
  private enum Phase { case setup, prompt, extents, packingPlan, retentionPlan, screenPlan, allocation, packing, history, screen, alternate, complete }
  private static let retirement = DispatchQueue(label: "terminal.reflow.retirement", qos: .utility)
  private var state: State?
  private var earlyStatus: Step?
  private final class RetirementFence {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish() { lock.lock(); finished = true; lock.unlock() }
  }
  private var retirementFence: RetirementFence?
  private final class RetiredHistory {
    var rows: [TerminalRow] = []
    var history: TerminalHistory?
    var lease: ReflowReservationLedger.Lease?
    func release() { rows.removeAll(); history = nil; lease = nil }
  }
  private var pressureBytes: UInt64 = 0
  // Span copies make thousands of cell work units cheap; the time deadline
  // remains the primary yield limit, with this hard ceiling as a backstop.
  private static let workBudget = 32_768
  private(set) var lastWorkUnits = 0
  private(set) var turnCount = 0

  init(source: TerminalDocument, geometry: TerminalResizeGeometry,
       anchor: UInt64?, promptEraseStyle: TerminalStyle?, historyRows: Int, historyBytes: Int) {
    guard geometry.isValid else { earlyStatus = .rejected(.invalidGeometry); return }
    // At most 8192 active rows, each O(1). No retained generation or private
    // builder allocation exists until its complete input reservation succeeds.
    var sourceBytes = State.sum(source.history.reflowAllocationBytes,
      UInt64(source.primary.rows.capacity + source.alternate.rows.capacity) * UInt64(MemoryLayout<TerminalRow>.stride))
    var alternateResources: UInt64 = 0
    var promptBytes: UInt64 = 0
    var largestPromptDictionary: UInt64 = 0
    for row in source.primary.rows {
      sourceBytes = State.sum(sourceBytes, row.reflowAllocationBytes)
      if promptEraseStyle != nil {
        promptBytes = State.sum(promptBytes, row.allocationSlotCost, 96)
        largestPromptDictionary = max(largestPromptDictionary, row.allocationBaseCost - row.allocationSlotCost)
      }
    }
    for (index, row) in source.alternate.rows.enumerated() {
      sourceBytes = State.sum(sourceBytes, row.reflowAllocationBytes)
      if index < geometry.rows { alternateResources = State.sum(alternateResources, row.reflowAllocationBytes - row.allocationSlotCost) }
    }
    let required = State.sum(sourceBytes, promptBytes, largestPromptDictionary,
      State.product(source.history.count + source.primary.rows.count, 16), 4096)
    guard required <= ReflowReservationLedger.operationLimit else {
      if source.history.isEmpty { earlyStatus = .rejected(.operationBudget) }
      else {
        earlyStatus = .pressure; pressureBytes = required - ReflowReservationLedger.operationLimit
        let fence = RetirementFence(); fence.finish(); retirementFence = fence
      }
      return
    }
    guard let lease = ReflowReservationLedger.shared.reserve(required) else { earlyStatus = .rejected(.processBudget); return }
    state = State(source: source, geometry: geometry, anchor: anchor, promptEraseStyle: promptEraseStyle,
                  historyRows: historyRows, historyBytes: historyBytes, lease: lease, alternateResources: alternateResources)
  }
  func advance() -> Progress {
    if let early = earlyStatus {
      earlyStatus = nil
      switch early {
      case .pressure: return .pressure
      case .rejected(let reason): return .rejected(reason)
      case .ready: preconditionFailure("no early replacement")
      }
    }
    guard let state else { return .rejected(.noOperation) }
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000
    var work = 0
    var nextClockCheck = 64
    repeat {
      if let result = state.step(work: &work) {
        lastWorkUnits = work; turnCount += 1
        switch result {
        case .ready: return .ready(state.replacement())
        case .rejected(let reason): return .rejected(reason)
        case .pressure:
          pressureBytes = state.requiredPressureBytes
          retire()
          return .pressure
        }
      }
      if work >= nextClockCheck {
        if DispatchTime.now().uptimeNanoseconds >= deadline { break }
        nextClockCheck = work + 64
      }
    } while work < Self.workBudget
    lastWorkUnits = work; turnCount += 1; return .pending
  }
  // Transfer the heavy containers away from the owner before releasing the
  // lease. Even a cancelled partial builder retires on this queue.
  func retire() {
    earlyStatus = nil
    guard let retired = state else { return }
    state = nil
    let fence = RetirementFence(); retirementFence = fence
    Self.retirement.async { [retired, fence] in retired.releaseResources(); fence.finish() }
  }
  // The old input must be gone before trimming the owner's FIFO, otherwise
  // Array COW would copy every history entry. Evicted rows then retire in one
  // bounded packet; wait for that packet before capturing/replanning input.
  func relieveHistoryPressure(in document: inout TerminalDocument) -> PressureProgress {
    guard retirementFence?.isFinished == true else { return .pending }
    if document.history.hasEmptyReflowStorage {
      guard let lease = ReflowReservationLedger.shared.reserve(document.history.reflowAllocationBytes) else { return .rejected(.processBudget) }
      let retired = RetiredHistory(); retired.lease = lease
      retired.history = document.history; document.history = TerminalHistory()
      retireHistory(retired)
      return .pending
    }
    guard pressureBytes > 0, !document.history.isEmpty else { return .ready }
    let retired = RetiredHistory()
    var work = 0
    repeat {
      guard !document.history.isEmpty else { break }
      let charge = document.history.retainedRow(at: 0).allocationBytes + 128
      if let lease = retired.lease {
        if !lease.grow(to: lease.bytes + charge) { break }
      } else {
        guard let lease = ReflowReservationLedger.shared.reserve(charge) else { return .rejected(.processBudget) }
        retired.lease = lease
      }
      var entry = document.history.takeOldestForReflow()
      pressureBytes -= min(pressureBytes, entry!.allocationBytes)
      retired.rows.append(entry!.row)
      work += max(1, entry!.row.count)
      // Remove this local row alias before the retirement queue can release
      // the packet and credit its reservation.
      entry = nil
    } while pressureBytes > 0 && work < 4096 && retired.rows.count < 64
    retireHistory(retired)
    return .evicted
  }
  private func retireHistory(_ retired: RetiredHistory) {
    let fence = RetirementFence(); retirementFence = fence
    Self.retirement.async { [retired, fence] in retired.release(); fence.finish() }
  }
  deinit { retire() }
  static func drainRetirementForTesting() { retirement.sync {} }
  static func withRetirementPausedForTesting(_ body: () -> Void) {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    retirement.async { entered.signal(); resume.wait() }
    entered.wait(); defer { resume.signal() }
    body()
  }

  private final class RowPages {
    private var pages: [[TerminalHistory.RetainedRow]] = []
    private let pageRows: Int
    private let base: Int
    private(set) var count = 0
    init(columns: Int, capacity: Int, base: Int) {
      self.base = base
      pageRows = max(1, min(64, 4096 / columns))
      pages.reserveCapacity((capacity + pageRows - 1) / pageRows)
    }
    func append(_ row: TerminalRow) {
      if count.isMultiple(of: pageRows) {
        var page: [TerminalHistory.RetainedRow] = []; page.reserveCapacity(pageRows); pages.append(page)
      }
      pages[pages.count - 1].append(TerminalHistory.RetainedRow(row)); count += 1
    }
    func retainedRow(at index: Int) -> TerminalHistory.RetainedRow { pages[(index - base) / pageRows][(index - base) % pageRows] }
    subscript(_ index: Int) -> TerminalRow { retainedRow(at: index).row }
    var last: TerminalRow? { count == 0 ? nil : self[base + count - 1] }
  }

  private struct RowPlan {
    let chargedBytes: UInt64
    let allocationBytes: UInt64
  }
  // Only the most recent potentially retained rows need plan records. The
  // extra page prevents overwriting any record in that window on page rollover.
  private final class PlanPages {
    private var pages: [[RowPlan]?]
    private(set) var count = 0
    init(capacity: Int) { pages = Array(repeating: nil, count: (capacity + 127) / 128 + 1) }
    static func allocationBytes(capacity: Int) -> UInt64 { UInt64((capacity + 127) / 128 + 1) * (128 * 16 + 64) }
    func append(_ plan: RowPlan) {
      let page = (count / 128) % pages.count
      if count.isMultiple(of: 128) { var next: [RowPlan] = []; next.reserveCapacity(128); pages[page] = next }
      pages[page]!.append(plan); count += 1
    }
    subscript(_ index: Int) -> RowPlan {
      precondition(index >= max(0, ((count - 1) / 128 + 1 - pages.count) * 128) && index < count)
      return pages[(index / 128) % pages.count]![index % 128]
    }
  }

  private final class State {
    var source: TerminalDocument
    let geometry: TerminalResizeGeometry
    let anchor: UInt64?
    let promptEraseStyle: TerminalStyle?
    let historyRows: Int
    let historyBytes: UInt64
    var phase = Phase.setup
    var index = 0
    var alternateResources: UInt64 = 0
    var lease: ReflowReservationLedger.Lease?
    var requiredPressureBytes: UInt64 = 0
    var ends: [Int] = []
    var lastRelevant = 0
    var promptRow: Int?
    var promptPrepared = false
    var plannedCount = 0
    var plannedColumn = 0
    var plannedPayloadBytes: UInt64 = 0
    var plannedSparseCells = 0
    var plan: PlanPages?
    var newRowCharge: UInt64 = 0
    var newRowAllocation: UInt64 = 0
    var replacementAllocation: UInt64 = 0
    var windowPlanned = false
    var packedCount = 0
    var start = 0
    var retainedStart = 0
    var retainedBytes: UInt64 = 0
    var retainedRowIDs: Set<UInt64> = []
    var working: TerminalDocument?
    var output: RowPages?
    var current: TerminalRow?
    var column = 0
    var sourceColumn = 0
    var enteredRow = false
    var mappedAnchor: UInt64?
    var promptMap: PromptAnchor?
    var cursorMap = (row: 0, column: 0, pending: false)
    var savedMap = (row: 0, column: 0, pending: false)
    var oldScreenStart = 0
    var screenRows: [TerminalRow] = []
    var alternateRows: [TerminalRow] = []

    init(source: TerminalDocument, geometry: TerminalResizeGeometry, anchor: UInt64?, promptEraseStyle: TerminalStyle?,
         historyRows: Int, historyBytes: Int, lease: ReflowReservationLedger.Lease, alternateResources: UInt64) {
      self.source = source; self.geometry = geometry; self.anchor = anchor; self.promptEraseStyle = promptEraseStyle
      self.historyRows = max(0, historyRows); self.historyBytes = UInt64(max(0, historyBytes))
      self.lease = lease; self.alternateResources = alternateResources
    }
    var sourceCount: Int { source.history.count + source.primary.rows.count }
    var cursorSource: Int { source.history.count + source.primary.cursorRow }
    var savedSource: Int { source.history.count + source.primary.savedRow }
    var cursorBoundary: Int {
      let column = source.primary.cursorColumn
      if source.primary.pendingWrap { return column + 1 }
      return column > 0 && source.primary.rows[source.primary.cursorRow].kind(at: column) == 3 ? column - 1 : column
    }
    var savedBoundary: Int {
      let column = source.primary.savedColumn
      if source.primary.savedPendingWrap { return column + 1 }
      return column > 0 && source.primary.rows[source.primary.savedRow].kind(at: column) == 3 ? column - 1 : column
    }
    var widthChanges: Bool { source.columns != geometry.columns }
    func row(_ index: Int) -> TerminalRow {
      index < source.history.count ? source.history[index] : source.primary.rows[index - source.history.count]
    }
    func outputEntry(_ index: Int) -> TerminalHistory.RetainedRow {
      if widthChanges { return output!.retainedRow(at: index) }
      if index < source.history.count { return source.history.retainedRow(at: index) }
      return TerminalHistory.RetainedRow(row(index))
    }
    static func sum(_ values: UInt64...) -> UInt64 {
      values.reduce(0) { partial, value in let (sum, overflow) = partial.addingReportingOverflow(value); return overflow ? UInt64.max : sum }
    }
    static func product(_ lhs: Int, _ rhs: UInt64) -> UInt64 {
      let (value, overflow) = UInt64(lhs).multipliedReportingOverflow(by: rhs); return overflow ? UInt64.max : value
    }
    func rejectBudget(_ required: UInt64) -> Step? {
      guard required <= ReflowReservationLedger.operationLimit else {
        guard !source.history.isEmpty else { return .rejected(.operationBudget) }
        requiredPressureBytes = required - ReflowReservationLedger.operationLimit
        return .pressure
      }
      guard let lease else { return .rejected(.noOperation) }
      guard lease.grow(to: required) else { return .rejected(.processBudget) }
      return nil
    }
    func step(work: inout Int) -> Step? {
      switch phase {
      case .setup:
        let blank = TerminalRow(columns: geometry.columns)
        newRowCharge = blank.retainedBaseCost; newRowAllocation = blank.allocationBaseCost
        ends.reserveCapacity(sourceCount)
        index = 0; phase = promptEraseStyle == nil ? .extents : .prompt
        work += geometry.columns
      case .prompt:
        if !promptPrepared {
          guard let prompt = source.primary.promptAnchor else { source.primary.retirePromptAnchor(); phase = .extents; index = 0; return nil }
          if index < source.primary.rows.count {
            if source.primary.rows[index].id == prompt.row { promptRow = index; promptPrepared = true }
            else { index += 1; work += 1; return nil }
          } else { source.primary.retirePromptAnchor(); phase = .extents; index = 0; return nil }
        }
        guard let promptRow, let prompt = source.primary.promptAnchor, let style = promptEraseStyle else { preconditionFailure() }
        if index == promptRow {
          if !prompt.pendingWrap {
            var primary = source.primary
            source.erase(&primary, row: index, columns: min(source.columns, max(0, prompt.column))..<source.columns, style: style)
            source.primary = primary
          }
        } else if index < source.primary.rows.count { source.primary.rows[index] = source.eraseRow(style) }
        if index < source.primary.rows.count { index += 1; work += source.columns * 2; return nil }
        source.primary.cursorRow = promptRow
        source.primary.cursorColumn = min(source.columns - 1, max(0, prompt.column))
        source.primary.pendingWrap = prompt.pendingWrap
        index = 0; phase = .extents
      case .extents:
        if !widthChanges {
          start = max(0, source.history.count - max(0, geometry.rows - source.rowCount))
          if cursorSource < start { start = cursorSource }
          if cursorSource >= start + geometry.rows { start = cursorSource + 1 - geometry.rows }
          plannedCount = sourceCount; retainedStart = start; phase = .retentionPlan; return nil
        }
        if index < sourceCount {
          let item = row(index)
          var extent = 0
          for cell in 0..<item.count where item.kind(at: cell) != 0 || item.style(at: cell).background != 0 { extent = cell + 1 }
          if extent > 0 || index <= cursorSource || index <= savedSource { lastRelevant = index }
          if item.softWrapped { extent = source.columns }
          if index == cursorSource { extent = max(extent, min(source.columns, cursorBoundary)) }
          if index == savedSource { extent = max(extent, min(source.columns, savedBoundary)) }
          ends.append(extent)
          work += item.count * 2; index += 1; return nil
        }
        let maximumHistoryRows = min(historyRows, Int(min(UInt64(Int.max), historyBytes / newRowCharge)))
        // A clipped-wide cell occupies one old slot but may recover two.
        let maximumOutput = Self.product(sourceCount, UInt64(1 + 2 * source.columns / geometry.columns))
        let capacity = Int(min(maximumOutput, UInt64(maximumHistoryRows + geometry.rows)))
        if let error = rejectBudget(Self.sum(lease!.bytes, PlanPages.allocationBytes(capacity: capacity))) { return error }
        plan = PlanPages(capacity: capacity)
        index = 0
        phase = .packingPlan
      case .packingPlan:
        if index <= lastRelevant {
          let item = row(index); var cell = 0
          if index == source.history.count { oldScreenStart = plannedCount }
          while cell <= ends[index] {
            let atEnd = cell == ends[index]
            let kind: UInt8 = atEnd ? 0 : item.kind(at: cell)
            let nominal = !atEnd && (kind == 2 || item.flags(at: cell) & 1 != 0) ? 2 : 1
            let width = min(nominal, geometry.columns)
            let wrapsAtom = !atEnd && kind != 3 && kind != 4 && plannedColumn + width > geometry.columns
            if wrapsAtom || (plannedColumn == geometry.columns && hasBeforeBoundary(index, cell, row: item)) { finishPlan() }
            if index == cursorSource && cell == cursorBoundary {
              start = min(max(oldScreenStart, plannedCount - geometry.rows + 1), plannedCount)
              windowPlanned = true
            }
            if atEnd { break }
            if kind == 3 || kind == 4 { cell += 1; continue }
            if kind != 0 {
              let storage = item.reflowCellStorage(at: cell)
              plannedPayloadBytes += storage.textBytes + storage.linkBytes
              if storage.sparse { plannedSparseCells += 1 }
              if width == 2 {
                let continuation = kind == 2 && cell + 1 < item.count && item.kind(at: cell + 1) == 3
                  ? item.reflowCellStorage(at: cell + 1) : storage
                plannedPayloadBytes += continuation.linkBytes
                if continuation.hasLink { plannedSparseCells += 1 }
              }
            }
            plannedColumn += width; cell += kind == 2 ? 2 : 1
          }
          if !continues(index) { finishPlan() }
          work += item.count; index += 1; return nil
        }
        if plannedCount == 0 { finishPlan() }
        start = min(max(0, start), plannedCount - 1)
        retainedStart = start; phase = .retentionPlan
      case .retentionPlan:
        if retainedStart > 0 && start - retainedStart < historyRows {
          let bytes = widthChanges ? plan![retainedStart - 1].chargedBytes : outputEntry(retainedStart - 1).chargedBytes
          if bytes <= historyBytes - retainedBytes {
            retainedStart -= 1; retainedBytes += bytes
            if widthChanges { replacementAllocation = Self.sum(replacementAllocation, plan![retainedStart].allocationBytes) }
            work += widthChanges || retainedStart < source.history.count ? 1 : source.columns
            return nil
          }
        }
        index = start; phase = .screenPlan
      case .screenPlan:
        if index < start + geometry.rows {
          let bytes = widthChanges && index < plannedCount ? plan![index].allocationBytes
            : (index >= plannedCount ? newRowAllocation : 0)
          replacementAllocation = Self.sum(replacementAllocation, bytes)
          index += 1; work += 1; return nil
        }
        phase = .allocation
      case .allocation:
        let retainedCount = min(plannedCount, start + geometry.rows) - retainedStart
        let required = Self.sum(lease!.bytes, replacementAllocation,
          Self.product(geometry.rows, newRowAllocation), alternateResources,
          Self.product(retainedCount + geometry.rows, 192))
        if let error = rejectBudget(required) { return error }
        working = source
        working!.setSize(columns: geometry.columns, rows: geometry.rows)
        working!.history = TerminalHistory()
        retainedRowIDs.reserveCapacity(start - retainedStart + geometry.rows * 2)
        working!.history.reserveReflowRows(start - retainedStart)
        screenRows.reserveCapacity(geometry.rows); alternateRows.reserveCapacity(geometry.rows)
        index = 0
        if widthChanges {
          output = RowPages(columns: geometry.columns, capacity: retainedCount, base: retainedStart)
          beginOutputRow(); phase = .packing
        } else { index = retainedStart; phase = .history }
        work += geometry.columns
      case .packing:
        guard index <= lastRelevant else {
          if packedCount == 0 { finish(soft: false); work += geometry.columns }
          precondition(packedCount == plannedCount)
          index = retainedStart; phase = .history; return nil
        }
        let item = row(index)
        if !enteredRow {
          if item.id == anchor, let current {
            mappedAnchor = index > 0 && row(index - 1).softWrapped ? (output!.last?.id ?? current.id) : current.id
          }
          enteredRow = true
        }
        let atEnd = sourceColumn >= ends[index]
        let kind: UInt8 = atEnd ? 0 : item.kind(at: sourceColumn)
        let flags: UInt8 = atEnd ? 0 : item.flags(at: sourceColumn)
        let nominal = kind == 2 || flags & 1 != 0 ? 2 : 1
        let occupied = kind == 2 ? 2 : 1
        let width = min(nominal, geometry.columns)
        let wrapsAtom = !atEnd && kind != 3 && kind != 4 && column + width > geometry.columns
        if wrapsAtom || (column == geometry.columns && hasBeforeBoundary(index, sourceColumn, row: item)) {
          if wrapsAtom && column < geometry.columns { current?.setKind(4, at: column) }
          finish(soft: true); work += geometry.columns
          if item.id == anchor && mappedAnchor == nil { mappedAnchor = current?.id }
        }
        mapBoundary(sourceIndex: index, sourceColumn: sourceColumn)
        guard !atEnd else {
          if !continues(index) { finish(soft: false); work += geometry.columns }
          sourceColumn = 0; enteredRow = false; index += 1; work += 1; return nil
        }
        if column < geometry.columns {
          var limit = min(ends[index], sourceColumn + geometry.columns - column)
          if index == cursorSource && cursorBoundary > sourceColumn { limit = min(limit, cursorBoundary) }
          if index == savedSource && savedBoundary > sourceColumn { limit = min(limit, savedBoundary) }
          if let prompt = source.primary.promptAnchor, item.id == prompt.row {
            let boundary = prompt.column + (prompt.pendingWrap ? 1 : 0)
            if boundary > sourceColumn { limit = min(limit, boundary) }
          }
          let run = item.unchangedReflowRun(from: sourceColumn, until: limit)
          if !run.isEmpty {
            current?.copyCells(from: item, range: run, to: column)
            sourceColumn += run.count; column += run.count; work += run.count
            return nil
          }
        }
        if kind == 3 || kind == 4 { sourceColumn += 1; work += 1; return nil }
        if current == nil {
          column += width; sourceColumn += occupied; work += nominal; return nil
        } else if kind == 0 { current!.erase(at: column, style: item.style(at: sourceColumn)) }
        else {
          current!.copyCell(from: item, at: sourceColumn, to: column)
          current!.setKind(width == 2 ? 2 : 1, at: column)
          current!.setFlags(width < nominal ? flags | 1 : flags & ~UInt8(1), at: column)
          if width == 2 {
            let continuation = kind == 2 && sourceColumn + 1 < item.count && item.kind(at: sourceColumn + 1) == 3
              ? sourceColumn + 1 : sourceColumn
            current!.copyCell(from: item, at: continuation, to: column + 1)
            current!.clearText(at: column + 1); current!.setKind(3, at: column + 1)
            current!.setFlags(item.flags(at: continuation) & ~UInt8(1), at: column + 1)
          }
        }
        column += width; sourceColumn += occupied; work += nominal
      case .history:
        if index < start {
          let entry = outputEntry(index)
          working!.history.appendRetained(entry); retainedRowIDs.insert(entry.row.id)
          index += 1; work += widthChanges || index <= source.history.count ? 1 : source.columns; return nil
        }
        index = 0; phase = .screen
      case .screen:
        if index < geometry.rows {
          if start + index < plannedCount { screenRows.append(widthChanges ? output![start + index] : row(start + index)) }
          else { screenRows.append(working!.blankRow()) }
          if index == geometry.rows - 1 && start + geometry.rows < plannedCount && screenRows[index].softWrapped {
            screenRows[index].softWrapped = false; screenRows[index].revision &+= 1
          }
          retainedRowIDs.insert(screenRows.last!.id)
          index += 1; work += geometry.columns; return nil
        }
        assemblePrimary()
        index = 0; phase = .alternate; work += geometry.rows
      case .alternate:
        if index < geometry.rows {
          let blank = working!.blankRow() // preserve row-ID consumption of the old crop/pad path
          if index < source.alternate.rows.count {
            alternateRows.append(working!.resizedRow(source.alternate.rows[index], columns: geometry.columns))
          } else { alternateRows.append(blank) }
          if index == geometry.rows - 1 && geometry.rows < source.alternate.rows.count && alternateRows[index].softWrapped {
            alternateRows[index].softWrapped = false; alternateRows[index].revision &+= 1
          }
          retainedRowIDs.insert(alternateRows.last!.id)
          index += 1; work += source.columns + geometry.columns; return nil
        }
        var alternate = source.alternate
        alternate.rows = alternateRows
        alternate.cursorRow = min(geometry.rows - 1, source.alternate.cursorRow)
        alternate.cursorColumn = min(geometry.columns - 1, source.alternate.cursorColumn)
        alternate.savedRow = min(geometry.rows - 1, source.alternate.savedRow)
        alternate.savedColumn = min(geometry.columns - 1, source.alternate.savedColumn)
        alternate.pendingWrap = source.alternate.pendingWrap && source.alternate.cursorColumn == geometry.columns - 1
        alternate.savedPendingWrap = source.alternate.savedPendingWrap && source.alternate.savedColumn == geometry.columns - 1
        alternate.topMargin = 0; alternate.bottomMargin = geometry.rows - 1
        alternate.leftMargin = 0; alternate.rightMargin = geometry.columns - 1
        if let prompt = alternate.promptAnchor, !alternateRows.contains(where: { $0.id == prompt.row }) { alternate.retirePromptAnchor() }
        alternate.keyboardFlags = source.alternate.keyboardFlags; alternate.keyboardStack = source.alternate.keyboardStack
        alternate.cursorVisible = source.alternate.cursorVisible; alternate.cursorShape = source.alternate.cursorShape
        working!.alternate = alternate; phase = .complete
      case .complete:
        return .ready
      }
      work += 1; return nil
    }
    func replacement() -> Replacement {
      Replacement(document: working!, mapping: TerminalDocument.ReflowMapping(
        anchor: widthChanges ? mappedAnchor : anchor, cursor: cursorMap, saved: savedMap),
        evictedHistory: retainedStart > 0, retainedRowIDs: retainedRowIDs)
    }
    func continues(_ sourceIndex: Int) -> Bool { sourceIndex < lastRelevant && row(sourceIndex).softWrapped }
    func hasBeforeBoundary(_ sourceIndex: Int, _ column: Int, row: TerminalRow) -> Bool {
      if sourceIndex == cursorSource && !source.primary.pendingWrap && column == cursorBoundary { return true }
      if sourceIndex == savedSource && !source.primary.savedPendingWrap && column == savedBoundary { return true }
      if let prompt = source.primary.promptAnchor, prompt.row == row.id, !prompt.pendingWrap && prompt.column == column { return true }
      return false
    }
    func finishPlan() {
      if !windowPlanned || plannedCount < start + geometry.rows {
        plan!.append(RowPlan(chargedBytes: newRowCharge + plannedPayloadBytes,
          allocationBytes: newRowAllocation + UInt64(plannedSparseCells) * 384 + plannedPayloadBytes * 2))
      }
      plannedCount += 1; plannedColumn = 0; plannedPayloadBytes = 0; plannedSparseCells = 0
    }
    func beginOutputRow() {
      if packedCount >= retainedStart && packedCount < min(plannedCount, start + geometry.rows) { current = working!.blankRow() }
      else { _ = working!.reserveRowIdentity(); current = nil }
    }
    func finish(soft: Bool) {
      if current != nil { current!.softWrapped = soft; output!.append(current!) }
      packedCount += 1; beginOutputRow(); column = 0
    }
    func mapBoundary(sourceIndex: Int, sourceColumn: Int) {
      if sourceIndex == cursorSource && sourceColumn == cursorBoundary {
        cursorMap = (packedCount, min(column, geometry.columns - 1), column == geometry.columns)
      }
      if sourceIndex == savedSource && sourceColumn == savedBoundary {
        savedMap = (packedCount, min(column, geometry.columns - 1), column == geometry.columns)
      }
      if let current, let prompt = source.primary.promptAnchor, row(sourceIndex).id == prompt.row,
         sourceColumn == prompt.column + (prompt.pendingWrap ? 1 : 0) {
        promptMap = PromptAnchor(row: current.id, column: min(column, geometry.columns - 1), pendingWrap: column == geometry.columns)
      }
    }
    func assemblePrimary() {
      var primary = source.primary
      primary.rows = screenRows
      if widthChanges {
        primary.cursorRow = min(geometry.rows - 1, max(0, cursorMap.row - start)); primary.cursorColumn = min(geometry.columns - 1, cursorMap.column)
        primary.pendingWrap = cursorMap.pending
        primary.savedRow = min(geometry.rows - 1, max(0, savedMap.row - start)); primary.savedColumn = min(geometry.columns - 1, savedMap.column)
        primary.savedPendingWrap = savedMap.pending
        primary.promptPhase = source.primary.promptPhase; primary.promptRedraw = source.primary.promptRedraw
        if let promptMap, screenRows.contains(where: { $0.id == promptMap.row }) { primary.promptAnchor = promptMap }
        else { primary.retirePromptAnchor() }
      } else {
        primary.cursorRow = min(geometry.rows - 1, max(0, cursorSource - start)); primary.savedRow = min(geometry.rows - 1, max(0, savedSource - start))
        if let prompt = source.primary.promptAnchor, !screenRows.contains(where: { $0.id == prompt.row }) { primary.retirePromptAnchor() }
        cursorMap = (primary.cursorRow, primary.cursorColumn, primary.pendingWrap)
        savedMap = (primary.savedRow, primary.savedColumn, primary.savedPendingWrap)
      }
      primary.topMargin = 0; primary.bottomMargin = geometry.rows - 1
      primary.leftMargin = 0; primary.rightMargin = geometry.columns - 1
      primary.keyboardFlags = source.primary.keyboardFlags; primary.keyboardStack = source.primary.keyboardStack
      primary.cursorVisible = source.primary.cursorVisible; primary.cursorShape = source.primary.cursorShape
      working!.primary = primary
    }
    func releaseResources() {
      // Clear rows before crediting the reservation; retained snapshots have
      // their own values and remain valid. This teardown never runs on owner.
      source = TerminalDocument(columns: 1, rows: 1)
      working = nil; output = nil; current = nil; plan = nil
      screenRows.removeAll(); alternateRows.removeAll(); ends.removeAll()
      retainedRowIDs.removeAll()
      lease = nil
    }
  }
}

// Internal implementation partition of TerminalDocument. It moves row slots
// and their sparse payloads together while rebuilding physical rows, and returns only the small mapping
// needed by the emulator to retain cursor and viewport identity.
extension TerminalDocument {
  struct ReflowMapping {
    var anchor: UInt64?
    var cursor: (row: Int, column: Int, pending: Bool)
    var saved: (row: Int, column: Int, pending: Bool)
  }

}

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
    let selection: TerminalSelectionReflowResult
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
       anchor: UInt64?, promptEraseStyle: TerminalStyle?, historyRows: Int, historyBytes: Int,
       primarySelection: TerminalSelectionReflowInput? = nil, alternateSelection: TerminalSelectionReflowInput? = nil) {
    guard geometry.isValid else { earlyStatus = .rejected(.invalidGeometry); return }
    // At most 8192 active rows, each O(1). No retained generation or private
    // builder allocation exists until its complete input reservation succeeds.
    var sourceBytes = State.sum(source.history.reflowAllocationBytes,
      UInt64(source.primary.rows.capacity + source.alternate.rows.capacity) * UInt64(TerminalRow.admissionStride))
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
      primarySelection?.content.allocationBytes ?? 0, alternateSelection?.content.allocationBytes ?? 0,
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
                  historyRows: historyRows, historyBytes: historyBytes, lease: lease, alternateResources: alternateResources,
                  primarySelection: primarySelection, alternateSelection: alternateSelection)
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
    var primarySelection: TerminalSelectionReflowTracker?
    var alternateSelection: TerminalSelectionReflowTracker?
    var selectionBudgetBase: UInt64 = 0

    init(source: TerminalDocument, geometry: TerminalResizeGeometry, anchor: UInt64?, promptEraseStyle: TerminalStyle?,
         historyRows: Int, historyBytes: Int, lease: ReflowReservationLedger.Lease, alternateResources: UInt64,
         primarySelection: TerminalSelectionReflowInput?, alternateSelection: TerminalSelectionReflowInput?) {
      self.source = source; self.geometry = geometry; self.anchor = anchor; self.promptEraseStyle = promptEraseStyle
      self.historyRows = max(0, historyRows); self.historyBytes = UInt64(max(0, historyBytes))
      self.lease = lease; self.alternateResources = alternateResources
      self.primarySelection = primarySelection.map(TerminalSelectionReflowTracker.init)
      self.alternateSelection = alternateSelection.map(TerminalSelectionReflowTracker.init)
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
          extent = max(extent, primarySelection?.extent(item.id) ?? 0)
          if extent > 0 || index <= cursorSource || index <= savedSource || primarySelection?.input.content.byRow[item.id] != nil { lastRelevant = index }
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
            if index == cursorSource && cell == cursorBoundary && source.primary.pendingWrap {
              start = min(max(oldScreenStart, plannedCount - geometry.rows + 1), plannedCount)
              windowPlanned = true
            }
            if wrapsAtom || (plannedColumn == geometry.columns && hasBeforeBoundary(index, cell, row: item)) { finishPlan() }
            if index == cursorSource && cell == cursorBoundary && !source.primary.pendingWrap {
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
          Self.product(retainedCount + geometry.rows,
            192 + UInt64(MemoryLayout<TerminalRow.SelectionObservation?>.stride)))
        if let error = rejectBudget(required) { return error }
        selectionBudgetBase = required
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
        if let error = reserveSelectionWork() { return error }
        guard index <= lastRelevant else {
          if packedCount == 0 { finish(soft: false); work += geometry.columns }
          precondition(packedCount == plannedCount)
          index = retainedStart; phase = .history; return nil
        }
        let item = row(index)
        if !enteredRow {
          primarySelection?.visit(item)
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
        mapBoundary(sourceIndex: index, sourceColumn: sourceColumn, after: true)
        primarySelection?.mapBoundary(source: item.id, column: sourceColumn, output: current?.id, targetColumn: column, after: true)
        if wrapsAtom || (column == geometry.columns && hasBeforeBoundary(index, sourceColumn, row: item)) {
          if wrapsAtom && column < geometry.columns { current?.setKind(4, at: column) }
          finish(soft: true); work += geometry.columns
          if item.id == anchor && mappedAnchor == nil { mappedAnchor = current?.id }
        }
        mapBoundary(sourceIndex: index, sourceColumn: sourceColumn, after: false)
        primarySelection?.mapBoundary(source: item.id, column: sourceColumn, output: current?.id, targetColumn: column, after: false)
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
          limit = primarySelection?.nextBoundary(item.id, after: sourceColumn, limit: limit) ?? limit
          let run = item.unchangedReflowRun(from: sourceColumn, until: limit)
          if !run.isEmpty {
            primarySelection?.copy(source: item.id, columns: run, target: column..<(column + run.count), retained: current != nil)
            current?.copyCells(from: item, range: run, to: column)
            sourceColumn += run.count; column += run.count; work += run.count
            return nil
          }
        }
        if kind == 3 || kind == 4 { sourceColumn += 1; work += 1; return nil }
        primarySelection?.copy(source: item.id, columns: sourceColumn..<(sourceColumn + occupied),
                               target: column..<(column + width), retained: current != nil)
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
        if let error = reserveSelectionWork() { return error }
        if index < start {
          var entry = outputEntry(index)
          if !widthChanges, let primarySelection {
            var row = entry.row
            primarySelection.transfer(&row, ordinal: index, mutable: false)
            entry = TerminalHistory.RetainedRow(row)
          }
          working!.history.appendRetained(entry); retainedRowIDs.insert(entry.row.id)
          index += 1; work += widthChanges || index <= source.history.count ? 1 : source.columns; return nil
        }
        index = 0; phase = .screen
      case .screen:
        if let error = reserveSelectionWork() { return error }
        if index < geometry.rows {
          if start + index < plannedCount { screenRows.append(widthChanges ? output![start + index] : row(start + index)) }
          else { screenRows.append(working!.blankRow()) }
          if index == geometry.rows - 1 && start + geometry.rows < plannedCount && screenRows[index].softWrapped {
            screenRows[index].softWrapped = false; screenRows[index].revision &+= 1
          }
          if !widthChanges { primarySelection?.transfer(&screenRows[index], ordinal: start + index, mutable: true) }
          retainedRowIDs.insert(screenRows.last!.id)
          index += 1; work += geometry.columns; return nil
        }
        assemblePrimary()
        index = 0; phase = .alternate; work += geometry.rows
      case .alternate:
        if let error = reserveSelectionWork() { return error }
        if index < geometry.rows {
          let blank = working!.blankRow() // preserve row-ID consumption of the old crop/pad path
          if index < source.alternate.rows.count {
            alternateRows.append(working!.resizedRow(source.alternate.rows[index], columns: geometry.columns))
          } else { alternateRows.append(blank) }
          if index == geometry.rows - 1 && geometry.rows < source.alternate.rows.count && alternateRows[index].softWrapped {
            alternateRows[index].softWrapped = false; alternateRows[index].revision &+= 1
          }
          alternateSelection?.transfer(&alternateRows[index], ordinal: index, mutable: true)
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
        primarySelection?.complete(); alternateSelection?.complete()
        return .ready
      }
      work += 1; return nil
    }
    func replacement() -> Replacement {
      Replacement(document: working!, mapping: TerminalDocument.ReflowMapping(
        anchor: widthChanges ? mappedAnchor : anchor, cursor: cursorMap, saved: savedMap),
        evictedHistory: retainedStart > 0, retainedRowIDs: retainedRowIDs,
        selection: TerminalSelectionReflowResult(primary: primarySelection?.output,
          alternate: alternateSelection?.output,
          primaryLost: primarySelection?.lost ?? false, alternateLost: alternateSelection?.lost ?? false,
          primaryOrigin: primarySelection?.origin, primaryHead: primarySelection?.head,
          alternateOrigin: alternateSelection?.origin, alternateHead: alternateSelection?.head))
    }
    func continues(_ sourceIndex: Int) -> Bool { sourceIndex < lastRelevant && row(sourceIndex).softWrapped }
    func hasBeforeBoundary(_ sourceIndex: Int, _ column: Int, row: TerminalRow) -> Bool {
      if primarySelection?.hasBeforeBoundary(row.id, column: column) == true { return true }
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
      if current != nil {
        current!.softWrapped = soft
        primarySelection?.finish(&current!, ordinal: packedCount, mutable: packedCount >= start)
        output!.append(current!)
      }
      packedCount += 1; beginOutputRow(); column = 0
    }
    func reserveSelectionWork() -> Step? {
      guard primarySelection != nil || alternateSelection != nil else { return nil }
      if primarySelection?.overflow == true || alternateSelection?.overflow == true { return .rejected(.operationBudget) }
      // One row can introduce at most one interval per output column. Reserve
      // dictionary/array growth and that scratch before touching the mapper.
      let required = Self.sum(selectionBudgetBase, primarySelection?.allocationBytes ?? 0,
        alternateSelection?.allocationBytes ?? 0, UInt64(geometry.columns) * 512 + 4096)
      return rejectBudget(required)
    }
    func mapBoundary(sourceIndex: Int, sourceColumn: Int, after: Bool) {
      if sourceIndex == cursorSource && sourceColumn == cursorBoundary && source.primary.pendingWrap == after {
        cursorMap = (packedCount, min(column, geometry.columns - 1), column == geometry.columns)
      }
      if sourceIndex == savedSource && sourceColumn == savedBoundary && source.primary.savedPendingWrap == after {
        savedMap = (packedCount, min(column, geometry.columns - 1), column == geometry.columns)
      }
      if let current, let prompt = source.primary.promptAnchor, row(sourceIndex).id == prompt.row,
         sourceColumn == prompt.column + (prompt.pendingWrap ? 1 : 0), prompt.pendingWrap == after {
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
      primarySelection = nil; alternateSelection = nil
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

// Selection remaps retain metadata only. Their ordered spans share the
// streaming document layout, without an all-history boundary map or cells.
struct TerminalSelectedSpan {
  let rowID: UInt64
  var columns: Range<Int>
  var softNextID: UInt64?
  let sourceOrdinal: Int
  let mutableAtCapture: Bool
  let group: Int
}
final class TerminalSelectionContent {
  var spans: [TerminalSelectedSpan] = []
  var byRow: [UInt64: Range<Int>] = [:]
  var mutableRows: [UInt64: Int] = [:]
  var allocationBytes: UInt64 {
    UInt64(spans.capacity * MemoryLayout<TerminalSelectedSpan>.stride)
      + UInt64(byRow.capacity) * 64 + UInt64(mutableRows.capacity) * 48 + 128
  }
  func append(_ span: TerminalSelectedSpan) {
    let index = spans.count
    spans.append(span)
    byRow[span.rowID] = (byRow[span.rowID]?.lowerBound ?? index)..<(index + 1)
    if span.mutableAtCapture { mutableRows[span.rowID] = span.sourceOrdinal }
  }
}
struct TerminalSelectionReflowInput {
  let generation: UInt64
  let rectangular: Bool
  let content: TerminalSelectionContent
  let origin: TerminalSelectionBoundary
  let head: TerminalSelectionBoundary
}
struct TerminalSelectionReflowResult {
  var primary: TerminalSelectionContent?
  var alternate: TerminalSelectionContent?
  var primaryLost = false
  var alternateLost = false
  var primaryOrigin: TerminalSelectionBoundary?
  var primaryHead: TerminalSelectionBoundary?
  var alternateOrigin: TerminalSelectionBoundary?
  var alternateHead: TerminalSelectionBoundary?
}

struct TerminalSelectionBoundary {
  let rowID: UInt64
  let column: Int
  let after: Bool
}
final class TerminalSelectionReflowTracker {
  let input: TerminalSelectionReflowInput
  let output = TerminalSelectionContent()
  var lost = false
  var overflow = false
  var origin: TerminalSelectionBoundary?
  var head: TerminalSelectionBoundary?
  private var segments: [(columns: Range<Int>, group: Int)] = []
  private var previous: (id: UInt64, soft: Bool)?
  private var seenRows = 0
  init(_ input: TerminalSelectionReflowInput) { self.input = input }
  var allocationBytes: UInt64 { output.allocationBytes + UInt64(segments.capacity) * 32 + 128 }
  func extent(_ row: UInt64) -> Int {
    var extent = 0
    if let indices = input.content.byRow[row], !indices.isEmpty { extent = input.content.spans[indices.upperBound - 1].columns.upperBound }
    if input.origin.rowID == row { extent = max(extent, input.origin.column) }
    if input.head.rowID == row { extent = max(extent, input.head.column) }
    return extent
  }
  func nextBoundary(_ row: UInt64, after column: Int, limit: Int) -> Int {
    var next = limit
    for boundary in [input.origin, input.head] where boundary.rowID == row && boundary.column > column { next = min(next, boundary.column) }
    return next
  }
  func hasBeforeBoundary(_ row: UInt64, column: Int) -> Bool {
    [input.origin, input.head].contains { $0.rowID == row && $0.column == column && !$0.after }
  }
  func mapBoundary(source row: UInt64, column: Int, output target: UInt64?, targetColumn: Int, after: Bool) {
    func mapped(_ boundary: TerminalSelectionBoundary) -> TerminalSelectionBoundary? {
      guard boundary.rowID == row, boundary.column == column, boundary.after == after else { return nil }
      guard let target else { lost = true; return nil }
      return TerminalSelectionBoundary(rowID: target, column: targetColumn, after: after)
    }
    if let value = mapped(input.origin) { origin = value }
    if let value = mapped(input.head) { head = value }
    if !after, let indices = input.content.byRow[row] {
      let spans = input.content.spans
      var lower = indices.lowerBound, upper = indices.upperBound
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if spans[middle].columns.lowerBound < column { lower = middle + 1 } else { upper = middle }
      }
      while lower < indices.upperBound && spans[lower].columns.lowerBound == column {
        let span = spans[lower]; lower += 1
        guard span.columns.isEmpty else { continue }
        if target != nil { append(targetColumn..<targetColumn, group: span.group) } else { lost = true }
      }
    }
  }
  func visit(_ row: TerminalRow) {
    guard input.content.byRow[row.id] != nil else { return }
    seenRows += 1
    if let observation = row.selectionObservation, observation.generation == input.generation, observation.overwritten { lost = true }
  }
  func copy(source row: UInt64, columns: Range<Int>, target: Range<Int>, retained: Bool) {
    guard let indices = input.content.byRow[row] else { return }
    let spans = input.content.spans
    var lower = indices.lowerBound, upper = indices.upperBound
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if spans[middle].columns.upperBound <= columns.lowerBound { lower = middle + 1 } else { upper = middle }
    }
    while lower < indices.upperBound && spans[lower].columns.lowerBound < columns.upperBound {
      let span = spans[lower]
      let start = max(span.columns.lowerBound, columns.lowerBound), end = min(span.columns.upperBound, columns.upperBound)
      if start < end {
        if !retained { lost = true }
        else if columns.count == target.count {
          append((target.lowerBound + start - columns.lowerBound)..<(target.lowerBound + end - columns.lowerBound), group: span.group)
        } else { append(target, group: span.group) } // indivisible wide/clipped atom
      }
      lower += 1
    }
  }
  private func append(_ columns: Range<Int>, group: Int) {
    if let last = segments.last, last.group == group, last.columns.upperBound == columns.lowerBound {
      segments[segments.count - 1].columns = last.columns.lowerBound..<columns.upperBound
    } else { segments.append((columns, group)) }
  }
  func finish(_ row: inout TerminalRow, ordinal: Int, mutable: Bool) {
    if let previous, previous.soft, let indices = output.byRow[previous.id] {
      output.spans[indices.upperBound - 1].softNextID = row.id
    }
    previous = (row.id, row.softWrapped)
    if !segments.isEmpty {
      guard output.spans.count <= 65_536 - segments.count else { overflow = true; segments.removeAll(keepingCapacity: true); return }
      var observation = TerminalRow.SelectionObservation(generation: input.generation,
        columns: segments[0].columns, observesSoftEdge: !input.rectangular)
      for (index, segment) in segments.enumerated() {
        if index > 0 { observation.include(segment.columns) }
        output.append(TerminalSelectedSpan(rowID: row.id, columns: segment.columns, softNextID: nil,
          sourceOrdinal: ordinal, mutableAtCapture: mutable, group: segment.group))
      }
      row.selectionObservation = observation
      segments.removeAll(keepingCapacity: true)
    } else { row.selectionObservation = nil }
  }
  func transfer(_ row: inout TerminalRow, ordinal: Int, mutable: Bool) {
    visit(row)
    if let indices = input.content.byRow[row.id] {
      for span in input.content.spans[indices] {
        if span.columns.upperBound > row.count { lost = true }
        else { append(span.columns, group: span.group) }
      }
    }
    for boundary in [input.origin, input.head] where boundary.rowID == row.id {
      if boundary.column > row.count { lost = true }
      else if boundary.rowID == input.origin.rowID && boundary.column == input.origin.column { origin = boundary }
      else { head = boundary }
    }
    if input.head.rowID == row.id, input.head.column <= row.count { head = input.head }
    finish(&row, ordinal: ordinal, mutable: mutable)
  }
  func complete() { if seenRows != input.content.byRow.count || origin == nil || head == nil { lost = true } }
}

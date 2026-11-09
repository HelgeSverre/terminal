import Foundation

enum TerminalPresentedContentProgress {
  case pending
  case accepted
  case rejected(TerminalSelectionFailure)
}

// Context is owner metadata, never a retained document/grid snapshot.
struct TerminalPresentationContext {
  let documentGeneration: UUID
  let screen: TerminalSelectionScreen
  let geometryEpoch: UInt64
  let snapshotID: UInt64
  let columns: Int

  func failure(for presentation: TerminalSelectionPresentation) -> TerminalSelectionFailure? {
    guard presentation.rows.count <= 4096,
      presentation.rows.capacity <= 512 * 1024 / MemoryLayout<TerminalSelectionPresentation.Row>.stride
    else { return .limitExceeded }
    guard presentation.snapshotID > 0, presentation.snapshotID <= snapshotID,
      presentation.documentGeneration == documentGeneration, presentation.screen == screen,
      presentation.geometryEpoch == geometryEpoch, presentation.columns == columns,
      TerminalSnapshot.geometryError(columns: columns, rows: presentation.rows.count) == nil
    else { return .staleTarget }
    return nil
  }
}

// Selection and content activation share identity, boundary and row-proof
// checks. Existing accepted selection anchors use their observation evidence;
// they do not pretend to be newly presented hits or pass a validation flag.
struct TerminalSelectionLookup {
  private var primary: [UInt64: Int] = [:]
  private var alternate: [UInt64: Int] = [:]
  init() {}
  init(_ document: TerminalDocument) {
    primary = Dictionary(uniqueKeysWithValues: document.primary.rows.enumerated().map { ($0.element.id, $0.offset) })
    alternate = Dictionary(uniqueKeysWithValues: document.alternate.rows.enumerated().map { ($0.element.id, $0.offset) })
  }
  mutating func addScreenRow(_ id: UInt64, at index: Int, screen: TerminalSelectionScreen) {
    if screen == .primary { primary[id] = index } else { alternate[id] = index }
  }
  func index(_ id: UInt64, screen: TerminalSelectionScreen, in document: TerminalDocument) -> Int? {
    guard id != 0 else { return nil }
    if screen == .alternate { return alternate[id] }
    if let index = document.history.index(ofRowID: id) { return index }
    return primary[id].map { document.history.count + $0 }
  }
  func acceptedBoundary(_ boundary: TerminalSelectionBoundary, screen: TerminalSelectionScreen,
                        in document: TerminalDocument) -> Int? {
    guard (0...document.columns).contains(boundary.column) else { return nil }
    return index(boundary.rowID, screen: screen, in: document)
  }
  func presentedHit(_ hit: TerminalSelectionHit, context: TerminalPresentationContext,
                    in document: TerminalDocument) -> Int? {
    guard context.failure(for: hit.presentation) == nil,
      hit.presentation.rows.indices.contains(hit.row),
      let index = acceptedBoundary(.init(rowID: hit.rowID, column: hit.boundary, after: hit.affinity == .after),
        screen: context.screen, in: document),
      Self.matches(document.selectionRow(at: index, screen: context.screen), proof: hit.presentation.rows[hit.row])
    else { return nil }
    return index
  }
  static func matches(_ row: TerminalRow, proof: TerminalSelectionPresentation.Row) -> Bool {
    proof.id != 0 && row.id == proof.id && row.revision == proof.revision && row.softWrapped == proof.softWrapped
  }
}
extension TerminalDocument {
  func selectionRow(at index: Int, screen: TerminalSelectionScreen) -> TerminalRow {
    if screen == .alternate { return alternate.rows[index] }
    return index < history.count ? history[index] : primary.rows[index - history.count]
  }
}

final class TerminalPresentedContentValidator {
  private let content: TerminalPresentedContent
  private var lookup = TerminalSelectionLookup()
  private var screenIndex = 0
  private var row: Int
  private var rangeIndex = 0
  private var firstDocumentIndex: Int?

  static func begin(_ content: TerminalPresentedContent,
                    context: TerminalPresentationContext) -> Result<TerminalPresentedContentValidator, TerminalSelectionFailure> {
    if let error = admission(content, context: context) { return .failure(error) }
    return .success(TerminalPresentedContentValidator(content))
  }
  private static func admission(_ content: TerminalPresentedContent,
                                context: TerminalPresentationContext) -> TerminalSelectionFailure? {
    if let error = context.failure(for: content.presentation) { return error }
    guard content.rows.count <= 4096,
      let bytes = content.retainedByteCount, bytes <= 512 * 1024
    else { return .limitExceeded }
    guard let first = content.rows.first, let last = content.rows.last,
      content.presentation.rows.indices.contains(first.row),
      content.presentation.rows.indices.contains(last.row), first.row <= last.row
    else { return .staleTarget }
    return nil
  }
  private init(_ content: TerminalPresentedContent) {
    self.content = content
    row = content.rows.first!.row // admission precedes capture
  }
  func advance(in document: TerminalDocument) -> TerminalPresentedContentProgress {
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000
    let screen = content.presentation.screen
    let screenCount = screen == .primary ? document.primary.rows.count : document.alternate.rows.count
    var units = 0
    while screenIndex < screenCount {
      let id = screen == .primary ? document.primary.rows[screenIndex].id : document.alternate.rows[screenIndex].id
      lookup.addScreenRow(id, at: screenIndex, screen: screen)
      screenIndex += 1; units += 1
      if units >= 256 || DispatchTime.now().uptimeNanoseconds >= deadline { return .pending }
    }
    let last = content.rows.last!.row
    while row <= last {
      let proof = content.presentation.rows[row]
      guard proof.id != 0 else { return .rejected(.staleTarget) }
      guard let index = lookup.index(proof.id, screen: screen, in: document) else { return .rejected(.evicted) }
      if let firstDocumentIndex {
        guard index - firstDocumentIndex == row - content.rows[0].row else { return .rejected(.staleTarget) }
      } else { firstDocumentIndex = index }
      let current = document.selectionRow(at: index, screen: screen)
      guard TerminalSelectionLookup.matches(current, proof: proof) else { return .rejected(.staleTarget) }
      if rangeIndex < content.rows.count {
        let range = content.rows[rangeIndex]
        guard range.row >= row else { return .rejected(.staleTarget) }
        if range.row == row {
          guard !range.columns.isEmpty, range.columns.lowerBound >= 0,
            range.columns.upperBound <= document.columns,
            current.kind(at: range.columns.lowerBound) != 3,
            (range.columns.upperBound == document.columns || current.kind(at: range.columns.upperBound) != 3)
          else { return .rejected(.staleTarget) }
          rangeIndex += 1
        }
      }
      row += 1; units += 1
      if units >= 256 || DispatchTime.now().uptimeNanoseconds >= deadline { return .pending }
    }
    return rangeIndex == content.rows.count ? .accepted : .rejected(.staleTarget)
  }
}

import Foundation
import TerminalEngine

/// The visible, actionable links in one immutable terminal snapshot.
///
/// This is deliberately presentation-side: OSC 8 remains terminal state, while
/// plain URL recognition is derived from the bounded visible grid.  Canvas and
/// accessibility consume the same occurrences so they cannot disagree about
/// what a click means.
package struct VisibleLinkProjection {
  /// An immutable, owner-validatable link activation. The URL policy and
  /// visible-cell proof are both established by this projection; consumers
  /// must not reconstruct either from a label, an AX string, or a pointer.
  package struct Activation: Equatable {
    package let target: URL
    package let content: TerminalPresentedContent

    fileprivate init(target: URL, content: TerminalPresentedContent) {
      self.target = target
      self.content = content
    }
  }
  package struct Occurrence: Equatable {
    package let target: URL
    /// Physical cell ranges, including both cells of a wide grapheme.
    package let gridSegments: [Range<Int>]
    /// The visible spelling, without an artificial separator at a soft wrap.
    package let label: String
    /// Missing for legacy or mismatched presentation metadata. The link can
    /// remain visible to AX, but it cannot bypass owner validation.
    package let activation: Activation?
    private let snapshotIdentity: SnapshotIdentity

    fileprivate init(target: URL, gridSegments: [Range<Int>], label: String, activation: Activation?,
                     snapshotIdentity: SnapshotIdentity) {
      self.target = target
      self.gridSegments = gridSegments
      self.label = label
      self.activation = activation
      self.snapshotIdentity = snapshotIdentity
    }

    package static func == (lhs: Occurrence, rhs: Occurrence) -> Bool {
      lhs.target == rhs.target && lhs.gridSegments == rhs.gridSegments && lhs.label == rhs.label
        && lhs.activation == rhs.activation && lhs.snapshotIdentity == rhs.snapshotIdentity
    }
  }

  fileprivate struct SnapshotIdentity: Equatable {
    package let revision: UInt64
    package let geometry: UInt64
    package let document: UInt64
    package let history: UInt64
    package let screen: UInt64
    package let viewport: UInt64
    package let scrollOffset: Int
    package let followingTail: Bool
  }

  private struct CellPart {
    package let text: String
    package let grid: Range<Int>
    /// Non-nil means OSC 8 explicitly annotated this cell. Invalid annotations
    /// are still a boundary: they must not silently become plain-text links.
    package let explicit: String?
  }
  private struct OccurrenceKey: Hashable { let target: String; let segments: [Range<Int>] }

  package let occurrences: [Occurrence]
  private let byGrid: [Int32]
  private static let maximumOccurrences = 4_096
  private static let maximumCandidateUTF16 = 8 * 1024
  private static let whitespaceAndNewlines = CharacterSet.whitespacesAndNewlines

  @inline(__always)
  private static func isURLWhitespaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    // Exactly the ASCII subset of Unicode Control plus Foundation whitespace:
    // C0, space, and DEL. Keep Foundation's existing Unicode policy outside it.
    if value < 0x80 { return value <= 0x20 || value == 0x7f }
    return scalar.properties.generalCategory == .control || whitespaceAndNewlines.contains(scalar)
  }

  @inline(__always)
  private static func isPlainTerminator(_ scalar: Unicode.Scalar) -> Bool {
    isURLWhitespaceOrControl(scalar) || scalar == "\"" || scalar == "'" || scalar == "<" || scalar == ">"
  }

  package init(snapshot: TerminalSnapshot) {
    let gridProduct = snapshot.cols.multipliedReportingOverflow(by: snapshot.rows.count)
    guard TerminalSnapshot.geometryError(columns: snapshot.cols, rows: snapshot.rows.count) == nil,
      !gridProduct.overflow
    else {
      occurrences = []
      byGrid = []
      return
    }
    let identity = SnapshotIdentity(
      revision: snapshot.revision, geometry: snapshot.geometry_epoch,
      document: snapshot.document_epoch, history: snapshot.history_epoch,
      screen: snapshot.screen_epoch, viewport: snapshot.viewport_clamp_revision,
      scrollOffset: snapshot.scroll_offset, followingTail: snapshot.following_tail)
    let presentation = Self.validatedPresentation(in: snapshot)
    var found: [Occurrence] = []
    var grid = [Int32](repeating: -1, count: gridProduct.partialValue)
    var emitted = Set<OccurrenceKey>()

    func append(_ target: URL, _ parts: [CellPart], label: String) {
      guard !parts.isEmpty, found.count < Self.maximumOccurrences,
        Self.openableURL(for: target.absoluteString) != nil
      else { return }
      var segments: [Range<Int>] = []
      for part in parts {
        if let last = segments.last, last.upperBound == part.grid.lowerBound {
          segments[segments.count - 1] = last.lowerBound..<part.grid.upperBound
        } else {
          segments.append(part.grid)
        }
      }
      guard emitted.insert(OccurrenceKey(target: target.absoluteString, segments: segments)).inserted else { return }
      let occurrence = Occurrence(
        target: target, gridSegments: segments, label: label,
        activation: Self.activation(target: target, segments: segments, presentation: presentation,
                                    columns: snapshot.cols, rowCount: snapshot.rows.count),
        snapshotIdentity: identity)
      let occurrenceIndex = Int32(found.count)
      found.append(occurrence)
      for segment in segments where segment.lowerBound >= 0 && segment.upperBound <= grid.count {
        for index in segment { grid[index] = occurrenceIndex }
      }
    }

    // Never gather a logical soft-wrapped line.  A visible grid can contain a
    // million cells in one logical line; only the still-unresolved URL token
    // is useful to the recognizer, and that token is bounded below.
    var explicitParts: [CellPart] = []
    var explicitRaw: String?
    var explicitUTF16 = 0
    var plainParts: [CellPart] = []
    var plainStart = 0
    var plainUTF16 = 0
    func emitExplicit() {
      defer { explicitParts.removeAll(keepingCapacity: true); explicitUTF16 = 0 }
      guard let raw = explicitRaw, let target = Self.openableURL(for: raw) else { return }
      append(target, explicitParts, label: explicitParts.map(\.text).joined())
    }
    func finishExplicit() {
      emitExplicit()
      explicitRaw = nil
    }
    func discardOverlongPlainPrefix() {
      // A candidate that fell out of this suffix is already longer than the
      // validation cap. Advancing an offset is O(1) per cell; compact only
      // after a whole buffer's worth has been retired, keeping the scan linear
      // for a giant non-delimited soft-wrapped token.
      while plainUTF16 > Self.maximumCandidateUTF16, plainStart < plainParts.count {
        plainUTF16 -= plainParts[plainStart].text.utf16.count
        plainStart += 1
      }
      if plainStart >= Self.maximumCandidateUTF16 {
        plainParts.removeFirst(plainStart)
        plainStart = 0
      }
    }
    func finishPlain() {
      let remaining = Self.maximumOccurrences - found.count
      if remaining > 0 {
        for candidate in Self.plainCandidates(in: Array(plainParts[plainStart...]), limit: remaining) {
          append(candidate.target, candidate.parts, label: candidate.label)
        }
      }
      plainParts.removeAll(keepingCapacity: true)
      plainStart = 0
      plainUTF16 = 0
    }
    func isTerminator(_ text: String) -> Bool {
      text.unicodeScalars.contains(where: Self.isPlainTerminator)
    }
    for (rowIndex, row) in snapshot.rows.enumerated() {
      for (column, cell) in row.cells.enumerated() {
        guard cell.kind != "Continuation" && cell.kind != "WrapSpacer" else { continue }
        let text = cell.kind == "Empty" ? " " : cell.text
        let width = cell.kind == "Lead2" ? 2 : 1
        let start = rowIndex * snapshot.cols + column
        let part = CellPart(text: text, grid: start..<(start + width), explicit: cell.link)
        if let raw = part.explicit {
          finishPlain()
          if raw != explicitRaw { finishExplicit(); explicitRaw = raw }
          explicitParts.append(part)
          explicitUTF16 += text.utf16.count
          // A pathological OSC 8 target is emitted in bounded chunks.  Normal
          // soft-wrapped links stay one occurrence across the row boundary.
          if explicitUTF16 > Self.maximumCandidateUTF16 { emitExplicit() }
        } else {
          if explicitRaw != nil { finishExplicit() }
          // Delimiters terminate a plain token but are not themselves part of
          // a candidate.  This avoids materializing even a one-cell buffer for
          // ordinary whitespace-only output.
          if isTerminator(text) {
            finishPlain()
          } else {
            plainParts.append(part)
            plainUTF16 += text.utf16.count
            if plainUTF16 > Self.maximumCandidateUTF16 { discardOverlongPlainPrefix() }
          }
        }
      }
      if !row.soft_wrapped || rowIndex + 1 == snapshot.rows.count {
        finishExplicit(); finishPlain()
      }
    }
    occurrences = found
    byGrid = grid
  }

  package func occurrence(atGrid index: Int) -> Occurrence? {
    guard byGrid.indices.contains(index) else { return nil }
    let stored = byGrid[index]
    return stored >= 0 && Int(stored) < occurrences.count ? occurrences[Int(stored)] : nil
  }

  private static func activation(
    target: URL, segments: [Range<Int>], presentation: TerminalSelectionPresentation?, columns: Int, rowCount: Int
  ) -> Activation? {
    guard let presentation, presentation.columns == columns, presentation.rows.count == rowCount,
      !segments.isEmpty
    else { return nil }
    var rows: [TerminalPresentedContent.RowRange] = []
    for segment in segments {
      guard segment.lowerBound >= 0, segment.lowerBound < segment.upperBound,
        segment.upperBound <= columns * rowCount
      else { return nil }
      var lower = segment.lowerBound
      while lower < segment.upperBound {
        let row = lower / columns
        let column = lower % columns
        let upper = min(segment.upperBound, (row + 1) * columns)
        let range = column..<(upper - row * columns)
        guard !range.isEmpty else { return nil }
        if let last = rows.last, last.row == row {
          rows[rows.count - 1] = .init(
            row: row,
            columns: min(last.columns.lowerBound, range.lowerBound)..<max(last.columns.upperBound, range.upperBound))
        } else {
          rows.append(.init(row: row, columns: range))
        }
        lower = upper
      }
    }
    guard rows.count <= 4_096 else { return nil }
    return Activation(target: target, content: TerminalPresentedContent(presentation: presentation, rows: rows))
  }

  /// Mirrors the projection's proof boundary: an action must be based on the
  /// displayed, owner-addressable rows, not merely a current URL string.
  private static func validatedPresentation(in snapshot: TerminalSnapshot) -> TerminalSelectionPresentation? {
    guard let presentation = snapshot.selectionPresentation,
      presentation.snapshotID != 0,
      presentation.geometryEpoch == snapshot.geometry_epoch,
      presentation.columns == snapshot.cols,
      presentation.rows.count == snapshot.rows.count,
      presentation.screen == (snapshot.alternate ? .alternate : .primary),
      zip(snapshot.rows, presentation.rows).allSatisfy({ row, proof in
        row.id != 0 && row.id == proof.id && row.revision == proof.revision
          && row.soft_wrapped == proof.softWrapped
      })
    else { return nil }
    return presentation
  }

  /// The only URL validation used for OSC 8, plain recognition, Canvas and AX.
  /// Plain recognition intentionally requires a scheme; it does not turn a
  /// bare host, local path, or arbitrary colon-delimited token into an action.
  package static func openableURL(for text: String?) -> URL? {
    guard let text, !text.isEmpty, text.utf8.count <= 8 * 1024,
      !text.unicodeScalars.contains(where: isURLWhitespaceOrControl),
      let components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(),
      let url = components.url
    else { return nil }
    switch scheme {
    case "http", "https":
      guard components.host?.isEmpty == false else { return nil }
    case "mailto":
      guard !components.path.isEmpty else { return nil }
    default:
      return nil
    }
    return url
  }

  private struct PlainCandidate {
    package let target: URL
    package let parts: [CellPart]
    package let label: String
  }

  private static func plainCandidates(in parts: [CellPart], limit: Int) -> [PlainCandidate] {
    guard !parts.isEmpty else { return [] }
    let text = parts.map(\.text).joined()
    let units = Array(text.utf16)
    var ranges: [Range<Int>] = []
    var offset = 0
    for part in parts {
      let next = offset + part.text.utf16.count
      ranges.append(offset..<next)
      offset = next
    }

    func foldedASCII(_ value: UInt16) -> UInt16 {
      (65...90).contains(value) ? value + 32 : value
    }
    func prefix(_ index: Int, _ value: [UInt16]) -> Bool {
      index + value.count <= units.count
        && zip(units[index..<(index + value.count)], value).allSatisfy { foldedASCII($0) == $1 }
    }
    func boundary(_ index: Int) -> Bool {
      guard index > 0 else { return true }
      let previous = units[index - 1]
      return !(previous >= 48 && previous <= 57 || previous >= 65 && previous <= 90
        || previous >= 97 && previous <= 122 || previous == 95)
    }
    var terminators = Set<Int>()
    var scalarOffset = 0
    for scalar in text.unicodeScalars {
      if isPlainTerminator(scalar) {
        terminators.insert(scalarOffset)
      }
      scalarOffset += scalar.utf16.count
    }
    func separator(at offset: Int) -> Bool {
      terminators.contains(offset)
    }

    let http = Array("http://".utf16)
    let https = Array("https://".utf16)
    let mailto = Array("mailto:".utf16)
    var output: [PlainCandidate] = []
    var partCursor = 0
    var index = 0
    while index < units.count {
      let isHTTP = prefix(index, http) || prefix(index, https)
      let isMail = prefix(index, mailto)
      guard boundary(index), isHTTP || isMail else { index += 1; continue }
      var end = index
      let maximumEnd = min(units.count, index + 8 * 1024)
      while end < maximumEnd && !separator(at: end) { end += 1 }
      // Do not truncate a longer token into a different, actionable URL.
      guard end == units.count || separator(at: end) else {
        while end < units.count && !separator(at: end) { end += 1 }
        index = end
        continue
      }
      end = trimmedURLBoundary(units, start: index, end: end)
      guard end > index else { index += 1; continue }
      let label = String(decoding: units[index..<end], as: UTF16.self)
      guard let target = openableURL(for: label) else { index = max(index + 1, end); continue }
      while partCursor < ranges.count && ranges[partCursor].upperBound <= index { partCursor += 1 }
      var matching: [CellPart] = []
      var matchingIndex = partCursor
      while matchingIndex < ranges.count && ranges[matchingIndex].lowerBound < end {
        if ranges[matchingIndex].upperBound > index { matching.append(parts[matchingIndex]) }
        matchingIndex += 1
      }
      guard !matching.isEmpty else { index = max(index + 1, end); continue }
      output.append(PlainCandidate(target: target, parts: matching, label: label))
      if output.count == limit { return output }
      index = end
    }
    return output
  }

  private static func trimmedURLBoundary(_ units: [UInt16], start: Int, end: Int) -> Int {
    var end = end
    func ascii(_ value: Character) -> UInt16 { Array(String(value).utf16)[0] }
    let trailing = Set([ascii("."), ascii(","), ascii(";"), ascii(":"), ascii("!"), ascii("?")])
    let pairs: [(UInt16, UInt16)] = [(ascii("("), ascii(")")), (ascii("["), ascii("]")), (ascii("{"), ascii("}"))]
    var counts = pairs.map { _ in (open: 0, close: 0) }
    for unit in units[start..<end] {
      for index in pairs.indices {
        if unit == pairs[index].0 { counts[index].open += 1 }
        if unit == pairs[index].1 { counts[index].close += 1 }
      }
    }
    while end > start {
      if trailing.contains(units[end - 1]) { end -= 1; continue }
      guard let index = pairs.firstIndex(where: { units[end - 1] == $0.1 }),
        counts[index].close > counts[index].open
      else { break }
      counts[index].close -= 1
      end -= 1
    }
    return end
  }
}

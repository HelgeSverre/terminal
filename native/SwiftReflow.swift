import Foundation

/// Reflows one contiguous terminal document (history followed by screen) without
/// leaking chain or anchor bookkeeping to its caller.  Callers provide physical
/// rows and receive physical rows plus the new viewport top; they never need to
/// reconstruct soft-wrap chains or repair a split wide glyph themselves.
enum SwiftReflow {
  /// A physical grid cell. A wide glyph is a `width == 2` lead followed by one
  /// continuation cell. Blank cells are normal width-one cells with empty text.
  struct Cell: Equatable {
    var text: String
    var width: Int
    var continuation: Bool

    init(_ text: String = "", width: Int = 1, continuation: Bool = false) {
      self.text = text
      self.width = width
      self.continuation = continuation
    }

    static let blank = Cell()
    static func wide(_ text: String) -> [Cell] {
      [Cell(text, width: 2), Cell("", width: 0, continuation: true)]
    }
  }

  struct Row: Equatable {
    var cells: [Cell]
    var softWrapped: Bool

    init(cells: [Cell], softWrapped: Bool = false) {
      self.cells = cells
      self.softWrapped = softWrapped
    }
  }

  struct Request {
    let rows: [Row]
    let oldColumns: Int
    let newColumns: Int
    /// Index into `rows` of the first row currently visible to the user.
    let viewportTop: Int

    init(rows: [Row], oldColumns: Int, newColumns: Int, viewportTop: Int) {
      self.rows = rows
      self.oldColumns = oldColumns
      self.newColumns = newColumns
      self.viewportTop = viewportTop
    }
  }

  struct Result {
    let rows: [Row]
    let viewportTop: Int
    /// True only when an invalid/evicted source anchor was clamped.
    let clamped: Bool
  }

  /// The sole API. Invalid geometry does not mutate the document and clamps the
  /// requested viewport. New rows are always exactly `newColumns` cells wide.
  static func reflow(_ request: Request) -> Result {
    guard request.oldColumns > 0, request.newColumns > 0 else {
      return Result(rows: request.rows, viewportTop: clamp(request.viewportTop, upper: request.rows.count), clamped: true)
    }
    guard !request.rows.isEmpty else { return Result(rows: [], viewportTop: 0, clamped: request.viewportTop != 0) }

    let normalized = request.rows.map { normalize($0, columns: request.oldColumns) }
    let sourceTop = clamp(request.viewportTop, upper: normalized.count)
    let anchorWasClamped = sourceTop != request.viewportTop
    let chains = chains(from: normalized, columns: request.oldColumns)
    let anchor = chains.anchor(forPhysicalRow: sourceTop)
    let emitted = emit(chains, columns: request.newColumns)
    let top = emitted.physicalRow(for: anchor)
    return Result(rows: emitted.rows, viewportTop: top, clamped: anchorWasClamped)
  }

  private struct Atom {
    let text: String
    let width: Int
  }

  private struct Chain {
    var atoms: [Atom]
    var sourceStarts: [(physical: Int, offset: Int)]
  }

  private struct Chains {
    var values: [Chain]
    var physicalAnchors: [(chain: Int, offset: Int)]

    func anchor(forPhysicalRow row: Int) -> (chain: Int, offset: Int) {
      guard physicalAnchors.indices.contains(row) else { return (max(0, values.count - 1), 0) }
      return physicalAnchors[row]
    }
  }

  private struct Emitted {
    var rows: [Row]
    var starts: [[Int]]

    func physicalRow(for anchor: (chain: Int, offset: Int)) -> Int {
      guard starts.indices.contains(anchor.chain), !starts[anchor.chain].isEmpty else { return 0 }
      let locations = starts[anchor.chain]
      var chosen = locations[0]
      for location in locations where location <= anchor.offset { chosen = location }
      // `starts` stores cell offsets, but the matching physical index is its
      // ordinal within all emitted rows for the chain; locate it once here.
      var prefix = 0
      for index in 0..<anchor.chain { prefix += starts[index].count }
      return prefix + starts[anchor.chain].firstIndex(of: chosen)!
    }
  }

  private static func clamp(_ value: Int, upper: Int) -> Int {
    max(0, min(value, max(0, upper - 1)))
  }

  private static func normalize(_ row: Row, columns: Int) -> Row {
    var cells = Array(row.cells.prefix(columns))
    if cells.count < columns { cells.append(contentsOf: repeatElement(.blank, count: columns - cells.count)) }
    // A dangling continuation has no lead. Preserve its physical width as a
    // blank rather than emitting an impossible continuation into a new layout.
    for index in cells.indices where cells[index].continuation && (index == 0 || cells[index - 1].width != 2) {
      cells[index] = .blank
    }
    return Row(cells: cells, softWrapped: row.softWrapped)
  }

  private static func chains(from rows: [Row], columns: Int) -> Chains {
    var values: [Chain] = []
    var anchors = Array(repeating: (chain: 0, offset: 0), count: rows.count)
    var atoms: [Atom] = []
    var starts: [(physical: Int, offset: Int)] = []
    var offset = 0
    var chainIndex = 0
    for (physical, row) in rows.enumerated() {
      anchors[physical] = (chainIndex, offset)
      starts.append((physical, offset))
      atoms.append(contentsOf: rowAtoms(in: row))
      offset += columns
      if !row.softWrapped {
        values.append(Chain(atoms: atoms, sourceStarts: starts))
        atoms.removeAll(keepingCapacity: true)
        starts.removeAll(keepingCapacity: true)
        offset = 0
        chainIndex += 1
      }
    }
    if !atoms.isEmpty || values.isEmpty { values.append(Chain(atoms: atoms, sourceStarts: starts)) }
    return Chains(values: values, physicalAnchors: anchors)
  }

  private static func rowAtoms(in row: Row) -> [Atom] {
    var output: [Atom] = []
    var column = 0
    while column < row.cells.count {
      let cell = row.cells[column]
      if cell.continuation { column += 1; continue }
      let requested = max(1, cell.width)
      let width = requested == 2 && column + 1 < row.cells.count && row.cells[column + 1].continuation ? 2 : 1
      output.append(Atom(text: cell.text, width: width))
      column += width
    }
    return output
  }

  private static func emit(_ chains: Chains, columns: Int) -> Emitted {
    var result: [Row] = []
    var starts: [[Int]] = []
    for chain in chains.values {
      var chainStarts: [Int] = []
      var row: [Cell] = []
      var consumed = 0
      func finish(softWrapped: Bool) {
        if row.count < columns { row.append(contentsOf: repeatElement(.blank, count: columns - row.count)) }
        result.append(Row(cells: row, softWrapped: softWrapped))
        row.removeAll(keepingCapacity: true)
      }
      if chain.atoms.isEmpty {
        chainStarts.append(0)
        finish(softWrapped: false)
      } else {
        for atom in chain.atoms {
          let width = min(atom.width, columns)
          if !row.isEmpty && row.count + width > columns {
            finish(softWrapped: true)
          }
          if row.isEmpty { chainStarts.append(consumed) }
          row.append(Cell(atom.text, width: width))
          if width == 2 { row.append(Cell("", width: 0, continuation: true)) }
          consumed += atom.width
          if row.count == columns && consumed < chain.atoms.reduce(0, { $0 + $1.width }) {
            finish(softWrapped: true)
          }
        }
        if !row.isEmpty { finish(softWrapped: false) }
      }
      starts.append(chainStarts)
    }
    return Emitted(rows: result, starts: starts)
  }
}

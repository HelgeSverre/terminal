#if os(iOS)
import UIKit

/// The input method edits only its pending composition. Terminal output is
/// immutable to UIKit; shell editing remains the remote program's job.
final class TouchComposition {
  static let maximumUTF16 = MarkedTextStorage.maximumLength
  var text = ""
  var selection = NSRange(location: 0, length: 0)
  var length: Int { text.utf16.count }
  func range(_ value: NSRange) -> NSRange {
    let start = min(length, max(0, value.location))
    let end = min(length, start + min(max(0, value.length), length - start))
    guard start < length else { return NSRange(location: start, length: 0) }
    let string = text as NSString
    // Never split a surrogate pair or a composed character during replacement.
    if end == start { return NSRange(location: string.rangeOfComposedCharacterSequence(at: start).location, length: 0) }
    return string.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
  }
  func set(_ value: String, selected: NSRange) {
    // Truncate on Character boundaries, not in the middle of a surrogate pair.
    var bounded = "", count = 0
    for character in value {
      let size = String(character).utf16.count
      if count + size > Self.maximumUTF16 { break }
      bounded.append(character); count += size
    }
    text = bounded
    selection = range(selected)
  }
  func replace(_ value: NSRange, with replacement: String) {
    let target = range(value)
    let updated = (text as NSString).replacingCharacters(in: target, with: replacement)
    set(updated, selected: NSRange(location: min(Self.maximumUTF16, target.location + replacement.utf16.count), length: 0))
  }
  func deleteBackward() {
    if selection.length > 0 { replace(selection, with: ""); return }
    guard selection.location > 0 else { return }
    let previous = (text as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1)
    replace(previous, with: "")
  }
}

final class TouchTextPosition: UITextPosition {
  let offset: Int
  init(_ offset: Int) { self.offset = offset; super.init() }
}
final class TouchTextRange: UITextRange {
  let value: NSRange
  init(_ value: NSRange) { self.value = value; super.init() }
  override var start: UITextPosition { TouchTextPosition(value.location) }
  override var end: UITextPosition { TouchTextPosition(NSMaxRange(value)) }
  override var isEmpty: Bool { value.length == 0 }
}
private final class TouchSelectionRect: UITextSelectionRect {
  let rectangle: CGRect
  let first: Bool, last: Bool
  init(_ rectangle: CGRect, first: Bool, last: Bool) {
    self.rectangle = rectangle; self.first = first; self.last = last; super.init()
  }
  override var rect: CGRect { rectangle }
  override var writingDirection: NSWritingDirection { .leftToRight }
  override var containsStart: Bool { first }
  override var containsEnd: Bool { last }
  override var isVertical: Bool { false }
}

extension TerminalCanvasView {
  var preeditPresentation: PreeditPresentation? {
    guard !composition.text.isEmpty, let snapshot else { return nil }
    return PreeditPresentation(text: NSAttributedString(string: composition.text, attributes: markedTextStyle),
      selection: composition.selection, columns: snapshot.cols, rows: snapshot.rows.count,
      cursorRow: snapshot.cursor.row, cursorColumn: snapshot.cursor.col)
  }
  func changeComposition(_ change: () -> Void) {
    inputDelegate?.textWillChange(self)
    inputDelegate?.selectionWillChange(self)
    change()
    inputDelegate?.selectionDidChange(self)
    inputDelegate?.textDidChange(self)
    redraw()
  }
  func cancelComposition() { changeComposition { composition.set("", selected: NSRange(location: 0, length: 0)) } }
  public var beginningOfDocument: UITextPosition { TouchTextPosition(0) }
  public var endOfDocument: UITextPosition { TouchTextPosition(composition.length) }
  public var selectedTextRange: UITextRange? {
    get { TouchTextRange(composition.selection) }
    set {
      guard let range = newValue as? TouchTextRange else { return }
      changeComposition { composition.selection = composition.range(range.value) }
    }
  }
  public var markedTextRange: UITextRange? {
    composition.text.isEmpty ? nil : TouchTextRange(NSRange(location: 0, length: composition.length))
  }
  public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    changeComposition { composition.set(markedText ?? "", selected: selectedRange) }
  }
  public func unmarkText() {
    let committed = composition.text
    cancelComposition()
    if !committed.isEmpty { _ = session.send(text: committed) }
  }
  public func text(in range: UITextRange) -> String? {
    guard let range = range as? TouchTextRange else { return nil }
    return (composition.text as NSString).substring(with: composition.range(range.value))
  }
  public func replace(_ range: UITextRange, withText text: String) {
    guard let range = range as? TouchTextRange else { return }
    if composition.text.isEmpty { insertText(text) }
    else { changeComposition { composition.replace(range.value, with: text) } }
  }
  public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
    guard let from = fromPosition as? TouchTextPosition, let to = toPosition as? TouchTextPosition else { return nil }
    return TouchTextRange(composition.range(NSRange(location: min(from.offset, to.offset), length: abs(to.offset - from.offset))))
  }
  public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
    guard let position = position as? TouchTextPosition else { return nil }
    let result = position.offset.addingReportingOverflow(offset)
    guard !result.overflow, (0...composition.length).contains(result.partialValue) else { return nil }
    return TouchTextPosition(result.partialValue)
  }
  public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
    guard offset != Int.min else { return nil }
    return self.position(from: position, offset: direction == .left || direction == .up ? -offset : offset)
  }
  public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
    let lhs = (position as? TouchTextPosition)?.offset ?? 0, rhs = (other as? TouchTextPosition)?.offset ?? 0
    return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
  }
  public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
    ((toPosition as? TouchTextPosition)?.offset ?? 0) - ((from as? TouchTextPosition)?.offset ?? 0)
  }
  public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
    direction == .left || direction == .up ? range.start : range.end
  }
  public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
    guard let position = position as? TouchTextPosition, composition.length > 0 else { return nil }
    let index = direction == .left || direction == .up ? position.offset - 1 : position.offset
    guard (0..<composition.length).contains(index) else { return nil }
    return TouchTextRange((composition.text as NSString).rangeOfComposedCharacterSequence(at: index))
  }
  public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
  public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
  public func firstRect(for range: UITextRange) -> CGRect {
    guard let range = range as? TouchTextRange, let segment = preeditPresentation?.firstSegment(for: range.value) else {
      return caretRect(for: range.start)
    }
    return CGRect(x: CGFloat(insetPixels + segment.column * cellWidth) / scale,
                  y: CGFloat(insetPixels + segment.row * cellHeight) / scale,
                  width: CGFloat(max(1, segment.cells) * cellWidth) / scale, height: CGFloat(cellHeight) / scale)
  }
  public func caretRect(for position: UITextPosition) -> CGRect {
    let offset = min(composition.length, max(0, (position as? TouchTextPosition)?.offset ?? 0))
    let segment = preeditPresentation?.firstSegment(for: NSRange(location: offset, length: 0))
    let row = segment?.row ?? snapshot?.cursor.row ?? 0
    let column = segment?.column ?? snapshot?.cursor.col ?? 0
    return CGRect(x: CGFloat(insetPixels + column * cellWidth) / scale,
                  y: CGFloat(insetPixels + row * cellHeight) / scale,
                  width: 2, height: CGFloat(cellHeight) / scale)
  }
  public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
    guard let range = range as? TouchTextRange, let preeditPresentation else { return [] }
    let spans = preeditPresentation.spans.filter { NSIntersectionRange($0.range, range.value).length > 0 }
    return spans.enumerated().map { index, span in
      TouchSelectionRect(CGRect(x: CGFloat(insetPixels + span.column * cellWidth) / scale,
        y: CGFloat(insetPixels + span.row * cellHeight) / scale, width: CGFloat(span.cells * cellWidth) / scale,
        height: CGFloat(cellHeight) / scale), first: index == 0, last: index == spans.count - 1)
    }
  }
  public func closestPosition(to point: CGPoint) -> UITextPosition? {
    closestPosition(to: point, within: TouchTextRange(NSRange(location: 0, length: composition.length)))
  }
  public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
    guard let range = range as? TouchTextRange else { return nil }
    let target = composition.range(range.value)
    // Reuse the renderer's bounded visible spans, including wide graphemes.
    let presentation = preeditPresentation
    let spans = presentation?.spans.filter { $0.range.location >= target.location && $0.range.location <= NSMaxRange(target) } ?? []
    let best = spans.min { a, b in
      let left = CGPoint(x: CGFloat(insetPixels + a.column * cellWidth) / scale, y: CGFloat(insetPixels + a.row * cellHeight) / scale)
      let right = CGPoint(x: CGFloat(insetPixels + b.column * cellWidth) / scale, y: CGFloat(insetPixels + b.row * cellHeight) / scale)
      return hypot(left.x - point.x, left.y - point.y) < hypot(right.x - point.x, right.y - point.y)
    }?.range.location ?? target.location
    return TouchTextPosition(best)
  }
  public func characterRange(at point: CGPoint) -> UITextRange? {
    guard let position = closestPosition(to: point) else { return nil }
    return characterRange(byExtending: position, in: .right)
  }
}
#endif

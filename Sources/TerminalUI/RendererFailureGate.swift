/// What became of one frame handed to the renderer.
package enum DrawOutcome {
  case submitted
  /// The drawable was supplied for another viewport size; the request stands.
  case staleDrawable
  /// Nothing can be drawn for this request, or the GPU refused it.
  case failed
}

/// Submission failures quiesce a surface until explicit new view demand.
/// Glyph completions and display-link callbacks cannot restart a failed loop.
package struct RendererFailureGate {
  package private(set) var blocked = false
  package mutating func requested() { blocked = false }
  /// Only a failure blocks. A stale drawable is retried with the next one.
  package mutating func finished(_ outcome: DrawOutcome, submittedGeneration: UInt64, currentGeneration: UInt64) {
    if outcome == .failed { failed(submittedGeneration: submittedGeneration, currentGeneration: currentGeneration) }
  }
  package mutating func failed(submittedGeneration: UInt64, currentGeneration: UInt64) {
    if submittedGeneration == currentGeneration { blocked = true }
  }
}

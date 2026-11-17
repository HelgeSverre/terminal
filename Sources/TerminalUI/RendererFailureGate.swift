/// Submission failures quiesce a surface until explicit new view demand.
/// Glyph completions and display-link callbacks cannot restart a failed loop.
package struct RendererFailureGate {
  package private(set) var blocked = false
  package mutating func requested() { blocked = false }
  package mutating func failed(submittedGeneration: UInt64, currentGeneration: UInt64) {
    if submittedGeneration == currentGeneration { blocked = true }
  }
}

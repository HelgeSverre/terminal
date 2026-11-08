# Native Swift terminal-engine research

## Scope, sources, and confidence

**Confidence: High for the source observations; Medium for the proposed
experiments.** This is a focused examination of the maintained native Swift
terminal engine [SwiftTerm at `ba89378`](https://github.com/migueldeicaza/SwiftTerm/tree/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1), retrieved on 2026-11-08. It is deliberately not a product survey: no second terminal engine was found necessary to answer the parser, row/history, and snapshot questions from the brief. All external sources below are first-party SwiftTerm source or benchmark material pinned to that revision.

The local comparison target is `terminal-swift-experiment` at
`43ef231afef6be7eac54e0eeecc3776944ef39e9`, on Apple Swift 6.2.4, Swift 5
language mode, `-O` and WMO, arm64 macOS 15. The local source already has the
right high-level row direction: reference-free `TerminalRowSlot`s, sparse
payloads, a custom COW storage seam, and direct bulk ASCII writes in
`native/TerminalDocument.swift:21-243`. Its Core retains a 1,024-scalar
scratch batch and has an existing borrowed `ASCIIInputScalars` view for long
plain input; that view enters the existing generic `TerminalDocument.print`
transaction, not a second placement API (`native/SwiftTerminalCore.swift:49-69`
and `201-229`).

No SwiftTerm code was built, benchmarked, or adopted for this research. The
facts below describe its implementation, not evidence that it is faster on
this app or host.

### Relevant upstream design, not a wholesale template

**Confidence: High.** SwiftTerm's parser takes an input `ArraySlice` and
immediately enters a borrowing `Span` path. In ground state it records a
print-run start and searches for the next C0 byte, then hands the whole
borrowed run to terminal printing only at a boundary. It holds parser buffers
in locals during the call and uses `inout` helpers specifically to keep those
locals from being captured. Incomplete DCS/OSC payloads are copied only when
they need to survive the feed call; normal text is not. Its OSC path also
searches a whole payload run for a control/ST boundary before appending the
bounded retained payload. These are concrete ownership and parser-boundary
choices, visible in [the borrowed parse loop](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/EscapeSequenceParser.swift#L1112-L1291) and [its whole-CSI fast path](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/EscapeSequenceParser.swift#L908-L994).

**Inference for ours (High):** the current Core has already taken the narrow
version of this idea: it scans a ground-state ASCII run, borrows it through
`ASCIIInputScalars`, and gives that `RandomAccessCollection` to the generic
document transaction; all other bytes stay on the normal decoder path
(`native/SwiftTerminalCore.swift:201-229` and `265-297`). It is therefore a
measurement/guard-tuning candidate, not a reason to add `Document.printASCII`.
The observed Core byte-admission samples and 59%/52% short-/long-ASCII pilot
ratios make it worth isolating, but do not prove this path is dominant.

**Confidence: High.** SwiftTerm separates row cell bits from uncommon shared
values: cells are packed values whose attribute/grapheme IDs refer to a
terminal-local arena. The arena's identifiers are never reused, its tables
are bounded, and a snapshot uses a read-only arena copy that can extend by
only the appended prefix. That lets its snapshot copy packed cells without
reading mutable live lookup tables afterward. See [the packed arena and its
bounded IDs](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/CellStorage.swift#L301-L368) and [snapshot-prefix synchronization](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/CellStorage.swift#L370-L480).

**Inference for ours (High):** our sparse-payload/reference-free slots already
solve the same broad problem without inventing an arena identifier space. A
SwiftTerm-like packed-cell migration would replace a passing, bounded COW
model, change representation seen by retained rows, and require new limits and
snapshot ownership proofs. It is not an experiment to queue for the 70% floor.

**Confidence: High.** SwiftTerm avoids rebuilding all render data merely
because a row scrolled. Its snapshot retains a pool of row objects, compares a
source identity and generation, copies only changed rows, and reuses the
prepared rows by buffer-line identity. It also moves deferred BiDi work after
the lock. The snapshot decision path is in [TerminalSnapshot](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/Apple/TerminalSnapshot.swift#L141-L291) and [its refresh loop](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/Apple/TerminalSnapshot.swift#L350-L521).

**Inference for ours (Medium):** binary publication currently walks every
visible row/cell, projects each cell, allocates borrowed C strings, and builds
new typed views on every call (`native/SwiftTerminalCore.swift:954-1000`). The
active `native/SnapshotBridge.swift` receives typed cell views and decodes only
small metadata JSON; it then copies the callback views into the owner snapshot
(`native/SnapshotBridge.swift:3-113`). `SwiftSnapshotBridge.swift` is an unused
old JSON bridge and is outside the current app source graph, so it is not
performance evidence. Publication remains a measurable candidate, but the
supplied profile attributes substantial work to Document/Core admission rather
than proving it dominates these pilots. Keep snapshot caching behind a separate
trace; do not introduce a second retained grid speculatively.

**Confidence: High.** For bounded scrollback, SwiftTerm uses a ring with a
logical start index and overwrites/recycles at capacity rather than repeatedly
removing index zero. The source also exposes why its implementation is not a
drop-in: it uses manually allocated optional slots, unchecked exclusivity in
non-debug builds, and an `unowned(unsafe)` owner. See [the ring storage and
ownership choices](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/CircularList.swift#L223-L355) and [recycle without a line retain](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/CircularList.swift#L407-L478).

**Inference for ours (Medium):** `enforceHistoryLimits` calls
`history.removeFirst()` for each evicted row (`native/SwiftTerminalCore.swift:833-842`). That can shift the retained-array tail, so it is an appropriate
line-heavy stress experiment, not an established explanation for the current
ASCII/ANSI measurements.

## Applicability matrix

| Technique observed in SwiftTerm | Applicability to `43ef231` | Deployment/toolchain status | Trade-off and guardrail |
| --- | --- | --- | --- |
| Borrow contiguous printable runs; dispatch/retain only at protocol boundaries | **High; already present as `ASCIIInputScalars` into generic `Document.print`** | Works with the existing C ABI `UnsafePointer<UInt8>` on macOS 15 / Swift 6.2.4. No `Span` ABI is needed. | Measure/tune this one admission seam; do not add a parallel `printASCII` placement API. It must stop before C0, ESC, and non-ASCII, preserve incomplete UTF-8 and resume offset semantics, and never reorder replies/history. |
| Keep CSI/OSC/APC accumulation as bounded bytes, decode only at dispatch | **High** for ANSI/control-heavy paths | `[UInt8]`, `ArraySlice`, and `UnsafeBufferPointer` are available on the stated target. | Retained payload is required across feeds; limits, BEL/ST, CAN/SUB, OSC 52, and malformed UTF-8 behavior must remain byte-identical. |
| SIMD/word scan for run boundaries | **Low now; possibly Medium after scalar run scanning is measured** | Availability is per API, not implied by the `Span` type: this SDK marks `Span` plus `ArraySlice.span`/`ContiguousArray.span` macOS 10.14.4, while `Array.span` and `InlineArray` are macOS 26. `Span`/`ArraySlice.span` can therefore support the stated macOS 15 target, but no generic `Collection` or `Array` conversion should be assumed. SwiftTerm's `RawSpan.load` implementation is also explicitly conditional on compiler 6.4+, so that exact branch is unavailable on Apple Swift 6.2.4; its fallback uses unsafe unaligned loads. [ByteRunScanner shows both branches.](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/ByteRunScanner.swift#L1-L320) | Do not begin with unsafe loads or underscored exclusivity controls. A scalar boundary scanner supplies the causality test; vectorization needs an independent speed and correctness result. Do not infer the usability of `~Escapable` or protocol-constrained `Span` APIs from these availability facts. |
| Packed values plus a stable arena | **Rejected for this acceptance cycle** | Swift 6.2/macOS 15 can express it, but no platform feature unlocks it. | It duplicates/replaces current sparse slots+COW and risks retained snapshots, capacity accounting, and Unicode/link correctness for unmeasured gain. |
| Fixed-capacity scrollback ring | **Medium, only after eviction trace** | Plain safe Swift is sufficient; do not import a dependency or copy SwiftTerm's raw-pointer ring. | Preserve row IDs/anchors, byte-limit accounting, reflow, snapshot order, and exact eviction. A ring must be the one retained history store, not a cache beside `[SwiftRow]`. |
| Per-row snapshot reuse | **Deferred** | No special deployment dependency. | SwiftTerm's retained snapshot/renderer cache is architecturally different from our synchronous borrowed C ABI. Add it only if a publication-only trace proves it, with ownership and memory-bound tests. |

SwiftTerm itself carries a Swift 6.2 package manifest and explicitly avoids an
Embedded setting on SwiftPM 6.2 because of a toolchain behavior; this supports
treating compiler-version details as part of each proposal rather than relying
on language labels. [Its manifest documents that gate.](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Package.swift#L1-L73)

## Ranked experiments

All expected mechanisms are hypotheses. None asserts a speedup; retain the
Rust snapshot branch and judge the floor only from the full shared app suite:
at least 70% of Rust's median for short ASCII, long ASCII, ANSI, and Unicode,
with 80% a stretch. The current pilot ratios are approximately 59%, 52%, 62%,
and 79%, respectively.

1. **Measure and, only if indicated, tune the existing borrowed ground-state ASCII admission — High confidence.**

   The current implementation already finds a contiguous `0x20...0x7e` run
   while `parser == .ground`, requires idle UTF-8 and no special charset, and
   feeds its borrowed `ASCIIInputScalars` to the existing generic
   `TerminalDocument.print` transaction. Keep that single writer and its first
   scalar/segmentation, placement, wrap, history, and identity boundaries.
   The experiment is to profile the 16-byte threshold and eligibility/fallback
   mix—not to introduce `TerminalDocument.printASCII(...)` or another placement
   path.

   * Expected mechanism: the existing path bypasses the per-byte switch and
     `UTF8Decoder.push` for proven ASCII, and avoids filling the 1,024-scalar
     scratch for that run. Profiling can establish whether threshold/scan cost
     or generic transaction work remains; neither result is assumed.
   * Validation: differential/oracle tests with every split point around ESC,
     C0, UTF-8 starts/continuations, margins, wrap, insert/protection and a
     full row/scroll; run the four shared app workloads plus a profile rooted
     at `feed`. Compare reply order, snapshots, history byte charge/eviction,
     and retained values, not just MiB/s.
   * Decision: keep only if every workload remains at/above the floor and the
     profile reduces the intended inclusive path without a Unicode or ANSI
     regression. The source precedent is SwiftTerm's run scan, while its own
     benchmark guide usefully keeps setup outside timed `feed` calls and uses
     fixed-size complete payloads. [Benchmark methodology source.](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Tools/SwiftTermBenchmarks/README.md#L1-L51)

2. **Replace `sequence: String` parser accumulation with a bounded byte buffer — High confidence.**

   Store CSI/OSC/APC bytes as `[UInt8]` plus explicit state (including a
   pending ESC/ST flag), reserve/retain capacity up to today's caps, and form a
   `String` or parsed parameters only in the existing final dispatch. Do this
   first without SIMD and without changing which state owns an ESC: current
   `feed` appends `UnicodeScalar(byte)` to `String`, checks `sequence.last`,
   and repeatedly measures `sequence.utf8.count` in these states
   (`native/SwiftTerminalCore.swift:247-303`).

   * Expected mechanism: remove repeated `String` Unicode bookkeeping from
     CSI/OSC/APC byte admission and make the retained-across-feed boundary
     explicit. It targets the 62%-of-Rust ANSI pilot directly, but remains
     unmeasured.
   * Validation: byte-by-byte and random chunking of CSI, OSC 8, OSC 52, APC,
     BEL/ST/CAN/SUB, oversized strings, non-ASCII payloads, and reply order;
     then the shared workload suite. Require unchanged terminal snapshots and
     bounded maximum retained bytes.
   * Decision: reject if the conversion merely moves work into `finishString`
     or changes malformed-sequence behavior. SwiftTerm's bounded OSC run
     handling is evidence for the design shape, not a proof of a numerical
     benefit on this parser.

3. **Measure then prototype a single safe fixed-capacity history store — Medium confidence.**

   First add measurement (not a new production representation) for evictions,
   bytes shifted or copied, viewport-anchor re-resolutions, and snapshot rows
   selected while history is full. If eviction shifting is material in a
   line-heavy workload, prototype a single logical ring with `(head, count)`;
   it must expose ordered slices/iteration without eagerly making
   `history + primary.rows`. Keep the current `SwiftRow` values and their COW
   snapshots—do not add a history cache.

   * Expected mechanism: avoid `removeFirst` tail movement as bounded history
     evicts at capacity. There is no evidence yet that this helps the four
     pilot workloads.
   * Validation: 10,000-row full-history scroll/eviction, byte-limit and
     count-limit combinations, anchored/non-tail viewport behavior, resize and
     reflow, JSON and binary snapshot order, plus shutdown/release checks.
   * Decision: land only with proof of material eviction cost and unchanged
     order/ownership. A safe array-backed implementation is required; do not
     copy SwiftTerm's `UnsafeMutablePointer`, `@exclusivity(unchecked)`, or
     `unowned(unsafe)` strategy just to chase its mechanics.

## Rejected/deferred ideas and remaining questions

**Confidence: High — reject for now:** replacing the row model with SwiftTerm's
packed-cell arena, changing snapshot ownership to a renderer-held mutable
cache, or importing its unsafe ring implementation. All are larger than the
measured gap, undermine the existing custom COW/sparse payload work, and lack
this app's measurements.

**Confidence: High — reject as a benchmark tactic:** disabling bounds,
overflow, exclusivity, or safety checks; adopting underscored attributes; or
claiming SIMD wins without a host profile. SwiftTerm's current code has
carefully delimited unsafe details, but that is not evidence that they are
necessary here.

**Confidence: Medium — unresolved:**

* How much of the 3,724 owner / 2,607 inclusive `feed` / 1,681 flush-site
  sample set is parser admission versus document mutation? The supplied sample
  counts overlap, so they cannot be turned into percentages.
* Does the C ABI's snapshot publication, rather than Core feed, materially
  affect each app workload? The active bridge's cell hand-off is typed and its
  JSON is metadata only; measure a publication-only trace before pursuing
  row-cache work.
* Can the existing borrowed ASCII collection retain every generic
  transaction's grapheme/wrap/identity boundary through all fallback cases?
  It must remain a guarded admission specialization, not a second document
  writer.
* `Span` deployment is API-specific: `Span` plus `ArraySlice.span` and
  `ContiguousArray.span` are SDK-available on macOS 10.14.4, but `Array.span`
  and `InlineArray` require macOS 26. The useful SwiftTerm `RawSpan.load` path
  is also not selected before compiler 6.4. The existing pointer ABI remains
  the stable experiment boundary on Swift 6.2.4/macOS 15; separate compiler
  work must establish any `~Escapable` or protocol-constrained design.

### Primary sources consulted

1. [SwiftTerm parser and borrowed-run paths](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/EscapeSequenceParser.swift#L908-L1291)
2. [SwiftTerm boundary scanner](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/ByteRunScanner.swift#L1-L320)
3. [SwiftTerm packed cells and snapshot arena](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/CellStorage.swift#L301-L480)
4. [SwiftTerm bounded line ring](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/CircularList.swift#L223-L478)
5. [SwiftTerm snapshot refresh and changed-row reuse](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/Apple/TerminalSnapshot.swift#L141-L525)
6. [SwiftTerm benchmark/profiling protocol](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Tools/SwiftTermBenchmarks/README.md#L1-L108)
7. [SwiftTerm package/toolchain gates](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Package.swift#L1-L73)

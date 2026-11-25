# Swift terminal performance: findings and decisions

## Outcome and scope

**High confidence in the source/API findings; performance gains remain
experiment-specific.** Four independent research streams examined the Swift
compiler and standard library, Apple Collections, SwiftNIO and SwiftTerm.
The reports separate documented behavior from hypotheses about this app:
[compiler/ownership](compiler-and-ownership.md),
[storage/collections](storage-and-collections.md),
[byte parsing](byte-parsing.md), and [terminal engines](terminal-engines.md).

The strongest opportunities are fewer operations per byte and per row,
with explicit ownership boundaries. There is no evidence for a compiler
annotation that makes the remaining gap disappear. WMO is already enabled.

**Measured follow-up:** the direct borrowed-view implementation `d934705`
passed correctness but regressed all four app workloads to
25.25/28.43/7.51/6.20 MiB/s, from `43ef231`'s
38.26/43.76/12.84/11.04. Its profile shows cheaper byte admission but more
time downstream in Document/Row; both paths are specialized, so this is not
proof of generic witness dispatch. The next controlled experiment batches
admission into the existing 1,024-scalar buffer, keeping ArraySlice as the
document's input type. Borrowing is a lifetime technique, not a speed guarantee.

The acceptance floor is **70% of Rust's median on each workload**, with
**80% a stretch target**. Longer repeated app trials and correctness/ownership
checks remain required. The Rust implementation is preserved on
[`archive/rust-2026-11-08`](https://github.com/HelgeSverre/terminal/tree/archive/rust-2026-11-08)
at `c8f279b`; creating that backup does not promote the Swift experiment.

## Decisions from the research

| Question | Decision for this app | Confidence and evidence |
| --- | --- | --- |
| How should contiguous text enter the emulator? | Borrow eligible ASCII input synchronously and project scalar values into the existing generic document writer. Preserve partial UTF-8, charset mapping, FIFO order and exact consumed-byte offsets. | High for lifetime/decoder contracts; Medium for speedup. [NIO readable-byte contract](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/ByteBuffer-core.swift#L1009-L1044), [SwiftTerm run parsing](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/EscapeSequenceParser.swift#L1112-L1291). |
| Where should COW/access checks occur? | At a row operation boundary: choose uniqueness once, mutate through one scoped buffer, and keep retained row/view snapshots immutable. | High for the mechanism. [Swift exclusivity guidance](https://www.swift.org/blog/swift-5-exclusivity/), [mutable buffer API](https://developer.apple.com/documentation/swift/array/withunsafemutablebufferpointer(_:)). |
| Which compiler changes should come first? | Keep `-O` plus WMO for measured release builds. Inspect optimized SIL/assembly before changing ownership annotations or forcing inline. Fast development builds may remain separate; shipping must retain the measured configuration. | High. [WMO](https://www.swift.org/blog/whole-module-optimizations/), [SIL](https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md), [cross-module inlining](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md). |
| Which newer Swift features work on this Mac? | Some Span APIs work, but availability differs by API and Span does not conform to Collection. InlineArray is outside the macOS-15 path. Use borrowing/consuming only where they match real ownership. | High: local compile/run checks plus [Span-providing APIs](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md), [ownership modifiers](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md). |
| What should happen to history storage? | Profile full-history eviction first, then replace Array front removal with one deque/ring if it is material. The current alternate-screen pilots do not test that cost. | High for collection complexity; Low for its contribution to these pilots. [Apple Collections Deque](https://github.com/apple/swift-collections#stable-data-structures). |
| What follows ASCII admission? | Profile CSI accumulation as bytes before extending the change to textual OSC/APC payloads. Keep framing, limits and malformed-input behavior explicit. | Medium. [NIO incremental scanning](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/NIOSplitLinesMessageDecoder.swift#L155-L207), [SwiftTerm parser](https://github.com/migueldeicaza/SwiftTerm/blob/ba89378a95a9070d3d8bcb9e15ad16b1762e50f1/Sources/SwiftTerm/EscapeSequenceParser.swift#L908-L1291). |
| Which plausible ideas should wait? | SIMD scanning, snapshot caching, new cell arenas and annotation churn need a remaining measured cost. They are not prerequisites for the 70% floor. | Medium; the individual reports explain the unknowns and validation needed. |

## Cross-system pattern matrix

**High confidence in the documented patterns; this is not a speed comparison
between libraries.** Each cell identifies the relevant evidence rather than
implying that adopting a dependency improves this terminal.

| Pattern | Swift/compiler | Swift Collections | SwiftNIO | SwiftTerm |
| --- | --- | --- | --- | --- |
| Ownership-aware mutation | `inout`, borrowing and COW guidance | COW containers | ByteBuffer ownership/slice contracts | Borrowed parser buffers and value snapshots |
| Contiguous borrowed input | Scoped buffers; selected Span APIs | Container-dependent | Readable-byte callback | Whole printable-run parsing |
| Efficient bounded history | A design choice, not a compiler flag | Deque/ring implementation | Adjacent buffering patterns | Logical ring storage |
| Specialization visibility | WMO; cross-module bodies where needed | Depends on module boundary | Typed buffer APIs | Compiler-version-specific scanner paths |
| Copy implementation wholesale? | No; verify available API and code generation | Not without build/size review | No dependency needed for an existing pointer ABI | No; its unsafe internals and arenas are different designs |

## Availability verified on the actual toolchain

**High confidence.** Research probes used Apple Swift 6.2.4,
`-swift-version 5 -target arm64-apple-macosx15.0`, and ran on macOS 15.6.
The installed SDK declares the first three APIs below from macOS 10.14.4;
the distinction was checked after an initial overgeneralization from a failed
`Array.span` probe. The individual reports retain commands and results.

| API/feature | macOS 15 result | Consequence |
| --- | --- | --- |
| `Span`, `ArraySlice.span`, `ContiguousArray.span` | Supported; actual slice/contiguous-array probe printed `2` / `3` | Potential local borrowed views; not a drop-in for `Collection<Unicode.Scalar>`. |
| `Array.span` | Requires macOS 26 | Do not use it in the common macOS-15 path. |
| `InlineArray` | Requires macOS 26 | Not suitable for this deployment target. |
| `Span` as a `Collection` or escaping stored value | Rejected by the relevant generic/escaping probes | The current C-pointer/generic writer seam still needs its scoped adapter. |
| `withUnsafeTemporaryAllocation` | Compiled and ran | Only temporary initialized scratch inside its closure; not retained parser state. |
| `[Token]` where `Token: ~Copyable` | Rejected in the tested configuration | Noncopyable rows are incompatible with the current arrays and snapshot model. |

## Implementation priorities and validation

**Medium confidence for the unmeasured changes.** Execute one hypothesis at a
time, keep negative results, and compare actual app throughput independently
from headless engine measurements.

1. **Amortized ASCII admission.** Test batch filling the existing scalar
   buffer after the direct-view regression above. Short fragments must be
   scanned once, not repeatedly. Preserve REP suffix ordering, decoder
   prefixes, DEC charset mapping, the 1,024-scalar scratch bound and the
   65,536-byte feed limit; reuse the same document writer.
2. **Keep non-history text in one document transaction.** Assign row IDs in
   their owner immediately, continue past alternate-screen replacements, and
   retain the primary-history yield needed for eviction/clamping.
3. **Measure row reset/recycling.** The remaining allocation/destruction path
   is a candidate when a removed row is not retained as history. Resetting it
   must preserve snapshot COW, new row identity, erasure style and charge.
4. **Re-profile ANSI and Unicode.** Consider CSI byte accumulation or sparse
   payload lookup changes only when the new profile identifies those costs.
5. **Test retained history and the SQL dump.** Add an eviction-heavy comparison
   before adopting a deque/ring; do not extrapolate alternate-screen results
   to the earlier large-dump requirement.

For each storage change retain the frozen 270-record comparison, exact
baseline-derived byte thresholds, complete snapshots and retained values.
For parser changes retain whole/byte/irregular chunking, invalid/incomplete
UTF-8, controls, replies, modes and exact consumption tests. Then use the
shared real-app benchmark with natural shutdown and owned-process cleanup.
No recommendation requires disabling exclusivity, bounds or overflow checks.

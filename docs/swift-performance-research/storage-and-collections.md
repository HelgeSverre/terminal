# Swift storage and collections: evidence and experiments

## Scope, version coverage, and method — High confidence

This report covers COW row storage and mutation scopes, sparse payload layout,
row allocation/recycling, and bounded FIFO history. It does **not** claim a
speedup: the only performance evidence in scope is the brief's profile
description, including empty-payload dictionary hashing and a small
uniqueness-check call site. The proposed changes remain hypotheses until the
frozen app comparison is rerun.

Source facts below come from public Swift/Apple and Apple-maintained
Collections sources. Repository-specific observations are explicitly marked
**Inference**. Source links were consulted on 2026-11-08; availability is
pinned more strongly by the local compiler probe than by upstream `main`.

The checked host/toolchain was:

```text
Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4)
-swift-version 5 -target arm64-apple-macosx15.0
runtime: macOS 15.6 (24G84), M2 Max
```

Two task-local, non-benchmark probes were run (no packages installed and no
app source changed):

```sh
swiftc -O -whole-module-optimization -swift-version 5 \
  -target arm64-apple-macosx15.0 /tmp/swift-storage-probe.swift \
  -o /tmp/swift-storage-probe && /tmp/swift-storage-probe
# withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16): compiled, ran; output 120

swiftc -O -whole-module-optimization -swift-version 5 \
  -target arm64-apple-macosx15.0 /tmp/swift-storage-probe.swift \
  -o /tmp/swift-storage-probe
# Array.span and InlineArray<4, UInt8>: compile failure, each “only available in macOS 26.0 or newer”
```

That failed probe was deliberately an `Array.span` probe, not a blanket test
of `Span`. A follow-up local compiler stream checked the SDK interface and
executed `ArraySlice.span` and `ContiguousArray.span` with the same language
mode, optimization, and macOS-15 target: they compiled and printed `2` and
`3`, respectively. The local SDK marks `Span`, `ArraySlice.span`, and
`ContiguousArray.span` available from macOS 10.14.4; it marks `Array.span`
and `InlineArray` macOS 26.0. That distinction controls the recommendations
below. The same check established that `Span<UInt8>` is nonescaping and does
not conform to `Collection`.

### Primary sources

1. [Swift optimizer guidance: container COW, `inout`, and layout tradeoffs](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst#using-container-types-efficiently).
2. [Swift standard library: front removal is O(*n*) for the general range-replaceable collection operation](https://github.com/swiftlang/swift/blob/main/stdlib/public/core/RangeReplaceableCollection.swift#L2703-L2767).
3. [Apple Swift Collections: public API status and `Deque` as a COW ring buffer](https://github.com/apple/swift-collections#stable-data-structures).
4. [Apple Swift Collections `RigidDeque` implementation notes: ring storage and its non-contiguity tradeoff](https://github.com/apple/swift-collections/blob/main/Sources/DequeModule/RigidDeque/RigidDeque.swift#L1052-L1081).
5. [Apple: `withUnsafeTemporaryAllocation` lifetime and initialization rules](https://developer.apple.com/documentation/swift/withunsafetemporaryallocation(bytecount:alignment:_:)).
6. [SE-0456: `Span`-providing properties, lifetime dependence, and potential bridging copy](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md).
7. [SE-0453: `InlineArray` fixed inline storage and deployment caveat](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md).
8. [Apple: `Array.withUnsafeMutableBufferPointer` provides mutable contiguous storage only for the closure](https://developer.apple.com/documentation/swift/array/withunsafemutablebufferpointer(_:)).

## Applicable techniques

| Technique | Source fact | Local applicability and relevant location | Constraints / tradeoffs | Confidence |
| --- | --- | --- | --- | --- |
| Keep value/COW rows; mutate at a narrow `inout` boundary | Swift containers use COW; copying occurs when shared storage is mutated, and Swift's optimizer guidance prefers in-place `inout` mutation to object reassignment. [Source 1](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst#using-container-types-efficiently) | **Inference:** `TerminalRow` already has a reference-backed COW store and calls `isKnownUniquelyReferenced` in `native/TerminalDocument.swift:122`; `TerminalDocument.printBatch` deliberately holds one selected screen (`:489-557`). Keep that ownership model, but arrange a whole same-row operation under one uniqueness check. | A captured `Cells` projection intentionally retains row storage (`:91-106`), so a later edit must still detach. Do not weaken snapshot ownership or retain an unsafe buffer past its scope. | High |
| Use a scoped mutable buffer only after choosing the COW boundary | The standard API gives a contiguous mutable buffer for the closure; the pointer must not escape. [Source 8](https://developer.apple.com/documentation/swift/array/withunsafemutablebufferpointer(_:)) | **Inference:** `replaceASCII` already calls `ensureUniqueForCellEdit()` once and then fills `slots` through `withUnsafeMutableBufferPointer` (`TerminalDocument.swift:225-242`). This is the correct pattern to extend to bulk erase/reset, not an argument to expose row storage publicly. | Bounds, initialization, aliasing, and all structural `Array` changes remain outside the pointer scope. A buffer scope does not make a shared row unique by itself. | High |
| Make the sparse payload table absent when it is empty | Swift's guidance says value types without references reduce retain/release traffic, while COW wrappers retain safety checks; it does not promise a dictionary optimization. [Source 1](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst#using-container-types-efficiently) | **Inference:** `TerminalRowStorage.payloads` is an always-present `[Int: TerminalRowPayload]` (`TerminalDocument.swift:47-53`) and hot projection probes it for every cell (`:102-120`). The brief's profile specifically observed hashing of empty payload dictionaries. Test `payloads: [Int: TerminalRowPayload]?`, normalized to `nil` when empty, with accessors that bypass lookup in that state. | This changes representation only; `nil` and empty must compare/serialize identically. It must retain existing rich-payload strings/links and exact `retainedStorageCost` accounting. It is a measured hypothesis, not a conclusion about `Dictionary`. | Medium |
| Recycle a discarded row only when it cannot become history | COW permits cheap copies until mutation, but a mutation of shared storage must copy. [Source 1](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst#using-container-types-efficiently) | **Inference:** full-width scrolling removes a row then allocates `TerminalRow.erased` (`TerminalDocument.swift:440-445`, `:629-636`). On alternate-screen, margin-only, or zero-retention paths, a removed row can be reset in place and inserted at the opposite end; on primary full-screen scrolling it becomes history and cannot be reused. | Reset must clear every payload, preserve new-row ID/revision semantics, styles, wide-pair invariants, and COW-detach if a published/saved snapshot shares the storage. It is not valid to recycle a history row. | Medium |
| Replace bounded history's front-erasing array only if eviction is materially hot | General `removeFirst` is documented O(*n*). [Source 2](https://github.com/swiftlang/swift/blob/main/stdlib/public/core/RangeReplaceableCollection.swift#L2703-L2767) Apple Collections defines stable `Deque` as a COW ring buffer. [Source 3](https://github.com/apple/swift-collections#stable-data-structures) Ring storage can be discontiguous. [Source 4](https://github.com/apple/swift-collections/blob/main/Sources/DequeModule/RigidDeque/RigidDeque.swift#L1052-L1081) | **Inference:** `SwiftTerminalCore.enforceHistoryLimits` evicts with `history.removeFirst()` (`native/SwiftTerminalCore.swift:830-842`) up to a 50,000-row configured cap. This is an asymptotic risk in eviction-heavy workloads, not evidence that it explains current short/long ASCII, ANSI, or Unicode pilot results. | The app is manually compiled with `swiftc` via `justfile`, not currently a SwiftPM target. Adding `swift-collections` changes build/release surface. A custom ring must replace—not mirror—history and preserve logical indexing, anchors, order, byte budget, and snapshot output. | High for complexity; Low for current-workload impact |
| Use temporary allocation only for truly local scratch | The supported API gives uninitialized temporary storage, may use heap or stack, auto-deallocates it after the closure, and forbids pointer escape. [Source 5](https://developer.apple.com/documentation/swift/withunsafetemporaryallocation(bytecount:alignment:_:)) The requested-target probe succeeded. | **Inference:** it could replace a demonstrably transient, bounded scratch buffer at an ABI boundary, but not `decodedScalars` or terminal state which survives partial input. Current byte/scalar state is in `SwiftTerminalCore.swift:118` and must survive parser chunking. | It has no guaranteed stack allocation and cannot carry protocol data across calls. No use should be introduced absent a specific allocation profile. | High |
| `Span` via `ArraySlice`/`ContiguousArray`, versus `Array.span` and `InlineArray` | `Span` views have lifetime-dependent borrowing; an array/string may be copied on Darwin if bridged. [Source 6](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md) `InlineArray` is fixed-size inline storage with deployment implications. [Source 7](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md) | **Local compiler/SDK fact:** `Span`, `ArraySlice.span`, and `ContiguousArray.span` are macOS-15 usable; `Array.span` and `InlineArray` diagnose as macOS-26-only. `Span<UInt8>` neither conforms to `Collection` nor escapes a normal function. **Inference:** the current `print<C: Collection>` scalar seam (`TerminalDocument.swift:464-476`) cannot take a `Span`; the C-pointer feed has no demonstrated need to construct one. | A local, nonescaping helper over a `ContiguousArray` or slice is available, but must not outlive its owner and cannot be dropped into generic collection APIs. Do not use preview/underscored substitutes. Reject `Array.span` and `InlineArray` for the macOS-15 core path; defer `Span` absent a measured, fitting helper. | High |

### COW and borrow-scope conclusion — High confidence

**Source fact:** COW is an ownership optimization, not a promise that every
mutation avoids a copy; `inout` permits the compiler to avoid a
pass-copy-reassign pattern in suitable code. [Source 1](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst#using-container-types-efficiently)

**Repository inference:** the existing `TerminalRow` box is a justified
snapshot boundary. The next reasonable change is not replacing it with raw
pointers or a second grid; it is adding internal, nonescaping bulk row
operations that call `ensureUniqueForCellEdit()` once, then use existing
arrays/buffer scopes. This directly targets the known uniqueness-check and
empty-payload observations while retaining `Row`/`Screen`/`Cells` snapshots.

## Ranked executable experiments

Each experiment is isolated, reversible, and has unknown speedup. “Pass”
requires both behavioral proof and the existing throughput rule: Swift must
reach at least 70% of Rust's median on **each** shared workload; 80% remains
a stretch, not a relaxed gate.

1. **Optional empty payload table, then profile all workloads — Medium confidence.**

   - Change only `TerminalRowStorage` internals so no rich payload storage is
     present for a completely scalar/blank row. Centralize lookup/insert/remove
     helpers; normalize empty back to `nil`. Keep slot layout, projected cells,
     history charge, and public ABI unchanged.
   - Mechanism to test: avoid hash-table lookup/removal work on the dominant
     empty-payload cell path identified in the prior profile. No speedup is
     assumed.
   - Validation: run the frozen 270-record snapshot comparison and its exact
     charges, revisions, retained values, byte thresholds, and memory-budget
     checks unchanged; run ownership/document semantic tests; then rebuild with
     `-O` + WMO and execute short ASCII, long ASCII, ANSI, and Unicode against
     the shared Rust medians. Retain profiles and reject on any regression or
     gate miss.

2. **One COW decision plus bulk reset for non-history row recycling — Medium confidence.**

   - Add a private `TerminalRow` reset/bulk-write primitive: detach once,
     clear payloads while retaining their capacity only when appropriate, fill
     slots inside one nonescaping mutable-buffer closure, and set row metadata
     explicitly. Use it only in paths where the removed row is not appended to
     primary history; preserve the current allocation path for history rows.
   - Mechanism to test: fewer repeated uniqueness checks and blank-row
     allocations during alternate/restricted scrolling and bulk erasure. This
     deliberately does not recycle a row still observable as history.
   - Validation: add focused retained-snapshot tests where a `Cells` view or
     copied row outlives a reset; verify IDs, revisions, soft-wrap, links,
     styles, wide-pair repair, history/byte accounting, alternate isolation,
     and row count. Then apply the unchanged 270-record/budget gate and all
     four shared throughput workloads above.

3. **History FIFO stress trial before choosing `Deque` or a small owned ring — High confidence for the problem, Low for payoff.**

   - First add a non-timing semantic stress case that exceeds both row and byte
     history limits while anchored away from tail. Profile that case to establish
     whether `enforceHistoryLimits` front removal is material. Only then put
     `history` behind a narrow FIFO abstraction. Prefer a pinned stable
     `Deque` only if the manual build can reproducibly vendor/build it; otherwise
     evaluate a small, owned ring replacing `[TerminalRow]`, not a duplicate
     cache.
   - Mechanism to test: remove O(*n*) contiguous front shifts on each eviction.
     A ring's non-contiguous physical storage is acceptable only behind the
     abstraction; callers retain logical zero-based history semantics.
   - Validation: preserve exact eviction order, `historyByteCount`, row IDs,
     `viewAnchor` clamping, search order, `rowsForSnapshot`, and the 64 MiB /
     50,000-row policy. Run a history-overflow differential fixture plus the
     frozen 270-record/budget gate and all four app workloads. Do not accept an
     extra retained array to make snapshots convenient.

## Rejected or deferred ideas

### `Array.span` and `InlineArray` — High confidence rejected for macOS 15

`Array.span` and `InlineArray` are macOS-26-only in the local SDK, and the
actual target probe rejects them. No `@_`/SPI/preview replacement is a stable
API recommendation.

### `Span` through `ArraySlice` or `ContiguousArray` — Medium confidence deferred

This is **available** on the macOS-15 target; it is not rejected on deployment
grounds. However, `Span<UInt8>` is nonescaping and not a `Collection`, while
the existing document batch API consumes `Collection<Unicode.Scalar>` and the
current ABI receives a C byte pointer. Do not force it into either seam. Revisit
only for a demonstrated local contiguous byte helper whose borrowing boundary
is smaller and clearer than the existing scoped pointer API.

### `withUnsafeTemporaryAllocation` as a parser-state replacement — High confidence rejected

It is available, but its pointer expires when the closure returns and storage
may be heap allocated. It cannot hold split UTF-8, escape, grapheme, reply, or
history state. Consider it only if a future profile points to a bounded,
single-call scratch allocation.

### Blind `Deque` migration — Medium confidence deferred

The front-removal complexity mismatch is real, but the present profiles call
out Core byte admission and Document work, not eviction. The manual `swiftc`
build means a dependency import is nontrivial. Measure the overflow case before
paying its integration and semantic-audit cost.

### Removing checks, using underscored internals, or keeping a parallel row grid — High confidence rejected

The Swift sources themselves caution that some performance techniques are
temporary/compiler-specific; their own examples identify underscored APIs as
unsupported. [Source 1](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst#unsafe-code)
None of these options preserves the required safety, snapshot ownership, or
one-representation memory budget.

## Open questions — Medium confidence

1. Does an optional payload table remove the observed dictionary hash work in
   optimized app code, or merely exchange it for optional branching?
2. Which currently retained `Cells`/row/screen snapshots cross a row mutation
   boundary often enough to force a COW clone? This needs an ownership test plus
   a profile, not speculation from `isKnownUniquelyReferenced` calls.
3. Under a history-overflow stream, are array front shifts a meaningful portion
   of wall time after row payloads are realistic, and is a stable dependency
   cheaper than a narrowly owned FIFO abstraction?
4. Can a non-history bulk reset preserve every detail of the frozen 270-record
   oracle, especially style-erasure, revisions, and viewport behavior? The
   answer must be demonstrated before it replaces allocation.

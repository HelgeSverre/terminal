# Compiler and ownership techniques for the Swift terminal

## Scope, evidence, and confidence

**Confidence: High for compiler/language availability and diagnostics; Medium for
the ranked code experiments.** This report covers compiler and ownership choices
for the Swift experiment only. It does not recommend changing its semantics,
snapshot contracts, memory bounds, shutdown behavior, or the C ABI.

The locally installed toolchain is `Apple Swift version 6.2.4
(swiftlang-6.2.4.1.4 clang-1700.6.4.2)`, targeting
`arm64-apple-macosx15.0`. The frozen `43ef231` release command already has
`-swift-version 5 -O -whole-module-optimization -target
arm64-apple-macosx15.0` ([build record](../../reports/swift-app-comparison-43ef231-wmo/build.json)).
`swiftc -help` on that exact compiler confirms `-emit-sil`, `-emit-silgen`,
`-emit-ir`, `-emit-assembly`, `-Rpass`, `-Rpass-missed`, and
`-save-optimization-record*` as supported driver options. The latter are
investigation outputs, not a stable machine-readable optimizer API.

Primary sources used (accessed 2026-11-08):

1. Swift.org, [Whole-Module Optimization](https://www.swift.org/blog/whole-module-optimizations/).
2. Swift Evolution, [SE-0377: parameter ownership modifiers](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md).
3. Swift Evolution, [SE-0390: noncopyable structs and enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md).
4. Swift.org, [Swift 5 exclusivity enforcement](https://www.swift.org/blog/swift-5-exclusivity/).
5. Swift language book, [Memory Safety / exclusive access](https://docs.swift.org/latest/documentation/the-swift-programming-language/memorysafety/).
6. Swift compiler source, [SIL documentation](https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md) and [compiler debugging output modes](https://github.com/swiftlang/swift/blob/main/docs/DebuggingTheCompiler.md).
7. Swift Evolution, [SE-0193: cross-module inlining and specialization](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md).
8. Swift Evolution, [SE-0447: Span](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md) and [SE-0453: InlineArray](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md).

Source facts below are linked; statements about this terminal are explicitly
labelled inferences and need the specified A/B validation.

### Span and fixed-array availability matrix

**Confidence: High.** The source proposals establish implementation status, but
deployment availability is API-specific; it must come from the selected SDK.
The local `MacOSX.sdk` arm64e Swift interface declares `Span` itself,
`ArraySlice.span`, and `ContiguousArray.span` as macOS 10.14.4; it declares
`Array.span` and `InlineArray` as macOS 26.0. These are materially different
APIs. Actual `-swift-version 5 -O -target arm64-apple-macosx15.0` binaries ran
on this Mac and printed `2` for `values[1...].span.count` and `3` for
`ContiguousArray(values).span.count`.

| API | macOS 15 status in this toolchain | Consequence here |
| --- | --- | --- |
| `Span<Element>`; `ArraySlice.span`; `ContiguousArray.span` | Available (10.14.4+) | May be used only within its lifetime-dependent, nonescaping scope. |
| `Array.span` | Unavailable (26.0+) | Do not write `someArray.span` in the macOS 15 core. |
| `InlineArray` | Unavailable (26.0+) | Not a macOS 15 core-path option. |

## Applicable techniques

**Confidence: High, except where marked Medium.**

| Technique | Source fact and deployment constraint | Local location and trade-off | Recommendation |
| --- | --- | --- | --- |
| Retain `-O` + WMO, then prove generated code | WMO lets the optimizer see the entire module, enabling cross-file inlining, concrete generic specialization and ARC analysis around calls ([Swift.org](https://www.swift.org/blog/whole-module-optimizations/)). The existing release compile is one WMO module. | All Swift sources, notably `native/SwiftTerminalCore.swift` and `native/TerminalDocument.swift`, are passed in one invocation. WMO costs build time; it is already paid. | Keep it. **Inference:** splitting/merging these two files or adding `@inlinable` will not improve visibility inside this current WMO unit. |
| Use `borrowing` only at demonstrable read-only value seams | `borrowing` and `consuming` select parameter conventions; their bindings are not implicitly copyable, and a `consuming` parameter gives the callee ownership for local mutation ([SE-0377](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md)). The modifiers affect ABI conventions, so do not casually apply them to externally stable APIs. | Existing `borrowing PrintAttributes` at `TerminalDocument.swift:466`, `:492`, and `:603` is a suitable intra-module read-only boundary. `attributes` contains a potentially retaining `String?`, so unwanted copies are meaningful. | Keep the existing narrow uses; add none wholesale. **Inference (Medium):** inspect optimized SIL first for `copy_value`/retain-release on a hot path, then compare an unannotated A/B only where it changes those operations. It cannot make copies in callees disappear. |
| Use `consuming` for real one-way ownership transfer, not snapshots | Noncopyable values model unique ownership; the initial feature deliberately excluded use in generic types such as `Array` and protocol conformances ([SE-0390](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md)). A local 6.2.4 / Swift-5-mode probe also rejects `[Token]` when `Token: ~Copyable`: `Array` requires `Copyable`. | `TerminalRow`, `TerminalScreen`, and history are value/COW snapshots in arrays (`TerminalDocument.swift:300-360`); `TerminalRowStorage` uses reference COW (`:45-58`). The opaque C core is a class handle. | Do **not** turn rows, screens, cells, or the core handle noncopyable. **Inference (High):** that conflicts with retained snapshots and current arrays before it can reduce their ARC/COW costs. A future noncopyable, non-escaping parser scratch resource is conceivable, but has no profile evidence. |
| Shorten mutable access and let the compiler prove exclusivity | Optimized Swift enforces exclusivity; the supported guidance is to avoid repeated class-property access in the hottest loops and make properties private/internal where possible, rather than disable checks ([Swift.org](https://www.swift.org/blog/swift-5-exclusivity/)). The language guarantees a long-lived access for `inout`/mutating calls and can prove some local stored-property accesses safe ([language book](https://docs.swift.org/latest/documentation/the-swift-programming-language/memorysafety/)). | The profile names a uniqueness-check call site. `TerminalRow.ensureUniqueForCellEdit()` (`TerminalDocument.swift:122-128`) runs before narrow row edits; `printBatch` already passes the selected screen `inout` once (`:464-476`, `:489-495`). | Preserve enforcement. **Inference (Medium):** concentrate a confirmed excess at the row boundary: one uniqueness check per contiguous edit transaction, then direct slots mutation, while keeping the current COW detach semantics. Do not broaden a borrow across callbacks/reentrancy or hold it across history publication. |
| Diagnose optimized SIL/assembly before annotations | SIL is the Swift-specific IR; mandatory passes canonicalize it and `-O` enables performance passes ([SIL docs](https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md)). The compiler documents `-emit-silgen`, `-emit-sil`, `-emit-ir`, and `-S`/assembly checkpoints ([debugging guide](https://github.com/swiftlang/swift/blob/main/docs/DebuggingTheCompiler.md)). | Probe `SwiftTerminalCore.feed`, `flushDecodedScalars`, `TerminalDocument.print/printBatch`, `replacePrintedASCII`, and `TerminalRow.ensureUniqueForCellEdit`. | Use the exact frozen release source list and flags, adding one output option at a time. Look for residual calls/generic witnesses, ARC (`retain_value`, `release_value`, `strong_retain`/`strong_release`), `begin_access`, and COW uniqueness calls. Confirm any suspected runtime check in final arm64 assembly (for example `swift_beginAccess`) before changing source. |
| Treat `@inlinable` and forced inline hints as exceptions | `@inlinable` exports a body for *other modules*; it exists to expose cross-module optimization, with resilience/API restrictions ([SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md)). WMO already has bodies of internal functions in this module. | `SwiftTerminalCore.emitDecoded` currently uses `@inline(__always)` (`SwiftTerminalCore.swift:153`). | No new `@inlinable`, `@_specialize`, `@_transparent`, or other underscored attributes. **Inference (Medium):** WMO means `@inlinable` adds no local visibility; forced inline may worsen code size/i-cache. Retain or remove the one existing forced hint only on an assembly/profile A/B. |
| Keep the current pointer-lifetime parser interface; assess Span narrowly | SE-0447 describes `Span` as a contiguous-memory view with lifetime constraints ([SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md)). The selected SDK makes `Span`, `ArraySlice.span`, and `ContiguousArray.span` available on 10.14.4+, but `Array.span` only on 26.0+ (matrix above). | The C ABI already calls `feed(_ bytes: UnsafePointer<UInt8>?, count: Int, now:)`, and processing stays within the call (`SwiftTerminalCore.swift:214-307`); it neither retains the pointer nor decodes each byte as `Character`. A local probe shows `Span<UInt8>` does **not** conform to `Collection`, and it is `~Escapable` (returning it from an ordinary function is rejected). The document batch seam is `Collection<Unicode.Scalar>` (`TerminalDocument.swift:464-496`), not a byte collection. | Do not create another byte representation or try to pass a Span to the document generic. The SDK also exposes a public but deliberately unsafe-named `Span(_unsafeStart:count:)`; do not recommend it as a replacement for this C ABI without a measured, leaf-only parser helper and a complete pointer-lifetime audit. **Inference (Medium):** first A/B an indexed pointer loop only if assembly proves `UnsafeBufferPointer(...).enumerated()` leaves iterator overhead; preserve the exact `offset + 1` REP return, caps, UTF-8 state, and control/Unicode order. |
| Use Span only for a demonstrable local contiguous-container seam | Span and its `ArraySlice`/`ContiguousArray` properties are deployed to macOS 15 here; it is a nonescaping view rather than a general collection (local SDK/probes above). | Turning incoming C bytes into `ArraySlice` or `ContiguousArray` would first allocate/copy them, violating the goal of eliminating admission overhead. The existing parsed scalar batch is an `Array<Unicode.Scalar>`/slice, but its downstream generic already expects `Collection`. | Defer. **Inference (Medium):** a Span may be useful later for a new leaf algorithm that already owns an `ArraySlice`/`ContiguousArray` and performs direct indexed reads before the owner mutates. It is not evidence for a parser rewrite, retained byte storage, or a new generic `Collection` abstraction. |
| Exclude `InlineArray`, not Span, from the macOS 15 hot path | `InlineArray` is implemented in Swift 6.2 ([SE-0453](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md)), but the selected SDK marks it and its subscript macOS 26.0+. | A local `-swift-version 5 -target arm64-apple-macosx15.0` probe reports the 26.0 availability error. | Reject `InlineArray` for the common terminal core on this deployment target. A separately availability-gated macOS-26 path cannot improve every shared workload on macOS 15. |

## Ranked experiments

**Speedup is unknown for all three. Confidence is Medium: the profile identifies
the vicinity, not a completed root-cause attribution.** Use the frozen baseline,
shared workload suite, retained snapshot/charge/revision assertions, and a fresh
Time Profiler run for each experiment. Do not rely on overlapping sample counts
as percentages.

1. **Prove and narrow the remaining row mutation/COW boundary** — inspect an
   optimized SIL and assembly build of the current release; if
   `ensureUniqueForCellEdit`/`swift_beginAccess` remains on the long-ASCII
   ASCII-run path, make the smallest `TerminalRow` bulk-edit helper that checks
   uniqueness once and performs the existing slot/payload edits directly.
   Relevant sites are `TerminalDocument.swift:122-175`, `:224-243`, and
   `:804-829`. Mechanism: fewer repeated uniqueness tests, dynamic accesses and
   ARC traffic without changing row storage or publication. Validate all
   snapshot ownership tests, history byte charges and frozen semantic records
   before measuring short/long ASCII, ANSI and Unicode against Rust. Stop if
   SIL already hoists/eliminates the work or if the profile does not move.

2. **Inspect the batch boundary, then remove only a surviving parser-loop
   abstraction** — compile the exact WMO command with `-emit-sil -O` and
   `-emit-assembly` (or the equivalent saved output) and inspect `feed`,
   `emitDecoded`, and `flushDecodedScalars` at `SwiftTerminalCore.swift:153-178`
   and `:214-307`. If assembly retains iterator calls/bookkeeping for the
   `UnsafeBufferPointer(...).enumerated()` loop, compare a bounded indexed
   pointer loop with identical state transitions; otherwise make no parser
   rewrite. Mechanism: remove only proven per-byte abstraction work while the
   bytes remain borrowed for the C callback duration. Validate byte-consumption
   return values, all split-UTF-8/control/reply fixtures, ordering, and the
   four workload medians. A result that helps only ASCII is insufficient for
   the acceptance floor.

3. **Use compiler evidence to remove rather than add annotations** — produce
   an optimization record (`-save-optimization-record-path`), narrow
   `-Rpass`/`-Rpass-missed` to a specific suspected transformation, and inspect
   final assembly for `emitDecoded` and the document printing chain. Then A/B
   the existing `@inline(__always)` at `SwiftTerminalCore.swift:153` only if a
   remaining call barrier is shown; do not add `@inlinable` in this WMO module.
   Mechanism: a smaller/hotter instruction footprint if the forced inline is
   counterproductive, or confirmation that it is necessary. Validate semantic
   outputs and profile samples first, then all four medians. This experiment is
   a diagnostic guardrail: it prevents speculative annotation churn, and may
   produce no source change.

## Rejected/deferred ideas and unresolved questions

**Confidence: High for rejections; Medium for unresolved attribution.**

- **Reject disabling checks:** no `-Ounchecked`,
  `-enforce-exclusivity=unchecked`, `-enforce-exclusivity=none`, or equivalent.
  Swift’s exclusivity guidance explicitly warns that disabling runtime
  enforcement can expose undefined behavior, crashes, and memory corruption
  ([Swift.org](https://www.swift.org/blog/swift-5-exclusivity/)). This is
  incompatible with the correctness requirement.
- **Reject noncopyable snapshots and containers:** current `Array` use does
  not accept a local `~Copyable` element under the requested toolchain/language
  mode, and snapshot sharing is intentional. Noncopyable types are not an ARC
  optimization switch for the existing model.
- **Defer only the unsupported pieces:** `InlineArray` and `Array.span` are
  macOS 26 APIs. `Span`, `ArraySlice.span`, and `ContiguousArray.span` are
  available on macOS 15, but their nonescaping/non-`Collection` shape does not
  fit the C pointer or `Collection<Unicode.Scalar>` document seam by itself.
  Do not add a duplicate buffer merely to manufacture a Span.
- **Do not promise a gain from `borrowing`, WMO, `final`, or forced inline:**
  WMO is already configured; the current `SwiftTerminalCore` is already
  `final` and its relevant state is private. Each annotation’s remaining
  benefit is a generated-code question.
- **Unresolved:** which profile frame owns the 159-sample uniqueness call site
  and whether it represents row detach, Array COW, or a dynamic access check;
  whether `enumerated()` survives optimized arm64 generation; and whether
  document work dominates after repeated `flushDecodedScalars` calls are
  attributed with non-overlapping measurements. Answer these from the emitted
  artifacts plus fresh profiles, not from source shape alone.

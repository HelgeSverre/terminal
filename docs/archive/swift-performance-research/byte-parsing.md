# Swift byte parsing: borrowing, state and bounded admission

## Scope and source coverage — High confidence

This report covers high-throughput byte admission in the Swift replacement at
`/Users/helge/code/terminal-swift-experiment`, without proposing a dependency
or a production-code change. It was written against the local compiler:

```text
Apple Swift 6.2.4 (swiftlang-6.2.4.1.4), arm64-apple-macosx15.0
-swift-version 5
```

The primary-source findings below are pinned to the source tips resolved on
2026-11-08: SwiftNIO `02d6d9ada2aac9dd15455548e497824b8a5ae9f3` and Swift
`abebf0614bc62de6568fe742ba498ccd50b06cde`. They are evidence about API and
implementation contracts, not a recommendation to add SwiftNIO.

**Source fact** labels describe those sources or the checked local code.
**Local inference** labels explain applicability to this terminal. A result is
not a promised speedup; the existing application measurements remain the
decision authority.

### Primary sources

1. SwiftNIO's [`ByteBuffer.withUnsafeReadableBytes`](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/ByteBuffer-core.swift#L1009-L1044) yields only readable bytes and says not to let the ordinary pointer escape its closure. Its separately named lifetime-management API requires balanced manual retain/release for an escaped pointer. **Source fact — High.**
2. SwiftNIO [`getSlice`](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/ByteBuffer-core.swift#L1090-L1156) normally shares storage, but its implementation deliberately copies once its slice-start limit is exceeded. “Slice” is therefore an ownership operation with a documented non-zero-copy fallback, not a blanket performance guarantee. **Source fact — High.**
3. SwiftNIO's [`SplitMessageDecoder`](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/NIOSplitLinesMessageDecoder.swift#L155-L207) remembers bytes already examined when it needs more input, then returns a readable slice only after the separator is found. **Source fact — High.**
4. SwiftNIO's [`NIOSingleStepByteToMessageDecoder`](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/SingleStepByteToMessageDecoder.swift#L29-L53) distinguishes ordinary decode from final/EOF decode; its adapter maps produced work to `continue` and incomplete input to `needMoreData`. **Source fact — High.**
5. The Swift standard-library [`String.UTF8View`](https://github.com/swiftlang/swift/blob/abebf0614bc62de6568fe742ba498ccd50b06cde/stdlib/public/core/StringUTF8View.swift#L115-L240) is a `BidirectionalCollection` whose index operations check/normalize encoding and select a fast UTF-8 or transcoding path. **Source fact — High.**

## Current boundary and implications — High confidence

`SwiftTerminalCore.feed` already receives `UnsafePointer<UInt8>` plus a length
([`SwiftTerminalCore.swift:214`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/SwiftTerminalCore.swift#L214)) and only the synchronous call can use it. The session obtains that pointer inside `Data.withUnsafeBytes`
([`Session.swift:499`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/Session.swift#L499)), so the byte storage remains owned by the queued output event but the pointer itself must not outlive that closure.

The owner FIFO retains an output event and its offset until `terminal_feed`
reports consumption ([`Session.swift:494`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/Session.swift#L494)). A zero return is meaningful: a bounded REP is advanced before later suffix bytes are admitted
([`SwiftTerminalCore.swift:214`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/SwiftTerminalCore.swift#L214)). The ABI also caps an offered turn at 65,536 bytes. These are protocol and scheduling semantics, not incidental parser details.

The hot ground-state path currently enumerates every byte, calls the incremental
decoder, and appends every decoded scalar to `decodedScalars`
([`SwiftTerminalCore.swift:226`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/SwiftTerminalCore.swift#L226)). The decoder deliberately preserves partial and malformed UTF-8 behavior across chunks
([`SwiftUnicode.swift:68`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/SwiftUnicode.swift#L68)). In contrast, `TerminalDocument.print` already accepts any `Collection<Unicode.Scalar>` and makes row/history/identity effects visible after a bounded transaction
([`TerminalDocument.swift:461`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/TerminalDocument.swift#L461)). Its existing ASCII replacement writes scalar values directly into row slots
([`TerminalDocument.swift:224`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/TerminalDocument.swift#L224)).

**Local inference — High:** the lowest-risk parsing experiment is not a second
document representation or an escaped zero-copy byte slice. It is a
non-escaping view over the existing ABI pointer, consumed immediately by the
same `TerminalDocument.print` transaction. The document retains scalar values
and its own payloads, never the offered input pointer.

## Applicable techniques

| Technique | Exact supporting source | Applicable local location | Deployment/ownership constraint and trade-off | Confidence |
| --- | --- | --- | --- | --- |
| Borrow readable input only for the duration of one parse call | [NIO readable-byte lifetime contract](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/ByteBuffer-core.swift#L1009-L1044) | `SwiftTerminalCore.feed` at `native/SwiftTerminalCore.swift:214`; `Session.pump` at `native/Session.swift:489` | Keep a raw-pointer scalar view local to `feed`/one call to `document.print`; do not store it in parser, row, history, reply or event state. This needs no new API and works with Swift 5 language mode. | High |
| Project an eligible printable-ASCII run as a non-allocating `Collection<Unicode.Scalar>` | `String.UTF8View` demonstrates that UTF-8 collection indexing has representation work [in the standard library](https://github.com/swiftlang/swift/blob/abebf0614bc62de6568fe742ba498ccd50b06cde/stdlib/public/core/StringUTF8View.swift#L115-L240); local document accepts a generic scalar collection at `native/TerminalDocument.swift:464` | Replace only the eligible branch within `native/SwiftTerminalCore.swift:226` | A tiny pointer+`Range<Int>` view can return `Unicode.Scalar(base[index])!` without `[Unicode.Scalar]`, `String`, or `Character`. It must be nonescaping and specialized/measured: a generic collection witness can erase the expected saving for short runs. | Medium |
| Preserve an explicit incomplete-input state, rather than decoding each transport chunk as a `String` | [NIO decoder normal vs EOF contract](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/SingleStepByteToMessageDecoder.swift#L29-L53) | `SwiftUnicode.UTF8Decoder` at `native/SwiftUnicode.swift:73`; `SwiftTerminalCore.finish` at `native/SwiftTerminalCore.swift:915` | Keep the current decoder for every non-eligible byte and at EOF. Whole-chunk `String(decoding:as:)` cannot substitute for this without re-proving partial-prefix and maximal-invalid-subpart behavior. | High |
| Use a byte accumulator only for bounded ASCII protocol syntax (CSI first) | [NIO scan cursor avoids rescanning incomplete input](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/NIOSplitLinesMessageDecoder.swift#L155-L207) | `sequence` and CSI collection at `native/SwiftTerminalCore.swift:247`; numeric parser at `native/SwiftTerminalCore.swift:375` | Reuse a bounded `[UInt8]` scratch store (the current CSI maximum is 16,384) and parse bytes directly. Do not apply it wholesale to OSC/APC: those paths have textual payload semantics and 65,536-byte limits that need separate equivalence tests. | Medium |
| Return the exact offered-byte offset and leave deferred work ahead of the suffix | [NIO’s continue/need-more-data state adapter](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/SingleStepByteToMessageDecoder.swift#L56-L77) | REP return at `native/SwiftTerminalCore.swift:216`; event replacement at `native/Session.swift:508` | A direct run may advance only by scalars actually accepted by the document. It must return `offset`, not `limit`, on a deferred condition, and must not consume/reorder the queued suffix. | High |
| Treat buffer slices as owned values, not a free parser optimization | [NIO slice sharing and copy fallback](https://github.com/apple/swift-nio/blob/02d6d9ada2aac9dd15455548e497824b8a5ae9f3/Sources/NIOCore/ByteBuffer-core.swift#L1090-L1156) | Queued `Data` output at `native/Session.swift:212` and `native/Session.swift:494` | Adding `ByteBuffer` merely to slice parser input is unproven: current input is already contiguous and borrowed. A retained slice could extend a whole event buffer’s lifetime, while NIO itself documents a copy fallback. | High |

### Eligibility contract for a borrowed ASCII projection — High confidence

The proposed fast path is eligible only when all of the following are true:

1. `parser` is `.ground`.
2. The UTF-8 decoder is idle **and** there is no unflushed prior decoded scalar.
   If prior decoded output exists, flush it before starting the direct run so
   source order is unchanged.
3. The selected charset is ordinary (`charsetSpecial[charsetSlot] == false`).
   DEC special graphics can remap printable ASCII bytes and must keep the
   scalar path.
4. Every offered byte in the candidate run is `0x20...0x7e`; stop before ESC,
   controls, DEL, or a non-ASCII byte.
5. The collection is used synchronously and the next outer offset is advanced
   by `PrintBatchEffect.consumedScalarCount`, not by the scanned extent.

**Source facts:** `printBatch` can stop after a row replacement to make
history/row identity visible ([`TerminalDocument.swift:522`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/TerminalDocument.swift#L522)); its own ASCII sub-run relies on the ordinary first-scalar transaction
([`TerminalDocument.swift:529`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/TerminalDocument.swift#L529)).  
**Local inference:** letting `document.print` remain the writer preserves that
transaction boundary, wrapping, insert-mode behavior, wide-pair repair,
history eviction, snapshots, `lastPrinted`, and style/link ownership. A parser
shortcut which writes row slots directly would duplicate those obligations and
is out of scope.

## Ranked experiments

### 1. Borrowed printable-ASCII window into the existing document writer — High confidence

**Change shape.** Add a private, nonescaping `ASCIIScalarWindow` that holds an
`UnsafePointer<UInt8>` and integer bounds and conforms to the minimum needed
`Collection` requirements. In the eligible ground state, scan a maximal
printable run within the existing `limit`; call the existing
`document.print(windowSuffix, ...)`; apply its effect; and advance exactly by
`consumedScalarCount`. Repeat until the scanned run is exhausted or the normal
state machine must resume. Do not materialize `decodedScalars`, a `String`, or
`Character` values for that run.

**Expected mechanism, not a result.** This removes the current per-byte
`UTF8Decoder.push` result dispatch and `[Unicode.Scalar].append` admission
from long ordinary ASCII, while deliberately retaining the same document
writer. It is relevant to the observed long-ASCII `feed`/flush samples; its
speedup is unknown.

**Correctness gates.** Preserve every partition result for each byte boundary,
including a run ending before UTF-8, ESC/CSI/OSC/APC, C0 control, SO/SI, DEC
special graphics, and a row/history boundary. Replay snapshot, revision,
history-byte, reply and `terminal_validate` oracles. In particular, test a
CSI REP followed by an ASCII suffix: the REP's empty turns must finish before
that suffix is replayed. Retain the 65,536-byte offer bound and assert
`0 <= returned <= offered`; a zero return is valid only while
`terminal_has_work` is true.

**Measure.** First compare direct-path disabled versus enabled across the four
shared workloads with their normal partitioning; collect median throughput,
allocation/retain counts, and inclusive/exclusive `feed`, decoder, flush and
document samples. Then run a threshold sweep for small mixed fragments (for
example 0/direct-all, 8, 16, 32, and 64 bytes), selecting only an observed
winner that does not regress any workload. No threshold is assumed in advance.

### 2. CSI-only bounded byte accumulator and byte-native parameter parser — Medium confidence

**Change shape.** Split the current `sequence: String` role. For `.csi`, reuse
a capacity-bounded `[UInt8]` (maximum 16,384 bytes) and pass the final byte as
`UInt8`; refactor `parseCSIParameters`/`handleCSI` to consume that byte
collection without a transient `String` or `Character`. Keep the legacy
grammar: non-ASCII rejects the command, integer overflow rejects it, colon SGR
and `CSI >`/`CSI = ... u` preserve their current special treatment. Keep OSC,
APC and OSC 52 unchanged in this experiment.

**Expected mechanism, not a result.** ANSI-heavy input currently appends one
byte at a time to `String.unicodeScalars` and subsequently walks `raw.utf8`.
The change can remove representation and conversion work for CSI syntax, but
ANSI throughput may be dominated elsewhere; benefit is unknown.

**Correctness gates.** Use existing CSI oracle cases plus every byte split of
CSI sequences, 16,383/16,384/16,385-byte bounds, malformed/non-ASCII bytes,
numeric overflow, colon SGR, kitty keyboard prefixes, mode replies and REP.
Compare reply bytes, screen/history snapshots, epochs and acceptance order to
the current implementation. Keep the event FIFO and all buffer limits.

**Measure.** Attribute allocations and CPU samples specifically to
`SwiftTerminalCore.feed`, CSI accumulation and `parseCSIParameters`; compare
short ASCII, ANSI, and a deliberately CSI-dense trace. Reject it if it adds a
long-ASCII regression or makes the code retain a second unbounded payload
representation.

### 3. Owned ingress slab without the `[UInt8]`-prefix-to-`Data` copy — Medium confidence

**Change shape.** Investigate a read buffer whose final `Data` object becomes
the queued output event, rather than reading into `[UInt8]` and constructing
`Data(slab.prefix(count))` at `Session.readAvailable`
([`Session.swift:608`](https://github.com/HelgeSverre/terminal/blob/swift-experiment-20261108-43ef231/native/Session.swift#L608)). The event must continue to own the bytes until its `offset` reaches
the data count; `feed` still borrows its pointer synchronously. Establish with
allocation instrumentation that the chosen Foundation operation actually
avoids the copy on this OS/runtime before accepting it.

**Expected mechanism, not a result.** The current 16 KiB ingress path appears
to create a `Data` value from a prefix for each successful read. Avoiding that
copy could reduce admission work before parsing; Foundation storage behavior is
not a source-level guarantee here, so benefit is unknown.

**Correctness gates.** Preserve `EINTR`/`EAGAIN`/EOF handling, 65,536-byte
read-turn cap, 2 MiB output backpressure, accounting (`queuedOutput`,
`bytesRead`, `bytesParsed`), offset retries, close/drain behavior and the
single owner queue. Test a partially consumed event followed by REP and
newly-read output so no bytes are lost or overtaken.

**Measure.** Count `Data`/heap allocations and copied bytes around the read and
queue boundary, then evaluate all shared workloads. Do not infer a parser
speedup from a microbenchmark alone, and do not hold an unsafe pointer beyond
the `withUnsafeBytes` closure.

## Rejected or deferred ideas

| Idea | Disposition | Reason |
| --- | --- | --- |
| Add SwiftNIO/`ByteBuffer` solely for parser slices | Rejected for this stage — High | The existing ABI already supplies a contiguous borrowed pointer. NIO’s useful contracts are design evidence, but introducing COW storage, retention and an extra dependency does not remove the current document work and slice sharing is not unconditional. |
| Escape the raw input pointer or use manual unmanaged storage retention | Rejected — High | The authoritative NIO API makes that an explicit lifetime-management contract, whereas queued `Data` already owns input correctly. Escaping a parser pointer risks use-after-free and pins buffers; it is unnecessary for synchronous projection. |
| Decode each offered chunk as `String`/iterate `Character` | Rejected — High | It conflicts with incremental UTF-8, incurs string representation work, and changes the level at which terminal protocol controls are recognized. The current decoder’s partial-prefix behavior must remain authoritative. |
| Directly mutate row slots from the scanner | Rejected — High | It would bypass the document transaction that owns segmentation, wrap, row identity, history and retained-snapshot correctness. The existing document ASCII batch path is precisely the safe convergence point. |
| Turn OSC/APC into one general `UInt8` accumulator in the CSI experiment | Deferred — Medium | Those paths currently implement delimiter, ESC/ST, payload, graphics and title/link behavior together. Separate a CSI-only equivalence proof before changing them. |
| SIMD/word-at-a-time delimiter scanning or a fixed run threshold | Deferred pending profiles — Medium | These can be useful only after the borrowed-window path is semantically proven. A scalar scan may be cheaper on short mixed input; use the threshold sweep rather than assume a value. |
| `withVeryUnsafeBytes`, disabled exclusivity/overflow checks, or unchecked indexing derived from transport input | Rejected — High | They weaken safety rather than demonstrate a retained cost. This report recommends no such setting or annotation. |

## Open questions — Medium confidence

1. What fraction of current long-ASCII time is parser admission versus the
   unavoidable document transaction and row COW? The cited profile overlaps,
   so sampling categories cannot be added as percentages.
2. Does a pointer-backed generic `Collection` specialize under this exact WMO
   Swift 5-language-mode build? If not, a narrowly scoped internal pointer-loop
   overload that still calls the same document transaction may be worth a
   separate design review; do not retain a second writer.
3. Does a Foundation owned-ingress implementation demonstrably preserve its
   bytes without a copy on macOS 15.6? Treat it as runtime-measured, not API
   guaranteed.
4. After experiments 1–2, which short mixed-run threshold improves every
   shared workload? The answer must come from medians plus semantic oracles,
   not from the long-ASCII workload alone.

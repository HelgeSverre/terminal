# Swift performance research brief

## Objective

Find practical, supported Swift techniques that improve this terminal's measured
throughput without weakening protocol correctness, snapshot ownership, memory
bounds or clean shutdown. The acceptance floor is 70% of Rust's median app
throughput on **every** shared workload; 80% is a stretch target. Rust will be
preserved on `archive/rust-2026-11-08` at `c8f279b` before any complete Swift
replacement.

The host is an M2 Max running macOS 15.6 (24G84), with Apple Swift 6.2.4.
The experiment builds in Swift 5 language mode with `-O` and whole-module
optimization, targeting arm64 macOS 15. New techniques must work on this Mac.

## Decisions to inform

1. Which ownership and mutation boundaries reduce ARC, uniqueness and dynamic
   access checks while preserving retained Row/Screen/Cells snapshots?
2. How should an ASCII protocol parser borrow and process contiguous bytes
   without per-byte decoding/array append overhead or reordering Unicode,
   controls, replies and history eviction?
3. Which compiler settings and diagnostics establish specialization/inlining
   and identify actual remaining costs? Which frequently suggested annotations
   add nothing inside our existing single WMO module?
4. Are `borrowing`, `consuming`, noncopyable types, `Span`, `InlineArray` or
   yielding accessors available and useful with this compiler, deployment
   target and existing C ABI? Distinguish supported features from underscored
   implementation details.
5. Which collection/storage patterns improve sparse cell payloads, row churn
   and bounded history without introducing another retained representation?
6. Which ideas from maintained Swift byte-processing libraries and terminal
   engines apply here, and what code change and benchmark would test each?
7. Which plausible changes should be rejected, deferred or treated as
   unproven hypotheses rather than promised speedups?

## Independent research streams

| Stream | Primary entry points | Adjacent systems |
| --- | --- | --- |
| Compiler and ownership | Swift.org, swiftlang/swift, swiftlang/swift-evolution, Apple developer videos/docs | Swift language/optimizer |
| Storage and collections | apple/swift-collections, Swift standard-library source, Apple performance docs | Deque and high-throughput collection designs |
| Byte parsing | apple/swift-nio and official Swift buffer APIs | Network protocol parsers |
| Terminal engines | migueldeicaza/SwiftTerm and directly relevant first-party source | Native Swift terminal processing |

Use primary sources only. Pin version-sensitive claims to the local compiler
or an identified source revision. Tiny compile/run availability probes are
allowed; do not install packages, change production code or run app benchmarks.

## Current evidence

The real-app pilot at `43ef231` measured Swift at 38.26/43.76/12.84/11.04 MiB/s
for short ASCII/long ASCII/ANSI/Unicode. Contemporary Rust measured
64.72/84.78/20.61/13.97 MiB/s. These are short pilots, not acceptance trials.
See `reports/swift-app-comparison-43ef231-wmo` in the main worktree.

The preceding reference-free row implementation regressed performance despite
passing correctness. Its profile showed hashing empty payload dictionaries,
per-cell access/uniqueness checks and redundant blank-row erasure. Bulk slot
mutation and direct erased-row construction recovered ASCII throughput.
The frozen-baseline comparison covers 270 records, with baseline-derived byte
thresholds and unchanged snapshots, charges, revisions and retained values.

The latest long-ASCII profile still contains substantial Document work and
Core byte admission: owner 3,724 samples; feed 2,607 inclusive; a flush call
site 1,681; feed itself 628 exclusive; uniqueness-check call site 159;
UTF8Decoder.push 136. These counts overlap and are not additive percentages.

Production main remains Rust at `/Users/helge/code/terminal`. Swift implementation
and profiles are in `/Users/helge/code/terminal-swift-experiment`, currently
`43ef231`; the temporary row worktree is separate. Research must not edit them.

## Per-stream report contract

Write only the assigned report in this directory. Each report must contain:

1. Scope and source/version coverage.
2. A table of applicable techniques, exact source links, deployment constraints,
   tradeoffs and the relevant local code locations.
3. Three ranked, concrete experiments with expected mechanism and validation;
   speedup remains unknown until measured.
4. Rejected/deferred ideas and unresolved questions.

Mark each section or recommendation **High**, **Medium** or **Low** confidence,
and distinguish source facts from inferences about our code. Prefer 4–8 strong
primary sources to a large link collection. Paraphrase; do not reproduce long
transcripts or documentation passages. Do not recommend disabling safety,
exclusivity or overflow checks to pass the benchmark. Root will synthesize the
streams into a source-linked decision table and implementation priorities.

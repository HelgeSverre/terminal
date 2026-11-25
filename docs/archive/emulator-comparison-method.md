# Frozen Swift–Rust core comparison

> Historical. The Rust core is archived on `archive/rust-2026-11-08`, and the
> client and runner this describes (`tools/EmulatorComparison.c`,
> `dev compare-emulators`) were removed after 0.3.0; they are in the history
> at tag `v0.3.0`. The method stands as the record of how the published
> comparisons were made.

tools/EmulatorComparison.c is one identical C ABI client, linked once to the
frozen Swift core and once to the frozen Rust core. `dev compare-emulators`
(tools/Dev/CompareEmulators.swift) orchestrates the resulting two executables. It never builds an executable, opens
the application bundle, starts a PTY, or launches a GUI.

This is a headless terminal-core comparison, not a product-performance claim.
It covers a fixed 160×50 grid with a zero-row history limit. It does not measure
the app host, renderer, Metal, font shaping, PTY, startup, input-to-photon
latency, or retained scrollback.

## Frozen artifacts first

Create clean, detached source snapshots for the selected Swift and Rust commits.
Build and run against those snapshots, never a production checkout that may have
unrelated report WIP or active commits. Keep all cache/output under
target/emulator-comparison/; do not clear a global cache. Preserve the frozen
binaries and provenance; remove the temporary source snapshots and their scoped
caches only after measurement is complete.

The intended recipes are emulator-comparison-build-swift and
emulator-comparison-build-rust. The Swift recipe must obtain its source list
from the shared graph, rather than copying it:

~~~sh
xcrun swift tools/SwiftIncrementalBuild.swift --print emulation
~~~

The Swift link uses that group, tools/EmulatorComparison.c, native/Bridge.h,
-swift-version 5 -O, and the Foundation, CoreGraphics and ImageIO frameworks.
The Rust link uses the same C file and header plus the frozen release
terminal-core static library. The Rust recipe must use the static-library linker
flags printed by its frozen Cargo invocation; neither recipe may link the app
bundle or any renderer source.

Each recipe writes an adjacent provenance file with this required schema:

~~~json
{
  "implementation": "swift",
  "source_root": "/absolute/frozen/swift-source-snapshot",
  "source_commit": "<full detached commit>",
  "source_tree_clean": true,
  "executable": "target/emulator-comparison/swift/emulator-comparison",
  "executable_sha256": "<sha256>",
  "compiler": "<full compiler version and flags>",
  "build_wall_seconds": 0.0,
  "build_command": "<exact command>"
}
~~~

Use "rust" for the Rust artifact. Build-wall time is the recipe's isolated
compile-and-link wall time, including the C harness. It is useful only as a
reproducible build measurement, not as a language-wide compilation benchmark.
Artifact bytes are the frozen executable sizes, reported beside their hashes.

## Workload and timed contract

The harness deterministically repeats complete parser-boundary records until
at least 32 MiB are emitted (the default; --bytes can change it). ascii contains
printable ASCII, SGR and DSR; mixed adds a combining sequence, CJK, an emoji ZWJ
sequence, regional-indicator flag, OSC title, truecolor SGR and DSR. Both end
every repeated record in CRLF after the query, so the requested byte count never
chooses a partial final escape sequence.

For every invocation the harness creates a 160×50 core, sets the history limit
to zero, then starts timing. Physical ingress is always an identical span of at
most 64 KiB; a zero-length feed is used only to drain already-admitted pending
work. It includes:

1. terminal_feed and all grid/parser mutation;
2. terminal_replies after every feed and after terminal_finish;
3. all terminal_has_work draining;
4. terminal_finish;
5. terminal_validate;
6. final terminal_snapshot, copying its JSON, and terminal_string_free.

Core creation/configuration, corpus allocation/hash, process startup, result
file I/O and snapshot report-file I/O are outside timing. The harness records
payload/reply byte counts and FNV-1a digests, elapsed monotonic time, and the
exact raw snapshot JSON.

## Controlled run

Do this only on an agreed quiet machine: no GUI terminals under test, no builds,
and no unrelated CPU-heavy jobs. The runner performs one warmup for each
implementation/workload, then three alternating pairs. Every turn contains five
samples: Swift→Rust, Rust→Swift, Swift→Rust. It samples the direct child
process's RSS every 25 ms and stores each sample, final sample, and peak. The
C child also records its Darwin getrusage maximum RSS after the timed interval.
Both values explicitly include the allocated 32 MiB replay corpus and runtime
allocations; neither is application-wide peak memory or GPU memory.

~~~sh
target/native/dev compare-emulators \
  --swift-bin target/emulator-comparison/swift/emulator-comparison \
  --rust-bin target/emulator-comparison/rust/emulator-comparison \
  --swift-root /absolute/frozen/swift-worktree \
  --rust-root /absolute/frozen/rust-worktree \
  --swift-provenance target/emulator-comparison/swift/provenance.json \
  --rust-provenance target/emulator-comparison/rust/provenance.json \
  --output reports/emulator-comparison-YYYYMMDD
~~~

The runner verifies that each artifact SHA-256 matches its provenance, each
specified source snapshot is still clean at the recorded commit, and the ABI harness
returns protocol version 1. It records OS, kernel, model, CPU, logical CPU
count, power report, compiler/build provenance, every runtime/RSS sample, and
both raw snapshot files.

summary.md contains the requested compile/size/median-throughput table.
result.json contains all samples and provenance. Existing output directories
are never overwritten. Child harnesses are process-group terminated and reaped
on an interruption or runner error. A 120-second per-child watchdog is the
default; timeout or interruption writes result.json with status incomplete and
the failure before exiting non-zero. The built-in --self-test verifies that a
timeout reaps its owned child and that input_ready remains canonical.

## Semantic hard gate

After all timed samples, the runner canonicalizes and compares every paired
final snapshot outside timing. A mismatch exits non-zero; no throughput table
is a result until that gate passes.

The canonical form preserves every shared terminal-visible field, including
input_ready, cursor state, modes, colors, links, graphics placements, cell
styles and cells. input_ready must be present and Boolean on both sides:
absence is a failure, not an equivalence with either Boolean value.

Only these legacy schema differences are projected, and raw snapshots retain
them:

- top-level publication counters and the empty legacy history projection;
- document-local row id and row publication revision;
- Swift's primary_margins, alternate_margins, and vertical_margins.

The margin fields are a documented ABI-v1 asymmetry; the published ASCII/mixed
corpus deliberately does not change margins. A future margin fixture needs
counterpart Rust fields and must compare them directly. New fields are not
silently discarded: an unlisted schema difference makes the canonical gate
fail. Passing this gate establishes equality only for these workload records
and this scoped headless profile, not full terminal-product parity.

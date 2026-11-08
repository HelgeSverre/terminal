# Swift replacement: promotion and remaining v1 work

Source review: Swift `65cb446`, Rust Main `3b18531`. This plan supersedes the
current-status portions of `swift-replacement-audit.md`; that document and
`swift-architecture-plan.md` retain the earlier design history. No runtime
changes or new measurements were made for this plan.

Follow-up: `75bbaa0` completes the neutral Unicode-input preparation in step 3
below. Both generators reproduce the checked-in sources exactly; the 853-case
corpus and 24 width-sequence checks pass. Root subsequently reported the full
SQL run passing in 165.6 seconds; final integrated validation remains in progress.

## Decision and remaining acceptance gates

Proceed toward replacement. The parent task reports all four actual-app
workloads at 86.8–96.3% of matched Rust throughput across both execution orders,
above the user's 70% requirement and 80% stretch goal. Those results belong to
the frozen candidate, not to arbitrary later edits. Full-file SQL and final
integrated validation are still pending at this checkpoint.

Before promotion, attach the final immutable source/executable hashes and
durable exit reports for:

- The mandatory native/headless suite, including Unicode, history/reflow,
  snapshots, search, graphics, palette, backpressure and real Session lifecycle.
  The current Session-test/CI edits are owned by the ongoing validation task.
- The exact 270-record row/history compatibility gate after integration. Keep
  identity, accounting and clamp assertions; do not normalize failures away.
- Complete 8 GB ingestion with accepted bytes equal to input bytes, final drain,
  bounded history and owned-process cleanup. Retain static, motion and pinned
  viewport evidence separately; a prefix or timeout is not a full-file pass.
- The existing native/rendering/input/application compatibility evidence, with
  any unresolved failures explicitly listed. The four throughput ratios alone
  are not a semantic or UI gate.

Do not repeat the entire performance campaign for documentation edits. A change
to compiler flags, runtime behavior or linked product sources needs the relevant
comparison on its own frozen artifact. Mechanical moves require source-graph,
clean-build and focused correctness checks before calling the result equivalent.

## Ordered promotion commits

1. **Preserve the last Rust release candidate.** Once Main is quiescent, create
   and push one clearly named immutable backup tag at its exact latest commit,
   for example `rust-before-swift-<short-sha>`, and verify the remote peeled SHA.
   Preserve the existing Rust snapshot branch. Archive the matched Rust app,
   benchmark inputs/configuration and hashes; Git alone does not retain built
   comparison artifacts. `swift-publication-prototype-a600105` is a Swift
   prototype backup and does not replace this Rust backup.
2. **Reconcile onto latest Main.** Merge directly onto Main without creating
   an integration branch or replacing either tree wholesale. The experiment originally lacked
   newer Main files including `tools/cat_stress.rb`, `compare_terminal_apps.rb`
   and its tests, `profile_terminal.rb` and its tests, `compare_swift_rows.rb`,
   `RowStorageCompatibilityProbe.swift`, `DistributionTests.swift`, close/native/
   AppleScript smoke tests and the benchmark clock test. Preserve these tools
   and reconcile their commands with the Swift source graph. Keep the Main
   viewport-condition diagnostics and split-directory host behavior.
3. **Make data regeneration and verification independent of Rust.** Move
   `crates/terminal-core/tests/fixtures/GraphemeBreakTest-18.0.0.txt` into a
   neutral test-data location and update `SwiftUnicode18CorpusTests.swift`.
   Convert the exact inputs consumed by `GenerateUnicode18.swift` and
   `GenerateTerminalWidth.swift` to checked-in, checksum-pinned neutral data
   under `tools/unicode`; preserve source version, license and generation
   provenance. The first currently reads `vendor/unicode-segmentation/src/tables.rs`;
   the second defaults to Helge's Cargo registry path. Require identical
   generated runtime tables, not a fresh Unicode-policy change. The lowercase
   generator already uses committed Unicode17 records and needs no Rust runtime.
4. **Remove Rust from the supported repository workflow.** Delete the Rust
   workspace (`crates/`, Rust-only `vendor/`, Cargo manifests/lockfile and
   `rust-toolchain.toml`) only after extracting fixtures/provenance above.
   Retire `tools/TerminalWidthOracle.rs` to the backup reference. Replace
   Cargo-based `fmt`, `lint` and `benchmark-core` recipes with honest Swift/
   source-graph checks or remove obsolete recipes; do not leave no-op checks.
   Update CI's Rust/Clippy labels, Cargo caches and cache inputs, and README's
   Rust prerequisites, badge, parser description and `cargo run` example.
   `SwiftDifferential.swift` may remain explicitly optional tooling against an
   externally supplied Rust backup, but no default build/test/regeneration path
   may invoke Cargo. Prefer a supplied frozen oracle executable to an implicit
   Cargo build. Preserve licenses for derived Unicode data.
5. **Validate and promote the reconciled source.** Run the mandatory graph and
   native checks from a clean checkout without relying on a Cargo installation
   or local generated files; verify the packaged terminfo/shaders/launcher and
   application dependencies. Publish an evidence ledger distinguishing final
   source from historical prototypes. Promote only after the pending acceptance
   gates above are resolved. Retain rollback references and measured artifacts.

Rust removal does not require deleting C. `Spawn.c`/`Launcher.c` implement PTY
launching, while `Bridge.h` and Swift's C exports still serve existing Session
calls and independent ABI tests. Removing these prematurely would combine a
host-interface migration with language replacement.

## Responsibility-based naming

The mechanical cleanup is implemented in the current source tree, with one
Swift compiler module and the stable C ABI retained:

| Source | Responsibility |
| --- | --- |
| `native/Emulation/TerminalEmulator.swift` | Ordered VT interpretation, commands, protocol state and admission |
| `native/Emulation/TerminalDocument.swift`, `DocumentReflow.swift` | Rows, history and geometry transformations |
| `native/Emulation/KittyGraphics.swift` | Image protocol validation, resources and placement lifetime |
| `native/Emulation/HistorySearch.swift` | Immutable search pages, bounded matching and acceptance proofs |
| `native/Emulation/TerminalInputEncoder.swift` | Negotiated terminal input bytes |
| `native/Emulation/TerminalPalette.swift`, `TerminalSnapshot.swift`, `ClipboardProtocol.swift` | Protocol-owned palette, immutable publication values and OSC52 decoding |
| `native/Text/` | Incremental text state and pinned grapheme, width and lowercase tables |
| `native/tests/EmulatorTests.swift` | Public emulator smoke and malformed-input boundaries |

Host and rendering files retain their existing locations. ABI exports remain
with the emulator until an extraction provides a useful access boundary;
there is no placeholder compatibility module. Generated output paths,
source graph, callers and current commands move together. Archived comparison
tools recognize old source-group names internally rather than exposing an
obsolete runtime alias.

The next substantive interface improvement is to let `Session` own a typed
`TerminalEmulator` on its existing owner queue. Today it still creates an
opaque handle and calls C-shaped feed/input/search/reply/image APIs, while
`SnapshotBridge` is only a two-method forwarding wrapper around a typed result.
Move those host calls in one narrow vertical slice at a time; then fold the
snapshot wrapper into the emulator's publication operation. Keep C exports as
test/oracle adapters for as long as they provide independent contract coverage.
Do not add actor hops per character, a generic mutable-grid callback, or a
second placement implementation. The document must continue to own printing,
row IDs, COW mutation, reflow and retention; retained snapshots must remain values.

## Replacement is not original-spec v1 completion

`docs/spec.md` explicitly mandates Rust and Vulkan/KosmicKrisp in §0.1 and GPU
validation in §§15/19/20. The shipping path is Metal and the selected replacement
is Swift. Record these architectural deviations and their actual Metal lifetime/
rendering gates; do not silently mark Vulkan requirements as passed. The user’s
relative 70% replacement gate also does not prove the spec's absolute throughput,
latency, memory or startup targets in §18.

Highest-priority full-v1 work after a correct replacement:

1. **Close native interaction evidence gaps.** Complete the named app, keyboard
   layout/dead-key/IME, VoiceOver, backing-scale/display, selection-under-flood,
   minimize/sleep/wake and close/drain matrix in §§18.2/18.5. Distinguish a missing
   real-device test from a confirmed implementation defect. Tabs/splits/search/
   clipboard already have implementations; do not propose rebuilding them.
2. **Finish row-run shaping.** `Font.rasterize` explicitly sets `.ligature: 0`.
   §13.1 allows this for M3 but requires v1 ligature mapping and selection/cursor
   behavior across shaped runs. Add a bounded row-layout owner with explicit
   cell-to-glyph mapping, then test scripts, fallback, emoji and selection colors.
   This is independent of Rust replacement and should not enter its promotion diff.
3. **Measure the remaining product budgets.** The spec requires eight active
   plus twenty hidden sessions, global resource behavior, input/echo latency,
   10k/50k-history resize, cold/warm startup, atlas churn and idle behavior.
   Existing four-stream and SQL results do not establish these targets. Use
   measured failures to choose the next implementation patch.

Graphics already exceeds the original text-first scope; further image protocols,
session daemons, plugins and remote control remain later work. No additional
storage redesign is required merely to make the Swift replacement “Swifty.”
The direct snapshot, bounded history owner, unified printing transaction and
COW row reuse are already substantial Swift-specific ownership improvements.

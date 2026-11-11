# Swift replacement validation

The app builds entirely from Swift, C and Metal. `just build` compiles the
emulator at `Sources/Terminal/Emulation/TerminalEmulator.swift`; `just release-build`
uses whole-module optimization. No supported build, test or data-generation
command requires Cargo. The Rust implementation is retained on the private
`archive/rust-2026-11-08` snapshot branch, alongside frozen comparison apps.

## Current evidence

The frozen `65cb446` application reached 86.8–96.3% of matched Rust throughput
across short ASCII, long ASCII, ANSI and Unicode workloads in both run orders.
Each workload used ten 16 MiB samples. Full SQL ingestion passed in 165.6 s
at 47.1 MiB/s, or 69.6% of the paired Rust run; this history-heavy result stays
separate from the four-workload acceptance gate. Full-file figure-eight motion
and resizing also passed in 237.1 s with 14,224 movement ticks. These are
source-scoped results, not measurements of arbitrary later revisions.

Subsequent reconciliation restores Main's input/clipboard termination behavior,
startup FIFO and physical-key regressions. The focused Session and clipboard
suites passed 35 and 17 checks respectively at `76dd3cd`. Official Unicode18
coverage is 853/853; the mandatory graphics ABI suite covers 17 groups.
The naming cleanup retains the C ABI and those protocols while grouping
emulation and version-pinned text behavior by responsibility.

Final integrated CI and release validation remain required before promotion.
A hosted Apple Paravirtual GPU independently crashes on a valid shared-heap
texture upload; CI records that exact hardware case as skipped, while local
Metal gates remain mandatory. Full original-spec completion is separate from
Rust replacement; resumable, budgeted reflow and owner-confined selection are
among the remaining requirements.

## Historical experiment record

Everything below records early, incomplete checkpoints. Counts, paths, build
sizes and timings in these sections are historical and do not describe the
current implementation. Raw measurements are preserved unchanged.

## Initial baseline

On this Mac, before the replacement, the Rust core passed all 86 core tests.
The clean release compile was 5.82 s (309.6 MB maximum resident memory), the
incremental compile was 0.05 s (30.1 MB), and `libterminal_core.a` was
20,269,136 bytes. Raw timing output is retained in
`reports/swift-port/rust-core-*-build.time`.

The first Swift-core smoke compile measured 5.32 s / 242.0 MB and produced a
170,232-byte executable. Repeating a direct `swiftc` command was 6.79 s /
236.3 MB: that is **not** an incremental result because direct `swiftc` does
not retain a compilation cache. App-bundle build was 25.42 s / 273.8 MB and
the app binary is 1,030,560 bytes. These figures are useful directional data,
not a final performance conclusion: the implementations do not yet have
feature parity and Rust's library measurement is not directly comparable to a
linked Swift executable.

## Acceptance matrix

| Area | Oracle | Swift status |
| --- | --- | --- |
| ABI/session/PTY ownership | native app + C bridge | Binary borrowed-row ABI restored; SnapshotBridge executable passes |
| Native PTY application corpus | shell, bash, fish, nvim, tmux, fzf | 10 / 10 C PTY corpus cases pass with Swift ABI core |
| Basic VT, SGR, cursor, alternate screen | semantic transcript | Implemented smoke coverage |
| Input and bracketed paste | key encoding tests | Swift encoder covers legacy, keypad and Kitty key events; standalone tests pass |
| Scrollback and viewport | viewport tests | Basic history/anchoring implemented |
| Unicode 18 grapheme width and maximal-subpart UTF-8 | 41 semantic + Unicode corpus | Official corpus: 715 / 853 cases pass, 138 fail (first U+094D); generated tables not yet parity |
| Margins, rectangle editing, atomic reflow | 9 margin tests | Reflow primitive smoke passes; margins/rectangles/style retention not integrated |
| Bounded incremental search | 7 search tests | Worker seam + standalone search test + Session highlight/anchor pass; core integration incomplete |
| Kitty graphics (PNG/zlib/direct, placements/cache) | 13 graphics + dmscene | Direct RGBA/PNG/zlib/chunks/placements standalone tests pass; dmscene and original 13-case replay remain |
| Binary snapshot ABI | bridge tests | Original typed borrowed callback restored; SnapshotBridge executable passes |

At that early checkpoint, `just swift-core-test` passed (the current command is
`just unit-test --filter EmulatorTests`). The full native Session exercise was
run separately while porting; its generated report is not committed.

After binary-snapshot, search, input and graphics integration, the real native
Session regression reported **20/20 checks passing**, including REP (`CSI Ps b`)
bounded-work ordering. This is one native regression suite, not a substitute
for the 86 Rust-core semantics/graphics/margin/search/viewport tests.

The experiment must not claim 100% parity until every original test has an
equivalent Swift differential replay and the dmscene/PTY corpus passes. System
Swift Unicode tables are not considered a replacement for the existing pinned
Unicode 18 tables.

The machine-readable differential harness passes all 15 frozen replays: five
smoke transcripts (plain text/LF, SGR/cursor, alternate return, one-byte UTF-8,
DSR) under whole-buffer, byte-at-a-time and deterministic random 1–7-byte
partitioning, against Rust `f4268ee`. Its canonical projection retains every
shared terminal-visible field, including cells, styles, links, colors and
pending-wrap. Raw reports retain Swift's screen-local margin observations and
reply bytes because the frozen Rust JSON format does not project equivalents;
row identities and epochs remain covered by transition/viewport oracles.
This is evidence for these five transcripts, not complete parity.

## Preliminary same-machine comparison

Both app builds below used detached commit `4ae6967` as the Rust source
baseline, the same host/toolchain/macOS, and the same bundled assets. Cargo's
registry cache and the Xcode toolchain were warm; each worktree had a fresh
local build output. The Swift result is not a claim of a faster terminal: its
core is still incomplete and its direct compiler invocation has no incremental
dependency graph.

| Metric | Rust baseline | Swift experiment | Delta | Qualification |
| --- | ---: | ---: | ---: | --- |
| Behavioral core tests | 86 / 86 | not comparable | — | Swift native Session: 20 / 20; graphics/Unicode/reflow suites incomplete |
| Full app build wall time | 26.24 s | 24.90 s | -1.34 s | Fresh worktree output, warmed shared tool caches |
| Full app build max RSS | 309.4 MB | 265.6 MB | -43.8 MB | Same command scope as above |
| Unchanged full `just build` | 17.86 s | 24.33 s | +6.47 s | Equal command scope; Rust benefits from Cargo’s incremental core cache while the normal Swift recipe still whole-compiles |
| App executable | 3,349,872 B | 1,198,304 B | -64.2% | Signed development bundle executable |
| Stripped executable copy | 2,590,288 B | 801,136 B | -69.1% | Strip performed on copied binaries only |
| Full app bundle | 8,476 KiB | 6,376 KiB | -24.8% | Same bundled fonts/assets |
| Incremental compile + link | 0.05 s core-only Cargo | 0.60 s executable-only Swift | +0.55 s | Both are cache-scope-specific; Swift is 399 ms compile + 197 ms link |
| Core/PTY throughput and memory | benchmark available | not yet valid | — | Same workload harness awaits semantic parity |

Raw measurements are retained in `reports/swift-port/*app*` and core timing
files. The true Swift incremental pipeline is documented in
`docs/swift-incremental-build.md`; it measured 24,000 ms clean compile + 266 ms
link, then 399 ms unchanged compile + 197 ms link. A shared transcript/PTY
benchmark is still required before runtime performance is compared.

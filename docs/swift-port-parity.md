# Swift port experiment

This detached worktree is deliberately a Swift-only build: `just build` compiles
`native/SwiftTerminalCore.swift` and never invokes Cargo or links
`libterminal_core.a`. Rust source remains only as a pinned behavioral oracle
during the experiment; it is not part of the app, test, or runtime dependency
graph.

## Baseline

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
| Basic VT, SGR, cursor, alternate screen | semantic transcript | Implemented smoke coverage |
| Input and bracketed paste | key encoding tests | Swift encoder covers legacy, keypad and Kitty key events; standalone tests pass |
| Scrollback and viewport | viewport tests | Basic history/anchoring implemented |
| Unicode 18 grapheme width and maximal-subpart UTF-8 | 41 semantic + Unicode corpus | Not yet parity |
| Margins, rectangle editing, atomic reflow | 9 margin tests | Not yet parity |
| Bounded incremental search | 7 search tests | Bounded immutable worker seam exists; Session highlight/anchor check passes |
| Kitty graphics (PNG/zlib/direct, placements/cache) | 13 graphics + dmscene | Direct RGBA/PNG/chunks/placements work in standalone tests; zlib and dmscene remain |
| Binary snapshot ABI | bridge tests | Original typed borrowed callback restored; SnapshotBridge executable passes |

`just swift-core-test` currently passes. The full native Session exercise is
run separately while porting; its generated report is not committed.

After binary-snapshot, search, input and graphics integration, the real native
Session regression reported **19/20 checks passing**. The remaining failure is
the REP (`CSI Ps b`) bounded-work ordering test: this Swift core does not yet
represent REP as resumable work, so it parses the suffix before publication.

The experiment must not claim 100% parity until every original test has an
equivalent Swift differential replay and the dmscene/PTY corpus passes. System
Swift Unicode tables are not considered a replacement for the existing pinned
Unicode 18 tables.

## Preliminary same-machine comparison

Both app builds below used detached commit `4ae6967` as the Rust source
baseline, the same host/toolchain/macOS, and the same bundled assets. Cargo's
registry cache and the Xcode toolchain were warm; each worktree had a fresh
local build output. The Swift result is not a claim of a faster terminal: its
core is still incomplete and its direct compiler invocation has no incremental
dependency graph.

| Metric | Rust baseline | Swift experiment | Delta | Qualification |
| --- | ---: | ---: | ---: | --- |
| Behavioral core tests | 86 / 86 | not comparable | — | Swift native Session: 19 / 20; graphics/Unicode/reflow suites incomplete |
| Full app build wall time | 26.24 s | 24.90 s | -1.34 s | Fresh worktree output, warmed shared tool caches |
| Full app build max RSS | 309.4 MB | 265.6 MB | -43.8 MB | Same command scope as above |
| App executable | 3,349,872 B | 1,198,304 B | -64.2% | Signed development bundle executable |
| Stripped executable copy | 2,590,288 B | 801,136 B | -69.1% | Strip performed on copied binaries only |
| Full app bundle | 8,476 KiB | 6,376 KiB | -24.8% | Same bundled fonts/assets |
| Incremental build | 0.05 s core-only Cargo | not configured | — | Direct `swiftc` repeat recompiles; do not compare it as incremental |
| Core/PTY throughput and memory | benchmark available | not yet valid | — | Same workload harness awaits semantic parity |

Raw measurements are retained in `reports/swift-port/*app*` and core timing
files. A true Swift incremental pipeline and a shared transcript/PTY benchmark
are required before runtime performance is compared.

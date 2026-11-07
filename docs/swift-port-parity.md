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

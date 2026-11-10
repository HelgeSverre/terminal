# Direct text path and gathered PTY reads

Measured on an Apple M2 Max, macOS 15.6 (24G84), on AC power, at source
`96efd66`. The baseline is the published v0.2.4 runtime (`5568f83`, signed
executable SHA-256 `34798ae9…a4e4c5`). References are Ghostty 1.4.0 and Kitty
0.45.0. The desktop was not quiet: unrelated processes kept the one-minute load
average between 4 and 10 during these runs, and near 40 for part of the
session. Treat differences of 10% between runs as noise.

## Where it stands

Whole-app PTY throughput, mean of the two trial medians, MiB/s. Run with
`just benchmark-terminals`: ten 16 MiB samples per workload, 100×30 cells,
both launch orders, alternate screen.

| Workload | Helge Terminal | Ghostty | Kitty | Ours / Ghostty | Ours / Kitty |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII lines | 203.4 | 262.9 | 109.0 | 77% | 187% |
| Long ASCII lines | 217.3 | 281.0 | 112.4 | 77% | 193% |
| ANSI truecolor | 190.0 | 197.2 | 77.8 | 96% | 244% |
| Mixed Unicode | 80.6 | 184.9 | 115.4 | 44% | 70% |

Our trial medians are 204.7/202.1, 214.4/220.3, 185.8/194.2 and 80.6/80.5.
Pixel extents were 900×630 (ours), 800×540 (Ghostty) and 900×540 (Kitty); the
window was on a non-Retina display, unlike the
[previous comparison](../terminal-comparison-2026-11-10/README.md). Raw samples
are in `three-app/`.

Three workloads are now within reach of Ghostty; mixed Unicode is not. The
goal of matching Ghostty on all four is unmet.

## Against v0.2.4

Two frozen app bundles, baseline–candidate–candidate–baseline, same driver and
grid (`paired/`). Trial medians in MiB/s; CPU is the terminal process's seconds
per 16 MiB sample.

| Workload | v0.2.4 | This build | v0.2.4 CPU | This build CPU |
| --- | ---: | ---: | ---: | ---: |
| Short ASCII lines | 104.4 / 104.6 | 213.0 / 231.6 | 0.25 | 0.11 |
| Long ASCII lines | 133.6 / 136.3 | 243.7 / 260.8 | 0.21 | 0.09 |
| ANSI truecolor | 46.1 / 46.0 | 194.9 / 208.4 | 0.47 | 0.16 |
| Mixed Unicode | 20.3 / 20.1 | 81.4 / 81.5 | 0.95 | 0.29 |

The paired run and the three-app run used the same executable
(`bf6d5bb2…1917d`) minutes apart; the paired run's ASCII results are about 10%
higher, which is the size of the run-to-run noise here.

The full 8.16 GB SQL dump through `/bin/cat` on the primary screen, with
scrollback, window motion and resizes (`just stress-cat-motion`, one run each,
`sql-motion/`):

| | v0.2.4 | This build |
| --- | ---: | ---: |
| Wall time | 150.2 s | 43.7 s |
| Peak physical footprint | 104.4 MiB | 84.7 MiB |

Both runs drained completely and exited cleanly.

Input latency while a child floods the PTY (`latency/`, headless `Session`,
128 requests per case, baseline–candidate–candidate–baseline). Ranges are the
two trials, in milliseconds:

| Case | v0.2.4 p95 | This build p95 | v0.2.4 p99 | This build p99 |
| --- | ---: | ---: | ---: | ---: |
| Unicode flood, input | 2.93–3.40 | 1.21–1.24 | 3.29–10.14 | 1.34 |
| SQL flood, input | 1.76–1.83 | 0.81–0.90 | 1.99–2.17 | 1.01–1.27 |
| Unicode flood, resize and input | 80.0–83.1 | 59.2 | 82.6–83.7 | 60.8–61.1 |
| SQL flood, resize and input | 27.1–28.4 | 27.3–27.6 | 28.5–30.4 | 27.9–28.3 |

These used the tree at `1197258`, before the history change in `96efd66`. No
case had a geometry mismatch or a rejected input.

One number moved the wrong way: the idle cursor-report round trip measured by
the driver went from 0.024 ms to 0.036 ms (p50). The reader now waits up to
10 µs for a refill before delivering a read.

## What the diagnosis was

Fed the same payloads directly, with no PTY, window or renderer, the v0.2.4
emulator ran at 125 / 190 / 50 / 23 MiB/s: barely faster than the whole app, and
slower than Ghostty's whole app on every workload. The core was the limit, not
the pipeline.

A terminal that reads and discards (`tools/ptyceil.c`) reaches about
200–240 MiB/s on this Mac. macOS hands over at most 1,024 bytes per PTY read, so
that is a kernel ceiling for a reader of this shape, and Ghostty's numbers sit at
it.

Headless emulator, 64 MiB per workload in 16 KiB feeds, best of three, MiB/s
(`tools/HeadlessBench.swift`; each tree built with its own release flags):

| Workload | v0.2.4, alternate | This build, alternate | v0.2.4, primary | This build, primary |
| --- | ---: | ---: | ---: | ---: |
| Short ASCII lines | 124.8 | 625.9 | 68.4 | 367.1 |
| Long ASCII lines | 189.7 | 936.7 | 92.7 | 470.5 |
| ANSI truecolor | 50.4 | 244.6 | 38.2 | 186.0 |
| Mixed Unicode | 23.3 | 105.5 | 20.6 | 85.8 |
| Unicode, no clusters | 47.4 | 216.5 | 37.9 | 149.8 |
| CJK text | 58.9 | 240.8 | 42.7 | 166.0 |
| Clusters only | 14.3 | 42.6 | 12.3 | 40.8 |

"Primary" keeps scrollback, which the alternate-screen comparison excludes.

## What changed

- Printable ASCII goes from the feed buffer straight into row cells. Complete
  `ESC [ … m` sequences are parsed in place.
- A cell is 8 bytes instead of 24. Its style is an index into a small per-row
  table, and a bit marks the cells that have a payload entry.
- A row is 40 bytes instead of 80, and a scroll moves the region once.
- Decoded text is printed by one transaction that writes runs of fresh one- and
  two-cell scalars as a single row edit, classifies scalars from one memoized
  table, and extends a whole cluster at once from a small cluster cache.
- The reader gathers consecutive kilobyte reads into one delivery, and no
  longer holds the broker's lock while reading.
- History no longer hashes every scrolled row's identity or measures each
  cell's UTF-8 length one at a time.
- Release builds pass `-enforce-exclusivity=unchecked`; development and test
  builds keep the checks.

## What is left

Mixed Unicode is limited by multi-scalar clusters: a line of only clusters runs
at 43 MiB/s headless while Unicode without clusters runs at 217. Each cluster
still costs about 200 ns, spread over the per-row payload dictionary, `String`
reference counting, and two row edits. No single remaining item is more than a
fifth of that. Closing it needs cluster text stored inline with the row rather
than as dictionary entries holding Strings.

On ASCII the reader thread is the limit: the stream diagnostic shows it busy
97% of the time at 4.4 µs per kilobyte read, with the parser idle more than
half the time. A read-and-discard loop that pauses about 0.7 µs after each read
reached 300 MiB/s (`tools/ptyspin.c`), but the same pause in the app did not
move its throughput, so it was not kept.

## How correctness was checked

- `just test` passes in full at `96efd66`, the measured source (12 min 49 s).
- `tools/DifferentialFuzz.swift` builds against two source trees and compares
  them. Across 400 seeds and 9,600 checkpoints the candidate's snapshot JSON
  (cells, row identities and revisions), replies, history bytes and invariant
  checks are byte-identical to v0.2.4. Streams mix ASCII, CJK, clusters,
  malformed UTF-8, SGR, cursor and erase commands, margins, modes, REP, links,
  resizes and scrolls, fed in random chunk sizes.
- `tools/CategoryFallbackCheck.swift` and `tools/DictionaryCapacityCheck.swift`
  are the exhaustive checks behind two changes that rely on a table or a model
  matching existing behavior.

## Limits

These are observations from one desktop under unrelated load. The throughput
figures measure PTY processing through an ordered cursor reply: not displayed
frame rate, input-to-photon latency or peak memory. The SQL figures are one
run each. Font family and size are configured equally across the three apps;
resolved-font equality was not established.

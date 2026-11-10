# Whole clusters, a quieter reader, and where throughput stands

Measured on an Apple M2 Max, macOS 15.6 (24G84), on AC power. This continues
the [direct text path report](../direct-text-path-2026-11-10/README.md); the
"previous build" below is that report's final source rebased onto the pane
work (`4f5f0e1`). References are Ghostty 1.4.0 and Kitty 0.45.0. The
one-minute load average was 3.1–3.8 during the comparison, lower than for the
previous report, so part of the ASCII change between the two reports is the
quieter machine and not code.

## Where it stands

Whole-app PTY throughput, mean of the two trial medians, MiB/s. Run with
`just benchmark-terminals` at `c74daae`: ten 16 MiB samples per workload,
100×30 cells, both launch orders, alternate screen.

| Workload | Helge Terminal | Ghostty | Kitty | Ours / Ghostty | Ours / Kitty |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII lines | 226.1 | 268.3 | 110.9 | 84% | 204% |
| Long ASCII lines | 254.2 | 297.0 | 113.0 | 86% | 225% |
| ANSI truecolor | 207.5 | 200.7 | 44.9 | 103% | 462% |
| Mixed Unicode | 138.6 | 185.0 | 116.4 | 75% | 119% |

Our trial medians are 232.4/219.7, 250.0/258.3, 205.3/209.7 and 138.3/138.8;
Ghostty's are 264.1/272.5, 274.6/319.4, 200.8/200.5 and 183.9/186.0. Pixel
extents were 900×630 (ours), 800×540 (Ghostty) and 900×540 (Kitty) on a
non-Retina display. Kitty's truecolor result is lower than in the previous
report (77.8); nothing here explains that. Raw samples are in `three-app/`.

The same table in the previous report read 77% / 77% / 96% / 44% of Ghostty.
Truecolor is level with Ghostty. ASCII and mixed Unicode are not: the goal of
matching Ghostty on all four workloads is still unmet.

The comparison ran one commit before the final source. That last commit
(`Keep the scrollback byte count inlined…`) changes only code that runs when a
row enters scrollback, which the alternate screen never does; the headless
alternate-screen numbers are the same before and after it.

## Headless emulator

64 MiB per workload in 16 KiB feeds, best of three, MiB/s
(`../direct-text-path-2026-11-10/tools/HeadlessBench.swift`), no PTY, window or
renderer.

| Workload | Alternate, previous | Alternate, now | Primary, previous | Primary, now |
| --- | ---: | ---: | ---: | ---: |
| Short ASCII lines | 657 | 657 | 386 | 388 |
| Long ASCII lines | 977 | 970 | 501 | 505 |
| ANSI truecolor | 250 | 250 | 196 | 199 |
| Mixed Unicode | 110 | 178 | 90 | 134 |
| Unicode without clusters | 225 | 269 | 161 | 163 |
| CJK | 252 | 306 | 176 | 179 |
| Clusters only | 44 | 94 | 41 | 76 |

## What changed

- **Whole clusters in the run that begins them.** A run of fresh text admits a
  multi-scalar cluster with all of its scalars when they are in the buffer, the
  cluster never narrows as it grows, and it fits the row. The row writes it
  with the singletons around it in one edit. Everything else still extends the
  lead cell one scalar at a time.
- **Cluster text and links in column order.** The per-row dictionary became an
  array sorted by column: printing appends, a bulk overwrite removes one
  contiguous run, and nothing is hashed. Reflow admission keeps charging the
  capacity the dictionary would have had.
- **UTF-8 decoded straight into the pending buffer**, taking short ASCII runs
  along, so mixed-script text no longer returns to the feed loop at every
  switch between scripts.
- **Refill wait only after a full-queue read.** The reader waits for a refill
  only when the last read emptied a full kernel queue. A lone echo or prompt is
  delivered at once.
- **`--background` launch flag** for diagnostic runs that must not take focus.

## Input latency

Input latency while a child floods the PTY (`latency/`, headless `Session`,
128 requests per case, previous–now–now–previous). Ranges are the two trials,
in milliseconds:

| Case | Previous p95 | Now p95 | Previous p99 | Now p99 |
| --- | ---: | ---: | ---: | ---: |
| Unicode flood, input | 0.83–0.91 | 0.57–0.61 | 0.91–0.96 | 0.63–0.66 |
| SQL flood, input | 0.44 | 0.50–0.51 | 0.47 | 0.55–0.60 |
| Unicode flood, resize and input | 30.3–30.4 | 28.0–28.9 | 32.4–33.1 | 35.1–43.4 |
| SQL flood, resize and input | 15.7–16.2 | 15.6–16.2 | 16.0–16.6 | 16.4–16.6 |

No case had a geometry mismatch or a rejected input. These used `c74daae`. The
absolute figures are lower than in the previous report because the machine was
quieter. Two things moved the wrong way: SQL input p95 by about 0.06 ms, and
the Unicode resize p99, whose two trials (35.1 and 43.4 ms) sit above the
previous build's (32.4 and 33.1) while its p95 improved. A rerun with the
fixed refill wait restored gave the same SQL figures, so the reader change is
not the cause; the text-path changes are the remaining suspect and it was not
pursued.

The idle cursor-report round trip, which the previous report recorded as a
regression (0.024 → 0.036 ms), is back to 0.023 ms in three background
diagnostic runs and 0.025 ms in the comparison run (Ghostty: 0.030 ms).

## The ASCII gap

On ASCII the reader thread is still the limit, at about 4.1 µs per kilobyte
read. What the experiments showed (`../direct-text-path-2026-11-10/tools/ptyspin.c`
and environment-gated experiment builds that were not kept):

| Experiment | Result |
| --- | --- |
| Read-and-discard loop, immediate re-read | about 235 MiB/s |
| Same loop with 0.5–1.0 µs of other work per kilobyte between reads | about 305 MiB/s |
| Same loop with 1.5 µs or more | falls back to 215–270 MiB/s |
| Same loop beside a thread that sleeps and wakes every 50 µs | 185 MiB/s, 238 with the pause |
| Same loop beside a thread that never sleeps | no effect |
| App with the pause in its read loop, five interleaved rounds | no gain; best runs about 230 MiB/s either way |
| App whose reader drops plain text instead of delivering it | 242–275 MiB/s, no gain from the pause |
| App whose parser thread stays awake up to 100 µs between deliveries | 228–249 against 184–232; within noise |

So inside the app the reader tops out near 270 MiB/s even with no parsing at
all, and delivery plus parsing costs it a further 12–15%. The pause that helps
a bare loop does nothing in the app, and the cause was not found. Parsing on
the reader thread would not help either: at 1.7 µs per kilobyte the parse is
longer than the pause that helps. Ghostty's 264–319 MiB/s sits at or above
what this app's reader reaches with nothing behind it.

## What is left

- **ASCII, 84–86% of Ghostty.** Needs an explanation of why the app's reader
  tops out below a bare loop's: candidates not yet tested are the Dispatch
  read source itself against a dedicated blocking thread, and the quality of
  service the child inherits.
- **Mixed Unicode, 75% of Ghostty.** Clusters are no longer the single cause:
  cluster-only text is 94 MiB/s headless, up from 44, but still a third of
  plain non-ASCII text. The remaining cost is spread over segmentation,
  the cluster cache lookup and `String` payload traffic; storing cluster
  scalars in a per-row arena instead of `String`s is the next structural step.
- **Not measured here:** primary-screen throughput in the app (headless only),
  display smoothness, input-to-photon latency, peak memory, and the full SQL
  motion stress, which was last run for the previous report.

## How correctness was checked

- `just test` passes in full at the rebased base (`4f5f0e1`), after the
  cluster work, at `c74daae`, and at the final source.
- The differential fuzzer (`../direct-text-path-2026-11-10/tools/DifferentialFuzz.swift`),
  built against the previous build and against each step: 400 seeds, 9,600
  checkpoints of screen, scrollback, replies and history bytes, identical every
  time, including at the final source.
- `tools/LongTextChunking.swift` feeds long unbroken mixed text whole, in
  pieces and one byte at a time: all chunkings agree, and both builds agree, on
  60 seeds.
- A new model-based test drives every row edit that moves, replaces or drops
  cluster text and links against a plain array of cells.

One regression was caught by measurement and fixed before this report: after
the payload store changed, the UTF-8 byte count for rows entering scrollback
stopped being inlined, and primary-screen ASCII fell from 390 to 309 MiB/s
headless. The alternate-screen comparison could not have shown it.

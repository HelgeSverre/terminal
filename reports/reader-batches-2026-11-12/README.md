# Larger read slabs: fewer wakes of the terminal owner

Measured on an Apple M2 Max, macOS 15.6, on AC power, on 2026-11-12. The
one-minute load average was 1.6–3.4. Base is `a9aee32` (0.4.0). References
are Ghostty 1.4.0 and Kitty 0.45.0. This continues the
[cluster and reader report](../unicode-clusters-2026-11-10/README.md), which
left the ASCII gap to Ghostty unexplained.

## What changed

`PTYReadBroker` reads into slabs of 64 KiB (was 16) and gives the reader
credit for two slabs, 128 KiB (was 64). The slab is no longer zero-filled, so
a session that reads little touches little of it.

## Why

Every delivery that finds the terminal owner idle wakes its thread. A wake
costs the reader about 20 microseconds in which the child's output waits. A
flood of plain text fills a slab faster than the owner parses one, so with
16 KiB slabs the owner was woken about 15,000 times a second.

This was found by running a bare read loop inside the app in place of the
reader, on short ASCII lines, and adding the pipeline's parts one at a time
(MiB/s, medians of ten 16 MiB samples, window in the background):

| Reader | MiB/s |
| --- | ---: |
| The app's reader (16 KiB slabs) | 237 |
| Bare loop, nothing delivered | 350 |
| Bare loop, one copy per 16 KiB | 343 |
| Bare loop, one empty block on another queue per 16 KiB | 240 |
| Same, per 64 KiB | 295 |
| Same, per 256 KiB | 328 |
| Bare loop, a parked thread signalled per 16 KiB | 253 |
| Bare loop, a thread that never sleeps, flagged per 16 KiB | 325 |

The app's reader then follows the same curve with its slab size:

| Slab, credit | Short ASCII | Mixed Unicode |
| --- | ---: | ---: |
| 16 KiB, 64 KiB (before) | 238 | 142 |
| 32 KiB, 64 KiB | 263 | 147 |
| 64 KiB, 64 KiB | 257 | 132 |
| 64 KiB, 128 KiB (chosen) | 290 | 152 |
| 64 KiB, 256 KiB | 287 | 154 |
| 128 KiB, 512 KiB | 300 | 153 |
| 256 KiB, 1 MiB | 310 | 156 |

Credit for a single slab makes the reader wait for the parser. Beyond 64 KiB
the gain is small and the output queued ahead of a key grows with it.

## Result

Whole-app PTY throughput, MiB/s, 100×30 cells, alternate screen, medians of
ten 16 MiB samples, mean of two interleaved rounds. "Foreground" is how
`just benchmark-terminals` runs the app; "background" starts it with
`--background`, where it is not drawn at display rate.

| Workload | Foreground before | Foreground after | Change | Background before | Background after | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Short ASCII lines | 222.1 | 248.3 | +12% | 238.1 | 287.0 | +21% |
| Long ASCII lines | 255.5 | 284.3 | +11% | 257.0 | 321.1 | +25% |
| ANSI truecolor | 196.7 | 204.8 | +4% | 208.8 | 215.4 | +3% |
| Mixed Unicode | 135.8 | 142.8 | +5% | 136.9 | 148.1 | +8% |

Four more background rounds gave the same means within 2% (`old-new/`).

Against the other terminals, `just benchmark-terminals` at the changed
source, mean of the two trial medians, MiB/s (`three-app/`):

| Workload | Helge Terminal | Ghostty | Kitty | Ours / Ghostty | Ours / Kitty |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII lines | 240.8 | 293.4 | 109.0 | 82% | 221% |
| Long ASCII lines | 283.3 | 329.7 | 111.9 | 86% | 253% |
| ANSI truecolor | 205.2 | 201.4 | 77.4 | 102% | 265% |
| Mixed Unicode | 141.6 | 186.9 | 115.1 | 76% | 123% |

Ghostty was faster in this run than in the 0.3.0 run (280 / 288), so the
ratios moved less than the absolute figures: 78% / 87% / 100% / 76% then.
The goal of matching Ghostty on ASCII and mixed Unicode is still unmet.

## Cost

A key typed during a flood waits behind the output read before it, which is
now bounded by 128 KiB instead of 64. Key-to-program latency in milliseconds,
300 keys, two runs before and three after
(`TERMINAL_MEASURE=1 just unit-test --filter SessionFloodLatencyMeasurement`):

| Case | Before | After |
| --- | ---: | ---: |
| Flood, median | 0.13–0.17 | 0.09–0.24 |
| Flood, 95th percentile | 0.28–0.31 | 0.26–0.51 |
| Flood, 99th percentile | 0.32–0.37 | 0.38–0.60 |
| Flood, slowest | 0.38–0.40 | 0.44–0.67 |
| Idle, median | 0.14–0.15 | 0.10–0.14 |

Each session's slab is 64 KiB of address space instead of 16; only what a
session reads into is touched.

## What did not help

Tried in the app with environment switches on short ASCII; none moved the
median by more than 3%, and none was kept:

- pausing 0.4–2.2 µs after each full read, and between retries of an empty
  one, although a 0.7 µs pause raises a bare loop from 222 to 290 MiB/s;
- waiting for a refill after a short read instead of ending the turn;
- a parked reader thread in place of the dispatch read source;
- the reader's queue at default quality of service;
- locks that never park their thread;
- an owner that spins up to 300 µs for the next batch;
- handing batches over through a list the owner drains, in place of one
  queue block per batch;
- a PTY line speed of 38,400 baud or more.

A successful read of one kilobyte takes about 2.3 µs in the app's reader
against 1.3 µs in the bare loop in the same process, in every one of these
variants. The child uses about the same processor time per kilobyte either
way and waits longer; the app and the child run on performance cores
throughout. What makes the child slower to refill while the pipeline runs,
beyond the owner's wakes, was not found.

## What is left

- **The foreground penalty.** Drawing costs the changed build 13% on short
  ASCII (287 to 248). During a foreground flood the render queue is busy 41%
  of the time, much of it in Metal's buffer allocator
  (`MTLRangeAllocatorGetMaxFreeSize`). Not yet looked into.
- **Mixed Unicode, 76% of Ghostty**, bound by the parser as before.
- Not measured here: the SQL motion stress, resize under flood, memory.

## How correctness was checked

`just test` passes on the changed source. `PTYAdmissionTests` now takes its
bound from `PTYReadBroker.readQuantum`; the broker and endpoint tests set
their own small slabs and are unchanged.

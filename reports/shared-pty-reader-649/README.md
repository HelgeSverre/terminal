# Shared PTY reader investigation

The owner queue previously alternated nonblocking PTY reads with terminal
mutation. A child writing continuously usually supplied about 1,023 bytes per
read on this Mac. Increasing the userspace buffer did not change that kernel
queue behavior. This experiment separates readiness and reads from the serial
terminal owner, so the child can keep writing while earlier output is parsed.

## Initial app comparison

These frozen apps use source `e62bd66`, whose runtime predates the CSI-run and
borrowed-ASCII changes in `649083c`. Stage A batches output on the existing
owner queue. Stage B adds a shared serial read lane, an ordered submission
broker, and descriptor leases. Neither prototype is a release artifact.

Six visible app runs execute baseline–A–B, then B–A–baseline, with ten 16 MiB
samples per workload. Each uses the same driver, 100×30 cells, configured
Obel Mono 14, alternate screen, output processing, and 1700×1230 pixel canvas.
The pixel geometry differs from the earlier three-terminal comparison; use the
matched baseline here when attributing gains. No competing build or benchmark
ran during these observations. Desktop load is recorded in the raw report.

| Workload | Baseline trial medians, MiB/s | Stage A | Stage B |
| --- | ---: | ---: | ---: |
| Short ASCII | 59.41 / 59.25 | 56.27 / 57.42 | 94.76 / 93.63 |
| Long ASCII | 75.70 / 75.02 | 70.63 / 72.84 | 123.28 / 100.97 |
| ANSI truecolor | 32.03 / 32.02 | 30.73 / 31.55 | 41.90 / 42.19 |
| Unicode | 16.85 / 16.83 | 16.33 / 16.62 | 19.49 / 19.58 |

Stage A alone is slower. Stage B improves all four workloads, though the long
ASCII result varies considerably between trials. All six apps and their owned
children exit naturally without survivors. These results measure PTY processing
through an ordered terminal reply, not frame rate or input latency.

`exploration-apps.json` retains every sample, command, executable hash, layout,
and lifecycle result. `compare_stages.rb` is the one-off runner. The two app
provenance files retain compiler arguments and input hashes.
Exact prototype patches are stored as `prototypes/*.patch.gz`; their recorded
patch hashes apply to the decompressed bytes.

## Correctness and rollout gates

The prototype's full Session suite passes. Deterministic transport tests cover
ordered data and controls, leased output with resumable zero-byte parser work,
consumption-held credit, EOF, close, and descriptor reuse. The missed-resume
test passes; removing the post-pause credit recheck makes its negative control
fail. `correctness.json` and `endpoint-negative-control.json` retain that proof.

The final candidate removes Stage A admission policy from the owner queue and
retains one record per broker delivery. Its source and tests are rebased onto
`649083c`; `shared-io-649-manifest.json` lists exact hashes. The rebased full
Session suite passes, and the five IO suites are wired into `just test` through
`just session-io-test`. Restoring the production default to 2 MiB makes the
default-admission regression fail (`default-2mib-negative.json`).

## Read-ahead and interactive latency

A native child continuously writes multilingual Unicode or synthetic
SQL-shaped output through a real PTY. An independent child thread records
numbered input receipts and its actual PTY dimensions in an acknowledgment
file. These timestamps measure child receipt without waiting for acknowledgment
text to be rendered behind the flood. Ordered owner probes are recorded
separately. Resize trials alternate 100/101 columns and submit input after each
resize, so their measurements include reflow and the resize ioctl.

Both matrices run baseline–candidate–candidate–baseline, with 128 requests per
workload/mode/trial and a 300 ms warmup. Every record contains all 128 receipts
and owner probes, correct geometry, no rejected input, advancing parse counters,
nonzero backlog, and a reaped child. These are headless Session measurements;
they do not include AppKit, GPU load, or input-to-photon latency.

The 2 MiB prototype reaches its full backlog and delays input: Unicode p99 is
62.59–64.36 ms and synthetic SQL p99 is 46.66–48.64 ms, against baseline values
below 1 ms. It is rejected for rollout.

The smaller candidate limits read-ahead to 64 KiB, one existing read-turn
quantum. It reaches that bound in every mode:

| Workload and operation | Baseline p95, ms | 64 KiB p95, ms | Baseline p99, ms | 64 KiB p99, ms |
| --- | ---: | ---: | ---: | ---: |
| Unicode input | 0.29–0.38 | 2.99–3.19 | 0.40–0.62 | 3.36–3.65 |
| Synthetic SQL input | 0.32–0.37 | 1.72–1.80 | 0.58–0.68 | 1.97–2.11 |
| Unicode resize and input | 80.19–80.79 | 81.55–81.67 | 80.85–98.10 | 82.74–84.85 |
| Synthetic SQL resize and input | 26.36–26.72 | 28.17–28.33 | 27.02–27.19 | 28.68–29.28 |

Ranges represent the two trial percentiles, using nearest rank. The smaller
bound keeps input p99 below the 16.7 ms gate, with about 1–2 ms of additional
resize p95 delay. Baseline Unicode resize p99 varies between trials; the lower
candidate value in the first order does not establish faster reflow.

`latency/frozen-2mib` and `latency/64k` contain raw samples, summaries, and
harness snapshots. Input manifests map compiler commands, sources, and binary
hashes. The original harness was restored by removing its sole later probe-drain
edit; its source hashes were captured after the runs, not at compile time. Its
original binaries were retained unchanged. The later harness explicitly drains
probe callbacks; the validator confirms all callbacks in both matrices.
These latency matrices use the frozen pre-649 runtime; final integration is
also checked through the rebased Session suite and the app gates below.

## Final app comparison against 649083c

The cleaned 64 KiB candidate uses the final 649 runtime plus the reviewed IO
changes. Two frozen WMO apps run baseline–candidate–candidate–baseline, ten
16 MiB samples per workload, with the same 100×30 grid, Obel Mono 14 setting,
1700×1230 pixel canvas, and alternate screen. All four apps and owned children
exit naturally, without cleanup survivors.

| Workload | Baseline trial medians, MiB/s | Candidate, MiB/s | Matched gain |
| --- | ---: | ---: | ---: |
| Short ASCII | 62.65 / 63.14 | 96.86 / 96.07 | +54.6% / +52.2% |
| Long ASCII | 78.83 / 77.65 | 101.65 / 100.96 | +29.0% / +30.0% |
| ANSI truecolor | 33.73 / 33.65 | 45.01 / 44.26 | +33.4% / +31.5% |
| Unicode | 16.87 / 16.82 | 19.82 / 19.59 | +17.4% / +16.5% |

`app-comparison.json` contains every sample and lifecycle check. The runner is
the unchanged [paired app runner](../borrowed-ascii-e62/compare_pair.rb).
`baseline-build.json` and `rebased-649-app.provenance.json` record the compiler
inputs. The measured candidate's signed executable hash is
`34798ae9dfbaab0e77a2c6feb042d2409c4a0ba5965e79f4ccabcd77b6a4e4c5`.

The throughput gain survives the smaller lookahead. It does not establish
comparable Ghostty performance; the remaining Unicode gap is substantial.

## Full SQL dump with window motion

One baseline run and one candidate run each read the same 8,162,501,113-byte
local SQL dump through `/bin/cat`, with primary history enabled. The window
follows a seven-second figure-eight cycle while its width and height vary at
a target 60 Hz. Both runs cover the same applied frame bounds. The source's
identity and size are checked before and after each run; no SQL contents are
stored in the reports.

| Observation | Baseline | Candidate |
| --- | ---: | ---: |
| PTY stream duration | 218.88 s | 156.38 s |
| Parsed PTY throughput | 35.66 MiB/s | 49.91 MiB/s |
| Main-queue heartbeat p99 | 4.86 ms | 4.94 ms |
| Ordered owner-probe p99 | 22.88 ms | 23.22 ms |
| Sampled peak physical footprint | 112.77 MiB | 101.97 MiB |
| Metal errors / mismatched presents / mismatched drawables | 0 / 0 / 0 | 0 / 0 / 0 |

Both apps parse every byte they read, stay within the 64 MiB history budget,
reap the child, and exit naturally without survivors. The candidate completes
about 29% sooner in this pair. This is a development stress comparison, with
one whole-file observation per build; it does not establish a general SQL
speedup or a controlled memory comparison. Duration differs, so the final
motion phase, retained history, and sample count differ too.

PTY byte totals are 8,183,995,283 and 8,183,995,155. Normal output processing
expands LF and can produce variable extra CR bytes under backpressure, as
documented in the [benchmark guide](../../docs/benchmarking.md#sql-dump-stress-test).
Equal read/parsed counters prove drainage, not a content hash. The reports in
`sql-motion-baseline` and `sql-motion-candidate` retain counters, timing
distributions, frame bounds, memory samples, executable hashes, and cleanup
checks. This motion run exercises one pane; focused transport tests and native
pane smoke cover other session and split interactions.

## Integrated verification

`just test`, `just release-build`, and `ruby tools/native_smoke.rb normal` pass.
The native smoke covers input, split panes, resize, and Metal, and confirms app
termination. The full suite also exercises interactive zsh editing, clipboard
policy, PTY tools, snapshot delivery, and all five IO groups. `local-test.log`,
`local-release-build.log`, and `local-session.json` retain the outcomes.

The production build has the exact signed executable hash measured in the app
and SQL comparisons above. `production-build.json` and `integration.json`
record that identity; no runtime changes were made after those measurements.
The build tool hashes its compiler output before bundle signing. The
[packaging proof](../terminal-comparison-2026-11-10/app-provenance.json) maps
that artifact to the measured signed executable and verifies payload identity.

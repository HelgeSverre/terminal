# Performance measurements

The [direct text path report](../reports/direct-text-path-2026-11-10/README.md)
is the current standing: three-app, paired against v0.2.4, headless, SQL stress
and input latency. It also holds the headless benchmark, the differential
fuzzer and the PTY-ceiling probes used to get there.

The earlier [three-app comparison](../reports/terminal-comparison-2026-11-10/README.md)
measures the v0.2.4 shared-reader build, Ghostty and Kitty with ten samples per
workload in two reversed launch orders. Run it with the reference apps installed:

```shell
just benchmark-terminals reports/terminal-comparison-next
```

This freezes independent copies, verifies report ownership and geometry, and
requires natural app/child exit. It leaves existing sessions and configurations
alone. All apps use 100×30 cells and configured Obel Mono 14; native cell-pixel
sizes differ. The driver measures PTY processing through an ordered reply,
including backpressure; it does not measure displayed FPS or input-to-photon
latency. Alternate-screen workloads exclude retained history.

The [shared-reader comparison](../reports/shared-pty-reader-649/README.md)
measures the reader change against `649083c`, including a full SQL dump with
window motion and separate sustained-flood input/resize latency gates. Keep its
paired app gains separate from the three-app observations. The previous
[9354d3a comparison](../reports/terminal-comparison-2026-11-09/README.md) retains
the earlier runtime and display geometry.

The earlier [Swift–Ghostty baseline](../reports/ghostty-swift-2026-11-09/README.md)
retains its raw results, limits and feature comparison. Its two-app runner is
preserved in repository history; the current command includes Kitty too.

The three-app pilots below predate the Swift cutover and measured the Rust-backed
app. They are retained as historical results.

## Historical three-app pilots

Run the same payload in three separate, visible application instances. The local
comparison driver uses 100×30 cells, Obel Mono 14, opaque backgrounds, cursor blink
disabled, and an alternate screen. Existing user configuration is not changed.
The alternate screen deliberately excludes history retention; the SQL stress run
below exercises primary-screen history separately.

Build this terminal once, then run the apps **sequentially**, with no other heavy
work and a consistent display, power mode, and window visibility:

```shell
just build
just benchmark terminal reports/comparison-001
just benchmark ghostty reports/comparison-001
just benchmark kitty reports/comparison-001
```

The runner saves exact reference versions, configuration, OS version, and executable
hashes alongside each JSON report. It refuses to replace an existing report.
`BENCH_BYTES=67108864 BENCH_RUNS=10` increases each workload to 64 MiB and ten
samples. The default is a short 16 MiB × five-run comparison, not a sustained
acceptance test. Keep both apps' versions and all settings with any published
numbers. If geometry differs, the driver refuses to benchmark it.

The first completed pilot is in `reports/comparison-002` (M2 Max, macOS 15.6,
Ghostty 1.4.0, Kitty 0.45.0). Median source throughput in MiB/s:

| Workload | This terminal | Ghostty | Kitty |
| --- | ---: | ---: | ---: |
| Short ASCII lines | 26.9 | 287.4 | 112.0 |
| Long ASCII lines | 36.4 | 326.5 | 115.6 |
| ANSI truecolor | 7.6 | 195.8 | 47.2 |
| Unicode | 5.1 | 186.8 | 116.3 |

This implementation is substantially slower in this pilot. It is useful evidence
for optimization, not a general ranking of terminal quality. The 16 MiB samples
are short, and display smoothness was not measured. Ghostty's resource counters
were unavailable. DSR median RTT was 0.021 ms here, 0.029 ms in Ghostty, and
3.213 ms in Kitty; that result includes each app's reply scheduling policy and
must not be presented as keyboard or display latency.

After replacing per-cell JSON with typed snapshot views, the same driver and
settings were rerun sequentially in all three apps (`reports/comparison-003`):

| Workload | This terminal | Ghostty | Kitty |
| --- | ---: | ---: | ---: |
| Short ASCII lines | 68.5 | 282.8 | 113.2 |
| Long ASCII lines | 92.3 | 309.8 | 115.8 |
| ANSI truecolor | 20.6 | 198.0 | 46.2 |
| Unicode | 12.7 | 187.4 | 116.2 |

The new bridge improves this terminal's throughput by roughly 2.5× in this pilot.
Both reference apps remain faster on every workload. All reports include exact
binary hashes; no published reference number has been substituted with our
headless parser measurements. This remains a short pilot with the limitations
above, rather than the original specification's sustained acceptance gate.

The deterministic workloads are short ASCII lines, unbroken ASCII, truecolor ANSI,
and Unicode with combining marks, CJK, emoji, and block drawing. Every timed run
ends with a cursor-position query. Its ordered reply establishes that the terminal
has parsed the preceding bytes. Reported source throughput includes ordinary PTY
output processing (LF may expand to CRLF), the final parser barrier, and backpressure.
It excludes neither parser work nor snapshot preparation that blocks the PTY path.

The driver measures the immediate parent terminal process's CPU time and physical
footprint using macOS `proc_pid_rusage`. These exclude child workload CPU and GPU
memory not charged to that process. Hardened reference apps can deny these counters;
the report then records `resource_usage_available: false` and null resource values.
No CPU/memory comparison should be made from missing counters.
Footprints are sampled at run ends and during
idle; they are **not peak memory**. A three-second idle pilot is also included.
Driver 0.2.0 converts CPU counters from Mach ticks with `mach_timebase_info`.
Earlier schema-1 reports treated ticks as nanoseconds, understating CPU time
and idle CPU percentage by about 41.7× on this Mac. Do not quote those older
CPU fields; their throughput, RTT and footprint measurements are unaffected.
The conversion follows [XNU's task accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L6391)
and is checked against the independent process CPU clock in `just test`.
Protocol RTT is a hundred DSR queries after the workloads. It is not keyboard
latency or input-to-photon latency. A DSR reply can precede GPU presentation.

For display smoothness, replay identical precomputed frames at a fixed rate and
resolution, then measure missed deadlines and frame intervals. Use the same native
dmscene player with explicit `--graphics kitty` and the same resolution when
comparing graphics; its own FPS also includes animation computation. A high-speed
camera or common display instrumentation is needed for comparable input-to-photon
measurements. Our Metal command timings alone cannot be compared to Kitty's GPU
submission timings as a display-latency result.

This distinction also matters for existing tools: [vtebench](https://github.com/alacritty/vtebench)
measures PTY processing throughput, and explicitly excludes framerate/latency.
Kitty documents its [performance tradeoffs](https://sw.kovidgoyal.net/kitty/performance/).
Use several independent whole-app runs, report distributions and variance, and
avoid declaring a winner from a single workload.

## SQL dump stress test

`reports/sql-cat-stress.json` is generated by the native `--cat-smoke REPORT BYTES`
mode, followed by `--execute /bin/cat ABSOLUTE_FILE`. It reads the actual local
file through the real PTY, without storing SQL in the report. It samples physical
footprint, main-thread heartbeat delay, ordered owner probes, read/parsed byte
counts, bounded history, Metal errors, and process exit/drain. Two live window
resizes occur during output. This is a development stress run, not an isolated
comparison benchmark. It does not record screenshots or persist a terminal replay.

An independent C-only read/discard control reproduced variable extra CR bytes
beyond one CR per source LF; its LF count matched the file exactly. The native
report includes those audit counts. This is consistent with [XNU's ttyoutput
path](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/tty.c#L895)
enqueueing CR before retrying an LF when the output queue fills. That explanation
for the native byte excess is an inference, not a byte-for-byte content hash.
Do not assume processed PTY byte count is exactly file size plus newline count.

Launch from an authorized shell when testing Downloads. An ad-hoc development
bundle opened via Launch Services may await macOS file-privacy authorization;
time spent blocked opening the file is not terminal processing time. Do not grant
unrelated broad permissions to obtain a benchmark.

## Frozen Swift–Rust core exploration

The [early frozen replay comparison](../reports/swift-decoder-a19f77f/summary.md)
pairs Swift `a19f77f` with the verified archived Rust `b5a9fea` executable.
Three alternating 2 MiB pairs per workload measured:

| Engine throughput | Swift | Rust |
| --- | ---: | ---: |
| ASCII | 2.90 MiB/s | 35.93 MiB/s |
| Mixed Unicode | 4.22 MiB/s | 20.59 MiB/s |

Payload/reply byte counts and hashes match, and canonical final states match.
The same report separately isolates the Swift UTF-8 decoder optimization:
ASCII improves 21.2% and mixed text 13.2% against its direct parent.

These are short headless C-ABI probes at 160×50 with zero retained history
and 64 KiB feed spans, collected on an M2 Max/macOS 15.6 under recorded desktop
load. They include feed, reply draining, parser finish, invariant validation
and final snapshot serialization/free. They exclude the GUI, renderer, PTY,
retained history and search; they do not establish complete behavioral parity.
Rust was not rebuilt, and recorded build wall times are provenance rather than
a matched full-app compilation benchmark. These are historical experiment
results; the application has since switched to Swift. See the [cutover record](swift-cutover.md).

Earlier evidence is retained in the [range-local printing probe](../reports/swift-printing-315f055/summary.md),
[ownership comparison](../reports/emulator-comparison-6c601d1-a49a5af/summary.md)
and `reports/emulator-comparison-ef3b625-b5a9fea/`. Each has its own source,
corpus and measurement contract; use its accompanying limitations when quoting
numbers instead of combining separate runs into a single speedup claim.

## Swift replacement target

Swift must reach at least **70% of Rust's median throughput on each** shared
app workload: short ASCII, long ASCII, ANSI truecolor and Unicode. Do not
average the workloads together to hide a failing case. Correctness, snapshot
ownership and clean process shutdown must pass alongside performance.

Helge lowered the performance threshold from 90% to 70% on 2026-11-08.
80% per workload is a stretch target where practical, not an acceptance
requirement. The Rust implementation is preserved on
`archive/rust-2026-11-08` before the Swift replacement is promoted.
Archived reports retain the criterion used when they were generated; their
measured ratios remain available for comparison with the current threshold.

Run a quick app-level diagnostic from the main worktree with:

```shell
just benchmark-apps /absolute/path/to/Rust.app /absolute/path/to/Swift.app reports/new-comparison
```

The runner compiles one shared driver and launches owned app instances
sequentially. It checks their grid, corpus, sample counts and report ownership,
then requires natural app exit and reaped children. Exceptions and interrupts
clean up only owned processes. `comparison.json` records the 70% performance
gate separately from successful measurement. The default 2 MiB × three-sample
run is a diagnostic pilot.

Before accepting a replacement, use 16 MiB × ten samples per workload and
repeat independent trials with alternating app order, fixed visibility and
the same hardware/power conditions. Preserve every result, source/binary
hashes and background activity; an isolated short passing pilot is insufficient.
The shared replay/semantic gates must also remain green. Full-app throughput
and headless engine measurements stay separate.

For example, run two independent trials in opposite orders, using the same
immutable bundles and a new output directory for each:

```shell
BENCH_BYTES=16777216 BENCH_RUNS=10 BENCH_FIRST=rust just benchmark-apps /absolute/path/to/Rust.app /absolute/path/to/Swift.app reports/acceptance-rust-first
BENCH_BYTES=16777216 BENCH_RUNS=10 BENCH_FIRST=swift just benchmark-apps /absolute/path/to/Rust.app /absolute/path/to/Swift.app reports/acceptance-swift-first
```

`BENCH_FIRST` defaults to `rust`; each report records its actual order. Both
trials must clear the per-workload gate. Compile and profile outside the timing
window, and keep the installed user session out of the test process tree.

The [snapshot optimization report](../reports/swift-app-comparison-ca252d0/summary.md)
records a measured 3.7–3.9× app improvement after removing the full-grid JSON
round trip. Its four Swift/Rust ratios remain below the replacement target.

The [same-source WMO comparison](../reports/swift-app-comparison-4ca285f-wmo/summary.md)
then measures Swift at 7.87/9.94/3.79/9.07 MiB/s for the four workloads,
respectively. This improves the batched incremental build, but all four
ratios remain below 90%. Compiler mode, source changes and workload changes
are measured separately.

The [earlier fused WMO comparison](../reports/swift-app-comparison-f10acc2-wmo/summary.md)
measures Swift at 16.61/20.12/10.32/12.12 MiB/s. It improves ANSI throughput
2.244× relative to the preceding fused pilot, while the other workloads change
by only one to two percent. Its four Swift/Rust ratios remain below 90%, so it
did not meet the replacement target used for that report. Later measurements
and the current criterion are recorded in the
[performance research findings](swift-performance-research/synthesis.md).

The app's `--background` launch flag opens the launch window behind other
apps and does not take focus. `BENCH_BACKGROUND=1 just diagnose-stream
APP OUTPUT BYTES` uses it, for diagnostic runs on a desktop in use. A window
behind others may present fewer frames, so never mix background runs with
comparison figures.

For the next diagnostic stack capture, use:

```shell
just profile-app /absolute/path/to/Terminal.app reports/new-profile
just profile-app /absolute/path/to/Terminal.app reports/unicode-profile unicode
```

This builds the common driver, launches an owned app, then samples only its
derived PID after startup. Both sampler and app must exit cleanly; failures
still clean up both owned trees. The saved driver wall/CPU numbers are
diagnostic-only because sampling perturbs them.

An optional workload selects `ascii_short_lines`, `ascii_long_lines`,
`ansi_truecolor` or `unicode`. Selected captures run 512 MiB of that workload
so the sampler can observe it independently; the default runs all four at
64 MiB each. These diagnostic sizes are separate from comparison pilots.

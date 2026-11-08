# Fused WMO Swift app comparison

Frozen Swift `03e90f6` was compiled with the same `-O
-whole-module-optimization` mode as the earlier `4ca285f` WMO pilot. The
source checkpoint and exact input hashes are in [build.json](build.json) and
[input.sha256](input.sha256). This pilot uses the same 2 MiB, three-sample,
100×30 Obel Mono 14 visible-app PTY workload as the prior report.

| Median MiB/s | Swift 4ca WMO | Swift 03e WMO | Change | Rust in 03e run | Swift 03e / Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII | 7.873706 | 8.803437 | +11.8% | 69.861674 | 12.60% |
| Long ASCII | 9.938036 | 11.437918 | +15.1% | 90.460898 | 12.64% |
| ANSI truecolor | 3.787456 | 4.136719 | +9.2% | 21.391061 | 19.34% |
| Unicode | 9.071323 | 9.660342 | +6.5% | 14.746979 | 65.51% |

The Rust column is the contemporary reference run, not a value copied from the
earlier pilot. The 03e source improves every measured Swift workload over the
4ca WMO pilot, but the at-least-90% replacement gate remains false for all
four workloads. This is optimization evidence, not replacement acceptance.

The focused correctness worker passed. The WMO core smoke passed; its concise
result is retained in the raw archive as `core-test.log`. The WMO native smoke
also passed; its compact result is [native-smoke.json](native-smoke.json).
Each measured app exited naturally with no surviving children according to
[comparison.json](comparison.json).

The raw driver, launcher logs, and core-test output are retained once in
`raw-evidence.tar.gz`; compact measurement and provenance files remain beside
this summary. The archive also preserves the exact input manifest. The frozen
bundle is preserved outside the repository with executable hash
`6f87c90fad680584905efe3fe79aeb4a51cd69365be56883132ce4c8724e1f95`.

## Diagnostic profiles and selected workloads

Two independent owned profiles of the frozen 03e bundle passed. In both, the
app and sampler exited naturally with no children. Their driver wall and CPU
fields are diagnostic-only because sampling perturbs the run.

The first, 64 MiB all-workload profile recorded 3,805 owner-queue samples in
the initial ASCII workload: `feed` had 1,708 inclusive samples, `flush` 1,289,
and `lineFeed` 913. The 512 MiB Unicode-only profile recorded 3,803 owner-queue
samples: `feed` had 1,645 inclusive samples, `flush` 1,304, and `lineFeed`
892 plus 400 branch samples. Parent and child samples are inclusive and must
not be added together.

Both raw samples show `TerminalCanvasView.display(_:)` entering
`AccessibilityProjection.init(snapshot:limit:)`, with row snapshot copying,
`CellStyle` initialization/destruction, and retain/release work below it. That
is the next measured hotspot; the profiles do not by themselves establish a
throughput change. `profile-evidence.tar.gz` retains each profile's raw sample,
launcher logs, driver output, and lifecycle proof without changing the sealed
comparison archive.

[profile/profile.json](profile/profile.json) and
[profile-unicode/profile.json](profile-unicode/profile.json) record each
contract, app and driver hashes, raw-sample hash, and clean lifecycle.

The selected-workload fixture separately exercised every named workload with
exact JSON selection and a natural app exit; an unknown selection was rejected.
Its [verification](../selected-workload-verification/verification.json), four
small reports, and [source/driver provenance](../selected-workload-verification/provenance.json)
are correctness checks, not results comparable to the 2 MiB pilot.

This is a short local pilot under ordinary desktop activity. It measures source
output/backpressure and ordered parser barriers, not display latency, search,
or retained-history throughput.

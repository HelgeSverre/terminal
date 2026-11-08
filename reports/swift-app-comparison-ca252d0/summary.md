# Swift app snapshot optimization

Swift `ca252d0` removes a full-grid JSON serialization/parse round trip from
binary snapshot publication. The same shared metadata builder serves the
typed binary view and the legacy diagnostic JSON snapshot. Cell selection,
styles, links, cursor state and callback lifetimes remain covered by the
snapshot-equivalence tests.

The two short app pilots used 100×30 cells, reported PTY pixels 900×630,
Obel Mono 14, the same compiled driver, 2 MiB per workload and three samples.
Each app ran sequentially in its own normal window with a real PTY. The
driver's alternate screen excludes retained history. Both apps exited
naturally with no surviving children in both runs.

| Median MiB/s | Swift before (`fb90061`) | Swift after (`ca252d0`) | Rust in after run | Swift / Rust |
| --- | ---: | ---: | ---: | ---: |
| Short ASCII | 1.172580 | 4.381382 | 69.912958 | 6.27% |
| Long ASCII | 1.357085 | 5.220269 | 89.377486 | 5.84% |
| ANSI truecolor | 0.949623 | 3.572500 | 21.355429 | 16.73% |
| Unicode | 1.629839 | 6.334406 | 14.965467 | 42.33% |

The snapshot change improves Swift by about 3.7–3.9× on these workloads.
**The replacement target of at least 90% of Rust on every workload is unmet.**
`comparison.json` records measurement completion separately from this
performance gate; a successful test run is not performance acceptance.

| Built app size | Swift after | Rust |
| --- | ---: | ---: |
| Executable bytes | 1,865,552 | 3,743,056 |
| Bundle regular-file bytes | 7,143,248 | 9,022,529 |

Bundle size sums regular files, including bundled fonts and resources; it is
not compressed package size or APFS allocated disk usage. This run does not
provide a matched compilation-speed comparison.

Read [comparison.json](comparison.json), [swift.json](swift.json) and
[rust.json](rust.json) for raw distributions, resource counters, binary hashes
and cleanup evidence. The fixed-clock baseline is in
[the preceding report](../swift-app-comparison-fb90061/comparison.json).
[provenance.json](provenance.json) links the tested source checkpoints,
identical timed driver and validation. All source changes through this
checkpoint are preserved by tag `swift-experiment-20261108-ca252d0`.

Full frozen app bundles and their hash manifest are also preserved locally at
`~/.codex/artifacts/terminal-swift-app-comparison-20261108/`. Main remains
Rust-backed; this report does not promote or install the Swift experiment.

## Measured bottleneck

The pre-fix five-second capture sampled the owner thread 3,841 times;
`Session.publish` accounted for 2,905 inclusive samples (75.6%), including
full-grid JSON serialization and parsing. After the fix, a separate capture
sampled the owner 3,815 times: `feed` accounted for 3,390 inclusive samples
(88.9%), while publication accounted for 360 (9.4%). These are stack samples,
not allocation-rate measurements, and parent/child counts must not be added.

The next optimization targets repeated per-scalar printing work. Its evidence
must be measured independently rather than combined into an assumed speedup.

## Validation and limits

The full Swift suite passed at `fb90061`. Snapshot bridge, core, semantic and
boundary tests passed after the snapshot change; the rebuilt native GUI smoke
also passed. History charging now includes row/cell storage and link/text
payloads; its regressions preserve the pre-fix failure and post-fix success.

These short sequential pilots establish a direction, not final acceptance.
They measure source output, backpressure and ordered parser drain. They do
not measure display FPS, input-to-photon latency, search or large retained
history. The two app runs share the same compiled C driver and settings;
ordinary desktop background activity was present. Final acceptance requires
longer repeated runs as described in the benchmark documentation.

Driver 0.2.0 reports CPU time using the host Mach timebase (125/3 here), checked
against `CLOCK_PROCESS_CPUTIME_ID`. Pre-0.2.0 CPU counters are invalid on this
Mac; their throughput and footprint fields use independent measurements.

[raw-evidence.tar.gz](raw-evidence.tar.gz) preserves both fixed-clock app
reports, the before/after stack captures and lifecycle records, validation
logs, driver binaries and all three frozen app executables. SHA-256:
`e41eab09dc01e61e6d28f35f6a065fbf97f91d216dace1b86de74f926a140298`.

# Range-local wide-pair repair probe

This frozen, headless Swift backend comparison isolates commit `315f055`
against `7fc6fac`. It is not a full-app performance claim.

Both C-ABI binaries used identical `-swift-version 5 -O` flags, 160×50
geometry, zero history, 64 KiB maximum feed chunks, a 2 MiB requested corpus,
one warmup per binary/workload, and three alternating pairs. All 12 timed
records and four warmups are retained in `result.json` and `logs/`.

| Workload | Baseline median MiB/s | Range-local candidate median MiB/s | Change |
| --- | ---: | ---: | ---: |
| ASCII | 2.150953 | 2.636098 | +22.56% |
| Mixed | 3.618594 | 3.957430 | +9.36% |

The replay payload/reply gate and canonical final-state gate both passed.
[raw-evidence.tar.gz](raw-evidence.tar.gz) retains snapshots, canonical
projections, logs, frozen binaries, build inputs and diagnostic stack captures.
The archive's SHA-256 is
`77bbff1868c972cc0f0a45e41b27fc038ba3e3c2978e8349bd43679c600523ec`.
Every timed and warmup record is also directly readable in [result.json](result.json).

| Side | Source commit | Binary bytes | SHA-256 | Recorded build wall seconds |
| --- | --- | ---: | --- | ---: |
| Baseline | `7fc6fac490a03f0eef2c67e9e2ce811a38f04cc4` | 615912 | `884c87d4525759376d3fd8ea55a859dae9c4030e82d97279d94cbe958f39a2bf` | 14.00 |
| Candidate | `315f0551008e54cf2496b96fd0545a788760ab68` | 618344 | `9c701177b34320156d8acf879a8afa5f3045459ad70836d4bd4aa2469eeb474f` | 13.81 |

Build timing is retained as provenance, not treated as a compile benchmark.
The experiment's `build/<side>/` directories retain the exact Swift invocation,
source list, source hashes, input hashes, binary hash/size, and clean-source
attestation. The source is preserved remotely by annotated checkpoint
`swift-experiment-20261108-54dc608`, whose ancestry includes both measured commits.

This short probe does not replace the [Swift/Rust comparison](../emulator-comparison-6c601d1-a49a5af/summary.md).
The measured sources, corpus size and run date differ; Rust was not rerun here.

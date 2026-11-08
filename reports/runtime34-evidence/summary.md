# Runtime 34bd618 evidence

Frozen source `34bd618195fb5f18fca00ca6e20df0aa098955b4` produced Swift runtime
executable `57fe2903874776c5dceff205c8e79244326cb5494cbdf2f8a33b016656a2c48f`
(`0.2.0`, build `5`). The 16 MiB × ten-run visible-app acceptance runs passed
in both launch orders. Every measured workload clears the 70% requirement and
the 80% stretch target.

| Workload | Rust median range (MiB/s) | Swift median range (MiB/s) | Swift/Rust ratio range |
| --- | ---: | ---: | ---: |
| Short ASCII lines | 69.532567–69.798892 | 64.125943–64.171724 | 91.9380–92.2243% |
| Long ASCII lines | 89.459942–89.555580 | 80.463065–80.520160 | 89.9108–89.9431% |
| ANSI truecolor | 20.791939–20.895557 | 18.965975–19.017802 | 90.7656–91.4672% |
| Unicode | 14.542374–14.802890 | 12.843287–12.860713 | 86.8797–88.3163% |

The ranges pair the exact p50 medians from the Rust-first and Swift-first
runs. Both reports validate their raw samples, use the same 100×30 Obel Mono
14 geometry, and record natural exit with no cleanup survivors. This measures
sequential visible-app PTY parsing and barriers in the alternate screen; it is
not a display-latency result.

The native final fixture set also passed all eight owned runs: native, editing,
glyph, atlas, atlas-budget, close-window, close-shortcut, and the 960×600 Kitty
demo. Every owned process exited naturally with an empty cleanup list. macOS
output was muted before the Kitty demo.

The retained [raw evidence archive](raw-evidence.tar.gz) has SHA-256
`b4d0307fce57d5eac87b9be86a8f97ac3e5c73e278c3b10f6cc0481f3873ce00` and
contains the fixture runner, provenance, JSON reports, logs, raw samples, and
benchmark binaries for both orders.

This is runtime-34 evidence only. The immutable 058 build pair remains
separate in [build-comparison-0587616](../build-comparison-0587616/summary.md),
and the earlier 65 acceptance evidence remains separate in
[swift-app-acceptance-65cb446-evidence](../swift-app-acceptance-65cb446-evidence/summary.md).
The test-only `5cfe701` follow-up is not part of this runtime result. CI for
that follow-up is pending, so this report does not claim CI success, promotion,
or final replacement readiness.

The paired 8.16 GB primary-history SQL stress result is separate:
[Swift reaches 67.9361% of Rust throughput there](../sql-full-34bd618-evidence/summary.md),
below the 70% target despite this report's four standard workloads passing.

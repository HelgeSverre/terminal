# Swift cutover, 0.2.0

Main now uses Swift for VT interpretation, terminal document/history, input
encoding, search and snapshots. AppKit, CoreText and Metal remain the native
host. C is retained for process launch and the compatibility ABI. Active build,
test and Unicode-generation workflows require no Rust toolchain.

The merge is `3b1fbb784babb9419010ad7f2344f410ad5cde6b`. Its production and
build inputs match validated candidate `5cfe701` exactly. That candidate changes
tests only after runtime `34bd618`. The last Rust Main is preserved on
`archive/rust-2026-11-08` and immutable tag `rust-before-swift-9190820`, both at
`91908204c4f8b56b795b4fc51da74813cd9125a7`.

## Runtime measurements

Each standard workload used 16 MiB of identical PTY output, ten samples per
implementation and both execution orders. These measure parser/output-drain
throughput in a visible app; they do not measure physical display latency.

| Workload | Swift throughput as a percentage of Rust |
| --- | ---: |
| Short ASCII | 91.94–92.22% |
| Long ASCII | 89.91–89.94% |
| ANSI | 90.77–91.47% |
| Unicode | 86.88–88.32% |

All four pass the user's 70% acceptance and 80% stretch thresholds. Raw paired
results, binary identities and owned-process exit checks are retained in
[runtime-34 evidence](../reports/runtime34-evidence/summary.md).

The real SQL dump is a separate primary-screen/history stress workload:

| Full 8,162,501,113-byte SQL file | Rust | Swift |
| --- | ---: | ---: |
| Duration | 112.58 s | 165.74 s |
| Throughput | 69.32 MiB/s | 47.09 MiB/s |
| Peak sampled physical footprint | 93.43 MiB | 182.97 MiB |
| Main-thread heartbeat p95 | 4.63 ms | 4.68 ms |

Both drain all accepted bytes, reap their child and leave no owned processes.
Swift reaches 67.94% of Rust here, below 70%; this remains an optimization gap.
See the [paired SQL evidence](../reports/sql-full-34bd618-evidence/summary.md).
No SQL contents are stored in the report.

The earlier frozen Swift `65cb446` also completed the entire dump while moving
the window in a figure eight and varying width/height for 14,224 ticks: 237.14 s,
32.92 MiB/s, bounded history, complete drain and no surviving owned processes.
This was programmatic window geometry stress, without a matched Rust motion run
or a physical-display smoothness claim.

## Build and size measurements

One sequential pair used fresh project outputs and warm external caches on the
same Mac. Rust `9cc6f92` ran its complete `just build`; Swift `0587616` ran its
complete WMO `just release-build`. Both produce optimized app bundles. The
recipes include different host/compiler work, so this is neither a language-only
comparison nor a statistical compilation benchmark.

| Measurement | Rust | Swift |
| --- | ---: | ---: |
| Complete app build | 29.47 s | 32.43 s |
| Executable | 3.57 MiB | 1.92 MiB |
| Bundle regular-file bytes | 8.61 MiB | 6.96 MiB |

See the [build comparison](../reports/build-comparison-0587616/summary.md) for
commands, byte counts, logs and provenance. These size results belong to that
build pair, rather than the subsequently signed runtime-34 artifact.

## Validation and distribution

The [final candidate CI](https://github.com/HelgeSverre/terminal/actions/runs/42535806699)
and [merged Main CI](https://github.com/HelgeSverre/terminal/actions/runs/42537105929)
pass the full current test graph. Hosted Apple Paravirtual heap-texture upload
failure has a narrowly diagnosed GPU skip; CPU glyph tests always run, and local
physical-Metal validation passes separately. Runtime-34 has eight passing owned
native fixtures, including editing, all Nerd Font pages, glyph-budget pressure,
both quit paths and a 960×600 Kitty demo with macOS output muted.

The signed 0.2.0/build 5 app and PKG were accepted by Apple's notary service,
stapled and independently validated with codesign, stapler, pkgutil and
Gatekeeper. Both signed-app shutdown fixtures exit naturally and reap their
HUP-resistant children. [Distribution evidence](../reports/distribution-0.2.0.json)
contains source identities, artifact hashes, notary receipts and command output.

After the user closed their old sessions, the matching notarized app was installed
at `~/Applications/Helge Terminal.app`. Every regular file matches the signed
source, and the installed copy passes signature, staple and Gatekeeper checks.
Separate signed native and editing smoke runs also pass. One earlier direct
launch failed to acquire an active key window; that observation is retained in
the distribution report, and its cause remains unproven.

The first installed launch also inherited `NO_COLOR=1` from the automation
environment. This disabled colors in Codex and `files`. A controlled real-PTY
`files` test emits zero SGR sequences with that value and 25 with it unset;
screenshots of the same signed Swift runtime confirm the visual difference.
A clean app instance was opened with inherited color overrides removed. Existing
user sessions were preserved. Normal launches continue to honor intentional
`NO_COLOR` settings; visual test fixtures sanitize their inherited color policy.

The broader terminal specification is still in progress; see [remaining v1 work](status.md).

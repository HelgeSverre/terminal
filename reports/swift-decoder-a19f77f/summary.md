# Swift UTF-8 optimization and fresh Rust reference

The Swift decoder now stores an incomplete UTF-8 prefix in fixed value fields
and emits zero, one or two scalars without allocating an array for each byte.
The experiment remains separate from the Rust-backed main app.

Two frozen replay experiments used the same 160×50 geometry, zero history,
64 KiB feed spans, 2 MiB requested corpus, one warmup per binary/workload and
three alternating pairs. Each includes feed, replies, pending-work drain,
finish, invariant checks and final snapshot serialization/copy/free.

## Decoder change only

`a19f77f` is compared with its direct parent `f5dd5a9`, using identical Swift
`-swift-version 5 -O` builds.

| Workload | Before MiB/s | After MiB/s | Gain |
| --- | ---: | ---: | ---: |
| ASCII | 2.451503 | 2.971472 | 21.21% |
| Mixed Unicode | 3.779404 | 4.277444 | 13.18% |

[decoder-result.json](decoder-result.json) contains every sample, machine and
background activity records, binary hashes and both correctness gates.

## Fresh Swift versus Rust replay

The second run pairs the same Swift `a19f77f` executable with the verified
archived Rust `b5a9fea` executable. These are newly collected samples; Rust
was not rebuilt. The separate run explains why its Swift medians differ
slightly from the decoder-only comparison.

| Metric | Swift | Rust |
| --- | ---: | ---: |
| ASCII median MiB/s | 2.897367 | 35.928574 |
| Mixed Unicode median MiB/s | 4.224177 | 20.592233 |
| Backend executable bytes | 619,320 | 2,438,272 |

Rust is 12.4× faster on ASCII and 4.9× on mixed text in this run. Swift's
backend executable is smaller; this is not a complete app-bundle comparison.
See [rust-reference-result.json](rust-reference-result.json).

Both experiments pass exact payload/reply byte counts and hashes, plus
canonical final-state comparison. Publication additionally checked all 24
timed and eight warmup records against their raw state hashes, canonical
states and streams; see [publication-verification.json](publication-verification.json).
Focused implementation tests cover every two-byte input, viable-prefix
boundaries against Swift's decoder, terminal semantics, transport boundaries,
wide cells and retained value snapshots.

These are short backend probes on an M2 Max/macOS 15.6 under recorded desktop
load, including a busy qemu process. They exclude GUI rendering, PTY ingress,
retained history and search. They establish neither full-app speed nor complete
behavioral parity. Build wall times are provenance, not a matched compilation
benchmark. All task-owned harnesses exited and temporary source worktrees were
removed.

[raw-evidence.tar.gz](raw-evidence.tar.gz) preserves both report trees, all raw
snapshots, canonical projections, logs, build provenance, all three frozen
binaries and the reproducer. SHA-256:
`039dc1395cd5633518ca68ac814328b5de88e5d904dc729bc94ead70e69f538c`.
The two pre-timing runner setup failures remain explicitly marked incomplete
inside the archive and contribute no measured samples.

Source is preserved remotely by annotated checkpoint
`swift-experiment-20261108-a19f77f`. After extracting the archive into a scratch
directory, reproduce the decoder probe with:

```sh
ruby decoder-emission-a19f77f/run_decoder_probe.rb NEW_REPORT_DIRECTORY \
  decoder-emission-a19f77f/binaries/baseline \
  decoder-emission-a19f77f/binaries/candidate
```

For the Rust comparison, use the same runner with `rust-emulator-comparison`
as the baseline, retaining the Swift candidate and setting `BASELINE_LABEL`
to `Archived Rust b5a9fea C-ABI binary (not rebuilt)`.

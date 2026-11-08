# Independent verification

The run completed 60 timed samples: 15 for each implementation/workload pair.
All samples used one payload byte count and FNV-1a digest per workload, and one
reply byte count and digest per workload across Swift and Rust:

| Workload | Payload bytes / FNV-1a | Replies bytes / FNV-1a |
| --- | --- | --- |
| ASCII | 33,554,482 / 45cb85c6ea07a4c6 | 3,273,599 / ed2b741a6f1f43e7 |
| Mixed Unicode | 33,554,516 / 13a836c609bb94cb | 2,606,167 / 7a941d26c8b86757 |

The canonical final-snapshot gate passed for all paired samples. Raw snapshot
differences remain archived with path-to-SHA-256 mapping in
snapshot-sha256.json; four representative raw states remain in
representative-snapshots/.

Elapsed-time quantiles use linear interpolation at p × (n − 1) over each
sorted set of 15 samples:

| Core / workload | p50 | p95 | p99 | Median MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Swift ASCII | 66.616 s | 68.088 s | 68.412 s | 0.480 |
| Rust ASCII | 0.809 s | 0.836 s | 0.845 s | 39.533 |
| Swift mixed | 25.250 s | 26.279 s | 26.315 s | 1.267 |
| Rust mixed | 1.476 s | 1.629 s | 1.714 s | 21.682 |

The median throughput ratios in this specific protocol are Rust/Swift 82.30×
for ASCII and 17.11× for mixed Unicode. These are not language-intrinsic or
full-product rankings.

RSS is process-local and explicitly includes the allocated 32 MiB replay corpus
and runtime allocations. The C helper's getrusage maximum RSS ranged from
46.3–63.5 MiB for Swift ASCII, 52.1–65.5 MiB for Swift mixed, 43.5–44.1 MiB
for Rust ASCII, and 43.7–44.7 MiB for Rust mixed. It excludes GPU memory and
is not application-wide peak memory.

## Identity and environment

- Swift source: clean detached ef3b62564abb9f83128cf9bd75aade814e781d58;
  executable SHA-256 d206e4d5c59e5b578e2a5db9ffe99e6ed45aa509ab339d576a23ac9b7bbe7a23.
- Rust source: clean detached b5a9fea0607f45a9ea891033ee454d0f1e7e4697;
  executable SHA-256 3b6eb607628b9c863cb917a2e0a80a34904692bb5ba8abbabff31fbb8a74b913.
- The C helper blob was byte-identical at the older Rust build checkpoint
  df9cc6e and final Swift checkpoint ef3b625: SHA-256
  a67e79ed93813a67ce88452eff2a1a2efa9d1950f68181e90c50f3cb3f81967e.
- Hardware: Apple M2 Max (Mac14,6), 32 GiB RAM, macOS 15.6, on battery power
  at 31% and discharging.

This was an exploratory background-loaded desktop run, not an idle-machine
acceptance run. At the measurement window, unrelated desktop work included
PHP, Chrome, and an Android/QEMU emulator; the recorded start snapshot has
load average 1.52/2.72/2.99 and retains its coarse process list in result.json.
No unrelated process was stopped.

Build-wall values (Swift 15.113 s; Rust 5.615 s) cover the documented isolated
headless-backend recipes, including the C harness. SDK/compiler caches were not
reset. They are neither full-app cold/incremental build measurements nor a
matched compile benchmark. The comparison excludes GUI, renderer, PTY,
scrollback retention, search, and streaming OSC 52; it is not a full-parity
claim.

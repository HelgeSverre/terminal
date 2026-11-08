# Frozen Swift vs Rust emulator comparison

Canonical final-snapshot gate: **PASS**. Rust has 82.30× higher ASCII and 17.11×
higher mixed throughput in these recorded workloads. These compare the current
implementations, not intrinsic language performance or complete app parity.

| Implementation | Recorded headless build seconds | Executable bytes | SHA-256 |
| --- | ---: | ---: | --- |
| swift | 15.113267 | 549296 | d206e4d5c59e5b578e2a5db9ffe99e6ed45aa509ab339d576a23ac9b7bbe7a23 |
| rust | 5.614658 | 2438272 | 3b6eb607628b9c863cb917a2e0a80a34904692bb5ba8abbabff31fbb8a74b913 |

The build times cover the recorded backend/harness recipes. SDK caches were
not reset; these are not matched full-app clean or incremental build results.
Executable sizes exclude shared system runtimes and app resources.

| Workload | Swift median MiB/s | Rust median MiB/s |
| --- | ---: | ---: |
| ascii | 0.48 | 39.53 |
| mixed | 1.27 | 21.68 |

See result.json for every runtime/RSS sample. Full raw final ABI states are in
the external archive documented by raw-snapshot-archive.json; deterministic
path-to-SHA-256 mapping and four representative raw states remain in this report.

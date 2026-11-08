# Paired full SQL stress, Swift 34bd618 and Rust 9cc6f92

Both applications completed the same local 8,162,501,113-byte SQL source
through `/bin/cat`, primary-screen history, and scheduled live resize probes.
Each report records complete parsing, successful child exit and reaping, ended
read/parser streams, zero queued output bytes, natural application exit, and
an empty cleanup list. No SQL content is retained in this evidence.
Swift read and parsed 8,183,995,084 wire bytes; Rust read and parsed
8,183,995,179. The small source-to-wire expansion is normal terminal
post-processing, not a missing-input count.

| Runtime | Wall time | Parsed throughput | Peak physical footprint |
| --- | ---: | ---: | ---: |
| Swift `34bd618` | 165.743605 s | 47.093159 MiB/s | 191,860,032 bytes |
| Rust `9cc6f92` | 112.575088 s | 69.319794 MiB/s | 97,963,136 bytes |

Swift reaches **67.9361%** of Rust throughput in this paired full-SQL run. It
is below the 70% target on this primary stress workload; the successful run
does not make it a performance pass. The separate four standard runtime-34
workloads remain a different scope and range from 86.8797% to 92.2243%.

Swift finished following the tail with scroll offset zero and no anchored
snapshots. Its main-queue delay was p95 4.679042 ms (maximum 5.000958 ms), and
its owner-probe delay was p95 0.162833 ms (maximum 21.245209 ms). These are
observed development-stress telemetry, not a display-latency measurement.

The [raw evidence archive](raw-evidence.tar.gz) has SHA-256
`3f7d9af8c579dd9f47aa5227b7438b9ee477c0a7e9cab6576eed63db4e875bc5`. It
contains the paired JSON, launch logs, and provenance only.

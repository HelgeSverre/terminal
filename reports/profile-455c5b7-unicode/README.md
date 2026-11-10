# Unicode after the shared reader

The five-second, 1 ms stack sample uses the production WMO executable from
`455c5b7`, SHA-256
`34798ae9dfbaab0e77a2c6feb042d2409c4a0ba5965e79f4ccabcd77b6a4e4c5`.
The real app processes a 512 MiB Unicode workload through its PTY. The app,
sampler, and owned child all exit cleanly. Commands, hashes, and lifecycle
checks are in `profile.json`; `sample.txt` is the raw sample.

The owner queue has 3,755 samples, partitioned without overlap:

| Work | Samples | Owner share |
| --- | ---: | ---: |
| Document printing and descendants | 2,832 | 75.4% |
| Remaining feed work | 829 | 22.1% |
| Snapshot publication | 61 | 1.6% |
| Other owner work | 33 | 0.9% |

The shared IO queue has 131 samples, including 110 in read handling. Most
main-thread samples are event-loop waiting. These queues run concurrently;
their sample counts cannot be added to estimate serial wall time.

Within owner printing, inclusive scalar printing has 1,921 samples, `setCell`
556, and dictionary operations 612. Explicit access begin/end frames and stubs
account for 316 samples, uniqueness checks 189, and retain/release 172. These
families overlap; they are attribution clues, not independent recoverable gains.
The sample includes specialized generic functions and does not establish a
failure to specialize Swift generics.

The next experiment should amortize repeated row mutation across a bounded
same-row transaction, including fresh cells and same-width cluster extensions.
It should retain the current payload representation and exact width algorithm.
The deferred result, continuation batching, and payload arena experiments were
held after measured regressions; this profile does not justify retrying them.

The sampler perturbs execution. `driver.json` is retained for provenance and
completion checks; its throughput and CPU values are diagnostic, not comparison
measurements. The separate three-app chart uses unsampled runs.

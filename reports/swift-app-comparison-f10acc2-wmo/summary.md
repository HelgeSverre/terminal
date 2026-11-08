# Fused WMO Swift app comparison: f10acc2

Frozen Swift `f10acc2` was compiled with `-O -whole-module-optimization` and
the same 2 MiB, three-sample, 100×30 Obel Mono 14 visible-app PTY contract as
the preceding 645 pilot. Exact commands and inputs are in
[build.json](build.json) and [input.sha256](input.sha256). The version 0.3
driver's default four workload labels were validated by the matched comparison.

| Median MiB/s | Swift 645 WMO | Swift f10 WMO | Change | Rust in f10 run | Swift f10 / Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII | 16.503557 | 16.610192 | +0.6% | 72.811999 | 22.81% |
| Long ASCII | 19.706569 | 20.119712 | +2.1% | 91.245038 | 22.05% |
| ANSI truecolor | 4.598653 | 10.320130 | +124.4% | 21.275464 | 48.51% |
| Unicode | 12.037678 | 12.124813 | +0.7% | 14.568871 | 83.22% |

The Rust values are the contemporary reference pilot, not values copied from
645. ANSI throughput is 2.244× the 645 result; the other changes are within
one to two percent. The at-least-90% replacement gate remains false for every
workload. This is optimization evidence, not replacement acceptance.

The scanner change byte-parses parameters and colon searches. It deliberately
rejects manufactured non-ASCII and oversized flat parameters while preserving
the keyboard `u` literal-field contract and valid colon SGR. Focused core,
semantic, and boundary gates passed, as did the source review, WMO core, and
native smoke. No claim is made that every new test passes on the frozen 645
baseline: the expected old difference includes a pre-existing overflow fix.

All benchmark apps exited naturally with no surviving children in
[comparison.json](comparison.json). `raw-evidence.tar.gz` retains the raw
driver and launcher evidence, core result, and native-smoke log; compact
measurement and provenance files remain beside this summary. The frozen bundle
is preserved outside the repository with executable hash
`d5771cd8167aa0f84a8ec66cab9dd5c5d934ba17caa99d4f7dcd8543a66b9181`.

This is a short local pilot under ordinary desktop activity. It measures source
output/backpressure and ordered parser barriers, not display latency, search,
or retained-history throughput.

# Fused WMO Swift app comparison: 9e5673a

Frozen Swift `9e5673a` was compiled with `-O -whole-module-optimization` and
the same 2 MiB, three-sample, 100×30 Obel Mono 14 visible-app PTY contract as
the prior fused WMO pilot. Exact commands and inputs are in
[build.json](build.json) and [input.sha256](input.sha256). The comparison uses
the version 0.3 driver, whose default four workload labels were independently
validated by the comparison run.

| Median MiB/s | Swift 03e WMO | Swift 9e WMO | Change | Rust in 9e run | Swift 9e / Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII | 8.803437 | 12.717226 | +44.46% | 69.177822 | 18.38% |
| Long ASCII | 11.437918 | 19.866694 | +73.69% | 89.051160 | 22.31% |
| ANSI truecolor | 4.136719 | 4.226998 | +2.18% | 21.528294 | 19.63% |
| Unicode | 9.660342 | 10.375381 | +7.40% | 15.331427 | 67.67% |

The Rust values are the contemporary reference pilot, not values carried from
03e. The 9e source improves every Swift workload against the 03e WMO pilot,
but the at-least-90% replacement gate remains false for every workload. This
is optimization evidence, not replacement acceptance.

The source-focused worker passed. The WMO core and native smoke also passed;
the compact native result is [native-smoke.json](native-smoke.json), while the
core result is retained in the raw archive. Each measured app exited naturally
with no surviving children in [comparison.json](comparison.json).

The 512 MiB long-ASCII stack profile passed with natural exits for its app and
sampler and no surviving children. Its wall and CPU values are diagnostic-only
because sampling perturbs the run. [profile-long-ascii/profile.json](profile-long-ascii/profile.json)
records its app, driver, runner, and raw-sample hashes.

`raw-evidence.tar.gz` retains raw driver and launcher evidence, the core test,
and the complete long-ASCII profile tree. Compact measurement and provenance
files remain beside this summary. The frozen bundle is preserved outside the
repository with executable hash
`9236b8f6f6465c485b1ba82df8c6b1c030f08a1280f3d9c4b2f83102075025b7`.

This is a short local pilot under ordinary desktop activity. It measures source
output/backpressure and ordered parser barriers, not display latency, search,
or retained-history throughput.

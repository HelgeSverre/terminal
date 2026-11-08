# Fused WMO Swift app comparison: 645f872

Frozen Swift `645f872` was compiled with `-O -whole-module-optimization` and
the same 2 MiB, three-sample, 100×30 Obel Mono 14 visible-app PTY contract as
the preceding 9e pilot. Exact commands and inputs are in
[build.json](build.json) and [input.sha256](input.sha256). The patch removes a
screen alias and redundant blank allocation, and intentionally corrects
viewport-clamp ordering; the retained index/history red-green logs exercise
that ordering regression.

| Median MiB/s | Swift 9e WMO | Swift 645 WMO | Change | Rust in 645 run | Swift 645 / Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII | 12.717226 | 16.503557 | +29.8% | 69.297668 | 23.82% |
| Long ASCII | 19.866694 | 19.706569 | -0.8% | 90.448625 | 21.79% |
| ANSI truecolor | 4.226998 | 4.598653 | +8.8% | 21.097492 | 21.80% |
| Unicode | 10.375381 | 12.037678 | +16.0% | 14.808562 | 81.29% |

The Rust values are the contemporary reference pilot, not values copied from
9e. The small long-ASCII change is pilot noise, while the other workloads
improve. The at-least-90% replacement gate remains false for all four
workloads. This is optimization evidence, not replacement acceptance.

The focused source gates and Astra review passed. The WMO core and native smoke
also passed; the compact native result is [native-smoke.json](native-smoke.json).
Every measured app exited naturally with no surviving children in
[comparison.json](comparison.json).

The 512 MiB ANSI profile passed with natural exits for its app and sampler and
no surviving children. Its wall and CPU values are diagnostic-only because
sampling perturbs the run. The owner queue contributed 3,833 samples. Its CSI
feed branch had 2,518 inclusive samples, including `applySGR` 641; the two
Foundation colon-string search branches had 327 and 288 samples. Parameter
handling had 625 samples, and validation had 607 in `Character.isNumber` and
splitting work. These counts overlap and must not be added or treated as
whole-app CPU shares. They identify ASCII control-syntax byte processing as the
next patch target; they do not establish a microprobe result.

[profile-ansi/profile.json](profile-ansi/profile.json) records the profile's
app, driver, runner, and raw-sample hashes. `raw-evidence.tar.gz` retains its
complete profile tree, raw driver and launcher evidence, core result, and
index/history red-green logs. Compact measurement and provenance files remain
beside this summary. The frozen bundle is preserved outside the repository with
executable hash
`6d5946a19d54c550b2b94bd4808199123711525a42c2d4b47a7f34f6f08df8a0`.

This is a short local pilot under ordinary desktop activity. It measures source
output/backpressure and ordered parser barriers, not display latency, search,
or retained-history throughput.

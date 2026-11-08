# Whole-module Swift app comparison

Frozen Swift `4ca285f` was compiled both with the existing incremental `-O`
recipe and with `-O -whole-module-optimization`. Source inputs, deployment
target, bundled assets and runtime settings stayed the same. WMO's input
manifest and exact commands are in [build-provenance.md](build-provenance.md).

Each app pilot uses the same compiled C driver, 100×30 cells, PTY pixels
900×630, Obel Mono 14, 2 MiB per workload and three samples. Apps run
sequentially in separate owned processes. Both variants use the real PTY,
with history excluded by the workload's alternate screen.

| Median MiB/s | Swift incremental | Swift WMO | Rust in WMO run | Swift WMO / Rust |
| --- | ---: | ---: | ---: | ---: |
| Short ASCII | 4.212610 | 7.873706 | 70.701358 | 11.14% |
| Long ASCII | 4.914222 | 9.938036 | 89.365505 | 11.12% |
| ANSI truecolor | 3.447212 | 3.787456 | 21.160886 | 17.90% |
| Unicode | 6.007738 | 9.071323 | 14.808124 | 61.26% |

The incremental and WMO columns come from separate short pilots; each ran
against the same Rust executable. The Rust column above is contemporaneous
with WMO. Raw reports preserve both reference runs, rather than substituting
one run's reference values into the other.

**The at-least-90% replacement gate remains false for every workload.**
WMO nearly doubles ASCII throughput here, but this is not replacement
acceptance. The incremental batching build was slightly slower than the
preceding `ca252d0` build; that regression is retained in the evidence.

| App bytes | Swift WMO | Rust |
| --- | ---: | ---: |
| Executable | 1,561,424 | 3,743,056 |
| Bundle regular files | 6,839,120 | 9,022,529 |

The full Swift WMO compile took 21.76 seconds on this Mac with existing SDK
caches. The earlier incremental compile took 5.77 seconds plus a 0.20-second
link after source changes; these scopes differ. No matched Rust/Swift
compilation-speed claim is made.

Focused ABI tests compiled under WMO and the actual WMO native GUI smoke
passed. The batching source also passed the focused document, Unicode,
semantic, boundary, viewport and snapshot tests; its new ABI cases passed
against the prior source as independent expected-behavior evidence.

`comparison.json` records measurement completion separately from the failed
performance gate. Every measured app exited naturally with no surviving
children. See [verification.json](verification.json),
[native-smoke.json](native-smoke.json), [swift.json](swift.json) and
[rust.json](rust.json). Source is preserved by checkpoint
`swift-experiment-20261108-4ca285f`.

The separate owned stack profile is diagnostic, not another timing sample.
It confirms specialized printing after WMO; cell replacement, reference
counting and per-scalar work remain. Parent and child sample counts are
inclusive and must not be added. A failed initial sampler invocation is
retained separately with its cleanup proof; it contributes no valid profile.

These are short local pilots under ordinary desktop activity, not the longer
repeated acceptance run. They measure source output/backpressure and parser
barriers, not display latency, search or retained-history throughput.

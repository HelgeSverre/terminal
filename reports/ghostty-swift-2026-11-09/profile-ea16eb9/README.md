# After the first parser changes

These profiles use a clean archive of `ea16eb9`, built with `just release-build`.
The signed executable SHA-256 is identical to the app in the preceding
`after-text-batching` comparison. The uncommitted settings preview is excluded.
Compiler flags and input hashes are in `build-provenance.json`; `source.json`
identifies the archived tree.

Each workload streams 512 MiB through the visible 100×30-cell app while
`sample` observes five seconds at a 1 ms interval. Profiles ran sequentially,
without concurrent builds or benchmarks. Each app, driver and sampler exited
naturally with no owned survivors. Raw call trees are compressed beside their
runner records. Profile driver timings are diagnostic: sampling perturbs them.

The Unicode owner spends most of its active samples in `feed`/`printBatch`,
including generated grapheme category lookup and cluster extension. Replacing
the binary category-range search with an exact indexed representation is the
next isolated text experiment. The official grapheme corpus and exhaustive
scalar category equivalence must pass before accepting it.

All three profiles also show main-thread work constructing accessibility/link
projections on each displayed snapshot. Unicode has 629 inclusive samples at
`AccessibilityProjection.init`, compared with 4,196 total main-thread samples;
these include nested link classification. An independent experiment reuses the
immutable whitespace set and handles its exact ASCII subset directly. It keeps
accessibility and link recognition enabled.

The separate instrumented short-ASCII run records 10×16 MiB. Per source MiB,
feeding takes 9.96 ms, owner pumping 10.41 ms, PTY reads 3.41 ms and snapshot
construction 0.16 ms. These intervals overlap: feeding is inside pumping, and
snapshot work is not an extra independent percentage. There are about 1,041
output events per MiB, averaging 1,023 bytes each. Reusing the 16 KiB read slab
is therefore a better initial experiment than snapshot caching for this
workload. Event boundaries, fairness and owned output copies must remain intact.

These findings select experiments; they do not establish their speedups.
The accepted whole-app throughput remains in `after-text-batching`.

```shell
just profile-app /path/to/clean/Terminal.app /tmp/new-unicode-profile unicode
just profile-app /path/to/clean/Terminal.app /tmp/new-ansi-profile ansi_truecolor
just profile-app /path/to/clean/Terminal.app /tmp/new-ascii-profile ascii_short_lines
just diagnose-stream /path/to/clean/Terminal.app /tmp/new-stream-diagnostic 16777216
```

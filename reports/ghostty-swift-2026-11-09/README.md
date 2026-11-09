# Swift terminal and Ghostty

Measured on 2026-11-09, Apple M2 Max, macOS 15.6, AC power. Ghostty was the
installed **1.4.0** release. Our app used whole-module optimization; the
[raw comparison](before-layout-cleanup-verified/comparison.json) records its
executable hash, the runner revision, configurations and individual samples.

## Visible-app throughput baseline

Each workload used ten 16 MiB samples at 100×30 cells, configured Obel Mono 14,
opaque background and an alternate screen. Two trials reversed the launch order.
Ranges below are the two trial medians, in MiB/s. The percentage uses matched
trial pairs, rather than independently choosing the fastest result from each app.

| Workload | Swift terminal | Ghostty 1.4.0 | Swift / Ghostty |
| --- | ---: | ---: | ---: |
| Short ASCII lines | 60.0–61.0 | 198.7–218.6 | 27.9–30.2% |
| Long ASCII lines | 74.0–78.3 | 182.0–202.3 | 38.7–40.7% |
| ANSI truecolor | 18.7–19.0 | 163.5–190.1 | 9.8–11.6% |
| Mixed Unicode | 12.4–12.7 | 168.2–179.5 | 7.1–7.4% |

This baseline is substantially slower in every workload. ANSI and Unicode have
the largest gaps. The active optimization work starts here; earlier Rust pilots
and isolated Swift parser results are different experiments.

Our bundle contained 8,131,016 bytes in regular files; Ghostty contained
67,296,342. This is bundle size, not installed disk allocation or runtime memory.
Ghostty denied process resource counters, so these runs cannot compare CPU or
memory usage across apps.

The driver waits for an ordered cursor-position reply after output. It measures
PTY processing and backpressure, including parser/snapshot work that blocks that
path. It does **not** measure displayed FPS, input-to-photon latency, SQL-history
performance or visual correctness. Both apps have the same cell grid; their
native cell sizes differ (our canvas 900×630 pixels, Ghostty 800×540). Font
settings match; independently verified resolved-font equality is not claimed.
Desktop load was not isolated. Reversed orders expose some variation, but two
trials are a pilot rather than a sustained ranking.

Both measured copies matched their recorded executable hashes and exited
naturally, with no owned child survivors. Earlier failed geometry/ownership
attempts elsewhere in this directory are diagnostics, not accepted trials.

## Feature coverage

There is no defensible overall feature-parity percentage. The everyday workflow
is covered, while protocol breadth and long-term validation differ.

| Area | This terminal | Ghostty 1.4.0 |
| --- | --- | --- |
| Windows, tabs, splits | Implemented; pane lifecycle and resize regressions | Supported |
| Search and retained text | Literal history search; bounded rows/bytes, selection and reflow tests | Supported; broader configurable UI |
| Text and color | Truecolor, Unicode 18 segmentation/width tables, bundled Obel Mono | Unicode/color support and OpenType font features |
| Ligatures | Disabled | Supported |
| Kitty graphics | Direct RGB/RGBA/PNG, chunks, zlib, image/placement IDs within explicit budgets | Complete graphics implementation, including animation and relative placements |
| Links, clipboard, keyboard | OSC 8 and detected URLs, OSC 52 policy, Kitty keyboard support | Supported; additional protocols and configuration |
| Shell integration | zsh prompt/cwd hooks; split inherits cwd | Automatic integration for bash, elvish, fish, nushell and zsh |
| Automation | AppleScript commands/settings and bounded read-only accessibility text | AppleScript windows/tabs/terminals; native accessibility |
| Platforms | Apple Silicon, macOS 15+ | macOS and Linux |

Our implementation evidence is in [the source map](../../docs/architecture.md),
[automation guide](../../docs/automation.md), [graphics implementation](../../Sources/Terminal/Emulation/KittyGraphics.swift)
and [replacement validation](../../docs/swift-port-parity.md). Source-level
coverage does not establish complete IME, VoiceOver, GPU recovery or multi-display
conformance. The current status document retains those limits.

Ghostty claims are drawn from its [1.4.0 release notes](https://ghostty.org/docs/install/release-notes/1-4-0),
[feature documentation](https://ghostty.org/docs/features),
[shell integration guide](https://ghostty.org/docs/features/shell-integration),
and [AppleScript guide](https://ghostty.org/docs/features/applescript).
The release notes are the version boundary; unreleased source features are not
counted as shipped.

## Reproduce

Run with no competing builds, profilers or other throughput tests:

```shell
just benchmark-ghostty reports/ghostty-comparison-next
```

This builds the release app, freezes copies, records provenance and runs both
orders. It refuses an existing report directory. See [benchmarking](../../docs/benchmarking.md)
for the separate history/SQL and display-smoothness tests.

## Layout and release-preflight check

The [post-cleanup comparison](after-layout-preflight/comparison.json) repeats the
same two orders at `2e8949b`, before signing/publication. Our trial medians were
58.8/58.8 MiB/s (short ASCII), 75.6/75.5 (long ASCII), 18.4/18.4 (ANSI), and
12.3/12.4 (Unicode). This check finds no substantial throughput loss from the
source layout and preflight changes. Small differences do not establish an
optimization or regression under varying desktop load. The table above remains
the initial optimization baseline; neither run includes the separate parser
prototypes. Exact executable identities and all reference samples are retained.

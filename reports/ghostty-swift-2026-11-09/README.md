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

## First parser/text optimization batch

The [development comparison](after-text-batching/comparison.json), at `0b7a6c0`,
uses the same settings and reversed orders. These changes are for 0.2.4;
released 0.2.3 remains the preflight baseline.

| Workload | 0.2.3 preflight | Optimized development | Ghostty in development trials |
| --- | ---: | ---: | ---: |
| Short ASCII | 58.8 | 57.1–59.0 | 209.0–244.0 |
| Long ASCII | 75.5–75.6 | 72.1–76.0 | 216.3–251.2 |
| ANSI truecolor | 18.4 | 31.0–31.1 | 177.8–183.0 |
| Unicode | 12.3–12.4 | 14.5–14.6 | 175.4–178.2 |

Values are trial medians in MiB/s. ANSI improves about 69% and mixed Unicode
about 18%; ASCII shows no clear improvement amid desktop/reference variation.
The headless prototype gains do not carry through in full. Ghostty remains
substantially faster, so comparable whole-app speed is still an open goal.
Both orders exit naturally without owned survivors. This batch replaces CSI
string accumulation, avoids unchanged screen copies for SGR, measures singleton
width without strings and batches narrowly admitted fresh Unicode row spans.
A separate payload-bit prototype had mixed timings and remains experimental.

## Profile-guided batch and approved settings

The [next app comparison](after-profile-batch/comparison.json) uses the same
contract at `d4788df`. It includes indexed Unicode category pages, reused
whitespace classification for visible links, owner-confined PTY read storage,
and the approved settings sidebar. The release-WMO app was built at `96c2eb7`;
the following `d4788df` commit adds only settings tests, their recipe/source
group and documentation. Its application source is identical.

| Workload | Swift terminal MiB/s | Ghostty MiB/s | Matched Swift / Ghostty |
| --- | ---: | ---: | ---: |
| Short ASCII | 38.7–59.9 | 100.5–135.3 | 28.6–59.6% |
| Long ASCII | 37.5–79.3 | 121.8–146.1 | 25.6–65.1% |
| ANSI truecolor | 24.8–31.8 | 106.1–119.4 | 20.8–29.9% |
| Unicode | 16.2–16.7 | 117.4–134.7 | 12.4–13.8% |

Ranges are the two reversed-order trial medians, not confidence intervals.
Desktop load varied markedly: system load averages rose from 6.72/5.36/5.49
to 8.89/6.66/5.99, and both apps differed from earlier measurements. The Mac
remained on AC power and reported no recorded thermal/performance warning.
The ASCII variation prevents a useful causal comparison with earlier app runs;
even matched ratios span a wide range. These trials confirm the remaining
performance gap, not its precise size or an app-level speedup for this batch.
All four app runs completed naturally with no owned survivors.

The independent, narrower experiments retain stronger evidence about their
specific changes: [Unicode lookup](../unicode-lookup-ea16eb9/README.md),
[visible links](../visible-link-classification-ea16eb9/README.md), and
[instrumented PTY reads](../pty-read-reuse-ea16eb9/README.md). The repeated read
diagnostic records its initially slower candidate as well as the subsequent
matched observations. Comparable Ghostty speed remains an open goal.

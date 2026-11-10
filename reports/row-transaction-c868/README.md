# Row transaction — held out of 0.2.4

This experiment is archived, not applied to the application. The release keeps
the tested shared-reader runtime from `455c5b7`. Further optimization is paused.

The prototype replaces separate ASCII/singleton batching with a bounded row
transaction over borrowed fixed slots. It preserves the existing text storage,
width rules, selection observations, revisions, and history charges. Both
versions pass exact ownership/parser comparisons, Unicode, selection, reflow,
capacity, and retained-snapshot checks.

V1 improves bulk Unicode by 35–44%, but regresses long ASCII by 6–8% in the
headless matrix. Disassembly identifies per-character payload checks that the
old ASCII span handled once. V2 moves that policy outside the loop; the checks
disappear, but long ASCII still regresses. This correction does not establish
the cause of the remaining loss.

The final candidate removes dead helpers, narrows the private return type, and
migrates the remaining direct helper test to the production print entry point.
It then runs against the unchanged app in baseline–candidate–candidate–baseline
order, ten 16 MiB samples per workload:

| Workload | Baseline medians, MiB/s | Candidate medians, MiB/s | Matched change |
| --- | ---: | ---: | ---: |
| Short ASCII | 107.50 / 104.41 | 109.51 / 108.73 | +1.9% / +4.1% |
| Long ASCII | 141.71 / 141.73 | 128.49 / 130.11 | −9.3% / −8.2% |
| ANSI | 47.44 / 47.22 | 50.08 / 49.89 | +5.6% / +5.7% |
| Unicode | 21.10 / 20.99 | 27.11 / 26.70 | +28.5% / +27.2% |

All four apps and owned children exit naturally. Correctness passes, but the
repeated long-ASCII regression prevents promotion. `app-comparison.json`
retains every sample, command, binary hash, grid, and lifecycle check.

The long-ASCII profiles and selected assembly are diagnostic evidence. The
merged ASCII scan/write loops have more stack reloads than the old specialized
loops. Sampled closure totals cover multiple program counters and do not
isolate the reloads' exact cost. No further correction was implemented.

`v1`, `v2`, and `final` retain patches, correctness evidence, fixtures, and
available raw headless samples. Patch SHA-256 values refer to decompressed
`*.patch.gz` contents. The final experimental app hash is
`0dfb0b5c84dbaceefca3830299c4ca251fb35cbbc8d227c60ac85a27f28fee8e`;
the unchanged release-development app hash is
`34798ae9dfbaab0e77a2c6feb042d2409c4a0ba5965e79f4ccabcd77b6a4e4c5`.

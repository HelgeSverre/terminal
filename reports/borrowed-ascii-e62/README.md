# Borrowed ASCII and the combined app gate

Long printable ASCII now borrows the feed buffer through the existing document
writer, after flushing earlier decoded text. The same document transactions own
segmentation, history enforcement, wide-cell repair and revisions. No pointer
escapes the synchronous feed call. A private out-of-line helper isolates the
specialized writer from the mixed-text scanner.

The first direct-writer variant improved ASCII but regressed 1,023-byte Unicode
by 3.9% in both candidate trials. It was held. The isolated-helper retry retained
8–11% ASCII gains with Unicode medians within −0.74% to +0.95% and ANSI within
−0.45% to −0.09%. Both complete observations are retained. This supports the
chosen function boundary, but does not prove a particular compiler-layout cause.

Correctness evidence includes 270 row/retention records and 337 parser records
identical to the scalar reference. Permanent emulator assertions compare the
bytewise path with larger chunks across Unicode prefixes, malformed UTF-8,
charsets, margins, insertion/wrapping, REP and history budgets.

The combined CSI-run and borrowed-ASCII build also matches all 62,918 grammar
records and 400 budget/offset/backpressure records. The integrated emulator and
15-case boundary suites pass. Independent source review approved both changes.

## Visible-app gate

Two frozen Swift WMO apps run baseline–candidate–candidate–baseline, ten 16 MiB
samples per workload, with the same 100×30 grid, configured Obel Mono 14, opaque
background and alternate screen. No competing builds or benchmarks run during
these observations. Desktop load is not laboratory-isolated.

| Workload | Baseline trial medians MiB/s | Combined candidate MiB/s | Matched changes |
| --- | ---: | ---: | ---: |
| Short ASCII | 61.13 / 60.19 | 64.61 / 64.34 | +5.7% / +6.9% |
| Long ASCII | 78.85 / 78.54 | 81.49 / 81.34 | +3.3% / +3.6% |
| ANSI truecolor | 31.80 / 31.78 | 33.29 / 33.09 | +4.7% / +4.2% |
| Unicode | 16.69 / 16.46 | 16.64 / 16.59 | −0.3% / +0.8% |

All four apps and owned children exit naturally without cleanup survivors.
The final source has comment-only cleanup after the frozen combined oracle
build; rebuilding produces the exact signed executable hash measured here.
`source.json` and both build provenance files record that identity.

These modest app gains support the batch. They do not establish comparable
Ghostty performance, displayed FPS or SQL-history behavior. `app-comparison.json`
contains all observations, commands, hashes and lifecycle checks. The retained
one-off `compare_pair.rb` uses the existing driver/report validators for two
Swift app bundles; it has no Rust replacement threshold.

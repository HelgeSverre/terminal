# Release throughput before and after the module split

Measured on 2026-11-14 to check that compiling the app as four modules
(`TerminalCore`, `TerminalSession`, `TerminalView` and the app) instead of
one compiler unit does not cost PTY throughput.

| | Baseline | Candidate |
| --- | --- | --- |
| Commit | `e229650` (one unit over every source) | `dbc36b0` (one unit per module); built before a rebase as `fae56c7`, with the same sources |
| Executable SHA-256 | `52e583a114c5e1c727ddf801e71a4b5e5ec19358e7510e1b096af6e821c707ef` | `b8f02ba7c3de84d5bb82304c1bbb2e8158a98471a489b0909309ba6a0f232043` |
| Executable size | 3,061,360 bytes | 3,256,496 bytes |

Both are `just release-build` bundles, copied before measuring. Method:
`just benchmark-apps`, 16 MiB per workload, 10 runs per workload, a 100 × 30
grid, once with each app measured first. Another process held one core busy
throughout, and the candidate-first pass has a wide spread.

Throughput is the median of 10 runs in MiB/s, with the lowest and highest run
in parentheses. The ratio is candidate median over baseline median.

| Order | Workload | Baseline (MiB/s) | Candidate (MiB/s) | Ratio |
| --- | --- | --- | --- | --- |
| baseline-first | ascii_short_lines | 238 (217–255) | 244 (204–252) | 1.03 |
| baseline-first | ascii_long_lines | 260 (243–291) | 270 (235–279) | 1.04 |
| baseline-first | ansi_truecolor | 203 (170–209) | 201 (188–207) | 0.99 |
| baseline-first | unicode | 135 (124–139) | 139 (137–144) | 1.04 |
| candidate-first | ascii_short_lines | 204 (119–242) | 252 (154–280) | 1.23 |
| candidate-first | ascii_long_lines | 210 (171–280) | 309 (240–330) | 1.47 |
| candidate-first | ansi_truecolor | 193 (172–204) | 193 (134–216) | 1.00 |
| candidate-first | unicode | 138 (134–139) | 141 (135–143) | 1.03 |

The candidate's median is within 1% of the baseline on truecolor output and
3% or more above it on the other three workloads, in both orders. The larger
ratios in the candidate-first pass sit inside that pass's spread and are not
evidence of a gain. The split shows no throughput loss.

The driver binary is not kept here; `comparison.json` records its hash.

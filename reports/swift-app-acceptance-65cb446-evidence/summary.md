# Exact 65cb446 both-order app evidence

Frozen `65cb446` passes the current 70% per-workload gate in both 16 MiB ×
ten-run orders. Raw Swift/Rust medians in MiB/s are:

| Order | Swift short/long/ANSI/Unicode | Rust short/long/ANSI/Unicode | Ratios |
| --- | --- | --- | --- |
| Rust first | 64.258/81.590/19.242/12.821 | 68.797/84.713/21.320/14.769 | 93.40/96.31/90.25/86.81% |
| Swift first | 62.020/80.585/19.133/12.737 | 68.206/88.266/20.678/14.489 | 90.93/91.30/92.53/87.91% |

The Swift executable is 1,998,656 bytes versus Rust 3,744,784; regular bundle
files total 7,278,796 versus 9,024,636 bytes. This measures alternate-screen
PTY parser barriers, not render latency. It is source-scoped evidence only:
prior `88aa5ef` ANSI gate failures at 69.1% and 69.89% remain preserved,
full-SQL evidence is separate, and final validation remains pending; no
replacement or full-spec claim follows. The 35.6-second Swift build wall time
is unmatched provenance, not a Swift/Rust compile-speed ratio.

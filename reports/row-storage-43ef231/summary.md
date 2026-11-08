# Row-storage compatibility and fused WMO evidence

The row-storage probes separate behavior compatibility from storage-accounting
changes. The initial `11d032f` compatibility run fails at record 18 because a
row charge changes from 97 to 673. The capacity-only hypothesis is rejected.
The 645 control passes 270 records. The cap-only `2497b1d` variant fails at
record 25 (223 versus 799); `0b1fc5b` and `a153edd` both pass 270 records with
explicit history-byte accounting. Raw fixtures, source copies, runner inputs,
compiler data, and probe binaries are retained in `raw-evidence.tar.gz`.

The 9106 matched pilot is negative evidence: Swift is 14.15/16.81/9.17/8.94
MiB/s versus Rust 70.25/90.79/21.21/14.57, below the best f10 pilot. The final
43 pilot measures Swift 38.26/43.76/12.84/11.04 versus Rust
64.72/84.78/20.61/13.97 MiB/s. Its ratios are 59.11/51.61/62.32/79.02%; all
remain below the mandatory 70% per-workload target, although Unicode clears
neither the overall gate nor the 80% stretch target.

`policy-70-percent.json` is a separate reassessment of the immutable 43
comparison. The original comparison remains unchanged with its historical
90% gate. Both 43 long-ASCII and Unicode profiles exited naturally with their
apps, samplers, and descendants reaped; their raw trees are archived only.

This evidence does not change the Rust runtime. The stable Rust source snapshot
is available at `archive/rust-2026-11-08` (commit `c8f279b`).

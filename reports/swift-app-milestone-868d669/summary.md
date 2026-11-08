# Source-scoped 868 acceptance milestone

Frozen `868d669` passes the current 70% per-workload acceptance gate in both
16 MiB × ten-run app orders. Rust-first ratios are 81.90%, 76.85%, 86.05%, and
77.91%; Swift-first ratios are 82.44%, 78.57%, 84.41%, and 78.68%.
Diagnostics were disabled for these normal app runs, and every owned app exited
naturally with descendants reaped.

This is a source-scoped milestone only. Search integration remains unmerged and
must be validated on the final source; this is not a Rust promotion or full
specification completion. The failed 1896 acceptance reports remain preserved.

The opt-in stream diagnostic reports 57.70 and 58.46 MiB/s for the same app's
short workload, about 1,040 events/MiB with mean event size near 1 KiB, no
suspends, and stable work/MiB. It does not establish that CR ownership work
caused the whole gain; the earlier 1896 slowdown remains unexplained. The CR
fixture retains corrected Z, box-line, and T cases. Raw fixtures, source
manifests, paired driver validation, stream reports, and ownership evidence are
in `raw-evidence.tar.gz`.

# Frozen d934 failure and 1a recovery pilots

The frozen `d934705` pilot is retained as negative evidence. Its Swift/Rust
ratios are 35.61%, 31.56%, 35.62%, and 40.46%, so it fails the current 70%
per-workload policy. Its clean long-ASCII profile is diagnostic-only.

The current best frozen `1a7373e` pilot reaches 39.07/47.13/12.67/10.87
MiB/s for short ASCII, long ASCII, ANSI, and Unicode. Its ratios are
55.00%, 53.01%, 59.52%, and 74.72%. Unicode clears 70%, but the overall gate
remains false; these short pilots are not acceptance.

Both raw archives retain driver, launcher, build, core, and native evidence.
The unmeasured bulk-buffer candidate is intentionally excluded.

# Row reuse checkpoint: sustained acceptance remains failed

The 2 MiB × three-run pilot reaches 76.4%, 80.3%, 82.6%, and 81.0% of Rust
for short ASCII, long ASCII, ANSI, and Unicode. It is diagnostic evidence only.

Both controlling 16 MiB × ten-run acceptance orders fail the mandatory 70%
per-workload policy. Rust-first ratios are 48.6%, 41.5%, 63.5%, and 82.4%;
Swift-first ratios are 51.7%, 69.8%, 84.3%, and 77.7%. Therefore the Swift
replacement is not accepted. The small ten-run diagnostic shows
82.9/101.5/80.1/84.5%, but its varying Rust baseline is retained separately and
must not be spliced into a speedup claim.

The row-reuse compatibility fixture preserves the activation control: old 046
exits 3 with all cases false; new 1896 exits 0 with all true, including actual
single-wrap, LF, and RI behavior. Native, core, and ownership checks pass. The
sustained short-ASCII profile passed cleanly but is diagnostic-only. Raw inputs,
fixtures, source copies, reports, and binaries are in `raw-evidence.tar.gz`.

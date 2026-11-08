# Optimized Swift vs Rust backend replay

Three alternating paired 8 MiB samples per workload, after warmup, on the same
M2 Max. Geometry is 160×50, history is disabled, and feed chunks are 64 KiB.
Payload/reply byte counts and hashes match; canonical final snapshots match.

| Metric | Rust | Swift |
| --- | ---: | ---: |
| ASCII median throughput | 39.60 MiB/s | 2.53 MiB/s |
| Mixed-text median throughput | 22.06 MiB/s | 1.28 MiB/s |
| Backend executable bytes | 2,438,272 | 600,400 |

Swift is frozen at `6c601d1`, including document-owned ASCII placement. Rust
reuses the verified `b5a9fea` archived executable; the retained source audit
confirms no Rust backend changes through main `a49a5af`.

These are bounded headless replay results, not full-app UI, bundle-size or
matched compilation measurements. Ordinary desktop background load was present
and is recorded in result.json. The Rust build timing in the raw provenance is
historical; it was not rebuilt for these timed samples.

See [result.json](result.json) for every sample and both gates.
[raw-evidence.tar.gz](raw-evidence.tar.gz) preserves the complete original report,
including all raw final snapshots, logs, source/input hashes and build provenance.

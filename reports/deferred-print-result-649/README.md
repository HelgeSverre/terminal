# Deferred typed print result — HOLD after bounded matrix

Archived patch: `print-effect.patch.gz`. Recorded patch hashes refer to the decompressed bytes.
The private-workspace commands and paths below document the experiment; this
record retains its fixture, raw samples, source hashes, and results.

Baseline 649083cde98fc2f4c8cd2e65104d4f1ebcb601f8, isolated archive; no live changes. DESIGN.md explains source/profile evidence and ownership invariants.

PrintEffect now carries one optional PrintedGrapheme with scalar-or-cluster content and nonoptional repeat attributes. Fresh scalar/span producers defer String materialization until apply; combining extensions retain owned combined text and previous-cell attributes. Existing assignment sites, cap/ignore behavior and mutation/history counts are unchanged. All callers/tests migrated, no old-field compatibility aliases. Borrowed attributes are explicitly copied into the owned result.

Both baseline and candidate full ownership/emulator suites pass. Exact 1,652-line direct-document trace (63 scenarios) and 54 emulator REP snapshot/reply traces match byte-for-byte. Source test additions are identical except access to the migrated result interface. Tests cover retained snapshots, IDs/revisions/charges, fresh and extended graphemes, prepend, VS/ZWJ, cap/ignored scalars, widths, batching and changed attributes before REP. checks.json and *.out/err retain outcomes. A new-test escaping/type compile typo was corrected equally in both variants; candidate borrowed-value diagnostics were resolved with explicit copy, without relaxing assertions.

Reproduce: ruby checks.rb, then during an exclusive timing window ruby timing.rb and ruby summarize.rb. Build flags/inputs in *command.json: Swift5 -O -whole-module-optimization arm64-apple-macosx15.0, same module/cache/frameworks. Bench is four fixture families, chunks1/1023/4096, seven samples in B-C-C-B order (14 per variant), headless feed only.

Candidate bench 1,081,776 bytes vs baseline 1,062,240 (+19,536). Compile times 19.730/19.736 seconds are sequential/cache-order-dependent and do not establish equal build cost. All compiler and correctness children exited naturally before timing authorization.

Patch: print-effect.patch SHA256 3d4a8d3e1991cc2f76c54ef2640d4d9996f7bbdb0051d774e6518116487c4e3e. Exact source hashes in source-hashes.json. Root alone owns integration; do not promote without measured results.

## Measured decision: HOLD

One quiet B-C-C-B matrix completed naturally; all children exited and the slot was handed directly to the IO worker. No additional variants or timings. No material Unicode gain, with repeatable-looking cluster/ASCII regressions in this matrix; do not promote this implementation merely for interface cleanup. The experiment does not isolate enum layout/ARC/codegen as the cause, though the 19,536-byte binary increase makes that a plausible cost.

| Fixture | Baseline ms | Candidate ms | Speedup |
|---|---:|---:|---:|
| ansi chunk=1 | 72.204 | 71.771 | 1.0060x |
| ansi chunk=1023 | 19.163 | 19.565 | 0.9795x |
| ansi chunk=4096 | 19.214 | 19.570 | 0.9818x |
| ascii chunk=1 | 79.340 | 79.457 | 0.9985x |
| ascii chunk=1023 | 14.156 | 14.783 | 0.9576x |
| ascii chunk=4096 | 14.223 | 14.622 | 0.9727x |
| clusters chunk=1 | 97.794 | 102.240 | 0.9565x |
| clusters chunk=1023 | 57.924 | 60.814 | 0.9525x |
| clusters chunk=4096 | 58.776 | 61.278 | 0.9592x |
| unicode chunk=1 | 128.354 | 130.681 | 0.9822x |
| unicode chunk=1023 | 29.130 | 29.007 | 1.0043x |
| unicode chunk=4096 | 28.920 | 29.314 | 0.9866x |

All 14 samples per variant/fixture are retained in timing-summary.json and raw timing-*.out. Results are headless feed measurements, not GUI claims. Existing bulk UTF-8 experiments are distinct and remain archived.

# Indexed payload arena — HOLD — archived

Archived patch: `payload-arena.patch.gz`. Recorded patch hashes refer to the decompressed bytes.
The private-workspace commands and paths below document the experiment; this
record retains its fixture, raw samples, source hashes, and results.

Frozen baseline 649083cde98fc2f4c8cd2e65104d4f1ebcb601f8. One scratch candidate; no live edits. See DESIGN.md for ownership, complexity, actual allocation accounting and conservative planning bounds. Production changes: TerminalDocument.swift and necessary DocumentReflow.swift resource query. No annotation/threshold variants.

All baseline/candidate full ownership, emulator, reflow and strict Unicode suites pass. New tests exercise hole reuse/fragmentation, copied-cell nonaliasing, shifts, >65,535 live payloads, retained snapshots, cleared String charges, kept empty capacity, all 4096 far-column extents and dense payload counts, and fragmented source/output reservation accounting. Exact movement, document effect/row and 216 emulator transport traces match byte-for-byte. Public logical history charges are unchanged; physical resource costs and budget admission can differ because representation changes.

Baseline-only test adapter exposes its old sparseCells*384 planning formula to the same assertions; no baseline production changes. Candidate permanent tests use the new production cost query. Existing reflow tests also cover process-budget rejection, cancellation, pressure and deferred resource release. Both Unicode suites pass all 853 segmentation cases and 1,114,112 category values.

Build commands are saved in *command.json: Swift 5, -O -whole-module-optimization, arm64-apple-macosx15.0, identical module/framework flags. Root correctness compilation could overlap; compile timings are recorded but do not support a build-speed comparison. Candidate bench 1,083,744 vs baseline 1,062,240 bytes (+21,504; +2.02%). All compiler/test children exited naturally before timing authorization.

Reproduce: ruby checks.rb. During an exclusive quiet slot: ruby timing.rb then ruby summarize.rb. Fixed B-C-C-B matrix, seven samples per executable/fixture/round (14 per variant), four workloads, chunks 1/1023/4096. Headless feed only; no GUI claim.

Patch payload-arena.patch SHA256 148344c70becaa6ca75c791c68ca910510b2d3a6d7db35206698af0be9bab990. Exact candidate source hashes are in source-hashes.json. Root alone owns integration; do not promote without measurements and review.

A final test-only strengthening explicitly checks that empty kept-capacity buffers remain charged. Both ownership executables were rebuilt and passed with identical traces; benchmark binaries and production sources stayed unchanged. test-strengthening.json records the exact source hash delta.

## Measured decision: HOLD

One quiet B-C-C-B matrix completed naturally; all children exited and slot returned to root for GUI/three-app gates. Clusters improve modestly in both orders, but ASCII bytewise and ANSI1023 regress in both orders; fresh Unicode is flat. Do not promote: the gain does not justify the representation/planner complexity, +21,504-byte binary, sparse far-column memory cost and regressions. No additional variants or timings. This experiment does not identify the new limiting operation without a new profile, and makes no GUI throughput claim.

| Fixture | Baseline ms | Candidate ms | Median speedup | First / reverse order |
|---|---:|---:|---:|---:|
| ansi chunk=1 | 70.778 | 71.994 | 0.9831x | 0.9747 / 1.0001x |
| ansi chunk=1023 | 18.885 | 19.166 | 0.9854x | 0.9830 / 0.9876x |
| ansi chunk=4096 | 19.050 | 18.880 | 1.0090x | 0.9730 / 1.0260x |
| ascii chunk=1 | 78.196 | 79.676 | 0.9814x | 0.9852 / 0.9777x |
| ascii chunk=1023 | 14.116 | 14.154 | 0.9974x | 0.9654 / 1.0027x |
| ascii chunk=4096 | 14.018 | 14.129 | 0.9921x | 0.9790 / 1.0098x |
| clusters chunk=1 | 96.534 | 94.866 | 1.0176x | 1.0138 / 1.0176x |
| clusters chunk=1023 | 57.473 | 56.542 | 1.0165x | 1.0125 / 1.0085x |
| clusters chunk=4096 | 57.320 | 55.595 | 1.0310x | 1.0255 / 1.0351x |
| unicode chunk=1 | 126.602 | 127.192 | 0.9954x | 0.9926 / 0.9980x |
| unicode chunk=1023 | 28.642 | 28.620 | 1.0008x | 0.9979 / 1.0066x |
| unicode chunk=4096 | 28.368 | 28.485 | 0.9959x | 0.9928 / 1.0030x |

All 14 samples per variant/fixture, order ratios and outcomes are in results.json; raw timing-*.out, exact compiler commands and artifact hashes are retained.

# Same-owner continuation batch — HOLD — archived

Archived patch: `continuation-run.patch.gz`. Recorded patch hashes refer to the decompressed bytes.
The private-workspace commands and paths below document the experiment; this
record retains its fixture, raw samples, source hashes, and results.

One isolated candidate against 649083cde98fc2f4c8cd2e65104d4f1ebcb601f8, no live edits. Admission/proof and resource bounds: DESIGN.md. Production changes only TerminalDocument.swift; unchanged PrintEffect/Emulator/width/payload interfaces. No annotation or threshold variants.

Both baseline/candidate full ownership and emulator suites pass. New 8,114 document partition scenarios compare batches against scalar transactions and emit byte-identical baseline/candidate traces, including consumed scalars, mutation/history counts, result attributes, row IDs/revisions/cells/storage charges, cursor/wrap, selection observations and retained snapshots. All 853 corpus inputs plus each internal cut and contextual suffixes are included. 216 emulator transport scenarios emit exact offered/consumed bytes, stable snapshots and replies. Existing emulator coverage includes REP budget backpressure. Both strict Unicode18 suites pass 853 boundaries and 1,114,112 category comparisons. No assertion changes between variants or production test flags. checks.json and executable logs retain results.

Trace files are intentionally verbose (~145 MiB per document version) and compared by cmp without loading both into memory. Test sources are byte-identical baseline/candidate. Future segmentation state is tested through appended combining/ZWJ/emoji/RI suffixes, not exposed as a production diagnostic API.

Build commands in *command.json: Swift 5 -O -whole-module-optimization arm64-apple-macosx15.0, same module and frameworks. Build/test processes overlapped IO worker's correctness compilation by permission; no build-speed claim. Candidate bench 1,079,568 vs baseline 1,062,240 bytes (+17,328). All compiler/test children exited naturally before quiet timing.

Reproduce ruby checks.rb; when machine is exclusively available, ruby timing.rb then ruby summarize.rb. Matrix is fixed B-C-C-B, seven samples/version/round, four workloads and chunks 1/1023/4096; headless feed only.

Patch continuation-run.patch SHA256 093df7abda91eaddb9e51dac14469034a576a78860c4e8bc2c76b71e226416eb. source-hashes.json records exact candidate sources. Root alone owns integration; measurement remains required.

## Measured result

One quiet B-C-C-B matrix completed naturally; all children exited and slot returned directly to root for app/SQL gates. No extra variants or timing runs. Bulk cluster throughput improved in both orders, but bytewise clusters regressed in both orders. Fresh Unicode is flat/mixed. Root decision: HOLD and stop; the small mixed gain does not justify added production complexity, the bytewise regression, and +17,328-byte binary cost. This does not demonstrate real-app gain.

| Fixture | Baseline ms | Candidate ms | Median speedup | First / reverse order |
|---|---:|---:|---:|---:|
| ansi chunk=1 | 72.310 | 72.886 | 0.9921x | 0.9838 / 0.9995x |
| ansi chunk=1023 | 19.852 | 19.464 | 1.0199x | 0.9935 / 1.0431x |
| ansi chunk=4096 | 19.502 | 19.348 | 1.0080x | 0.9891 / 1.0423x |
| ascii chunk=1 | 80.103 | 80.184 | 0.9990x | 0.9919 / 1.0079x |
| ascii chunk=1023 | 14.794 | 14.296 | 1.0348x | 0.9954 / 1.0927x |
| ascii chunk=4096 | 14.628 | 14.594 | 1.0024x | 0.9999 / 1.0186x |
| clusters chunk=1 | 98.970 | 100.384 | 0.9859x | 0.9925 / 0.9823x |
| clusters chunk=1023 | 59.610 | 56.986 | 1.0460x | 1.0374 / 1.0518x |
| clusters chunk=4096 | 58.888 | 56.886 | 1.0352x | 1.0477 / 1.0313x |
| unicode chunk=1 | 129.202 | 129.428 | 0.9983x | 1.0003 / 0.9970x |
| unicode chunk=1023 | 29.022 | 29.034 | 0.9996x | 0.9994 / 1.0036x |
| unicode chunk=4096 | 29.014 | 29.350 | 0.9885x | 1.0050 / 0.9737x |

All samples and pair-order summaries are in results.json. Raw timing-*.out and exact commands are retained. Artifact/source hashes record the frozen candidate; prior rejected prototypes remain separate.

# CSI compatibility after text batching

The [frozen-ref comparison](comparison.json) compiles the same corpus against
released `v0.2.3` (`2e8949b`) and development `0b7a6c0`. All 62,918 canonical
snapshot/reply records match by SHA256 and exact bytes on this Mac.

The corpus covers malformed numeric syntax, colon SGR, keyboard flags, high
bytes, 16 KiB sequence limits, final opcodes, and chunk partitions. Both builds
use whole-module optimization. Exact inputs, flags, compiler and executable
hashes are retained. This proves compatibility for the corpus, not complete VT
conformance or display correctness.

```shell
just compare-csi v0.2.3 HEAD reports/csi-comparison-next
```

The ordinary optimized width, official Unicode 18 corpus, document ownership,
emulator, semantic/boundary, reflow, selection and prompt-clear suites also pass
locally for this batch. Source-level reviewers found no correctness issue.
Full current-head CI remains a separate gate.

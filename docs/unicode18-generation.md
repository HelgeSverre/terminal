# Unicode 18 pinning

The canonical generator inputs are committed under `tools/unicode`:
`grapheme-ranges-18.0.0.txt`, `terminal-width-18.0.0.json`, and the official
`GraphemeBreakTest-18.0.0.txt` corpus. Generators and the corpus runner validate
their frozen SHA-256 checksums. `tools/unicode/unicode18-inputs.json` records
the original upstream-source hashes and the neutral inputs' hashes and sizes.
See [the Unicode data guide](../tools/unicode/README.md) for provenance,
licenses and regeneration commands. No Rust workspace or Cargo cache is needed.

Run the verifier with:

```sh
just swift-unicode18-corpus
just terminal-width
```

The corpus runner reports every mismatch count and first mismatch. Generated
GCB/Extended_Pictographic/InCB-Consonant ranges plus the pinned InCB linker
set are emitted into Swift. The mandatory recipe passes `--strict` to enforce
the 853-case official fixture as a hard gate.

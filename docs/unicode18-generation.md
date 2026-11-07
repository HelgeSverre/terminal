# Unicode 18 pinning

The canonical grapheme source is the vendored `unicode-segmentation` table
source at the revision recorded in `vendor/README.md`. The official fixture is
`crates/terminal-core/tests/fixtures/GraphemeBreakTest-18.0.0.txt`, checked by
SHA-256 in `SwiftUnicode18Tables.swift`.

Run the verifier with:

```sh
xcrun swift native/SwiftUnicode18Tables.swift tools/GenerateUnicode18.swift
xcrun swift native/SwiftUnicode.swift native/SwiftUnicode18Tables.swift native/tests/SwiftUnicode18CorpusTests.swift .
```

The corpus runner reports every mismatch count and first mismatch. It is
currently report-only because `SwiftUnicode` is a compact classifier; the
complete generated range tables from vendored `tables.rs` have not yet been
emitted into Swift. `completeGeneratedRanges` must remain false until the full
fixture reports zero mismatches, after which the runner becomes a hard gate.
